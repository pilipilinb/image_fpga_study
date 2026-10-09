# Sharpen —— M5.1 USM 锐化（感知域，RGB888）

ISP 链**最后一级**：**USM（Unsharp Mask）锐化**。输入 = M4-3 Gamma 出的 **RGB888 24bit 简流**（`in_data[23:0]`），输出同格式。定点化推导与验证方案见 [Sharpen实现计划.md](Sharpen实现计划.md)。

## 文件清单

| 文件 | 说明 |
|---|---|
| `sharpen_core.v` | USM 核：3×3 高斯模糊（0 乘法器）+ 强度加权 + 饱和（**LAT=2**：T1 寄存 `{orig,blur}`，T2 做差/乘/round/饱和） |
| `sharpen_stage.v` | 行缓存(N=3, DW=24) + **窗口寄存器** + 核 + **bypass 旁路（排空点切换）** + 反压冻结 + `k_gain` 强度端口（**处理路径总延迟 = 窗口 1 + 核 2 = 3**） |
| `tb_sharpen.v` | 自检 TB：协议四场景 + bypass 三段 + **K64 模式**（k=0.25）+ IMG 模式 |
| `make_sharpen_data.py` | golden（Python 位级同构，small/img 双模式） |
| `verify_sharpen.py` | 独立复算（位级）+ 锐度量化（Tenengrad/Laplacian）+ PSNR + 对比图 |
| `sharpen_compare.png` | 对比图：原图 \| 锐化 \| 边缘区放大 |

## 算法与定点化

```
blur = 3×3 高斯模糊(orig)，核 [1 2 1;2 4 2;1 2 1]（Σ=16）
       sum = (角×1) + 2·(边) + 4·(心 ≤16×255=4080)；blur = (sum+8)>>4       ← 纯加法 + 常数移位
out  = clip( orig + k·(orig − blur) )                                       ← USM
```

| 量 | 值 | 说明 |
|---|---|---|
| 高斯模糊 | Σ=16 | 复用降噪的空间核，**0 乘法器** |
| **k（强度）** | `k = k_gain / 2^K_FRAC`，`K_FRAC=8`，`k_gain` **10bit 端口** | 默认 `k_gain=128 → k=0.5`；范围 k ∈ [0, 3.996] |
| 修正量 | `d=|orig−blur|`；`adj=(d·k_gain + 2^7)>>8`；`out = orig ± adj` | **"符号-幅值"两路**，无任何 signed 运算（见下） |
| 输出 | `sat(orig + adj)` → [0,255] | 满量程饱和 |
| LAT | **2**（核内）／处理路径总延迟 **3**（含 stage 窗口寄存器） | 见下「时序」 |

### 时序（Vivado 2021.2 OOC，`xcvu19p-fsva3824-2-e`，150 MHz）

| | 逻辑级数 | WNS | 结论 |
|---|---|---|---|
| **改前**（LAT=1，pad mux 直连核） | **35** | **−1.930 ns** | ❌ ≈116 MHz |
| **改后**（窗口寄存器 + 核 LAT=2 + 显式定位宽） | **15** | **+2.583 ns** | ✅ 150 MHz 收敛（路径 4.074ns） |

> **为什么要拆（面试主线）**：改前关键路径是 `行缓存 lc_r/lc_c_reg → sel_row/sel_col 组合 mux → 9:1 pad mux → 核内 gsum 加法树 → blur → 差 → 乘法 → round → 饱和 → 输出寄存器` 全在**一拍**里。根因有三：① 行缓存 pad mux 是**组合**的，和核逻辑叠在同一拍；② `gsum` 里 `2*(...)`/`4*p4`/`1<<7` 用**未定宽常量**，按 Verilog 上下文位宽规则把表达式抬到 32 位 → 加法器被撑宽；③ LAT=1 没有任何切点。
> **改法**：在 stage 里对 `lb_win` 插一级窗口寄存器（切掉 pad mux，**不动共用的 `line_buffer_fifo_nxn`**，保护 M1/M3 的 FIFO 占用不变式）+ 核内 LAT 1→2 + 全链路显式定位宽。**功能位级不变**（三模式 TB 重跑仍 0 误差）。
> 复现脚本 [`synth_ooc_timing.tcl`](../synth_ooc_timing.tcl)；报告由脚本生成在 `synth_rpt/`（本地产物，未入库）。

