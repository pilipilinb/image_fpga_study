# Sobel 算子实现计划

## 需求确认
- 灰度 8bit 输入，行缓存端直接复用 `line_buffer/pad_verison/line_buffer_3x3_pad.v`（输出 H×W 全尺寸窗口，w22 为中心，replicate padding）
- 幅值估算：Alpha-Max-Beta-Min，α=1、β=0.5，即 `mag = max(|Gx|,|Gy|) + (min(|Gx|,|Gy|) >> 1)`
- 输出形式（已确认）：双输出 `o_mag[7:0]`（幅值，右移 2 位 + 饱和）+ `o_edge[7:0]`（阈值二值化，0/255，阈值可配输入）
- **Gx/Gy 全程零乘法器**：系数只有 0/±1/±2，×2 用左移 1 位（p<<1），×1 直接连线，×0 直接不接——纯加法/减法/移位实现
- 所有产物（含计划文档）存到 `d:/FPGA_proj/image_fpga_test/sobel/`

## 算法与数学推导（先算后写）

### Gx/Gy 定义与零乘法器展开
Sobel 核（中心 w22 = 当前像素，p00=w11 左上 … p22=w33 右下）：
- Gx = (w13 + 2·w23 + w33) − (w11 + 2·w21 + w31)   —— 垂直边缘（左右列加权差）
- Gy = (w31 + 2·w32 + w33) − (w11 + 2·w12 + w13)   —— 水平边缘（上下行加权差）

零乘法器展开（2·p = p<<1）：
- Gx = (w13 + (w23<<1) + w33) − (w11 + (w21<<1) + w31)
- Gy = (w31 + (w32<<1) + w33) − (w11 + (w12<<1) + w13)
- 级1 拆两路加法树：正项和 A（3 个加数，其中 1 个来自移位）与负项和 B，Gx = A − B（signed）
- 硬件代价：每路 3 输入加法树 2 层（第1层 2 个加数，第2层累加）+ 1 个减法，只有加减与 `<<1` 连线，0 个乘法器 0 个 DSP

### 位宽推导（逐级表格，写代码前定死）
| 信号 | 表达式 | 最大值 | 位宽 | 说明 |
|------|--------|--------|------|------|
| 输入像素 | w | 255 | 8bit 无符号 | 行缓存输出 |
| 单侧和 A/B | w + 2w + w | 1020 | [10:0] 无符号 | 2·255+255=1020 < 1024 |
| Gx/Gy | A − B | ±1020 | signed [10:0]（11bit） | 范围 [-1024,1023] 安全 |
| \|Gx\|,\|Gy\| | 取绝对值 | 1020 | [10:0] 无符号 | 11111111 满幅也不溢出（仅 -1024 才溢出，实际最大 ±1020） |
| mag | max + (min>>1) | 1530 | [11:0]（12bit） | 1020 + 510 = 1530 < 2048 |
| 移后幅值 | mag >> 2 | 382 | 9bit | 触发饱和 |
| o_mag | sat8 | 255 | 8bit 无符号 | 382 → 钳到 255 |
| o_edge | 阈值比较 | 0/255 | 8bit 无符号 | (mag>>2) > thresh ? 255 : 0 |

### AMBM 精度与饱和策略
- 精确幅值 = sqrt(Gx² + Gy²)，AMBM = M + m/2（M=max, m=min）。令 r = m/M：
- 相对误差率 = (1 + 0.5r)/sqrt(1 + r²) − 1；r=0（纯水平/垂直边）误差 0，r=1（45° 对角）误差约 +6.07%，中间最差约 +6.5%
- 结论写在 README：AMBM 最大偏高 ~6.5%，即幅值如实引用无偏置，FPGA 用 AMBM 换掉开方器（开方在 FPGA 要么用 IP 要么迭代器，代价高）
- `>>2` 再做饱和（而不是先饱和再移位）：mag 最大 1530>>2=382 → 饱和 255，保留一般边缘（如 100 级差 → 400>>2=100）的灰度区分度
- 定点细节：min>>1 是整数右移（截断），max + (min>>1) 整数加法；参考模型必须用同一截断顺序，否则边界差 1

## 新建文件（sobel/ 目录）

### 1. sobel_3x3_8b.v —— Sobel 核（LAT=3，0 DSP，约 80~100 行）

接口：
- 输入：clk、rst_n（异步低有效）、`p00..p22`（9×8bit 窗口）、valid_in、`thresh[7:0]`（可配，慢信号不打拍）
- 输出：`o_mag[7:0]`、`o_edge[7:0]`、valid_out（与数据同拍）

