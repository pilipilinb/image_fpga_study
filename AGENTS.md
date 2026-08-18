# AGENTS.md

This file provides guidance to Qoder (qoder.com) when working with code in this repository.

> 本工程是"换工作向"FPGA 图像处理学习项目。配套学习路线与每日执行清单见 `fpga-image-month1-plan.md`——本文件已融合其全部核心决策；若需逐日细节，以原计划文件为准。

## 项目定位与学习路线

- **阶段**：P1 图像处理地基（08月），主线：**行缓存范式 → CSC 手写 → 双线性缩放手写 → 2D 卷积滤波**
- **时间分配**：工作日 2h/天（理论 30min + 上手 75min + HDLBits 15min），休息日 3h/天（40+110+30）；加班砍 HDLBits，不砍上手时间
- **当前进度**：W1-W3 全部完成；W4 进行中（均值滤波、高斯滤波、中值滤波已完成，Sobel/串链路待办）。代码库子系统：line_buffer、CSC、bilinear_v3/v4、MeanFilter、GaussianFilter、MedianFilter

### 计划进度对照

| 周 | 主线 | 验收标准 | 代码库状态 |
|---|---|---|---|
| W1 | 行缓存范式 | 手写行缓存仿真跑通；能讲"BRAM 存 N-1 行 + 窗口移位"、"为什么用 BRAM 不用 FIFO" | ✅ `line_buffer/` 已实现并验证 |
| W2 | 手写 CSC（不用 IP） | 手写 CSC 仿真跑通；能推导 YCbCr↔RGB 矩阵；能讲"定点化怎么选位宽"、"限幅防溢出怎么做" | ✅ `CSC/` 已实现并验证 |
| W3 | 双线性插值缩放 | 手写缩放仿真跑通；能讲"四个权重怎么算"、"行列两级怎么衔接"、"和 IP 核的区别" | ✅ `bilinear_v3`（整图 ROM）+ `bilinear_v4`（行缓存 BRAM 版）均已实现并验证（含缩小） |
| W4 | 2D 卷积滤波 + 收尾 | 均值+高斯卷积仿真跑通；能讲"对称核怎么用 pre-add 省乘法器"、"手写 vs IP"差异 | 🔶 部分完成：`MeanFilter/`、`GaussianFilter/` 已实现验证（去噪对比高斯 22.50dB > 均值 22.14dB）；Sobel/串链路/IP 对比待办 |

### 计划修订记录（重要，避免误导）

- **W2 周四原任务"完善 CSC RTL，接 W1 的行缓存输出做 tb"已判定为可跳过**：CSC 是逐像素点运算（point operation），数学上不需要行缓存；其功能验证已由直连像素流 TB + `verify_csc.py` 独立完成（0 错误），再绕到行缓存后面喂一遍验证覆盖无增加。真正的模块级联练习留到 W3 周日（缩放/CSC/行缓存串通路）与 W4 周五（四模块串链路）。若确要练级联，正确接法是取 3×3 窗口右下角（当前像素）喂 CSC，而非把整个窗口灌进去。
- **W2 周六"理解 CSC 属于基于像素点的操作（不需要行缓存）"认知正确，保留**：点运算（CSC/伽马，1 对 1 映射）vs 邻域运算（卷积/缩放/中值，需 N×N 窗口）的分类，是后续 W3/W4 理解行缓存复用的基础。

## 各周任务要点

### W1 行缓存范式（✅）· 详细每日清单见原计划文件
- 关键产物：手写 BRAM 行缓存（存 2 行 + 窗口移位）→ 加边缘 replicate padding → 参数化（行宽/窗口大小）→ 自检 TB（MATLAB golden 对比）
- 核心理解：BRAM read-first 同址读写实现行延迟、打拍对齐、BRAM 阵列不可复位

### W2 手写 CSC（✅）· 已全部完成
- 关键产物：MATLAB 浮点验证 → 定点化（系数 ×256/×1024，验证 SNR）→ RTL 3 路并行乘加 + 移位截断 + 限幅 → DSP48 优化对比（选做）
- 核心理解：BT.601 系数推导、定点位宽选择、负值处理（正负分开相加再比较）

### W3 双线性插值缩放（✅）· 已全部完成
- 完成方式与计划描述的差异：未用行缓存做缩放数据通路，而是做了两版——`bilinear_v3`（整图 ROM，任意整数倍缩放）与 `bilinear_v4`（3 行环形行缓存 + 反压，BRAM 版，流式输入）；缩小 1/2、1/3 均验证通过（PSNR >59dB）
- 关键产物与核心理解见 `bilinear/bilinear_v4/README.md`（含行缓存反压死锁修复：槽位占用检查规则）

