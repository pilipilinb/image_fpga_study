# FpgaIspChain —— M5.3 八级 ISP 整链（AXIS RAW10 进 → AXIS RGB888 出）

> **定位**：把前面 5 个阶段（M1 行缓存 / M2 BLC / M3 DPC+Demosaic / M4 线性 RGB 三模块 / M5.1 锐化+出端）
> 串成**一条完整的 8 级流水**，两端直接对接实机契约：入端 `AXIS(RAW10)`（承 MIPI CSI-2 RX）、
> 出端 `AXIS(RGB888, tkeep=111)`（接 VDMA S2MM）。AWB 先放**1 拍 1.0 增益占位**（真实现留 M6），
> 但顶层已把 AWB 的增益/统计端口按最终形态预留在位。
> 详细设计推导（为什么这么排、时序怎么收敛、stall 怎么量）见 [八级ISP整链设计与验证.md](八级ISP整链设计与验证.md)。

---

## 一句话结论（可背）

> **8 级整链一次点亮、逐级位级 0 误差**（TB 1152/1152 + 真图 4 帧 46144/46144，独立复算逐级 0 误差），
> **时序从 OOC −0.939ns/26 级收敛到 +1.589ns/17 级 @150MHz**，且**功能 0 误差 ≠ 时序能过**
> 这个 M5.1 的老结论在**整链集成时又被撞了一次**：唯一违例路径不是"反压跨 8 级"，
> 而是 **M3 遗留的 DPC 级内部路径（行缓存 pad mux + 核挤在一拍）** —— 修法=M5.1 同款窗口寄存器。
> **级间弹性 FIFO 一个没加**（先量后加）：实测只有**入口**需要 ≥ ~6·W 字的弹性来吸收"帧末造行期"，
> 出端 sink 恒 ready 时**第 4~8 级 stall 恒为 0**。

## 链路结构

```
AXIS(RAW10) ─[blc_axis_adapter]─ BLC ─ DPC ─[awb_stub 增益占位]─ Demosaic
            ─ 降噪 ─ CCM ─ Gamma ─ 锐化 ─[axis_out_adapter]─ AXIS(RGB888,tkeep=111)
  位宽：   RAW10=10bit ── Bayer 域 ──►  线性 RGB=30bit {R[29:20],G[19:10],B[9:0]}
          ── Gamma 是**全链唯一换位宽的一级** (30→24) ──► RGB888=24bit
  域：     RAW 域(BLC,DPC) → Bayer 域增益(AWB) → 线性 RGB 域(Demosaic,降噪,CCM) → 感知域(Gamma,锐化)
```

## 文件清单

| 文件 | 作用 |
|---|---|
| `isp_chain_top.v` | **整链顶层**：8 级 + 两端 AXIS 适配；端口按最终形态预留 AWB 增益/统计 |
| `awb_stub.v` | AWB 增益级占位（Bayer 域按相位乘增益，Q2.8，1.0=256 时恒等；延迟 1 拍） |
| `tb_isp_chain.v` | 自检 TB：AXIS 进/出，协议三场景 + 真图 4 帧，位级比对 + tkeep/tuser/tlast 契约 + 反压稳定 + **stall 测量** |
| `make_chain_data.py` | 数据/golden：系数表（4 个 `.coe`）+ small 输入 + 真图传感级 RAW（OB+噪声+坏点）+ 理想靶子 |
| `verify_isp_chain.py` | 独立第二判据：**逐级**重算比对 + 逐级 PSNR + 端到端 PSNR + 基线对照 + 6 格对比图 |
| `isp_chain_compare.png` | 输入 Bayer / 理想 Bayer / Demosaic 出 / 末端出 / 理想末端 / 放大差异 |
| 生成物 `.hex` | `chain_in_{small,img}.hex` · `exp_{small,img}.hex` · `ideal_in_img.hex` |
| `range_lut.coe`/`inv_rom.coe`/`ccm_coef.coe`/`gamma_lut.coe` | 由 `make_chain_data.py` 与各模块同源生成（`$readmemh` 走运行目录，必须在本目录） |

## 接口（顶层）

