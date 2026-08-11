# image_fpga_study · FPGA 图像处理学习项目

> 换工作向 FPGA 图像处理学习项目（2026-08）· 主线程三个子系统已全部手写实现并仿真验证
> 纯 RTL 推断实现（不依赖任何 FPGA IP），iverilog 仿真 + 自校验 TB + Python 独立校验脚本

`Verilog` `手写 RTL` `行缓存` `色彩空间转换` `双线性插值` `自校验 TB` `iverilog` `PSNR 验证`

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
- [目录结构](#目录结构)
- [快速开始](#快速开始)
- [验证工具链](#验证工具链)
- [已知问题与注意事项](#已知问题与注意事项)
- [参考与致谢](#参考与致谢)

---

## 项目简介

用 Verilog 手写实现 FPGA 图像处理链路上的三个基础子系统，均不依赖 Xilinx/Intel 算法 IP：

| 子系统 | 类别 | 一句话定位 |
|---|---|---|
| **行缓存（LINE_BUFFER）** | 邻域运算地基 | N×N 窗口生成器，卷积/缩放/滤波的复用底座 |
| **色彩空间转换（CSC）** | 逐像素点运算 | RGB → YCbCr（BT.601），1 对 1 映射，不需要行缓存 |
| **双线性插值缩放（bilinear）** | 邻域运算 | 任意整数倍缩放（放大 N 倍 / 缩小 N 倍）；v3 整图 ROM 版 + v4 行缓存版（大图/实时视频） |

每个子系统都遵循同样的学习闭环：**算法原理推导 → 定点化设计 → 手写 RTL → 自校验 TB → 独立脚本二次校验 → 中文讲解文档**。

---

## 学习路线与进度

| 周 | 主线 | 验收标准 | 状态 |
|---|---|---|---|
| W1 | 行缓存范式 | 手写行缓存仿真跑通；讲清 BRAM 存 N-1 行 + 窗口移位、为什么用 BRAM 不用 FIFO | ✅ `LINE_BUFFER/` |
| W2 | 手写 CSC（不用 IP） | 手写 CSC 仿真跑通；能推导转换矩阵；讲清定点化位宽与限幅 | ✅ `CSC/` |
| W3 | 双线性插值缩放 | 手写缩放仿真跑通；能讲四权重计算、行列两级衔接 | ✅ `bilinear/`（v3 整图 ROM 版 + v4 行缓存版） |
| W4 | 2D 卷积滤波 + 收尾 | 均值/高斯卷积仿真跑通；四模块串链路 | ⬜ 待执行 |

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

---

## 参考与致谢

- 牟新刚《基于 FPGA 的数字图像处理原理及应用》
- 冈萨雷斯《数字图像处理》
- [FPGA-Imaging-Library](https://github.com/dtysky/FPGA-Imaging-Library)（对照学习）
- 各子系统 README 内的 CSDN/cnblogs 参考来源详见对应文档