### 为什么修正量用"符号-幅值"两路，而不是有符号乘 + 算术右移

```
d   = |orig − blur|                          // 无符号，≤255
adj = (d·k_gain + 128) >> 8                  // 幅值 round-half-up
out = (orig >= blur) ? orig + adj : orig − adj
```

对比"朴素"写法 `signed diff * k >>> 8`：① Verilog 里 **signed 与无符号常量相加会把整式翻成无符号**（经典坑）；② 负数算术右移是 **floor** 而非就近取整——同一组数据 floor 与"幅值就近"会差 1 LSB。幅值两路**语义唯一、无歧义**，Python golden 照写即天然位级同构。这是本模块最值得记的定点技巧。

## 验证结果

| 判据 | 结果 |
|---|---|
| 协议 TB（16×12，四场景 + bypass 三段，`k_gain=128`） | **[PASS]** fire 1536 = 收 1536，0 误差，稳定性断言零违例 |
| **K64 TB**（同场景，`k_gain=64 → k=0.25`） | **[PASS]** 1536/1536 —— 验证"强度 k 参数化" |
| 图像 TB（112×103，M3→CCM→Gamma→锐化 四级串联） | **[PASS]** 11536/11536 |
| Python 独立复算（位级） | **全等 0 误差** |
| **OOC 时序**（Vivado 2021.2，`xcvu19p-fsva3824-2-e`，150 MHz） | **WNS +2.583 ns ✅ / 15 级**（改前 35 级 / −1.930 ns ❌；拆流水后三模式 TB 重跑仍 0 误差） |

**锐度量化（8bit 域，k=0.5，112×103 真图）**：

| 指标 | 原图（Gamma 出） | 锐化（RTL） | 变化 |
|---|---|---|---|
| Tenengrad（平均梯度幅值） | 46.85 | 51.21 | **+9.3%** |
| 平均 \|Laplacian\| | 8.16 | 11.08 | **+35.7%** |
| PSNR(原图, 锐化图) | — | — | **39.30 dB** |

**读法**：高频能量上升即锐化的目的达成；边缘区（Sobel 幅值 > 60 的 29.1% 像素）平均 \|Δ\| = 2.85，明显高于全图 1.48 ⇒ **锐化集中在边缘**（符合预期）。PSNR 39.3dB 是"改动幅度"指标——锐化本就该改变像素，越大＝越温和。对比图 [sharpen_compare.png](sharpen_compare.png)。

## 设计要点

1. **bypass = 排空点切换**（与 CCM/Gamma 的"等延迟旁路"形成架构对比）：处理路径含行缓存，延迟 ≈ `K·W+K+1`（上千拍），旁路走 `axis_stream_fifo`（几拍）——两路延迟差 W+1 像素量级 ⇒ **帧中间热切换必然错位** ⇒ "停源 → 排空 → 切 → 再发"。bypass 期行缓存整体冻结（`in_valid=0`），保住"FIFO 占用恒 = IMG_W"不变式。
2. **`k_gain` 是帧级参数**：不能像 bypass 那样"随意切"——修正量在核里组合生效，而像素到达核时已晚于进入行缓存 `K·W+K` 拍。若与帧边界不对齐地中途改 k，帧头帧尾会被串用两个 k。实践约束：**k 变化必须发生在排空点**（同 bypass）。本 TB 用"整轮常量 k、另开 K64 模式"绕开该问题并独立覆盖 k 端口。
3. **资源**：0 乘法器（高斯）+ 3 个 `8bit×10bit` 乘法（修正量，DSP 或 LUT 皆可）；1 个 BRAM 系的行缓存（复用 `line_buffer_fifo_nxn`）。与降噪/CCM 的资源差异是一个可讲的对比点。