```verilog
module isp_chain_top #(
    parameter DW=10, OW=8, IMG_W=640, IMG_H=480,
    parameter N_DPC=5, N_RGB=3, THR=128, DEMOSAIC_SEL=0, FRAC=12,
    parameter KW=10, K_FRAC=8, AWB_GW=10, AWB_GF=8,
    parameter ENTRY_FIFO_EN=0, ENTRY_FIFO_DEPTH=512, OUT_FIFO_DEPTH=512
)(
    input  wire aclk, aresetn,
    input  wire [11:0] s_axis_tdata, input wire s_axis_tvalid, output wire s_axis_tready,
    input  wire s_axis_tlast, input wire s_axis_tuser,
    input  wire [DW-1:0] ob_00, ob_01, ob_10, ob_11,          // 四通道黑电平 R/Gr/Gb/B
    input  wire [AWB_GW-1:0] awb_gain_00..awb_gain_11,        // AWB 增益（Q2.8，1.0=256）
    input  wire bp_denoise, bp_ccm, bp_gamma, bp_sharpen,     // 四段 bypass
    input  wire [KW-1:0] sharpen_k,
    output wire [31:0] awb_stat_00..awb_stat_11,              // AWB 统计（预留，现恒 0）
    output wire [23:0] m_axis_tdata, output wire [2:0] m_axis_tkeep,
    output wire m_axis_tvalid, input wire m_axis_tready,
    output wire m_axis_tlast, output wire m_axis_tuser
);
```

- **入端**：1 pixel/clock，`tdata[11:0]` 低 10bit=像素；`tuser`=帧首、`tlast`=行末
- **出端 S2MM 契约**：`tkeep ≡ 3'b111`、`tuser`=帧首、`tlast`=行末、每帧 H×W 像素
- **AWB 端口按最终形态预留**：增益 4 路 + 统计 4 路（M6 接真 AWB 时顶层不用再改）

## 验证结果（全部 [PASS]）

| 项 | 结果 |
|---|---|
| 协议 TB（16×12×6 帧，A 满速 / B 汇随机 50% / C 汇长拉低 40~240 拍） | **[PASS]** 入 1152 / 出 1152，位级 0 误差 + tkeep/tuser/tlast 契约全对 + 反压稳定零违例 |
| 真图 TB（112×103 连发 4 帧） | **[PASS]** 入 46144 / 出 46144，位级 0 误差 |
| 独立第二判据（`verify_isp_chain.py`） | **逐级 8 级全 0 误差**（img 各级 11536/11536；small 1152/1152） |

### 逐级插桩：每级 vs「理想输入的同级输出」PSNR（真图，10bit→8bit 口径）

| 级 | 1 BLC | 2 DPC | 3 AWB | 4 Demosaic | 5 降噪 | 6 CCM | 7 Gamma | 8 锐化 |
|---|---|---|---|---|---|---|---|---|
| PSNR(dB) | 24.54 | 26.16 | 26.16 | 28.39 | **31.16** | 27.16 | 27.59 | 26.77 |

> 一眼可读的两件事：**DPC 把坏点压掉 +1.6dB**（24.54→26.16）；**降噪是最大的单级增益 +2.8dB**（28.39→31.16，峰值）。
> CCM 后 PSNR 下降是**预期**（CCM 增益/负系数会放大残余噪声，与 M5.2 的顺序实验结论一致）。

### 端到端 PSNR（末端 RGB888 vs 理想靶子，8bit 口径）

| 配置 | PSNR |
|---|---|
| DPC/降噪全关（最差） | 22.05 dB |
| 仅降噪关（DPC 开） | 23.00 dB |
| **整链（DPC + 降噪全开）** | **26.77 dB** |

### ★ 时序：整链 OOC（150MHz，`synth_ooc_timing.tcl`，顶层取 `isp_chain_top`）

| 版本 | WNS | LOGIC_LEVELS | 器件占用 |
|---|---|---|---|
| 集成初版 | **−0.939ns ❌** | 26 | — |
| 修 DPC 窗口寄存器后 | **+1.589ns ✅** | 17 | LUT 9340 / FF 4181 / DSP48 46 / RAMB 12 |

- **违例根因**：10 个失败端点**全在 `u_dpc/u_dpc/dout_reg[*]`**，路径 = `u_dpc/u_lb/...` → `u_dpc/u_dpc/dout_reg`，
  即 **M3 的 DPC 级内部** —— 行缓存 pad mux（`sel_row/sel_col`+9:1 mux，组合）与核内极值树/比较
  **挤在同一拍**（M3 交付早于 M5.1 的"时序预检铁律"）。
- **修法**：在 DPC 的行缓存→核之间插一级**窗口寄存器**（不改共用的 `line_buffer_fifo_nxn`），
  `dpc_stage` 处理延迟 1→2、sof/eol/相位对齐链同步改 2 拍。修后最差路径变成**核自身**（17 级 / +1.589ns）。
- **反压跨 8 级的路径不是瓶颈**：`u_out_adp/u_fifo/wptr → u_dpc/u_lb/.../empty_r` 这一族实测 **MET +1.9ns**。

### ★ stall 测量（先量后加，决定"级间要不要弹性 FIFO"）