三级流水（valid 链 3bit 对齐，沿工程铁律）：
- **级1（组合→寄存）**：两路差分。`sumR = p02 + (p12<<1) + p22`、`sumL = p00 + (p10<<1) + p20`、`gx  = $signed(sumR) - $signed(sumL)`（11bit signed）；同理 `sumB = p20 + (p21<<1) + p22`、`sumT = p00 + (p01<<1) + p02`、`gy`。沿 clk 寄存 gx/gy
- **级2（组合→寄存）**：`ax = gx[10] ? ~gx+1 : gx`（取绝对值，11bit）、`ay` 同理；`M = (ax>=ay)?ax:ay`、`m = (ax>=ay)?ay:ax`（共用 1 个比较器出两路）；`mag = M + (m>>1)`（12bit）。沿 clk 寄存 mag
- **级3（组合→寄存）**：`m8 = mag[11:2]`（右移 2 位）；`o_mag_tmp = (m8 > 255) ? 255 : m8`（饱和）；`o_edge_tmp = (m8 > thresh) ? 255 : 0`。沿 clk 寄存 → o_mag/o_edge
- 复位：所有流水寄存异步复位；BRAM 数组不可复位规则不涉及本核（行缓存里已有）
- 资源预估：0 DSP、0 BRAM（纯 LUT），比较器 3 个（1 个 max/min + 2 个饱和/阈值，阈值比较器可用 LUT 实现）

### 2. top_sobel.v —— 顶层
- `include "line_buffer_3x3_pad.v"` + `include "sobel_3x3_8b.v"`
- 例化 pad 行缓存（DW=8，IMG_W/IMG_H/AW 参数化，AW = $clog2(IMG_W)+1）→ 窗口 9 线接 sobel 核（p00=w11 左上 … p22=w33 右下），matrix_valid 接 valid_in，thresh 透传
- 接口：`din[7:0]/din_valid → o_mag[7:0]/o_edge[7:0]/o_valid`
- 全链路延迟：din → 窗口 4 拍（pad 行缓存）+ 核 3 拍 = 7 拍，TB 不手算对齐，按 valid 计数

### 3. tb_sobel.v —— 自检 TB（流程参考 tb_median_filter.v）

- 头部 `include "top_sobel.v"`；$dumpfile/$dumpvars 生成 `tb_sobel.vcd`
- 宏配置（同 MedianFilter 风格）：`-DSMALL` 4×3 小图（input_4x3.hex）；默认 112×103 真实图（input.hex）；输入 hex 文件复制进 sobel/ 目录（工程惯例：子系统自包含，不跨目录引用）
- **灰度化（review 修正）**：输入是 RGB888，TB 用 BT.601 定点转灰度 `Y = (77R + 150G + 29B) >> 8`，din 喂 Y——比直接取 G 通道专业，面试可讲"灰度化 + Sobel"完整链路；参考模型用同一函数对同像素求 Y，保证同源
- 参考模型（Verilog function，与 RTL 逐位全等的整数运算协议）：
  1. 输出坐标 (r,c)（0-based，全图 H×W，无 crop 偏移）从原图取 3×3 邻域；越界按 replicate 处理：r<0→行0、r≥H→行H-1、c<0→列0、c≥W→列W-1（与 pad 行缓存的复制规则一致）
  2. 每像素先 BT.601 转灰度（同上）
  3. gx = (p02 + (p12<<1) + p22) − (p00 + (p10<<1) + p20)，gy 同理（11bit signed）
  4. ax/ay 取绝对值 → M/m → mag = M + (m>>1)（12bit）
  5. exp_mag = min(mag>>2, 255)；exp_edge = (mag>>2) > thresh ? 255 : 0
  - 全等比对 o_mag 与 o_edge，任何一步截断顺序不一致都会在边界差 1，全等通过即截断协议一致
- 两帧激励与阈值：帧0 真实图（thresh=64，出边缘图）；帧1 纯色 0x80（thresh=48）——纯色帧梯度必须全 0（mag=0/edge=0，零梯度不变性），同时用不同阈值验证阈值可配
- **激励时序（pad 版硬性要求，crop 版 TB 没有）**：行末 din_valid 拉低 ≥1 拍（h-blank，rflush 插入窗口）；帧末拉低 ≥ IMG_W+8 拍（v-blank，bflush 整行回放）；行间用随机气泡 `repeat(1 + {$random}%3)` 验证空拍容忍
- 记分板：EXP_CNT = IMG_W×IMG_H×2（pad 版每像素一窗口，窗口 k 对应坐标 (k/IMG_W, k%IMG_W)）；o_valid 每个拉高拍比对两路输出；错误打印前 10 条（含坐标/期望/实际）；第一帧幅值写 `output.coe`（16 进制灰度）；结束打印 [PASS]/[FAIL] + out_cnt/err_cnt；超时兜底 `#(IN_TOTAL*60 + 1_000_000)`