## ★ 时序收敛实战：35 级 / −1.930ns → 15 级 / +2.583ns（面试主线）

> 数据来自 Vivado 2021.2 OOC 综合（器件 `xcvu19p-fsva3824-2-e`，约束 150 MHz = 6.667 ns），
> 顶层取 **`sharpen_stage`**（不是 `sharpen_core`）；脚本 [synth_ooc_timing.tcl](../synth_ooc_timing.tcl)，报告生成在 `synth_rpt/`（本地产物，未入库）。
> **功能侧全程 0 误差**（三模式 TB：small 1536/1536、K64 1536/1536、真图 11536/11536 每轮重跑）——拆流水是**纯 retiming**，输出序列一位不变。

### 迭代 0 · 现象：功能 100% 正确，时序差 1.93 ns

| 顶层 | 逻辑级数 | WNS @150MHz |
|---|---|---|
| `sharpen_stage` | **35** | **−1.930 ns** ❌（隐含上限 ≈116 MHz） |
| `ccm_stage`（**无行缓存**、LAT=2） | 8 | +4.748 ns ✅ |

**先做对照实验再改代码**：`ccm_stage` 与本级同为"逐像素/小窗口 + 乘加 + 饱和"，差别只有**行缓存** ⇒ 嫌疑锁死在"行缓存输出 → 核"这段接口，而不是"用了 function"。

### 病因 ①：行缓存 pad mux 是**组合**逻辑，与核叠在同一拍

报告片段（迭代 0）：
```
Slack (VIOLATED) : -1.930ns
  Source:      u_lb/lc_c_reg[1]/C          ← 行缓存"窗口中心列"坐标寄存器（不是数据寄存器！）
  Destination: u_core/dout_reg[14]/D
  Data Path Delay: 8.587ns (logic 3.588 (41.8%) route 4.999 (58.2%))
  Logic Levels: 35 (CARRY8=6 DSP_A_B_DATA=1 DSP_ALU=1 DSP_M_DATA=1 DSP_MULTIPLIER=1
                   DSP_OUTPUT=1 DSP_PREADD_DATA=1 LUT1=1 LUT2=2 LUT3=6 LUT4=3 LUT5=4 LUT6=7)
```
路径逐级（节选每条关键台阶）：
```
FDCE   u_lb/lc_c_reg[1]/Q         0.079      ← 窗口中心列
LUT6   i___0_carry_i_86/O         0.445      ┐
LUT5   i___0_carry_i_83/O         0.717      │ sel_col：occ + jj − K
CARRY8 i___0_carry_i_80/CO[1]     1.032      │
LUT3   …sc[7]                     1.323      ┘（含两级 clamp）
LUT5   …lb_win[81]                2.249      ← 9:1 pad mux 出口
CARRY8 u_core/gsum0_return2_carry/O[2]  2.829   ┐
CARRY8 u_core/blur_of0_…_carry/O[6]     4.187   │ 核内 gsum 加法树 + >>4
LUT6   u_lb/usm4__0_i_21/O              4.624   ┘ USM 差值/比较
DSP_A_B_DATA usm4__0/A[7]               5.694   ┐
DSP_PREADD / MULTIPLIER / M_DATA /              │ 修正量乘法（d·k_gain）
  OUTPUT / ALU                          8.587   ┘ + round + 饱和 → 输出寄存器
```
`Source` 是**窗口中心列坐标寄存器**而非数据寄存器——因为 `out_win_flat` 的 pad 选择器是真组合逻辑：
```verilog
assign win_out_flat[(oi*N+oj)*DW +: DW] = win_reg[sel_row(oi,lc_r)*N + sel_col(oj,lc_c)];
```
`sel_row/sel_col`（带 clamp）→ 9:1 mux → `gsum` 加法树 → `blur` → 差 → 乘法 → round → 饱和，**全在一个时钟周期**里。