### W4 2D 卷积滤波 + 收尾（🔶 进行中）
- ✅ 3×3 均值滤波（`MeanFilter/`）：9 路加法树 + 除 9 定点近似 (sum×57+256)>>9，crop/pad 双版本
- ✅ 3×3 高斯滤波（`GaussianFilter/`）：系数 [1 2 1;2 4 2;1 2 1] 完整推导（σ=0.849 精确/σ≈1 近似），对称分组 + 移位加权 0 乘法器，去噪优于均值
- ✅ 3×3 中值滤波（`MedianFilter/`）：行排序三部曲排序网络（19 比较器，cand2 中行 mid 错误简化被反例推翻），椒盐去噪碾压线性（26.18 vs 20.5dB）
- ⬜ 待办：Sobel 边缘检测（pre-adder 真正用武之地）、手写 vs IP 资源对比、均值+高斯+中值+CSC+缩放五模块串链路、模块清单整理
- 验收收尾：能讲"行缓存是地基，CSC/缩放/卷积都建立在它之上"

## 行动力规则（源自计划，AI 协作时遵守）

1. **别等"状态好"才开始**——写一行 assign 就算进步；用户卡住超 20 分钟就应主动答疑
2. **每周只看本周清单**——AI 不要主动推销后续周的内容，专注当前周任务
3. **卡住超 20 分钟就问 AI**——CSC 矩阵推导、双线性权重、行缓存对齐等，AI 应逐模块注释讲解

## 关键资源速查

| 资源 | 用途 |
|------|------|
| 牟新刚《基于FPGA的数字图像处理原理及应用》第 3-7 章 | 行缓存/CSC/缩放/卷积/滤波原理 + Verilog 源码 |
| 冈萨雷斯《数字图像处理》第 6 章 | 色彩空间转换理论（CSC 矩阵推导） |
| CSDN 博客"行缓存 linebuffer 生成像素矩阵" / "实现缓存卷积窗口" | W1 行缓存手写参考（blog.csdn.net/qq_39507748/article/details/115269289 等） |
| FPGA-Imaging-Library（github.com/dtysky/FPGA-Imaging-Library） | 对照学习别人的 RTL 怎么写 |
| Vivado Video Process Subsystem IP | W3/W4 对比手写 vs IP 的资源/速度 |
| MATLAB Image Processing Toolbox / HDLBits（hdlbits.01xz.net） | 算法验证 / 每日刷题 |

## 代码库结构（五个独立子系统，无顶层集成）

- **CSC**（RGB→YCbCr 色彩空间转换）：同一算法多种实现变体
  - `CSC/3stage/`：三/四级流水线、乘法器实现，BT.601 带 offset 公式，系数 ×256 定点化。**含独立 Python 校验脚本 `verify_csc.py`**
  - `CSC/3stage_selftest/`：同算法自测版，系数参数化命名（`Y_R_stone` 等），Cb_G 系数为 87（3stage 版为 86，四舍五入差异）；TB 通过层次引用 `dut.*` 取参数避免硬编码不一致
  - `CSC/shift_v/`：移位代替乘法版本（系数拆解为移位和，×1024 定点化，6 级流水）
  - `CSC/matlab/`：MATLAB 浮点参考实现（BT.601 标准系数）
- **line_buffer**（行缓存，3x3/N×N 窗口生成）：同一功能四种实现
  - `line_buffer/line_buffer3x3/`：手写推断 BRAM（`ram_style="block"`）+ read-first 同址读写，crop 输出（(H-2)×(W-2) 窗口）
  - `line_buffer/pad_verison/`：同上 + replicate padding 全尺寸输出（H×W 窗口），依赖 h-blank/v-blank 空拍做右/下边 flush
  - `line_buffer/fifo_linebuffer3x3/`：FIFO IP 级联版（**外部参考代码，无 TB，有已知代码风格问题**，见 `三种行缓存方案对比速查.md`）
  - `line_buffer/line_buffer_nxn/`：参数化 N×N 模板（N-1 块 BRAM 级联 + adly 对齐延迟链 + N×N 横向移位窗），本工程最核心可复用模块，W3/W4 缩放与卷积应复用
