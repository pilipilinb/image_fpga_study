# image_fpga_study · FPGA 图像处理学习项目

> 换工作向 FPGA 图像处理学习项目（2026-08）· 六个子系统已手写实现并仿真验证（W4 收尾中：Sobel/串链路待办）
> 纯 RTL 推断实现（不依赖任何 FPGA IP），iverilog 仿真 + 自校验 TB + Python 独立校验脚本

`Verilog` `手写 RTL` `行缓存` `色彩空间转换` `双线性插值` `均值滤波` `高斯滤波` `中值滤波` `排序网络` `自校验 TB` `iverilog` `PSNR 验证`

---

## 目录

- [项目简介](#项目简介)
- [学习路线与进度](#学习路线与进度)
- [子系统一览](#子系统一览)
  - [LINE_BUFFER · 行缓存（W1）](#line_buffer--行缓存w1)
  - [CSC · 色彩空间转换（W2）](#csc--色彩空间转换w2)
  - [bilinear · 双线性插值缩放（W3）](#bilinear--双线性插值缩放w3)
    - [bilinear_v3 · 整图 ROM 版](#bilinear_v3--整图-rom-版)
    - [bilinear_v4 · 行缓存版](#bilinear_v4--行缓存版)
  - [MeanFilter · 均值滤波（W4）](#meanfilter--均值滤波w4)
  - [GaussianFilter · 高斯滤波（W4）](#gaussianfilter--高斯滤波w4)
  - [MedianFilter · 中值滤波（W4）](#medianfilter--中值滤波w4)
- [目录结构](#目录结构)
- [快速开始](#快速开始)
- [验证工具链](#验证工具链)
- [已知问题与注意事项](#已知问题与注意事项)
- [参考与致谢](#参考与致谢)

---

## 项目简介

用 Verilog 手写实现 FPGA 图像处理链路上的五个基础子系统，均不依赖 Xilinx/Intel 算法 IP：

| 子系统 | 类别 | 一句话定位 |
|---|---|---|
| **行缓存（LINE_BUFFER）** | 邻域运算地基 | N×N 窗口生成器，卷积/缩放/滤波的复用底座 |
| **色彩空间转换（CSC）** | 逐像素点运算 | RGB → YCbCr（BT.601），1 对 1 映射，不需要行缓存 |
| **双线性插值缩放（bilinear）** | 邻域运算 | 任意整数倍缩放（放大 N 倍 / 缩小 N 倍）；v3 整图 ROM 版 + v4 行缓存版（大图/实时视频） |
| **均值滤波（MeanFilter）** | 邻域运算（滤波） | 3×3 窗口 9 像素平均，9 路加法树 + 除 9 定点近似；crop/pad 双版本 |
| **高斯滤波（GaussianFilter）** | 邻域运算（滤波） | 高斯核 [1 2 1;2 4 2;1 2 1]，对称分组 + 移位加权 0 乘法器，去噪优于均值 |
| **中值滤波（MedianFilter）** | 邻域运算（非线性滤波） | 排序取中值：19 比较器行排序三部曲，椒盐噪声碾压线性滤波（+5.7dB） |

每个子系统都遵循同样的学习闭环：**算法原理推导 → 定点化设计 → 手写 RTL → 自校验 TB → 独立脚本二次校验 → 中文讲解文档**。

---

## 学习路线与进度

| 周 | 主线 | 验收标准 | 状态 |
|---|---|---|---|
| W1 | 行缓存范式 | 手写行缓存仿真跑通；讲清 BRAM 存 N-1 行 + 窗口移位、为什么用 BRAM 不用 FIFO | ✅ `LINE_BUFFER/` |
| W2 | 手写 CSC（不用 IP） | 手写 CSC 仿真跑通；能推导转换矩阵；讲清定点化位宽与限幅 | ✅ `CSC/` |
| W3 | 双线性插值缩放 | 手写缩放仿真跑通；能讲四权重计算、行列两级衔接 | ✅ `bilinear/`（v3 整图 ROM 版 + v4 行缓存版） |
| W4 | 2D 卷积滤波 + 收尾 | 均值/高斯/中值卷积仿真跑通；能讲"对称核怎么用 pre-add 省乘法器"、"排序网络取中值"、"手写 vs IP"差异；四模块串链路 | 🔶 进行中：`MeanFilter/`、`GaussianFilter/`、`MedianFilter/` 三滤波已实现验证（椒盐：中值 26.18dB 碾压；高斯：均值/高斯略优）；Sobel/串链路/IP 对比待办 |

---

## 子系统一览

### LINE_BUFFER · 行缓存（W1）

行缓存解决邻域运算的窗口生成：**N×N 窗口只需 N-1 条行缓存**，同列对齐后横向移位出窗口。本目录四个实现变体：

| 变体 | 目录 | 输出 | 验证状态 |
|---|---|---|---|
| 手写 BRAM 基础版 `line_buffer_3x3.v` | `line_buffer3x3/` | 3×3 窗口，crop 输出 (H-2)×(W-2) | ✅ 48 窗口 0 错误 |
| padding 版 `line_buffer_3x3_pad.v` | `pad_verison/` | 3×3 窗口，replicate padding 全尺寸 H×W | ✅ 96 窗口 0 错误 |
| FIFO IP 级联版 `fifo_line_buffer3x3.v` | `fifo_linebuffer3x3/` | 三行对齐数据流（非完整窗口） | ⚠️ 无 TB（外部参考代码） |
| **参数化 N×N 模板 `line_buffer_nxn.v`** | `line_buffer_nxn/` | 参数化 N×N 窗口（N 可配） | ✅ N=3/N=4 双 DUT 0 错误 |

设计要点：

- **BRAM read-first 同址读写**：读旧值（上一行）同拍写新值（当前行），一个端口完成行交换
- **打拍对齐**：BRAM 同步读潜伏 1 拍，`din/col/valid` 逐级打拍；`line_buffer_nxn` 用 `等待拍数 = (N-1) − 出生偏移` 统一公式泛化所有行的对齐
- **BRAM 阵列不可复位**：原语无复位 pin，读输出寄存器同步复位，上电脏数据靠 `matrix_valid` 门控屏蔽
- **参数化 N×N 模板是本工程最核心可复用模块**，W4 卷积将直接复用

文档：[三种行缓存方案对比速查](LINE_BUFFER/三种行缓存方案对比速查.md) · [BRAM 与 FIFO 版本对比](LINE_BUFFER/BRAM与FIFO版本对比.md) · [N×N 对齐原理与要点](LINE_BUFFER/line_buffer_nxn/line_buffer_nxn_对齐原理与要点.md)

---

### CSC · 色彩空间转换（W2）

RGB → YCbCr（BT.601），**逐像素点运算**（1 对 1 映射），数学上不需要行缓存——这是区分点运算与邻域运算、理解行缓存复用边界的关键。四个变体：

| 变体 | 目录 | 定点化 | 流水 | 系数来源 | 验证状态 |
|---|---|---|---|---|---|
| 乘法器版（主版本） | `CSC/3stage/` | ×256 | 4 级 | 博主公式 | ✅ 9885 拍 0 错误 + `verify_csc.py` |
| 参数化自测版 | `CSC/3stage_selftest/` | ×256 | 4 级 | 博主公式（Cb_G=87） | ✅ TB 层次引用 `dut.*` 取参数 |
| 移位代替乘法版 | `CSC/shift_v/` | ×1024 | 6 级 | 标准 BT.601 | ⚠️ 无 TB |
| MATLAB 参考 | `CSC/matlab/` | 浮点/定点验证 | — | 标准 BT.601 | — |

设计要点：

- **定点化**：浮点系数放大为整数（×256 / ×1024），运算后右移还原，`(v>>8) + ((v>>7)&1)` 四舍五入
- **负数处理**：正数项、负数项分开累加，比较大小后大减小——避免有符号运算
- **饱和限幅**：结果钳位 0~255 防回绕
- **异步复位同步释放**：两级同步器避免复位释放亚稳态；同步信号（h_sync/v_sync/data_en）打拍与数据路径对齐

文档：[CSC/README.md](CSC/README.md)（含独立校验脚本用法与验证结果）

---

### bilinear · 双线性插值缩放（W3）

RGB888 图像按**整数倍缩放**（`OUT = IN × SCALE_N / SCALE_D`，分子=放大倍数、分母=缩小倍数），两个版本：v3 整图 ROM 版（小图学习）与 v4 行缓存版（大图/实时视频）。

#### bilinear_v3 · 整图 ROM 版

| 模块 | 职责 |
|---|---|
| `coord_gen.v` | 定点累加坐标/权重生成器（`STEP=(IN<<FB)/OUT` 编译期算好，无运行期除法，含帧内防御） |
| `bilinear_interp_8b.v` | 8bit 单通道插值核：2×2 邻域四权重加权，8 级流水（LAT=8） |
| `image_rom.v` | 推断式 BRAM ROM（`$readmemh` 初始化输入图像） |
| `bilinear_rgb_top.v` | 顶层组装：coord_gen + 地址钳位 + 4 份 ROM 并联 + 3 插值核（R/G/B） |

验证结果（独立浮点参考 + PSNR）：

| 场景 | TB 自检 | PSNR（独立浮点参考） |
|---|---|---|
| 合成小图 4×3 → 8×6 | ✅ 48 像素全对 | — |
| 真图 2 倍 112×103 → 224×206 | ✅ 46144 像素全对 | **58.86 dB**，最大误差 0 LSB |
| 真图 3 倍 112×103 → 336×309 | ✅ 103824 像素全对 | **59.04 dB**，最大误差 0 LSB |
| 真图缩小 1/2 112×103 → 56×51 | ✅ 2856 像素全对 | **59.41 dB**，最大误差 0 LSB |
| 真图缩小 1/3 112×103 → 37×34 | ✅ 1258 像素全对 | **59.07 dB**，最大误差 0 LSB |

验证闭环：`真实图片 → COE → 仿真 → 输出 COE → PSNR 校验 + 对比图渲染`。

文档：[bilinear/bilinear_v3/README.md](bilinear/bilinear_v3/README.md)

#### bilinear_v4 · 行缓存版

用 3 行环形行缓存替代 v3 的 4 份整图 ROM，支持**流式像素输入**（din/din_valid）与双端反压（rd_ready/wr_ready），存储恒定——1920×1080 下 v3 ≈5500 块 BRAM（爆）vs v4 ≈3 块 BRAM。复用 v3 的 coord_gen / 插值核 / 验证链（零改动）。

验证结果（含随机气泡反压压力测试）：

| 场景 | TB 自检 | PSNR（独立浮点参考） |
|---|---|---|
| 合成小图放大 2 倍 4×3 → 8×6 | ✅ 48 像素全对 | — |
| 真图放大 2 倍 112×103 → 224×206 | ✅ 46144 像素全对 | **58.86 dB**（与 v3 一致） |
| 真图缩小 1/2 112×103 → 56×51 | ✅ 2856 像素全对 | **59.41 dB**（与 v3 一致） |

文档：[bilinear/bilinear_v4/README.md](bilinear/bilinear_v4/README.md)

---

### MeanFilter · 均值滤波（W4）

3×3 窗口 9 像素平均（`out = Σw / 9`），作用于高斯噪声去噪。**crop/pad 双版本**：crop 版输出 (H-2)×(W-2)（简单）；pad 版全尺寸 H×W（边缘 replicate，靠 blanking 空拍补右/下边 flush，级联不缩水）。

| 模块 | 职责 |
|---|---|
| `mean_3x3_8b.v` | 8bit 均值核：9 路加法树（3 级流水）+ 除 9 定点近似 `(sum×57+256)>>9` + 饱和 |
| `top_mean_filter.v` / `top_mean_filter_pad.v` | 顶层：1×行缓存(DW=24) + 3×核（R/G/B），crop/pad 两版 |
| `tb_mean_filter.v` / `tb_mean_filter_pad.v` | 自检 TB（定点全等 + 浮点误差统计 + 气泡/blanking 压力） |
| `noise_add.py` | 高斯噪声生成 + 滤波前后对比图 + PSNR（--full 支持 pad 版） |

验证结果（σ=40 高斯噪声去噪）：crop 22.14 dB / pad 22.18 dB，去噪提升 +4.58/+4.62 dB；除 9 近似实测误差 0.89 LSB（≤1）。

设计要点：**9 不是 2 的幂**——除 9 用定点近似 ×57>>9（误差 0.2%、纯乘加可进 DSP48）而非直接除法器。

文档：[MeanFilter/README.md](MeanFilter/README.md)

---

### GaussianFilter · 高斯滤波（W4）

高斯核 **[[1 2 1],[2 4 2],[1 2 1]]**，中心权重最大、越远越小——平滑噪声的同时比均值**更保边缘**。

**系数推导（本次学习核心）**：一维高斯采样（σ=0.849 精确导出 [1,2,1]；σ≈1 为习惯近似）→ 可分离外积得到二维核 → 核总和 16=2⁴，归一化就是右移 4 位。

| 模块 | 职责 |
|---|---|
| `gaussian_3x3_8b.v` | 8bit 高斯核：对称分组（角/边/中心）+ 移位加权（×1/×2/×4）+ `(sum+8)>>4`，**0 个乘法器** |
| `top_gaussian_filter.v` | 顶层：1×行缓存(DW=24) + 3×核 |
| `tb_gaussian_filter.v` | 自检 TB（两帧：真图 + 纯色均值不变性；加权浮点误差统计） |

验证结果（去噪 σ=40，同一份 noise.hex）：**22.50 dB（+4.94）**，比均值滤波 22.14 dB 高 0.36 dB——中心权重 4/16 保边缘的效果。

设计要点：**对称分组 + 2 的幂系数（1/2/4）= 0 乘法器**——教材"9 乘法器 → pre-adder 4 乘法器"在此退化到 0，pre-adder 的价值在任意系数对称核（Sobel）才体现。

文档：[GaussianFilter/README.md](GaussianFilter/README.md)（含系数推导全流程）

---

### MedianFilter · 中值滤波（W4）

3×3 窗口 9 像素**排序取中值**（第 5 大/小）——非线性滤波，椒盐噪声（脉冲 0/255）的主场：窗口内极值点少于 5 个时中值必为真实像素，脉冲被直接剔除；对比之下均值/高斯会把极值"抹开"成灰斑。

| 模块 | 职责 |
|---|---|
| `median_3x3_8b.v` | ★ 中值核：**行排序三部曲排序网络（19 比较器）**：三行 sort3（9）→ 三列候选提取（7）→ 三数取中（3） |
| `top_median_filter.v` | 顶层：1×行缓存(DW=24) + 3×核 |
| `tb_median_filter.v` | 自检 TB（参考模型 = 计数法取第 5 小，与排序网络不同源） |
| `noise_add.py` | 噪声工具（新增 `--salt` 椒盐模式） |

**去噪对比实测（同一份噪声图过三滤波器）**：

| 滤波器 | 椒盐（p=0.10） | 高斯（σ=40） |
|---|---|---|
| 均值 | 20.53 dB | 22.14 dB |
| 高斯 | 20.44 dB | 22.50 dB |
| **中值** | **26.18 dB（碾压 +5.7dB）** | 22.01 dB（垫底） |

交叉验证的知识点：**脉冲噪声选中值，高斯噪声选线性加权**——排序免疫极端值，但也丢弃数值信息。

设计要点：**找中值 ≠ 全排序**（19 比较器 vs 几十个）；反例 {{5,2,8},{4,9,1},{7,3,6}} 证明"cand2 必须取三行 mid 的中值"（16 比较器错误版被推翻）。

文档：[MedianFilter/README.md](MedianFilter/README.md)（含行排序三部曲推导与反例记录）

---

## 目录结构

```
image_fpga_study/
├── LINE_BUFFER/               # W1 行缓存（窗口生成）
│   ├── line_buffer3x3/        #   手写 BRAM 基础版（crop）
│   ├── pad_verison/           #   + replicate padding 全尺寸版
│   ├── fifo_linebuffer3x3/    #   FIFO IP 级联版（外部参考）
│   ├── line_buffer_nxn/       #   参数化 N×N 模板（核心可复用模块）
│   └── *.md / *.svg           #   对比文档与时序图
├── CSC/                       # W2 RGB→YCbCr 色彩空间转换
│   ├── 3stage/                #   乘法器 4 级流水版（主版本）
│   ├── 3stage_selftest/       #   参数化自测版
│   ├── shift_v/               #   移位代替乘法版
│   ├── matlab/                #   浮点参考实现
│   └── README.md
├── bilinear/                  # W3 双线性插值整数倍缩放
│   ├── bilinear_v3/           #   整图 ROM 版（小图学习）
│   │   ├── 4 个 RTL + 3 个 TB #   coord_gen / interp / rom / top
│   │   ├── *.py               #   图像↔COE bridge + PSNR 校验脚本
│   │   ├── *.jpg / *.png / *.coe / *.hex  # 测试数据与验证产物
│   │   └── README.md
│   └── bilinear_v4/           #   行缓存版（大图/实时视频，流式输入 + 反压）
│       ├── line_cache2.v / bilinear_lb_top.v / tb_bilinear_lb.v
│       ├── line_buffer_principle.html
│       └── README.md
├── MeanFilter/                # W4 3×3 均值滤波（crop/pad 双版本 + 去噪实验）
│   ├── mean_3x3_8b.v / top_mean_filter(_pad).v / tb_*.v
│   ├── noise_add.py / noise.hex / *.png
│   └── README.md
├── GaussianFilter/            # W4 3×3 高斯滤波（对称分组 0 乘法器 + 系数推导）
│   ├── gaussian_3x3_8b.v / top_gaussian_filter.v / tb_gaussian_filter.v
│   ├── noise_add.py / noise.hex / *.png / 高斯滤波实现计划.md
│   └── README.md
├── MedianFilter/              # W4 3×3 中值滤波（19 比较器排序网络 + 椒盐去噪）
│   ├── median_3x3_8b.v / top_median_filter.v / tb_median_filter.v
│   ├── noise_add.py / salt_pepper.hex / *.png / 中值滤波实现计划.md
│   └── README.md
├── .gitignore                 # 仿真产物（*.vcd/*.vvp/*.v.out 等）
└── README.md                  # 本文档
```

---

## 快速开始

仿真工具链为 **iverilog + vvp**（各 TB 均自校验记分板，结束打印 PASS/FAIL 并生成 .vcd 波形）：

```powershell
# 1. 行缓存（LINE_BUFFER/line_buffer3x3 为例）
cd LINE_BUFFER/line_buffer3x3
iverilog -o tb.vvp tb_line_buffer_3x3.v
vvp tb.vvp                # 期望输出: 48 窗口 0 错误

# 2. CSC（含独立 Python 校验）
cd CSC/3stage
iverilog -o tb.vvp tb_rgb_to_ycbcr.v
vvp tb.vvp > sim_log.txt  # 期望输出: 9885 拍全部 PASS
python verify_csc.py      # 独立算法二次校验（解析 sim_log.txt 重算比对）

# 3. 双线性缩放（完整验证链）
cd ../../bilinear/bilinear_v3
iverilog -I . -o tb.vvp tb_bilinear_rgb.v
vvp tb.vvp > sim_top.txt
python verify_scale.py --in-hex input.hex --out-coe output.coe --in-w 112 --in-h 103 --scale-n 2 --scale-d 1 --log verify_scale.log
# 缩小 2 倍改传 --scale-n 1 --scale-d 2

# 4. 均值/高斯滤波（W4，含高斯噪声去噪对比）
cd ../../MeanFilter
iverilog -I . -o tb.vvp tb_mean_filter.v; vvp tb.vvp > sim_log.txt
python noise_add.py --sigma 40                     # 生成噪声图
iverilog -DNOISE -I . -o tb_n.vvp tb_mean_filter.v; vvp tb_n.vvp > sim_noise.txt
python noise_add.py --compare --sigma 40           # 对比图 + PSNR

cd ../GaussianFilter
iverilog -I . -o tb.vvp tb_gaussian_filter.v; vvp tb.vvp > sim_log.txt
iverilog -DNOISE -I . -o tb_n.vvp tb_gaussian_filter.v; vvp tb_n.vvp > sim_noise.txt
python noise_add.py --compare --sigma 40           # 高斯 vs 均值 22.14dB 对照
```

查看波形：`gtkwave tb_x.vcd`

---

## 验证工具链

每个子系统统一遵循（详见各 TB）：

1. TB 头部 `` `include "被测模块.v" ``
2. 自动生成 VCD：`$dumpfile` + `$dumpvars`
3. 自校验记分板：TB 内建参考模型/算法逐拍比对，统计错误数，超时保护兜底
4. 结束打印统一格式：`[PASS]/[FAIL]` + 统计计数
5. CSC/bilinear 另有 **Python 独立校验脚本**（不依赖 TB 内建模型，第三方算法重算比对）：`verify_csc.py` / `verify_scale.py`

---

## 已知问题与注意事项

- **CSC 3stage 系列使用博主近似系数**（非标准 BT.601）：Y 系数和 0.859 < 1.0，灰阶亮度被压缩约 1.5%（`R=G=B=128 → Y=126`）；`shift_v`/`matlab` 为标准 BT.601，实链路线建议用后者
- **CSC Cb_G 系数不一致**：3stage 版取 86（截断）、selftest 版取 87（四舍五入），TB 期望应优先复用 `dut.*` 层次引用
- **FIFO 行缓存版**：外部参考代码，无 TB；读模式必须 FWFT（标准模式每级斜 1 像素）；存在 `always @(*)` 内用 `<=` 等代码风格问题
- **padding 版依赖 blanking**：h-blank≥1 拍、v-blank≥W+8 拍，无空拍则物理上无法补出全尺寸
- **bilinear 支持整数倍缩放**（放大 N 倍 / 缩小 N 倍）：非整数倍（N/M 比例）参数化支持但未专项验证；大比例缩小（1/8 及以下）2×2 采样不抗混叠，PSNR 显著下降；v3 的 4 份 ROM 随输入尺寸线性膨胀（v4 行缓存版存储恒定，行列并行度需按 BRAM 读端口另行考量）
- **均值滤波除 9 为近似**（×57>>9）：实测误差 0.89 LSB（<1 视觉无感）；要求零误差需换除法器；判断"滤波是否有效"用去噪实验的 PSNR 提升（σ=40 时 +4.58 dB）
- **高斯滤波 σ 固定**：核 [1 2 1;2 4 2;1 2 1] 对应 σ≈0.849；换 σ 需重推核并保持总和为 2 的幂，否则归一化不能纯移位；3×3 窗口未走可分离（大核 5×5 起用行/列两次一维卷积更省）

---

## 参考与致谢

- 牟新刚《基于 FPGA 的数字图像处理原理及应用》
- 冈萨雷斯《数字图像处理》
- [FPGA-Imaging-Library](https://github.com/dtysky/FPGA-Imaging-Library)（对照学习）
- 各子系统 README 内的 CSDN/cnblogs 参考来源详见对应文档