### 病因 ②：未定宽常量把表达式抬到 32 位

```verilog
// 改前（LHS 是 12bit，但常量 2/4 是 32bit ⇒ 整个表达式按 32 位求值）
gsum = (p0+p2+p6+p8) + 2*(p1+p3+p5+p7) + 4*p4;
blur_of = (gsum + 8) >> 4;
adj  = (prod + (1 << (K_FRAC-1))) >> K_FRAC;   // `1<<7` 同样是 32bit 常量
usm  = (res > MAXO) ? ... ;                    // 与 32bit 常量比较 ⇒ 宽比较器
```
Verilog 的**上下文位宽规则**：赋值表达式的位宽 = max(LHS, 所有操作数) ⇒ 被常量撑到 32 位 ⇒ **宽加法器 / 宽比较器**（报告里 `CARRY8=6` 与此有关）。
**改后**：先算进定宽中间量、乘 2/4 用**移位**、round 常量做 `localparam [DW+KW:0] RND`、饱和比较改成"高位是否非零"（`|res[DW+4:DW]`）。

### 修法（三刀）

| # | 动作 | 位置 | 效果 |
|---|---|---|---|
| 0 | 显式定位宽（见上） | `sharpen_core.v` | 宽加法器/宽比较器消失（CARRY8 58→40） |
| 1 | **窗口寄存器**：对 `lb_win` 打一拍（+`valid` 同行、`sof/eol` 等深对齐链） | `sharpen_stage.v` | 切掉行缓存 pad mux |
| 2 | **核内拆流水 LAT 1→2**：T1 寄存 `{orig, blur}`，T2 做差/乘/round/饱和 | `sharpen_core.v` | 再切一半 |

> **为什么不动共用件 `line_buffer_fifo_nxn`？** 它被 M1/M3/M4 共用，"内部 FIFO 占用恒 = IMG_W"是已验证的不变式；在 stage 里打拍是**局部、零风险**的改法。

### 结果

| 迭代 | 级数 | WNS | PF* |
|---|---|---|---|
| 0（原设计，LAT=1） | 35 | −1.930 ❌ | LUT 1625 / FF 582 |
| 0+1+2 | **15** | **+2.583 ✅** | LUT 1590 / FF 852 |

最终报告片段：
```
Slack (MET) : 2.583ns
  Source:      u_core/oG_q_reg[2]/C        ← 我新加的 T1 寄存器（已不含行缓存 ✓）
  Destination: u_core/dout_reg[15]/D
  Data Path Delay: 4.074ns (logic 2.233 (54.8%) route 1.841 (45.2%))
  Logic Levels: 15 (DSP_A_B_DATA=1 DSP_ALU=1 DSP_M_DATA=1 DSP_MULTIPLIER=1
                   DSP_OUTPUT=1 DSP_PREADD_DATA=1 LUT3=2 LUT5=3 LUT6=3 MUXF7=1)
```
新关键路径只剩核 T2（差 → DSP 乘法 → round → 饱和），**已完全不含行缓存那一段**——这是"步 1 生效"的直接证据（`Source` 从 `u_lb/lc_c_reg` 变成 `u_core/oG_q_reg`）。

**代价**：核 LAT 1 → 2（stage 总延迟 3 = 窗口 1 + 核 2，对齐链 3 级）；FF 582 → 852；LUT 基本不变（1625 → 1590）。**输出一位没变。**

**仍未做**：若目标频率升到 200 MHz+，新关键路径（4.074ns，其中 DSP 内部 6 级）需再拆一刀——把 DSP 输出寄存单独拆出（即"步 3"，做法见 `BilateralFilter/README.md` 的"乘积寄存"）。

### 面试问答（预演）

