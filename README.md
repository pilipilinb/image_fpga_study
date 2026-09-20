# image_fpga_study · FPGA 图像处理学习项目

> 换工作向 FPGA 图像处理学习项目（2026-08）· 十个子系统已手写实现并仿真验证（W4 收尾中：手写 vs IP 资源对比待办；Month-2 行缓存 + 8 级 ISP 建链已完成 M0 / M0.5 / M1 / M2）
> 纯 RTL 推断实现（不依赖任何 FPGA IP），iverilog 仿真 + 自校验 TB + Python 独立校验脚本
> 最终目标：把自研 8 级 ISP（BLC → DPC → Demosaic → 降噪 → AWB → CCM → Gamma → 锐化）接入 Microblaze + MIPI 实机平台，替换 Xilinx 官方 Sensor Demosaic IP——详见[未来目标](#未来目标自研-8-级-isp-接入-microblaze--mipi-平台)

`Verilog` `手写 RTL` `行缓存` `色彩空间转换` `双线性插值` `均值滤波` `高斯滤波` `中值滤波` `Sobel 边缘检测` `AMBM 幅值估算` `排序网络` `自校验 TB` `iverilog` `PSNR 验证`

---

## 目录

- [项目简介](#项目简介)
- [学习路线与进度](#学习路线与进度)
- [未来目标：自研 8 级 ISP 接入 Microblaze + MIPI 平台](#未来目标自研-8-级-isp-接入-microblaze--mipi-平台)
- [子系统一览](#子系统一览)
  - [fifo · 手写 FIFO 基础件（M0/M0.5）](#fifo--手写-fifo-基础件m0m05)
  - [LINE_BUFFER · 行缓存（W1）](#line_buffer--行缓存w1)
  - [CSC · 色彩空间转换（W2）](#csc--色彩空间转换w2)
  - [bilinear · 双线性插值缩放（W3）](#bilinear--双线性插值缩放w3)
    - [bilinear_v3 · 整图 ROM 版](#bilinear_v3--整图-rom-版)
    - [bilinear_v4 · 行缓存版](#bilinear_v4--行缓存版)
  - [MeanFilter · 均值滤波（W4）](#meanfilter--均值滤波w4)
  - [GaussianFilter · 高斯滤波（W4）](#gaussianfilter--高斯滤波w4)
  - [MedianFilter · 中值滤波（W4）](#medianfilter--中值滤波w4)
    - [三滤波器对比：资源 + 效果（W4）](#三滤波器对比资源--效果w4)
  - [Sobel · 边缘检测（W4）](#sobel--边缘检测w4)
  - [filter_csc_bilinear · 滤波+CSC+缩放 串链路（W4 收尾）](#filter_csc_bilinear--滤波csc缩放-串链路w4-收尾)
  - [BLC · 黑电平校正（M2，ISP 第一级）](#blc--黑电平校正m2isp-第一级)
  - [BAYER_DPC_DEMOSAIC · DPC→Demosaic 串联链（M3，Bayer 域 RAW10）](#bayer_dpc_demosaic--dpcdemosaic-串联链m3bayer-域-raw10)
- [目录结构](#目录结构)
- [快速开始](#快速开始)
- [验证工具链](#验证工具链)
- [已知问题与注意事项](#已知问题与注意事项)
- [参考与致谢](#参考与致谢)

---

## 项目简介

用 Verilog 手写实现 FPGA 图像处理链路上的各基础子系统，均不依赖 Xilinx/Intel 算法 IP：

| 子系统 | 类别 | 一句话定位 |
|---|---|---|
| **手写 FIFO 基础件（fifo）** | 基础设施 | 双时钟 FIFO（对齐 FIFO Generator）+ AXIS Data FIFO（侧带打包 tuser/tlast）：跨域、速率匹配、链路首尾弹性缓冲 |
| **黑电平校正（BLC）** | 逐像素点运算（ISP 第一级） | max(p−OB[相位], 0) 四通道饱和减；AXIS(RAW10) 入口 + 写法乙省位宽 + out_phase 直供后级 |
| **DPC→Demosaic 串联链（M3）** | Bayer 域 5×5 窗口两级 | 算法核参数化复用旧工程 + 简流反压 + 窗口相位自算；DPC 后 Bayer 域 28.33→38.84dB（+10.51） |
| **行缓存（LINE_BUFFER）** | 邻域运算地基 | N×N 窗口生成器，卷积/缩放/滤波的复用底座；含 FIFO 版（支持反压 + 可换 IP） |
| **色彩空间转换（CSC）** | 逐像素点运算 | RGB → YCbCr（BT.601），1 对 1 映射，不需要行缓存 |
| **双线性插值缩放（bilinear）** | 邻域运算 | 任意整数倍缩放（放大 N 倍 / 缩小 N 倍）；v3 整图 ROM 版 + v4 行缓存版（大图/实时视频） |
| **均值滤波（MeanFilter）** | 邻域运算（滤波） | 3×3 窗口 9 像素平均，9 路加法树 + 除 9 定点近似；crop/pad 双版本 |
| **高斯滤波（GaussianFilter）** | 邻域运算（滤波） | 高斯核 [1 2 1;2 4 2;1 2 1]，对称分组 + 移位加权 0 乘法器，去噪优于均值 |
| **中值滤波（MedianFilter）** | 邻域运算（非线性滤波） | 排序取中值：19 比较器行排序三部曲，椒盐噪声碾压线性滤波（+5.7dB） |
| **Sobel 边缘检测（sobel）** | 邻域运算（差分卷积） | RGB→灰度(CSC)→3×3 差分梯度：AMBM 幅值 + 阈值二值化双输出，0 乘法器 |

每个子系统都遵循同样的学习闭环：**算法原理推导 → 定点化设计 → 手写 RTL → 自校验 TB → 独立脚本二次校验 → 中文讲解文档**。

---

## 学习路线与进度

| 周 | 主线 | 验收标准 | 状态 |
|---|---|---|---|
| W1 | 行缓存范式 | 手写行缓存仿真跑通；讲清 BRAM 存 N-1 行 + 窗口移位、为什么用 BRAM 不用 FIFO | ✅ `LINE_BUFFER/` |
| W2 | 手写 CSC（不用 IP） | 手写 CSC 仿真跑通；能推导转换矩阵；讲清定点化位宽与限幅 | ✅ `CSC/` |
| W3 | 双线性插值缩放 | 手写缩放仿真跑通；能讲四权重计算、行列两级衔接 | ✅ `bilinear/`（v3 整图 ROM 版 + v4 行缓存版） |
| W4 | 2D 卷积滤波 + 收尾 | 均值/高斯/中值卷积仿真跑通；能讲"对称核怎么用 pre-add 省乘法器"、"排序网络取中值"、"手写 vs IP"差异；四模块串链路 | 🔶 进行中：`MeanFilter/`、`GaussianFilter/`、`MedianFilter/` 三滤波已实现验证（椒盐：中值 26.18dB 碾压；高斯：均值/高斯略优）；**`filter_csc_bilinear/` 串链路已跑通**（混合噪声→高斯+中值→CSC→放大2x，逐级 PSNR ≥51dB）；**`sobel/` 边缘检测已实现验证**（RGB→CSC灰度→零乘法器差分→AMBM，双输出全等 0 错误）；手写 vs IP 资源对比待办 |

---

## 未来目标：自研 8 级 ISP 接入 Microblaze + MIPI 平台

学习工程的终点不是几个孤立模块，而是**把自学的手写 ISP 链路装到实机平台上跑通**。本章记录目标平台、集成位置与设计约束，作为后续写代码的背景约束。

### 现有平台（起点）

```
OV5640 摄像头（输出 RAW / Bayer）
   │  MIPI 差分
   ▼
MIPI CSI-2 RX IP ──AXI-Stream（RAW）──► Xilinx 官方 Sensor Demosaic IP ──AXI-Stream（RGB）──► VDMA（⇄ DDR3）──► AXI-Stream to Video Out ──► HDMI 1.4 显示器
```

- **控制面**：Microblaze 经 **AXI-Lite** 配置 OV5640 的 IIC、显示屏驱动芯片的 IIC、MIPI CSI-2 RX IP、VDMA IP
- **数据面**：MIPI CSI-2 RX IP 输出的 RAW 走 **AXI-Stream**
- **帧缓存**：VDMA 与 DDR3 交互（双缓冲/多缓冲），Video Out 按固定分辨率扫描输出

### 集成位置（结论：整体替换官方 Sensor Demosaic IP 的槽位）

目标 8 级链路：`BLC → DPC → Demosaic → 降噪 → AWB → CCM → Gamma → 锐化`

**插入点 = MIPI CSI-2 RX 的 AXI-Stream 输出之后、VDMA 的 AXI-Stream 输入之前**，替换掉 Xilinx 官方 Sensor Demosaic IP（官方 IP 只做"去马赛克"这一件事，正好被自研的 Demosaic 级取代；其余 7 级环绕它铺开）：

```
OV5640 → MIPI CSI-2 RX ──AXIS(RAW)──► ┌────────────────── 自研 8 级 ISP（替换官方 Sensor Demosaic IP）──────────────────┐ ──AXIS(RGB)──► VDMA → Video Out → HDMI
                                      │ BLC → DPC → Demosaic → 降噪 → AWB → CCM → Gamma → 锐化 │
                                      └─────────────────────────────────────────────────────────┘
                                        └─ Bayer 域（RAW）─┘   └────────── RGB 域 ──────────┘
```

### 上下游接口契约（实机，写代码按这个适配）

#### 上游：MIPI CSI-2 RX 输出（AXI4-Stream Video）

| 信号 | 方向 | 含义 |
|---|---|---|
| `video_out_tdata[23:0]` | RX → ISP | **RAW10、每拍 2 个像素**：低 20bit 装两个 10bit 像素，高 4bit 补零（AXIS 要求 TDATA 宽度为 8 的整数倍） |
| `video_out_tvalid` | RX → ISP | 数据有效 |
| `video_out_tready` | ISP → RX | ISP 反压（低 = 忙，发送端保持数据稳定） |
| `video_out_tlast` | RX → ISP | **行结束 EOL**（每行最后一个像素置 1） |
| `video_out_tuser` | RX → ISP | **帧起始 SOF**（每帧第一个像素置 1） |
| `video_out_tdest[9:0]` | RX → ISP | 目的地/流 ID；单下游固定 0（可忽略） |

#### 下游：VDMA S2MM 输入（帧缓存，1~5 帧可选）

| 信号 | 方向 | 含义 |
|---|---|---|
| `s_axis_s2mm_tdata` | ISP → VDMA | 像素数据（如 RGB888 打包 24bit） |
| `s_axis_s2mm_tkeep` | ISP → VDMA | 字节有效（`tkeep[0]` ↔ `tdata[7:0]`）；24bit 全有效时 = 3'b111 |
| `s_axis_s2mm_tvalid` | ISP → VDMA | 数据有效 |
| `s_axis_s2mm_tready` | VDMA → ISP | VDMA 反压（帧缓存满 / DDR 带宽不足时会拉低） |
| `s_axis_s2mm_tlast` | ISP → VDMA | **行末 EOL**（每行最后一拍）；VDMA 不靠它判帧（见要点 3） |
| `s_axis_s2mm_tuser[0:0]` | ISP → VDMA | **帧起始 SOF**（每帧第一拍拉高） |

#### 由接口推出的 6 条实现要点（直接决定架构）

1. **输入端只需一级轻量的“取低位 10bit”提取（不是双像素解包）**：`tdata[23:0]` 是 CSI-2 RX 的承载总线（**低 10bit = 第 1 个像素**、`[19:10]` = 第 2 个、MSB 补零，已按实机确认）。项目默认把 IP 配成 **1 pixel/clock**，每拍只有低位 10bit 有效 → 链路最前面加一级“取低位 10bit”即可；**只有**以后启用双路并行（扩展项）时才需要拆成两路。
2. **数据形态：项目默认单路（每拍 1 像素）；双路并行列为扩展研究项**
   - **单路（默认，后续所有工程按此执行）**：把 CSI-2 RX IP 配置成 **1 pixel/clock** 即可；若 IP 仍以 24bit 总线承载单像素，链路最前面只需一级轻量提取（取低位 10bit），**不需要双像素解包**。
   - **双路并行（每拍 2 像素）= 扩展研究项**：仅在有余力/时间充裕时研究，**不纳入当前主线**。思路：拆成偶列一路、奇列一路（各为列数 W/2 的子图，每路一套行缓存），吞吐翻倍、时钟不用提高；代价是面积约翻倍、同一拍两个像素在 Bayer 上**相位不同**（相位电路要按偶/奇列分路）、跨路边界需要各存一个“邻居路边界像素”寄存器。
3. **`tlast` 全链统一为“行末 EOL”——直接透传，不需要转换**（初版这里写错了，已按实机确认纠正）：上游 `tlast` = 行末；**VDMA S2MM 的 `tlast` 同样是行末**，不是帧末。
   VDMA 判断帧边界靠这几条：配置的 **VSIZE**（收满多少行算一帧）、外部视频时序（vsync / frame sync / VTC）、**下一帧的 SOF（tuser）**、或"最后一行的 tlast + 行号计数"。
   自己产生视频流送给 VDMA 时要做的事：
   - 每帧**第一拍**拉高 `tuser[0]`（SOF）
   - 每行**最后一拍**拉高 `s_axis_s2mm_tlast`（EOL）
   - VDMA 的 **HSIZE / VSIZE / stride** 配成与实际视频格式一致
   - **帧末不需要额外的特殊信号接到 tlast 上**——VDMA 会按帧尺寸 + 帧同步机制自己处理

   对 ISP 链路的含义：各级只需保证"行末 tlast、帧首 tuser"两个语义不丢；pad 版行缓存输出**行数仍是 H 行**（与 VSIZE 一致），帧末多花的那 2W 拍只是产出最后两行的最后几列，不需要额外配置。
4. **`tuser` 就是现成的显式帧同步**：上游 SOF（每帧第一个像素）可直接作为 ISP 各级的帧同步信号，替代"行列计数器 + 帧末回绕"（计数器回绕已在本项目踩过相位错位的坑）；输出给 VDMA 的 `tuser` 同样在帧首置 1。
5. **`tkeep` 别忘**：ISP 输出 24bit（RGB888）时 `tkeep = 3'b111`；若内部某级是 10bit/8bit 数据，打包成字节对齐后再给 tkeep。
6. **位宽全面转向 RAW10**：BLC/DPC/Demosaic 的 `DW` 要升级到 10（窗口打包宽度 = `N*N*DW`，如 5×5×10 = 250bit），内部累加器位宽同步 +2~4bit；输出给 VDMA 前再转成 RGB888（8bit×3）。

### 协议转换策略（链路骨架与反压通路）

AXIS 只在链路**首尾**做完整协议适配，中间用“简流 + 侧带”跑——既省事，又不丢反压：

```
CSI-2 RX ─AXIS─► [AXIS 适配 + 入端弹性 FIFO]
      └─► 内部简流：valid/ready + data + sideband(SOF/EOL)，每拍必收
          unpack → BLC → DPC → Demosaic → 降噪 → AWB → CCM → Gamma → 锐化 → pack
                        ─► [AXIS 适配 + 出端弹性 FIFO] ─AXIS(RGB888, tkeep=3'b111)─► VDMA
反压通路：VDMA.tready → 出端FIFO.full → 入端FIFO.full → CSI-2 RX.tready
```

| 项 | 结论 |
|---|---|
| 首尾 | 做完整 AXIS 适配（补 tkeep/tlast/tuser 语义）+ 弹性 FIFO |
| 中间 | 简流：`valid/ready + data + sideband(SOF/EOL)`；各级**每拍必收**，不逐级做反压 |
| 可砍字段 | `tkeep` / `tdest` / `tid`（链路内部无意义） |
| **不可砍** | `tuser(SOF)` / `tlast(EOL)` / 握手——砍了末端无法恢复行末语义 |
| 为什么中间不做逐级反压 | 窗口类模块“逐拍冻结”（窗口移位停、valid 链停、BRAM 使能停）代价大；纯组合级（BLC/CCM/Gamma）倒是很轻松，可单独考虑 |
| 突发怎么吃 | 靠首尾 FIFO：VDMA 反压时出端 FIFO 兜，满了再压到入端 FIFO，最后反压 `CSI-2 RX.tready`（不丢数据） |
| 何时必须刷新 | 帧粒度不匹配（如行缓存帧末造行占用 k×W 拍）时，入端 FIFO 深度要 ≥ k×W 词 |

### 逐级归属与现状

| 级 | 处理域 | 输入 → 输出 | 邻域/资源依赖 | 现状 |
|---|---|---|---|---|
| BLC 黑电平校正 | Bayer | RAW → RAW | 无（逐像素减偏置，每通道一个偏置） | ✅ 已实现（Month-2 M2：双形态双判据 0 误差；图像链 PSNR 不校 19.47dB → 校准 inf / 校偏 36.12dB） |
| DPC 坏点校正 | Bayer | RAW → RAW | 5×5 窗口 | ✅ 新链路版（Month-2 M3：`dpc_envelope_dw.v` DW 参数化 + 简流反压；RAW10 注 60 坏点 28.33→38.84dB；8bit 旧版 26.43→31.91dB） |
| Demosaic 去马赛克 | Bayer → RGB | RAW → RGB(3×DW) | 5×5 窗口 | ✅ 新链路版（Month-2 M3：双线性/MHC 双核 DW 参数化，换核不改线；RAW10 干净图基准下双线性 40.38dB；8bit 旧版 26.05/29.23dB） |
| 降噪 | RGB | RGB → RGB | 3×3 窗口 | 已有三套可选（均值/高斯/中值；椒盐场景中值 26.18 dB 最优） |
| AWB 自动白平衡 | RGB | RGB → RGB | **帧级统计** + 增益 | 未实现（统计 R/G/B 均值 → 增益，需帧级统计 + 增益延迟一帧生效） |
| CCM 色彩校正矩阵 | RGB | RGB → RGB | 无（3×3 矩阵乘） | 未实现（唯一必须用乘法器/DSP 的一级） |
| Gamma 伽马校正 | RGB | RGB → RGB | 无（LUT） | 未实现（256×10bit 表放 BRAM，Microblaze 写表） |
| 锐化 | RGB | RGB → RGB | 3×3 窗口 | 未实现（USM：原图 + 高频×强度，可复滤波的行缓存） |

**顺序的依据**：BLC/DPC **必须在 Demosaic 之前**——它们处理的是"每个像素只有一个颜色"的 Bayer 数据，坏点若留到 Demosaic 之后会被插值扩散成刺眼的彩色斑点；AWB/CCM/Gamma/锐化 **必须在 Demosaic 之后**——它们需要 RGB 三通道齐全。

### 集成设计约束（后续写代码按这 10 条来）

1. **接口演进到 AXI-Stream**：现有模块是 `din_valid/din` 的简化流；集成时在链路外围加一层 AXIS 适配（`tvalid/tready/tlast/tuser`），模块内部保持简单流，级间用 `axis_register_slice` / FIFO 隔离
2. **RAW 位宽按 10bit 设计**：OV5640 支持 RAW8/RAW10/RAW12，ISP 常用 RAW10（给 BLC/Gamma 留动态范围）→ 所有模块的 `DW` 要真正参数化（现有 `win_flat[199:0]`、`23:0` 等硬编码需改成按 DW/N 推导）
3. **全链保持尺寸不变（关键）**：VDMA/HDMI 要求固定分辨率，而 5×5 窗口类模块 crop 会缩水 → 必须用 **pad 版行缓存**，且要"输出侧补齐、不依赖输入 blanking"的版本（AXIS 连续流不给行末打洞）；否则分辨率逐级变化、VDMA 帧尺寸对不上
4. **显式帧同步**：用 `tlast` / `tuser(SOF)` 做帧边界，替代"行列计数器 + 帧末回绕"（计数器回绕在多帧连续流下已暴露过相位错位的坑）
5. **跨时钟域隔离**：CSI-2 RX 的像素时钟与 AXI 系统时钟不同源 → 级间加 AXIS FIFO（本项目已有 `axis_fifo` 实战经验）
6. **控制面走 AXI-Lite**：每级的系数/阈值（BLC 偏置、DPC 阈值、AWB 增益、CCM 系数、Gamma 表、锐化强度）都要可配 → 每级一组寄存器或统一寄存器文件，由 Microblaze 写入
7. **AWB 的帧延迟**：整帧统计必须"统计第 N 帧、应用到第 N+1 帧"→ 增益寄存器延迟一帧生效，与 VDMA 双缓冲配合（本项目已有 `histeq_core` 双 BRAM 乒乓的帧级统计经验可复用）
8. **CCM/锐化需要乘法**：与"零乘法器"惯例的取舍——滤波/插值这类能用移位+加法的继续用；3×3 矩阵乘法用 DSP48（先定量预算 DSP 用量）
9. **资源与时序**：8 级级联前先估 BRAM/DSP/LUT 预算；每级 OOC 综合 + 整链时序收敛；上板用 ILA 抓关键节点（本项目已有 mark_debug/ILA 调试经验）
10. **验证策略沿用**：逐级位级全等（RTL vs Python 参考）+ 整链 PSNR + 上板实拍对比

### 分阶段路线图

| 阶段 | 内容 | 验收标准 |
|---|---|---|
| 阶段 1 | BLC（简单）+ 现有 DPC/Demosaic 位宽升级到 DW=10 + **pad 版行缓存（输出侧补齐）** | 各级位级全等；链路尺寸全程不变 |
| 阶段 2 | 降噪选型（中值/高斯按场景）+ AWB（帧统计 + 增益延迟） | 混合噪声场景 PSNR 提升；白平衡主观色偏消除 |
| 阶段 3 | CCM + Gamma + 锐化 | 整链 8 级串联逐级 0 误差 + 上板 HDMI 实拍 |

每一级仍遵循本项目的学习闭环：**算法原理推导 → 定点化设计 → 手写 RTL → 自校验 TB → 独立脚本二次校验 → 中文讲解文档**。

### Month-2 里程碑：行缓存复用件 + 8 级 ISP 建链

上面阶段 1~3 是"整链怎么落地"的粗路线；具体到逐模块任务，另有一份可执行里程碑计划：
[fifo行缓存与8级ISP链路实施计划.md](fifo行缓存与8级ISP链路实施计划.md)（含接口契约、每个模块的目录/验收标准/踩坑记录）。

| 里程碑 | 内容 | 状态 |
|---|---|---|
| **M0** | `async_fifo` 五阶段 [PASS]（含组合环 22.6GB 大坑复盘） | ✅ 2026-09-18 |
| **M0.5** | `axis_stream_fifo` 手写（AXIS Data FIFO 对齐版，侧带打包 + 协议断言） | ✅ 2026-09-18 |
| **M1** | `line_buffer_fifo_nxn`（FIFO 版 N×N，pad + 反压；双判据 0 误差，4 组参数含 640 宽图；稳态 1 pixel/clock） | ✅ 2026-09-18 |
| **M2** | BLC（AXIS 适配 + 黑电平校正核，逐通道偏置） | ✅ 2026-09-19 |
| **M3** | DPC→Demosaic 串联链（算法核参数化复用 + 简流反压 + hold_in 丢数修复；双核双判据 0 误差） | ✅ 2026-09-20 |
| **M4** | 降噪 / AWB / CCM / Gamma（Demosaic 出 RGB 之后） | ⬜ 下一步 |
| **M5** | 锐化 + 出端 AXIS 适配 + 8 级整链 | ⬜ |

---

## 子系统一览

### fifo · 手写 FIFO 基础件（M0 / M0.5）

为 8 级 ISP 链路准备的两个手写 FIFO 基础件（目标链路见[未来目标](#未来目标自研-8-级-isp-接入-microblaze--mipi-平台)，任务分解见 [fifo行缓存与8级ISP链路实施计划.md](fifo行缓存与8级ISP链路实施计划.md)）：

| 模块 | 目录 | 接口对齐目标 | 用途 | 验证状态 |
|---|---|---|---|---|
| `async_fifo.v` | `fifo/` | Xilinx **FIFO Generator**（Independent Clocks） | 跨时钟域/速率匹配；行缓存内部的行延迟 | ✅ 五阶段 [PASS]（同步 / 写快读慢 / 写慢读快 / 满空 / 运行中复位），err=0，0.8s |
| `axis_stream_fifo.v` | `fifo/` | Xilinx **AXI4-Stream Data FIFO IP** | 链路首尾弹性 FIFO（原生打包 tuser/tlast 侧带） | ✅ 四阶段 [PASS]（满速背靠背 / 双侧随机 / 空读+写满 / 运行中复位），data-tlast-tuser 逐拍 0 误差，AXIS 协议断言零违例 |

设计要点：

- **格雷码双域指针 + 2 拍同步**（async_fifo）：相邻码字只变 1 位，跨域采样最多采旧/采新、不会出乱码；指针多 1 位绕圈位区分"空/满"
- **组合逻辑环的惨痛教训（本次最大坑）**：`empty/full` 原本是裸 `assign` 且又参与自身读/写门控 → 构成组合环，vvp 进入**零延迟事件风暴**：0.5s 吃 300MB+（用户机上积累到 **22.6GB**、系统内存 98%），仿真时间冻结、`#超时` 兜底失效、综合同样非法。修法：判断照用前瞻值但**寄存一拍输出**（Cummings 标准），从空写满恰好 DEPTH 个字
- **AXIS 版必须 FWFT（不是可选项）**：AXIS 规范要求 `tvalid=1 ⇒ tdata 有效`，而 BRAM 同步读做不到当拍出数 → 输出寄存器 + 自动预取；代价是总容量 = DEPTH+1（与 Xilinx FWFT 模式容量语义一致）
- **侧带同拍打包** `{tuser, tlast, tdata}` 进同一块 BRAM：数据与语义逐拍对位、绝不错位——这正是官方 AXIS Data FIFO 比"FIFO Generator + 手动侧带"省事的地方
- **换官方 IP 无缝**：两者端口分别与 FIFO Generator / AXIS Data FIFO 同名同义，集成时删掉手写版按同名直连即可（IP 仿真模型加密，替换后需用**同一套 TB 在 Vivado xsim 复跑**）

文档：[fifo/README.md](fifo/README.md)（含 22.6GB 组合环踩坑全过程、TB 三类激励竞态、标准读 vs FWFT、Xilinx IP 替换缝）

---

### LINE_BUFFER · 行缓存（W1）

行缓存解决邻域运算的窗口生成：**N×N 窗口只需 N-1 条行缓存**，同列对齐后横向移位出窗口。本目录四个实现变体：

| 变体 | 目录 | 输出 | 验证状态 |
|---|---|---|---|
| 手写 BRAM 基础版 `line_buffer_3x3.v` | `line_buffer3x3/` | 3×3 窗口，crop 输出 (H-2)×(W-2) | ✅ 48 窗口 0 错误 |
| padding 版 `line_buffer_3x3_pad.v` | `pad_verison/` | 3×3 窗口，replicate padding 全尺寸 H×W | ✅ 96 窗口 0 错误 |
| FIFO IP 级联版 `fifo_line_buffer3x3.v` | `fifo_linebuffer3x3/` | 三行对齐数据流（非完整窗口） | ⚠️ 无 TB（外部参考代码） |
| **参数化 N×N 模板 `line_buffer_nxn.v`** | `line_buffer_nxn/` | 参数化 N×N 窗口（N 可配） | ✅ N=3/N=4 双 DUT 0 错误 |
| N×N pad 版 `line_buffer_nxn_pad.v` | `line_buffer_nxn_pad/` | 参数化 N×N，replicate padding 全尺寸 H×W | ⚠️ **已弃用**（自身 TB 超时，既有缺陷；见已知问题） |
| **★ FIFO 版 N×N `line_buffer_fifo_nxn.v`** | `line_buffer_fifo_nxn/` | 参数化 N×N，pad 全尺寸 **+ out_ready 反压** | ✅ 六场景 × 4 组参数，双判据 0 误差 |

设计要点：

- **BRAM read-first 同址读写**：读旧值（上一行）同拍写新值（当前行），一个端口完成行交换
- **打拍对齐**：BRAM 同步读潜伏 1 拍，`din/col/valid` 逐级打拍；`line_buffer_nxn` 用 `等待拍数 = (N-1) − 出生偏移` 统一公式泛化所有行的对齐
- **BRAM 阵列不可复位**：原语无复位 pin，读输出寄存器同步复位，上电脏数据靠 `matrix_valid` 门控屏蔽
- **参数化 N×N 模板是本工程最核心可复用模块**，W4 卷积将直接复用
- **★ FIFO 版（`line_buffer_fifo_nxn/`，Month-2 的 M1）**：行延迟改用 N-1 级 FWFT FIFO 级联——**FIFO 的"延迟"= 当前占用字数**，预热到占用恒 `IMG_W` 后"写读严格同拍配对"，即得"上一行同一列"（只读不写或只写不读都会让延迟漂移 → 行错位）。两个相对 BRAM 版的真增量：**出侧可被反压**、**集成时可整体换 FIFO Generator / AXIS Data FIFO IP**。工程要点：造行期把第 1 级 FIFO 输出**原地回写**实现"按列循环吐最后一行"；反压时全链冻结（各级 FIFO 停写停读 → `in_ready=0` → 压上游）。帧末造行期 `in_ready=0` 持续 `K×W+K` 拍，上游需入端弹性 FIFO 吸收

FIFO 版实测（TB 内建 golden + 独立 Python 双判据）：

| 参数 | TB golden | Python 独立复算 | 稳态吞吐 |
|---|---|---|---|
| 16×12 N=3 DW=10 | ✅ 7 帧 × 192 窗口 0 误差 | ✅ 1344 窗口 × 9 点 0 误差 | 1.01 拍/beat |
| 16×12 N=5 / 8×6 N=3 | ✅ PASS | — | 1.01 拍/beat |
| 640×8 N=5 | ✅ 7 帧 × 5120 窗口 0 误差 | ✅ 35840 窗口 × 25 点 0 误差 | **1.0003 拍/beat（1 pixel/clock）** |


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
| `row_conv_8b.v` / `col_conv_8b.v` / `top_gaussian_sep.v` | ★ **可分离版**：行卷积 [1,2,1]（2 拍延迟，不归一化）→ 行缓存 → 列卷积（唯一一次 ÷16） |
| `tb_gaussian_sep.v` | ★ 双 DUT 位级全等对照（可分离 vs 直接） |

验证结果（去噪 σ=40，同一份 noise.hex）：**22.50 dB（+4.94）**，比均值滤波 22.14 dB 高 0.36 dB——中心权重 4/16 保边缘的效果。

设计要点：**对称分组 + 2 的幂系数（1/2/4）= 0 乘法器**——教材"9 乘法器 → pre-adder 4 乘法器"在此退化到 0，pre-adder 的价值在任意系数对称核（Sobel）才体现。

**可分离版实测（W4 补充）**：行卷积不归一化 + 列卷积一次 ÷16，与直接版 `(sum+8)>>4` 严格同构 → **22220 窗口位级全等（0 误差）**，可分离数学等价实证。Vivado 资源（含行缓存）：LUT 230→**170（-26%）**、FF 480→515（+7%）、BRAM 相同——**分离省运算省组合、不省缓存**（纵向 N-tap 与直接 N×N 同需 N-1 行）；3×3 优势有限，5×5 起（运算 25→10）才是必选项。完整推导见 [GaussianFilter/README.md](GaussianFilter/README.md)。

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

### 三滤波器对比：资源 + 效果（W4）

**资源实测（Vivado 2021.2 `synth_design`，xc7z010-1，OOC 无约束，单通道 8bit 核；脚本 [MedianFilter/synth_compare.tcl](MedianFilter/synth_compare.tcl)）**：

| 核（8bit 单通道） | LUT | FF | DSP48 | 算法结构 |
|---|---|---|---|---|
| mean_3x3_8b | 77 | 53 | **1** | 9 路加法树 + 乘 57（映射进 DSP48） |
| gaussian_3x3_8b | **67** | 49 | **0** | 对称分组加法树 + 移位加权 |
| median_3x3_8b | **410** | 18 | 0 | 19 比较器排序网络（比较+选择树） |

- 三通道 RGB = 单核 ×3；行缓存三者共用（2 块 BRAM/通道），不参与算法对比
- **结论 1**：高斯核最省（对称分组 + 2 的幂系数 = 0 DSP + 最少 LUT）
- **结论 2**：均值核的 ×57 定点乘法被 Vivado 映射进 1 个 DSP48——"乘加可进 DSP"的实证；LUT 与高斯相当
- **结论 3**：中值核 **LUT 是高斯的 6 倍**（19 个 8bit 比较器 + 每级选择 mux 是 LUT 大户）——排序网络省 DSP 但吃 LUT，工业上 8bit 中值常用位平面/直方图法折衷
- 面试表述："**资源结构跟着算法结构走：加法树 + 乘法 → LUT + DSP48；移位系数 → 0 DSP48；比较网络 → LUT 大户**，所以选型是效果与资源的联合权衡"

**效果对比（同一份噪声图，PSNR）**：

| 滤波器 | 椒盐 p=0.10 | 高斯 σ=40 |
|---|---|---|
| 均值 | 20.53 dB | 22.14 dB |
| 高斯 | 20.44 dB | 22.50 dB |
| 中值 | **26.18 dB** | 22.01 dB |

结论：椒盐选中值（效果碾压、代价 LUT 最大）；高斯滤波兼顾（效果最好 + 资源最省）——均值滤波在两者间的性价比一般。

---

### Sobel · 边缘检测（W4）

**RGB888 → CSC 灰度化（复用 CSC 3stage，取 Y 通道）→ pad 版行缓存 → 3×3 差分卷积 → AMBM 幅值估算 → 双输出（幅值图 + 阈值二值化边缘图）**。与均值/高斯的平滑卷积相对：Sobel 是差分卷积（核系数和为 0），平坦区输出 0，只有灰度突变处非 0——"边缘 = 灰度变化率"。

| 模块 | 职责 |
|---|---|
| `rgb_to_ycbcr_3stage.v` | 复用 CSC 3stage 工程（BT.601 Y = 0.183R+0.614G+0.062B+16，系数×256：47/157/16，四舍五入截取；Cb/Cr 悬空） |
| `line_buffer_3x3_pad.v` | 复用 pad 版行缓存（replicate padding，H×W 全尺寸窗口） |
| `sobel_3x3_8b.v` | ★ Sobel 核：**零乘法器**（Gx/Gy 系数只有 0/±1/±2，×2 左移 1 位）；LAT=3（3 组寄存器：gx_r→mag_r→输出）；**AMBM**（α=1，β=0.5，1 个比较器替代开方器） |
| `top_sobel.v` | 顶层：CSC + 行缓存 + 核，`din[23:0]/din_valid/thresh → o_mag/o_edge/o_valid` |
| `tb_sobel.v` | 自检 TB（参考模型用 CSC 同系数灰度化，与 RTL 逐位全等） |
| `verify_sobel.py` | numpy 独立整数重算（含 CSC 同款 Y 系数）+ 四宫格对比图 |

验证结果：

| 项目 | 结果 |
|---|---|
| 真实图 112×103 ×2 帧（thresh=64/48） | [PASS]，23072 窗口全等 0 错误 |
| 小图 4×3 冒烟（四边 replicate） | [PASS]，24 窗口全等 |
| numpy 独立整数重算 vs RTL | 全等 0 错误，PSNR ∞ |
| 纯色帧零梯度 | mag=edge=0 恒成立 |

设计要点：

- **位宽链**：像素 8bit → 单侧和 11bit → Gx/Gy 11bit signed（±1020）→ abs 11bit → mag 12bit（≤1530）→ >>2 后 9bit（≤382）→ 饱和 8bit
- **AMBM 精度**：`mag = max(|Gx|,|Gy|) + (min>>1)`，45° 对角误差 +6.07%、最差约 +6.5%（只偏大不偏小）——用 1 个比较器 + 移位换掉开方器
- **阈值用未饱和 9bit 值判定**：`o_edge` 比较的是 `mag>>2` 原始值，饱和只影响幅值图显示，不影响边缘判定
- **灰度化复用 CSC 的 Y**：BT.601 带 +16 offset，但差分运算中偏移相互抵消，直接用 Y 无影响
- 踩坑记录：CSC 是异步复位同步释放，TB 必须等复位稳定（≥2 拍）再喂数据，否则丢首像素整帧错位

文档：[sobel/README.md](sobel/README.md)（含 AMBM 误差推导 + 面试讲点）· 计划 [sobel 实现计划.md](sobel/sobel%20实现计划.md)

---

### filter_csc_bilinear · 滤波+CSC+缩放 串链路（W4 收尾）

**混合噪声图（高斯 σ=20 + 椒盐 p=0.10，seed 固定可复现）→ 高斯滤波 → 中值滤波 → CSC(RGB→YCbCr) → 双线性放大 2 倍**，四级模块流式级联（W4 计划"四模块串链路"的实际执行版，按用户指定以"高斯+中值"替换"均值+高斯"）。行缓存支持 crop/pad 双链（`-DPAD` 切换）：**crop 链 216×198 / pad 链 224×206 全尺寸不缩水**（crop 逐级收缩问题已用 pad 版行缓存解决）。

| 级 | crop 链尺寸 | pad 链尺寸 | 实现精度（均为位级全等） | 恢复度（crop / pad） |
|---|---|---|---|---|
| 输入（混合噪声图） | 112×103 | 112×103 | — | 13.59 / 13.56 dB（噪声度） |
| 高斯滤波 | 110×101 | 112×103 | **inf** | **19.74 / 19.68 dB** |
| 中值滤波 | 108×99 | 112×103 | **inf** | **20.66 / 20.72 dB** |
| CSC（YUV 打包） | 108×99 | 112×103 | **inf** | 18.23 / 18.19 dB |
| **缩放输出** | **216×198** | **224×206** | **inf** | **18.69 / 18.63 dB** |

设计要点：**速率匹配 FIFO**（无背压前级 vs 缩放反压之间的帧缓冲，深度 2^14 保证不溢出）；YUV 打包作三通道独立插值；**pad 链级联需 blanking 重生成**（frame_sync_adapter：pad 版依赖输入空拍执行 rflush/bflush，输出却是连续流，级间须插 512 深度小 FIFO 按行结构重插 h/v-blank）；滤波顺序实验（-DSWAP）实测**先中值后高斯更优 +2.76dB**（椒盐须在极值形态时处理）。

调试亮点（面试可讲）：AXIS FIFO **valid 保持语义**（只打 1 拍在反压时悬空丢数据，实测差 95 像素）；**参考模型舍入必须与 RTL 同构**（初版 63/51/56dB 全是参考的 Python half-even/截断错误，修正后四级 inf 位级全等）；RGB 中值 = **逐通道中值**；pad 版窗口是**中心模型**（w22 中心）与 crop 右下角模型不同。完整调试记录（A/B/C/D 四类）见子 README。

文档：[filter_csc_bilinear/README.md](filter_csc_bilinear/README.md)（含 8 条面试工程要点 + 4 类调试记录 + pad 级联原理）· 验证脚本 [verify_chain.py](filter_csc_bilinear/verify_chain.py)（--pad/--swap）· 改造方案 [全握手链帧闸改造方案.md](filter_csc_bilinear/全握手链帧闸改造方案.md)

---

### BLC · 黑电平校正（M2，ISP 第一级）

8 级 ISP 链路的第一级：CMOS 暗电流底电平（OB）不减掉，会被后级增益/AWB/伽马放大成"暗部发灰"。`p_out = max(p_in − OB[ch], 0)`——纯逐像素点运算，**零行缓存、delay 1 拍**。

| 模块 | 职责 |
|---|---|
| `blc_axis_adapter.v` | AXIS(RAW10,1ppc) → 简流：取低位 10bit、tuser/tlast→sof/eol；`ENTRY_FIFO_EN` 预留入端弹性 FIFO（复用 `fifo/axis_stream_fifo.v`） |
| `blc_core.v` | Bayer 相位计数 + 四通道 OB 选择 + **写法乙**饱和减（先比较再减，省 DW+1 位借位链），1 级流水可反压，`out_phase` 直供 DPC/Demosaic |
| `blc_top.v` | adapter + core 串联 |
| `tb_blc_top.v` / `tb_blc_img.v` | AXIS 全协议 TB（四场景 + 断言）/ 图像实验 TB |
| `verify_blc.py` / `verify_blc_img.py` / `make_blc_data.py` | numpy 独立复算 / 图像链校验（PSNR + 四宫格对比图）/ 实验数据生成 |

验证结果（三套判据）：

- **协议/场景**（双形态直连/入端 FIFO）：四场景 960/960 像素 data/phase/sof/eol 位级全等，AXIS 断言零违例
- **位级**：numpy 独立复算 0 误差；图像链 11536 像素 RTL vs Python 全等
- **图像 PSNR**（vs 理想 RAW，真图 112×103 加每通道黑电平 OB={100,64,180,32}）：

| 场景 | PSNR |
|---|---|
| 不校（黑电平被当信号，暗部发灰） | 19.47 dB |
| BLC 校正（OB 准确） | **inf**（位级还原） |
| BLC 校正（OB 标定偏差 1.6%） | 36.12 dB |

→ 不校损失 16.7dB；OB 偏 1.6% 就从 ∞ 掉到 36dB——"OB 精标定/实时统计 + 随增益分档重写"的定量依据。对比图 [blc_compare.png](BLC/blc_compare.png)。

设计要点：相位不变式（"fire 拍读到的是当前像素相位，拍末推进"；sof 拍强制 00 抹跨帧行奇偶残留）；图像实验必须留满量程 headroom（否则满阱钳位让实验失真）。

文档：[BLC/README.md](BLC/README.md) · 详细讲解 [BLC黑电平校正实现.md](BLC/BLC黑电平校正实现.md)（含写法甲乙对比、四要点落地、相位踩坑）

### BAYER_DPC_DEMOSAIC · DPC→Demosaic 串联链（M3，Bayer 域 RAW10）

ISP 第三/四级串联：**坏点校正 → 去马赛克**。算法核来自已验证的 `DPC/`、`Demosaic/` 工程（8bit 版），**算法逻辑零改动**，仅位宽参数化（8→DW）+ 接口适配（简流握手 + `line_buffer_fifo_nxn` pad 全尺寸 + 反压）。两级各自内含一份行缓存（窗口中心错开 K×(W+1) 个有效拍，共享不划算）。

| 文件 | 说明 |
|---|---|
| `dpc_envelope_dw.v` / `demosaic_bilinear_dw.v` / `demosaic_mhc_dw.v` | 三个参数化核（源：DPC/Demosaic 工程），带 `hold_in` 保持 |
| `dpc_stage.v` / `demosaic_stage.v` / `bayer_dpc_demosaic_top.v` | 行缓存 + **窗口相位自算** + 核 + 反压；`DEMOSAIC_SEL` 选双线性/MHC（换核不改线） |
| `tb_bayer_dpc_demosaic.v` | 协议（16×12×5 帧四场景）/ 图像（真图 112×103）双模式，期望由 Python 预生成逐拍比对 |
| `make_dpc_demosaic_data.py` | 真图→Bayer RAW10→BLC→注 60 坏点→期望链→PSNR→对比图 |

**验证（四套 TB 全 PASS）**：双线性/MHC × 协议/图像，全部期望比对 0 误差 + 出侧稳定性断言零违例 + 收发计数一致（960/960、11536/11536）。

**PSNR（RAW10，THR=128，注 60 坏点）**：

| 口径 | 无 DPC | DPC 后 | 提升 |
|---|---|---|---|
| Bayer 域 | 28.33 dB | **38.84 dB** | +10.51 dB |
| RGB 域·双线性 | 30.30 dB | **40.38 dB** | +10.08 dB |
| RGB 域·MHC | — | 32.64 dB | — |

→ 坏点链上 **MHC 反而低于双线性**（无坏点时 MHC 更锐）——MHC 的高通细节项会放大 DPC 残留（漏网/边缘误伤），双线性的平均将其抹平。对比图 [dpc_demosaic_compare.png](Bayer_DPC_Demosaic/dpc_demosaic_compare.png)。

关键设计/踩坑：① **`hold_in` 保持**——"LAT=1 核直接当输出寄存器"必须配保持语义，否则行缓存弹出（滞后一拍的 ostall 决策）与下游取走之间的时序差会丢数（TB 断言海量"valid 未 ready 撤销"实锤）；② 窗口相位自算（光栅序计数器）替代"输入相位打 K 拍延迟链"，任意反压/气泡严格对齐；③ 跨帧语义 = 行缓存帧间排空 → 每帧独立（clamp 窗口）；④ pad 版边缘窗口用 replicate 像素参与判定（旧 crop 版直接不输出边缘）。

文档：[Bayer_DPC_Demosaic/README.md](Bayer_DPC_Demosaic/README.md)

---

## 目录结构

```
image_fpga_study/
├── LINE_BUFFER/               # W1 行缓存（窗口生成）
│   ├── line_buffer3x3/        #   手写 BRAM 基础版（crop）
│   ├── pad_verison/           #   + replicate padding 全尺寸版
│   ├── fifo_linebuffer3x3/    #   FIFO IP 级联版（外部参考）
│   ├── line_buffer_nxn/       #   参数化 N×N 模板（核心可复用模块）
│   ├── line_buffer_fifo_nxn/  #   ★ FIFO 版 N×N（支持反压，Month-2 M1）
│   │   ├── fwft_wrapper.v / line_buffer_fifo_nxn.v / tb_line_buffer_fifo_nxn.v
│   │   ├── verify_fifo_nxn.py / FIFO行缓存设计要点.md
│   └── *.md / *.svg           #   对比文档与时序图
├── fifo/                      # 手写 FIFO 基础件（Month-2 M0/M0.5）
│   ├── async_fifo.v / tb_async_fifo.v           # 双时钟 FIFO（对齐 FIFO Generator）
│   ├── axis_stream_fifo.v / tb_axis_stream_fifo.v  # AXIS Data FIFO（侧带打包）
│   ├── sim_log.txt / sim_log_axis.txt
│   └── README.md
├── fifo行缓存与8级ISP链路实施计划.md   # Month-2 里程碑计划（M0~M5）
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
├── GaussianFilter/            # W4 3×3 高斯滤波（对称分组 0 乘法器 + 系数推导 + 可分离版）
│   ├── gaussian_3x3_8b.v / top_gaussian_filter.v / tb_gaussian_filter.v
│   ├── row_conv_8b.v / col_conv_8b.v / top_gaussian_sep.v / tb_gaussian_sep.v / synth_sep.tcl
│   ├── noise_add.py / noise.hex / *.png / 高斯滤波实现计划.md
│   └── README.md
├── MedianFilter/              # W4 3×3 中值滤波（19 比较器排序网络 + 椒盐去噪）
│   ├── median_3x3_8b.v / top_median_filter.v / tb_median_filter.v
│   ├── noise_add.py / salt_pepper.hex / *.png / 中值滤波实现计划.md
│   └── README.md
├── sobel/                     # W4 Sobel 边缘检测（CSC 灰度化 + 零乘法器差分 + AMBM）
│   ├── sobel_3x3_8b.v / top_sobel.v / tb_sobel.v
│   ├── rgb_to_ycbcr_3stage.v（复用）/ line_buffer_3x3_pad.v（复用）
│   ├── verify_sobel.py / sobel_compare.png / sobel 实现计划.md
│   └── README.md
├── filter_csc_bilinear/       # W4 收尾 滤波+CSC+缩放 串链路（crop/pad 双链）
│   ├── top_chain.v / axis_fifo.v / frame_sync_adapter.v
│   ├── top_*_pad.v（pad 版顶层） / tb_chain.v / verify_chain.py
│   ├── 滤波CSC缩放串链路实现计划.md / 全握手链帧闸改造方案.md / *.coe / *.png
│   └── README.md
├── BLC/                       # M2 ISP 第一级 黑电平校正（AXIS 入口 + 四通道饱和减）
│   ├── blc_axis_adapter.v / blc_core.v / blc_top.v
│   ├── tb_blc_top.v / tb_blc_img.v
│   ├── make_blc_data.py / verify_blc.py / verify_blc_img.py
│   ├── blc_compare.png
│   ├── BLC黑电平校正实现.md
├── Bayer_DPC_Demosaic/        # M3 DPC→Demosaic 串联链（Bayer 域 RAW10，算法核参数化复用）
│   ├── dpc_envelope_dw.v / demosaic_bilinear_dw.v / demosaic_mhc_dw.v
│   ├── dpc_stage.v / demosaic_stage.v / bayer_dpc_demosaic_top.v
│   ├── tb_bayer_dpc_demosaic.v / make_dpc_demosaic_data.py
│   ├── dpc_demosaic_compare.png
│   └── README.md
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

# 5. Sobel 边缘检测（RGB→CSC灰度→差分梯度→AMBM 双输出）
cd ../sobel
iverilog -I . -o tb.vvp tb_sobel.v; vvp tb.vvp > sim_log.txt
python verify_sobel.py                            # 独立重算全等比对 + 四宫格对比图

# 6. 手写 FIFO 基础件（Month-2 M0 / M0.5）
cd ../../fifo
iverilog -o tb_fifo.vvp tb_async_fifo.v; vvp tb_fifo.vvp > sim_log.txt       # 五阶段 [PASS]
iverilog -o tb_axis.vvp tb_axis_stream_fifo.v; vvp tb_axis.vvp > sim_log_axis.txt

# 7. FIFO 版 N×N 行缓存（Month-2 M1，双判据）
cd ../line_buffer/line_buffer_fifo_nxn
iverilog -o tb_a.vvp -DTB_W=16 -DTB_H=12 -DTB_N=3 -I ../../fifo tb_line_buffer_fifo_nxn.v
vvp tb_a.vvp > sim_log.txt
python verify_fifo_nxn.py fifo_wins.txt 16 12 3 10 7   # 独立 Python 复算（先跑仿真生成 fifo_wins.txt）
# 宽图（关 VCD 加速）：-DTB_W=640 -DTB_H=8 -DTB_N=5 -DNOVCD，verify 传 640 8 5 10 7

# 8. BLC 黑电平校正（Month-2 M2，三套判据）
cd ../BLC
iverilog -o tb_blc.vvp -I ..\fifo tb_blc_top.v;  vvp tb_blc.vvp > sim_log.txt          # 协议/场景 TB（直连）
iverilog -o tb_blcf.vvp -DEFIFO -I ..\fifo tb_blc_top.v; vvp tb_blcf.vvp > sim_log_fifo.txt  # 入端 FIFO 形态
python verify_blc.py blc_out.txt 16 12 5                   # numpy 独立复算
python make_blc_data.py                                    # 真图 -> 理想/带黑电平 RAW10
iverilog -o tb_img.vvp -I ..\fifo tb_blc_img.v; vvp tb_img.vvp > sim_log_img.txt       # 图像链
python verify_blc_img.py                                   # 位级 + PSNR 三组 + blc_compare.png

# 9. DPC→Demosaic 串联链（Month-2 M3，双核双模式）
cd ../Bayer_DPC_Demosaic
python make_dpc_demosaic_data.py                           # 协议场景期望（16x12x5 帧）
iverilog -o tb_s_b.vvp -DNOVCD -I . -I ..\line_buffer\line_buffer_fifo_nxn -I ..\fifo tb_bayer_dpc_demosaic.v
vvp tb_s_b.vvp > sim_log_s_b.txt                           # 协议 TB（加 -DMHC 换 MHC 核）
python make_dpc_demosaic_data.py --img                     # 真图链：BLC后+60坏点 -> 期望+PSNR+对比图
iverilog -o tb_i_b.vvp -DNOVCD -DIMG -I . -I ..\line_buffer\line_buffer_fifo_nxn -I ..\fifo tb_bayer_dpc_demosaic.v
vvp tb_i_b.vvp > sim_log_i_b.txt                           # 图像 TB（-DMHC 同理）
```

查看波形：`gtkwave tb_x.vcd`

---

## 验证工具链

每个子系统统一遵循（详见各 TB）：

1. TB 头部 `` `include "被测模块.v" ``
2. 自动生成 VCD：`$dumpfile` + `$dumpvars`
3. 自校验记分板：TB 内建参考模型/算法逐拍比对，统计错误数，超时保护兜底
4. 结束打印统一格式：`[PASS]/[FAIL]` + 统计计数
5. CSC/bilinear/sobel 另有 **Python 独立校验脚本**（不依赖 TB 内建模型，第三方算法重算比对）：`verify_csc.py` / `verify_scale.py` / `verify_sobel.py`
6. FIFO 类模块另有 **AXIS 协议断言**（SVA 风格用 always 检查实现）：`tvalid` 未 ready 时字段必须稳定、valid 不得提前撤销、复位期 `tvalid=0`（见 `tb_axis_stream_fifo.v`）
7. `line_buffer_fifo_nxn` 采用**双判据**：TB 内建 golden 记分板 + `verify_fifo_nxn.py`（numpy 独立重算 padded 窗口，解析 TB 落盘的 `fifo_wins.txt`）

---

## 已知问题与注意事项

- **CSC 3stage 系列使用博主近似系数**（非标准 BT.601）：Y 系数和 0.859 < 1.0，灰阶亮度被压缩约 1.5%（`R=G=B=128 → Y=126`）；`shift_v`/`matlab` 为标准 BT.601，实链路线建议用后者
- **CSC Cb_G 系数不一致**：3stage 版取 86（截断）、selftest 版取 87（四舍五入），TB 期望应优先复用 `dut.*` 层次引用
- **FIFO 行缓存版**：外部参考代码，无 TB；读模式必须 FWFT（标准模式每级斜 1 像素）；存在 `always @(*)` 内用 `<=` 等代码风格问题
- **padding 版依赖 blanking**：h-blank≥1 拍、v-blank≥W+8 拍，无空拍则物理上无法补出全尺寸
- **bilinear 支持整数倍缩放**（放大 N 倍 / 缩小 N 倍）：非整数倍（N/M 比例）参数化支持但未专项验证；大比例缩小（1/8 及以下）2×2 采样不抗混叠，PSNR 显著下降；v3 的 4 份 ROM 随输入尺寸线性膨胀（v4 行缓存版存储恒定，行列并行度需按 BRAM 读端口另行考量）
- **均值滤波除 9 为近似**（×57>>9）：实测误差 0.89 LSB（<1 视觉无感）；要求零误差需换除法器；判断"滤波是否有效"用去噪实验的 PSNR 提升（σ=40 时 +4.58 dB）
- **高斯滤波 σ 固定**：核 [1 2 1;2 4 2;1 2 1] 对应 σ≈0.849；换 σ 需重推核并保持总和为 2 的幂，否则归一化不能纯移位；3×3 窗口未走可分离（大核 5×5 起用行/列两次一维卷积更省）
- **Sobel 灰度化链路**：`o_mag` 是 8bit 饱和幅值（强边缘钳到 255），边缘判定用的是未饱和 9bit `mag>>2`，两者互不影响；AMBM 幅值比精确 sqrt 最大偏高 ~6.5%（只偏大不偏小，阈值筛选可接受）
- **CSC 异步复位同步释放（sobel 实链踩坑）**：`rgb_to_ycbcr_3stage` 复位释放需 2 拍，上电后必须等复位稳定再喂数据，否则首像素丢失导致整帧错位（TB 已用 `repeat(16)` 等待并记录）
- **`empty/full` 这类空满判断必须寄存一拍输出**（Month-2 M0 大坑）：裸 `assign` 且参与自身门控会构成**组合逻辑环** → vvp 零延迟事件风暴（内存 22.6GB、仿真时间冻结、超时兜底失效），综合亦非法
- **FIFO 版行缓存的造行期反压**：帧末造行 `in_ready=0` 持续 `K×W+K` 拍，上游必须靠入端弹性 FIFO 吸收（模块刻意不做入端 FIFO，保持单一职责）；集成时首尾用 AXIS Data FIFO IP
- **`$random` 是有符号的（TB 通用坑）**：`($random % 1000)` 遇负值恒小于阈值，会让概率完全走样（"2% 长拉低"变成几乎全程拉低）；一律写 `{$random} % 1000`
- **BRAM pad 版行缓存 `line_buffer_nxn_pad` 已弃用**：其 `row_cnt/col_cnt` 复位用了裸 `din_sof`（未与 valid 门控），首个 beat 的计数被复位吃掉 → 帧末造行触发条件永不满足（自身 TB 亦超时）。后续行缓存统一用 `line_buffer_fifo_nxn`（支持反压 + 可换 IP）
- **Demosaic / DPC 旧源码曾被清空**：8bit 旧版已从备份恢复（`DPC/`、`Demosaic/`，历史指标 DPC 26.43→31.91dB；双线性 26.05 / MHC 29.23dB）；Month-2 M3 已在其基础上完成 DW 参数化 + 简流反压新链路（`Bayer_DPC_Demosaic/`），RAW10 域新指标见其 README
- **给无守卫文件补 include 守卫时的连带修改**：`async_fifo.v` 加守卫后，`fwft_wrapper.v` 里旧的"`define ASYNC_FIFO_V_INC` 再 include"写法会把整个 async_fifo 内容屏蔽（宏已置位）→ 必须删掉这个过时 define，直接 include（靠 async_fifo 自带守卫防重复）

---

## 参考与致谢

- 牟新刚《基于 FPGA 的数字图像处理原理及应用》
- 冈萨雷斯《数字图像处理》
- [FPGA-Imaging-Library](https://github.com/dtysky/FPGA-Imaging-Library)（对照学习）
- 各子系统 README 内的 CSDN/cnblogs 参考来源详见对应文档