### 4. verify_sobel.py —— 独立验证（参考 MedianFilter/verify_grid.py 风格）
- 读 original 图像（G 通道或 BT.601 同款灰度）+ output.coe
- numpy 整数重算（完全相同的移位/截断/饱和规则）：replicate pad → 灰度 → Gx/Gy → AMBM → sat8
- 统计：全等错误数（期望 0）、逐像素差分布直方图、PSNR
- 生成对比图 `sobel_compare.png`：原图灰度 / RTL 幅值 / 边缘二值，三张并排（工程惯例：明确的前后对比）

### 5. 文档（sobel 实现计划.md + README.md，均存 sobel/）
- **sobel 实现计划.md**：需求、Gx/Gy 零乘法器展开推导、位宽推导表、AMBM 公式与误差分析、LAT=3 流水结构图（文字版各级输入输出）、pad 行缓存复用要点（全尺寸输出 + blanking 要求 + 窗口命名）、TB 验证方案与参考模型协议、验收标准
- **README.md**：模块功能与接口、数据流图（文字版）、资源数据（0 DSP/BRAM 数量/LUT）、AMBM vs sqrt 精度对比（~6.5%）、Sobel vs Canny 面试讲点、踩坑记录（如有）、仿真命令

## 验证流程
```powershell
cd d:\FPGA_proj\image_fpga_test\sobel
iverilog -o tb_sobel.vvp tb_sobel.v        # TB 已 include top（内含 pad 行缓存 + 核）
vvp tb_sobel.vvp > sim_log.txt             # 期望 [PASS]
python verify_sobel.py                     # 独立重算比对 + 对比图
iverilog -DSMALL -o tb_sobel_small.vvp tb_sobel.v
vvp tb_sobel_small.vvp >> sim_log.txt      # 小图冒烟（含 4 边 replicate 边界）
```

## 执行步骤（写码顺序）
1. 建 sobel/ 目录，复制 input.hex、input_4x3.hex（自 MedianFilter/）
2. 写 sobel_3x3_8b.v（核）→ 写 top_sobel.v（例化 pad 行缓存 + 核）
3. 写 tb_sobel.v（参考模型 + 记分板 + 激励 + VCD）→ iverilog/vvp 跑真实图，修到 [PASS]
4. 跑 -DSMALL 小图冒烟，确认 pad 四边 replicate 正确
5. 写 verify_sobel.py → 全等比对 + PSNR + 对比图
6. 写 sobel 实现计划.md + README.md，记录资源与面试讲点

## 验收标准
1. 真实图 + 纯色帧全等比对 0 错误，记分板 [PASS]（含 thresh=64/48 两档阈值）
2. 小图 4×3 冒烟通过（四边 replicate 边界全对）
3. Python 独立重算与 RTL 输出全等（0 错误），对比图生成
4. 纯色帧输出恒 0（零梯度不变性）
5. 代码零乘法器：综合/代码检查确认无 `*` 运算符、0 DSP

## 风险与坑（预判）
- **pad 版 blanking 是硬性要求**：TB 若不给 h-blank/v-blank，窗口序列会错位或丢拍——激励按"行末≥1 拍、帧末≥IMG_W+8 拍"写死
- **参考模型截断顺序**：min>>1 与 >>2 必须在 abs 之后、饱和之前，顺序差 1 拍会全等失败（错误集中在边界像素，便于定位）
- **-1024 取绝对值溢出**：11bit signed 的 -1024 取 abs 越界，但 Gx/Gy 实际范围 ±1020 不会触发；仍写注释说明，防止后人改位宽踩坑
- **窗口坐标映射**：pad 版每像素一窗口无 (H-2)(W-2) 偏移，TB 窗口 k 直接对应 (k/W, k%W)，别沿用 crop 版的 +2 偏移
- **纯色帧零梯度**：全 128 灰度 → gx=gy=0 → mag=0，若 TB 出现非 0 即对齐错误或行缓存脏数据