- **Q：你用了很多 function 和组合逻辑，综合会不会有问题？** function 在 Verilog 里是**内联语法糖**，不产生硬件、不产生调用开销——它不是问题。真正的问题是**组合路径深度**：LAT=1 把"行缓存 pad mux + 加法树 + 乘法 + 饱和"压进了一拍。**量化的办法是 OOC 综合 + `report_timing`**，而不是凭感觉。
- **Q：为什么行缓存的 pad mux 会成为瓶颈？** `sel_row/sel_col` 是按窗口中心坐标做**组合**选择（带 clamp），再经过 9:1 mux 出窗口。它本身没问题，但它**不许有自己的寄存器**——一旦和核拼在一拍，两者深度相加。关键路径的起点甚至不是数据寄存器，而是**窗口中心坐标寄存器**。
- **Q：`2*(...)` 这种写法也会影响时序？** 会。未定宽字面常量是 32bit，按 Verilog 上下文位宽规则会把整个表达式撑到 32 位，综合出宽加法器/宽比较器。**算术表达式要始终在定宽上下文里求值**——这是很便宜的一刀。
- **Q：怎么证明改动没破坏功能？** 每轮改完都重跑三模式 TB（含 bypass 三段、K64 非默认强度）+ Python 独立复算，全部位级 0 误差。**拆流水只改时延、不改数值**，所以 golden 一行都不用改。
- **Q：我怎么知道该切几级？** 看 `report_timing` 的 `Logic Levels` 和 `Data Path Delay`：目标周期 6.667ns，单段逻辑 ≤ ~15 级且延迟有余量即可。**先切最大的一块，实测，再决定要不要继续。**

## 复现命令

```powershell
cd Sharpen
# 1) 生成 golden（small：kg=128 + kg=64）
python make_sharpen_data.py
# 2) 协议 TB（四场景 + bypass）
iverilog -o tb_s.vvp -DNOVCD -I . -I ..\line_buffer\line_buffer_fifo_nxn -I ..\fifo tb_sharpen.v
python ..\CCM\_run_wd.py vvp tb_s.vvp          # ★ 一律在看门狗下跑
# 3) k 参数化模式（kg=64）
iverilog -o tb_k.vvp -DNOVCD -DK64 -I . -I ..\line_buffer\line_buffer_fifo_nxn -I ..\fifo tb_sharpen.v
python ..\CCM\_run_wd.py vvp tb_k.vvp
# 4) 图像链：真图 → M3 → CCM → Gamma → 锐化 + 锐度/PSNR/对比图
python make_sharpen_data.py --img
iverilog -o tb_i.vvp -DNOVCD -DIMG -I . -I ..\line_buffer\line_buffer_fifo_nxn -I ..\fifo tb_sharpen.v
python ..\CCM\_run_wd.py vvp tb_i.vvp
python verify_sharpen.py
# 5) 硬切对照实验：帧中间切 bypass（不排空、不停源）→ 量化"被跳过的像素"
iverilog -o tb_h.vvp -DNOVCD -DHARD -I . -I ..\line_buffer\line_buffer_fifo_nxn -I ..\fifo tb_sharpen.v
python ..\CCM\_run_wd.py vvp tb_h.vvp          # 看 HARD-SOF 序列：切换那帧间隔 171 ≠ 192（少 21）
```

## 面试点清单

1. **USM 的原理**：`orig − blur` 就是高频（细节+噪声），乘 k 加回去 = 增强高频
2. **为什么放在 Gamma 之后（感知域）**：位宽缩减（10→8）已完成，锐化作用在最终显示值上；在 10bit 线性域做会把 Gamma 的量化台阶一起放大
3. **定点化的舍入陷阱**：有符号乘 + 算术右移 = floor，与"幅值就近"差 1 LSB；用符号-幅值两路消灭歧义
4. **0 乘法器的高斯**：Σ=16 的核 → 纯加法 + `>>4`；只有修正量那一项需要乘法
5. **bypass 实现方式由"处理路径延迟"决定**：含行缓存 ⇒ 排空点切换（对比 CCM/Gamma 等延迟旁路可热切）
6. **k 为什么必须帧级/排空点改**：修正量在核中生效，早于/晚于边界会串用两个 k