- **bilinear**（双线性插值缩放，W3）：`bilinear_v3/` 整图 ROM 版（任意整数倍缩放，含缩小）；`bilinear_v4/` 行缓存版（3 行环形缓冲 + 槽位冲突反压 + BRAM，流式输入，大图可行）——v4 是架构进阶版，含反压死锁修复、BRAM 同步读对齐等工程要点
- **MeanFilter**（3×3 均值滤波，W4）：crop/pad 双版本，9 路加法树 + 除 9 定点近似（×57>>9），含高斯噪声去噪对比实验（PSNR 提升 +4.58dB）
- **GaussianFilter**（3×3 高斯滤波，W4）：系数推导完整记录（σ=0.849），对称分组 + 移位加权 0 乘法器，去噪 22.50dB 优于均值（+0.36dB）
- **MedianFilter**（3×3 中值滤波，W4）：行排序三部曲排序网络（19 比较器），椒盐去噪主场（26.18dB 碾压线性滤波）；cand2 误省比较器被反例推翻的坑详见核注释

## 常用命令

仿真工具链为 **iverilog + vvp**（各目录下的 `.vvp`、`.v.out`、`sim_log.txt`、`.vcd` 产物确认），TB 内已含自检记分板，仿真结束打印 PASS/FAIL。以 `CSC/3stage` 为例的完整流程：

```powershell
# 1. 编译（TB 头部已 `include 被测模块.v`，只需编译 TB）
iverilog -o tb_rgb_to_ycbcr.vvp tb_rgb_to_ycbcr.v

# 2. 运行仿真，日志重定向（TB 会自动生成 .vcd 波形）
vvp tb_rgb_to_ycbcr.vvp > sim_log.txt

# 3.（仅 CSC/3stage）独立 Python 校验：解析 sim_log.txt 的 RES| 行，
#    用独立算法重算期望值比对，并输出定点 vs 浮点精度误差
python verify_csc.py

# 4. 查看波形
gtkwave tb_rgb_to_ycbcr.vcd
```

line_buffer 各子目录同理（`iverilog -o tb_x.vvp tb_x.v` → `vvp tb_x.vvp`），无 Python 校验脚本。

## 架构与约定

### Testbench 模式（每个 TB 严格遵循，见规则 tb.md）

1. TB 文件头部 **必须**使用 `` `include "被测模块.v" ``（不能只写 `timescale`）
2. **必须生成 VCD**：`$dumpfile` + `$dumpvars(0, tb_module)`
3. 自校验记分板模式（非手工看波形）：TB 内建参考模型/参考算法，逐拍比对并计数错误，超时保护（`#N; $finish`）兜底
4. 结束打印统一格式：`[PASS]/[FAIL]` + 统计计数

### RTL 设计铁律（所有模块反复出现，改代码时不可破坏）

- **BRAM 阵列不可复位**（原语无复位 pin）：存储阵列的读输出寄存器用同步复位（`if(!rst_n)` 写在 `posedge clk` 内），否则推断失败退化 FF；上电脏数据靠 valid/坐标门控屏蔽
- **打拍对齐**：BRAM 同步读潜伏 1 拍，`din/col/valid` 必须逐级打拍对齐；漏一级即错一列/行
- **valid 链与数据链分离**：valid 每拍自由传递，数据寄存器仅在 valid 时更新
- **窗口门控**：`matrix_valid = valid && row>=N-1 && col>=N-1`（crop 版），屏蔽帧头 N-1 行/行头 N-1 列
- 复位风格：DUT 内计数器/流水线用异步复位（`negedge rst_n` 进敏感表）；`rgb_to_ycbcr_3stage.v` 含异步复位同步释放两级同步器

### 学习工程的文化约定

- 每个模块目录都配有中文 .md 讲解文档（速查卡、难点详解）+ .svg 时序图，论述"为什么这么设计"优于"怎么用"
- 文档与代码同目录存放，修改代码时应同步更新对应 .md 的结论（如 `line_buffer/三种行缓存方案对比速查.md`、`line_buffer/line_buffer_nxn/line_buffer_nxn_对齐原理与要点.md`）
- 代码注释为详细中文，含设计特点、公式定点化推导、踩坑记录
- 版本变体并存（同一算法多实现），新实现作为独立子目录，不覆盖旧版

### 已知坑（避免重犯）

- `CSC/3stage` 版 Cb_G 定点系数取 86（0.338×256=86.53 截断），selftest 版取 87（四舍五入）——TB 期望算法必须与所测 DUT 参数一致，优先用层次引用 `dut.*` 取参数而非硬编码
- FIFO 版若改用标准读模式（非 FWFT），valid 级联当拍传而数据晚 1 拍，每级斜 1 像素——IP 配置错误代码 review 不可见