节点 0=整链入口，1..8=各级输出；测"valid 且未 ready"的**最长连续拍**：

| 场景 | node0 入口 | node1 BLC | node2 DPC | node3 AWB | node4..8（Demosaic 之后） |
|---|---|---|---|---|---|
| 真图 112 宽 · 4 帧 · **外零反压** | **684**（1 段） | 684 | 3 | 3 | **0** |
| 小图 16 宽 · 2 帧 · 外零反压 | 36 | 36 | 1 | 1 | **0** |
| 小图 · 汇随机 50% | 237 | 237 | 240 | 246 | 283~349 |
| 小图 · 汇长拉低 40~240 | 474 | 474 | 572 | 572 | 661~**1033** |

**结论（也是"级间先不加 FIFO"的数据依据）**：
1. **外零反压时，只有入口会 stall，且来自"帧末造行期"**：4 个含行缓存的级（DPC/Demosaic/降噪/锐化）
   的造行期在帧边界**级联起来**，入口最长被压 **684 拍**（≈ Σ 各级 `K·W+K`，W=112 时 ≈ 6·W）。
   ⇒ **入端弹性 FIFO 深度需 ≥ ~6·W**（W=640 → **4096** 字），这正是 `blc_axis_adapter` 入端 FIFO 的用途。
2. **Demosaic 之后的级（node4~8）在外零反压时 stall 恒为 0** ⇒ **级间不需要弹性 FIFO**；
   只有当出端真实反压（VDMA 忙）时才逐级冻结，且是"冻结+保持"零丢数，**深度加在级间没有收益**。
3. 反压时长随外部 deassert 累积（node8 最长 1033 拍）→ 出端 FIFO 是**平滑外部突发**的地方，
   与 M5.1 出端适配的结论一致。

## 复现命令

```powershell
python make_chain_data.py                       # 系数表 + small 输入/golden
python make_chain_data.py --img                 # 真图传感级 RAW + golden + 理想靶子
# ★ -I 必须把 8 个源目录全指到（跨模块 include 链）
$inc = "-I . -I ..\BLC -I ..\Bayer_DPC_Demosaic -I ..\BilateralFilter -I ..\CCM -I ..\Gamma -I ..\Sharpen -I ..\AxisOut -I ..\line_buffer\line_buffer_fifo_nxn -I ..\fifo"
iverilog -o tb_isp.vvp     -DNOVCD        $inc.Split(' ') tb_isp_chain.v
iverilog -o tb_isp_img.vvp -DIMG          $inc.Split(' ') tb_isp_chain.v
python ..\CCM\_run_wd.py vvp tb_isp.vvp         # ★ 一律在看门狗下跑
python ..\CCM\_run_wd.py vvp tb_isp_img.vvp
python verify_isp_chain.py                      # 逐级比对 + 逐级 PSNR + isp_chain_compare.png
# 整链时序预检（非沙箱；顶层已加进 synth_ooc_timing.tcl 的 tops 列表）
cd ..\synth_rpt; vivado -mode batch -source ../synth_ooc_timing.tcl -log synth_ooc_timing.log
```

## 踩坑

**坑 1 · 一个模块被 4 条 include 链重复引入 → iverilog 报 "Module already declared"**：
`axis_stream_fifo.v` 原先**没有 include 守卫**，之前的链每次只从一条路径引入它（没问题）；
整链顶层同时经 `blc_axis_adapter`/`denoise_stage`/`sharpen_stage`/`axis_out_adapter` **四条路径**引入
⇒ 重复声明。给 `fifo/axis_stream_fifo.v` 补 `\`ifndef AXIS_STREAM_FIFO_V_INC` 守卫即解决
（按项目惯例，补守卫前先确认没有别处用"`\`define 同名宏 + include`"的旧写法，已 grep 确认无）。

**坑 2 · 功能 0 误差 ≠ 时序能收敛（M5.1 老结论在整链集成时再次应验）**：
TB 两模式一次全过（逐级位级 0 误差），但整链 OOC **WNS −0.939ns**。
且**违例点不在"反压跨 8 级"**（那族路径 MET +1.9ns），而在 **M3 遗留的 DPC 级内部**
—— 只看单模块（M3 当年没做 OOC）或只看反压链都会漏掉，**必须按最终顶层跑 OOC**。

**坑 3 · 单帧仿真量不出 stall**：真图单帧时，行缓存的造行期只发生在"输入已全部收完"之后，
源已无数据 ⇒ 入口 `tvalid=0` ⇒ 测不到任何 stall（全 0）。要量出真实反压**必须多帧连续**
（让"上一帧造行期"与"下一帧数据"重叠）。本 TB 在 IMG 模式**连发 4 帧**正是为此。
