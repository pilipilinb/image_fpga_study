# FIFO 行缓存与 8 级 ISP 链路实施计划

> 目标：以 `fifo/async_fifo.v` 为基础制作 **FIFO 版任意尺寸行缓存 `line_buffer_fifo_nxn`**（pad 输出 + 简流握手反压），作为未来 8 级 ISP 唯一行缓存复用件；随后按 **BLC → DPC → AWB → Demosaic → 降噪 → CCM → Gamma → 锐化** 逐级建工程（AWB 增益应用在去马赛克**之前**的 Bayer 域——工业主流；AWB 模块实现放链路最后，先直通占位），首级承接 MIPI CSI-2 RX 的 AXIS(RAW10)，末级对接 VDMA S2MM。
> 上下游接口契约全部依据 `README.md` "未来目标"一节（实机确认版）。

---

## 一、现状盘点（探索结论）

| 资产 | 状态 | 结论 |
|---|---|---|
| `fifo/async_fifo.v` | RTL 完整 | 标准读模式（rd_en 下一拍出数）、格雷码指针、高有效复位+双域同步释放、data_count、**ram_style="block"**、接口对齐 Xilinx FIFO Generator |
| `fifo/tb_async_fifo.v` | TB 完整 | 五阶段自检（A 同步/B 写快读慢/C 写慢读快/D 满空/E 运行中复位），记分板 0 误差判据，超时兜底 |
| `fifo/sim_log.txt` | **五阶段 [PASS]** | 2026-09-18 完整跑通（err=0、写满增量=DEPTH、水线峰值 512）；期间修复 RTL empty/full 组合环 + TB 三类激励竞态，踩坑记录见 `fifo/README.md` |
| `line_buffer/line_buffer_nxn/`（crop 版） | 已验证 | BRAM read-first + adly 对齐链 + 横向移位窗；对齐公式"等待拍数 = (N-1) − 出生偏移" |
| `line_buffer/line_buffer_nxn_pad/`（pad 版） | 已验证 | 输出级 sel_row/sel_col replicate mux + 帧末造行 FSM（FLUSH_BEATS = K·W+K+N-1）+ `in_ready` 造行期拉低；**但输出侧无握手、无法反压下游** |
| `filter_csc_bilinear/axis_fifo.v` | 已恢复 | 简流 FIFO，可参考其握手写法 |
| README 未来目标契约 | 已确认 | AXIS(RAW10) 入口，**1 pixel/clock：tdata[11:0]，低 10bit=像素、高 2bit 补零**（2ppc tdata[23:0] 为扩展项）、tlast=行末、tuser=帧首；中间级用简流（valid/ready + sof/eol）；首尾 FIFO 兜反压 |

## 二、总体架构决策

```
CSI-2 RX ─AXIS(RAW10)─► [AXIS适配+入端FIFO] ─简流─► BLC ─简流─► DPC ─简流─► [AWB增益占位]
     ─简流─► Demosaic ─简流(RGB 3×10bit)─► 降噪 ─► CCM ─► Gamma ─简流(RGB888)─► 锐化
（AWB：增益应用在 DPC→Demosaic 之间的 Bayer 域；模块最后实现，先 1.0 增益直通占位）
                                                              ─► [出端适配+出端FIFO] ─AXIS(RGB888,tkeep=3'b111)─► VDMA S2MM

反压通路：VDMA.tready → 出端FIFO → 逐级简流 ready → 入端FIFO → CSI-2 RX.tready
```

**八条铁律（写代码前先读，来自 README + 本工程历史踩坑）**：

1. **每级简流接口统一**：`in_valid/in_ready + in_data[DW-1:0] + in_sof/in_eol`，输出同名 `out_*`。`ready` 允许与 `valid` 独立（不要求 ready 有效时 valid 必须有效，反之亦然；数据仅在 `valid && ready` 拍消费）。
2. **sof/eol 语义不可丢**：tuser→帧首、tlast→行末，逐级透传；sof 同时做各级计数器清零（替代行列计数器回绕，已知相位错位坑）。
3. **全链尺寸不变**：窗口类模块必须 pad 输出（H×W 全尺寸），crop 版只用于离线学习。
4. **BRAM 阵列不可复位**：读输出寄存器用同步复位；上电脏数据靠 valid 门控。
5. **打拍对齐**：FIFO/BRAM 读出晚 1 拍时，valid/col/row/beat 必须逐级同步打拍，漏一级斜一列/行。
6. **RAW10 全链 DW=10**：Bayer 域（BLC/DPC/Demosaic 入口）DW=10；Demosaic 输出转 RGB888（DW=24 或 3×8 分通道，见阶段 5）。
7. **单像素/拍**：不做双像素解包（README 已定为默认，双路并行仅扩展研究）。
8. **每模块验证闭环**：手写 RTL → 自校验 TB（`include` DUT + VCD + 记分板 + PASS/FAIL + 超时兜底）→ 独立 Python 脚本二次校验 → 中文讲解文档（同目录 .md）。

---

## 三、阶段 0：async_fifo 仿真收尾（M0）✅ 2026-09-18 完成

**结果**：五阶段全部 `[PASS]`——A 同步连续 1000 字 / B 写快读慢随机气泡 3000 字 / C 写慢读快 3000 字 / D 从空写满恰好 DEPTH=512 个写后 full、读空后 empty / E 运行中复位后重收 500 字，err=0，水线峰值 512（真撞过满）。vvp 0.8s 正常跑完。

**过程中修复的两个问题**：
1. **RTL 组合逻辑环**：`empty`/`full` 原为裸 assign 且参与自身读/写门控 → vvp 零延迟事件风暴（实测 0.5s 吃 300MB+，用户机上积累到 22.6GB）。修复：按 Cummings 标准寄存一拍输出
2. **TB 三类激励竞态**：①流程里直接写 `wr_en=0` 被 always 随机激励覆盖 → 改 wr_stop/rd_stop 源头关断；②激励带 `if(!rst)` 门控导致复位期间 wr_en 保持旧值 1、释放沿吃进计划外写入 → 去门控（DUT/记分板都有 busy 门控，复位期多出的激励无害）；③B/C 排空判据用定值 r_mark，收尾时读侧滞后几个字没排空 → 阶段D 假错 → 改排空到 `r_cnt==w_cnt`

踩坑全过程见 `fifo/README.md`。

**任务**：把五阶段 TB 完整跑通，作为后续一切的地基。

1. `cd fifo`
2. `iverilog -o tb_fifo.vvp tb_async_fifo.v`（TB 头部已 `` `include "async_fifo.v" ``）
3. `vvp tb_fifo.vvp > sim_log.txt 2>&1`（修复 GBK 乱码：日志重定向即可，检查时忽略中文显示乱码，以 [PASS]/err 计数为准）
4. 验收：`[PASS] async_fifo：五个阶段全部通过`，err=0，五阶段各自打印 w_cnt=r_cnt、满时写入数=DEPTH、复位后 empty=1
5. 若 FAIL：用 VCD 定位（重点盯阶段 D 满判断、阶段 E 复位 busy 时序），修 RTL 直至 0 误差

**产出**：`fifo/sim_log.txt` 完整 + 更新 `fifo/` 下无文档的现状（补一份简短中文说明：async_fifo 与 Xilinx IP 的模式差异——标准读 vs FWFT）。

---

## 三b、阶段 0b：axis_stream_fifo 手写（M0.5，M0 后插队）✅ 2026-09-18 完成

**结果**：四阶段全部 `[PASS]`（满速 500 字 / 双侧随机 1000 字含排空 / 空读+写满容量=DEPTH+1+读出 / 运行中复位丢弃重收 200 字），data/tlast/tuser 三元组逐拍 0 误差，AXIS 协议断言（s/m 侧稳定性、复位期 tvalid=0）零违例，水线峰值 17=DEPTH+1（真撞满）。日志 `fifo/sim_log_axis.txt`。

**实现要点（与计划的差异/明确化的点）**：
1. **输出级采用"输出寄存器 + 自动预取"（FWFT 结构）**：AXIS 规范要求 tvalid=1 时 tdata 必须有效，BRAM 同步读做不到"tvalid 当拍才出数"，必须提前预取——这不是可选模式而是 AXIS 语义的必然。代价：总容量 = DEPTH+1（与 Xilinx FWFT 模式容量语义一致）
2. **空满比较当前指针值**（不前瞻、不参与自身门控）→ 无组合环（async_fifo 踩坑的结构性规避）；full 滞后一拍 = 恰好 DEPTH 个 BRAM 写满
3. **同拍"消费+预取"无缝续流**：连续流零气泡
4. TB 全程用 8×6 帧语义流（tuser=帧首/tlast=行末），帧语义对位合并进记分板逐字比对（计划的场景 5 并入 A-D 全程）

**动机**：链路首尾弹性 FIFO 的最终形态是 Xilinx **AXI4-Stream Data FIFO IP**（原生 tuser/tlast sideband），但按本项目"先手写对齐接口、集成时换 IP"的既定路线（同 async_fifo → FIFO Generator），M0 后插队做一个接口对齐的手写版。

**新增文件**（放 `fifo/` 下，与 async_fifo 同族）：
```
fifo/
├── axis_stream_fifo.v      # 手写 AXIS Data FIFO：同时钟域，包内顺带 tuser/tlast
├── tb_axis_stream_fifo.v   # 自检 TB（协议断言 + 记分板）
└── sim_log.txt
```

**接口（对齐 AXI4-Stream Data FIFO IP，数据按你的规格 8bit 起步，位宽参数化）**：
```verilog
module axis_stream_fifo #(
    parameter DW        = 8,        // 用户给的第一版 8bit；IP 接口位宽任意
    parameter DEPTH     = 512,      // 2 的幂
    parameter TLAST_EN  = 1,        // tlast 侧带使能
    parameter TUSER_EN  = 1,        // tuser 侧带使能
    parameter TUSER_W   = 1         // tuser 位宽（链路里 1bit=帧首 SOF）
)(
    input  wire             aclk, aresetn,          // AXIS 标准：单时钟、低有效复位
    // Slave 侧（入）
    input  wire [DW-1:0]    s_axis_tdata,
    input  wire             s_axis_tvalid,
    output wire             s_axis_tready,
    input  wire [TLAST_EN-1:0] s_axis_tlast,
    input  wire [TUSER_W-1:0]  s_axis_tuser,
    // Master 侧（出）
    output wire [DW-1:0]    m_axis_tdata,
    output wire             m_axis_tvalid,
    input  wire             m_axis_tready,
    output wire [TLAST_EN-1:0] m_axis_tlast,
    output wire [TUSER_W-1:0]  m_axis_tuser
);
```

**与 async_fifo 的差异（写代码前想清楚）**：
1. **单时钟域**：AXIS Data FIFO 是 aclk 单时钟（跨域由 CDC 层做），不复用 async_fifo 的格雷码双域机制——内部可直接用简化同域 FIFO（甚至复用 async_fifo 主体接同频时钟，但注意其 rst 高有效/异步复位与 AXIS 的 aresetn 低有效相反，需外层转接）
2. **侧带同拍同存**：tuser/tlast 与 tdata 打包成一个宽字进出（`{tuser, tlast, tdata}`），天然保证数据与语义不错位——这正是官方 IP 比"FIFO Generator + 手动侧带"省事的地方，手写也要做到
3. **标准读模式即可**：官方 AXIS Data FIFO 默认 FWFT 可配，M0.5 版先做标准读（配合出端适配器），需要 FWFT 时套用 M1 的 fwft_wrapper 思路

**验证要点（TB 三阶段 + 协议断言）**：
1. 背靠背连续传输（满速流，0 丢字 0 错序）
2. 入侧气泡 + 出侧反压（tready 随机，含拉低跨多拍；侧带与数据逐拍比对）
3. 边界：空读、写满反压、复位中途丢包行为（aresetn 复位后 FIFO 清空）
4. **AXIS 协议断言（SVA 风格，用 iverilog 可写的 always 检查实现）**：tvalid 拉高且未 ready 时 tdata/tlast/tuser 必须保持稳定；复位期间 m_axis_tvalid=0
5. 场景 5 起接入 ISP 语义：构造"帧首 tuser + 行末 tlast"的 640×480 帧流，检查 N 帧 × H×W 全收且 sof/eol 位置逐拍正确

**验收（M0.5）**：全场景 0 误差；tdata/tuser/tlast 逐拍对位；协议断言零违例。

**定位**：M2 的 blc_axis_adapter 出入两端直接用 `axis_stream_fifo`；集成时整体替换为官方 AXIS Data FIFO IP（接口同名，行为一致）。

---

## 四、阶段 1：line_buffer_fifo_nxn（M1，本计划核心）✅ 2026-09-18 完成

### 4.1 目录与文件

```
line_buffer/line_buffer_fifo_nxn/
├── fwft_wrapper.v              # 标准 FIFO → FWFT（首字直通）包装
├── line_buffer_fifo_nxn.v      # 主模块
├── tb_line_buffer_fifo_nxn.v   # 自检 TB
├── verify_fifo_nxn.py          # 独立 Python 校验（解析 sim_log 比对）
├── sim_log.txt / *.vcd
└── FIFO行缓存设计要点.md       # 中文讲解（为什么 FIFO 能做行缓存、反压怎么设计）
```

### 4.2 数据通路（与 BRAM 版逐块对应）

| BRAM pad 版 | FIFO 版 | 说明 |
|---|---|---|
| N-1 块 read-first BRAM 级联 | **N-1 个 async_fifo（经 fwft_wrapper）级联** | 第 m 级 FIFO 存"当前输入行往前数第 m 行"；写入端推当前行，读出端（FWFT）给出 m 行前的数据 |
| adly 对齐延迟链 | **取消** | FWFT 输出与 valid 同拍有效，天然对齐；这正是选 FWFT 的原因（已知坑：标准读模式 valid 当拍传、数据晚 1 拍，每级斜 1 像素） |
| 横向移位窗 win_flat_reg | 保留不变 | 使能来自 FWFT valid 链 |
| 输出级 sel_row/sel_col replicate mux | 原样移植 | 窗口中心模型、坐标锁存（ocr_l/occ_l）照抄 pad 版 |
| 帧末造行 FSM | 原样移植，**stage1 读出改为"循环读"** | 见 4.3 关键点 |

### 4.3 三个关键设计点（写进讲解文档）

**① FWFT 包装**：async_fifo 是标准读模式，外面包一层预取寄存器：`dout` 空闲时自动发 `rd_en`，非空时 `dout_v=1 && dout 有效`，消费拍才发 `rd_en`。全链统一 FWFT 语义 → 数据与 valid 同拍，级联不斜。
　**官方 IP 无缝替换路径**：Vivado FIFO Generator 原生支持 FWFT（Read Clock Domain 选项里选 "First-Word Fall Through"），且 FWFT 语义与本 wrapper 外部行为完全一致（empty=0 时 dout 已有效、rd_en=消费确认）；async_fifo 端口命名（rst 高有效/wr_rst_busy/rd_rst_busy/full/empty）已对齐 Xilinx，替换 = 删掉 wrapper、FIFO Generator 配 Independent Clocks + FWFT 后同名直连，主模块零改动。注意：IP 仿真模型加密，替换后需用**同一套 TB 在 Vivado xsim 重跑**（iverilog 编不了 IP）。

**② 帧末造行与 stage1 循环读**：BRAM 版造行是"只读不写、fcol 循环扫"。FIFO 版 stage1（存第 H-1 行）改成**弹出一字、同拍回写一字**（pop + push back 循环），行数据原地循环供给 K·W+K 拍注入；stage2..N-1 正常弹出（旧行数据下一帧头被自然冲掉，与 BRAM 版"脏数据靠 emit 门控"同构）。造行期间 `in_ready=0` 挡上游。

**③ 反压冻结链**（本模块相对 pad 版的真正增量）：

```
out_ready=0 ──► 冻结横向移位窗 + 造行FSM + 各级FIFO读（数据原地保留）
            ──► 各级FIFO渐满 ──► stage_N-1 快满 ──► in_ready=0 ──► 上游停写
恢复：out_ready=1 → 冻结解除 → 数据无损续传（FIFO 顺序保证不乱序）
```

- 行 FIFO 深度：`DEPTH_LB = 2**$clog2(IMG_W)`（≥IMG_W 的 2 的幂）；冻结期最坏积压 = 整行 IMG_W 词，够用。
- 上游责任：造行期 in_ready=0 持续 `K·W+K+N-1` 拍，链路集成时由入端 FIFO 吸收（README 既有结论），模块本身**不做**入端 FIFO（保持单一职责）。

### 4.4 接口定义（八级 ISP 行缓存唯一形态）

```verilog
module line_buffer_fifo_nxn #(
    parameter DW    = 10,     // RAW10
    parameter IMG_W = 640,
    parameter IMG_H = 480,
    parameter N     = 5       // 窗口边长（奇数）
)(
    input  wire clk, rst_n,
    // 入侧简流（完整握手）
    input  wire              in_valid,
    output wire              in_ready,     // 造行期/行FIFO满时为 0
    input  wire [DW-1:0]     in_data,      // 逐行光栅扫描
    input  wire              in_sof,       // 帧首（=tuser），给则强同步，不给靠内部计数
    input  wire              in_eol,       // 行末（=tlast）：用于校验/重同步（eol 到时应满足 col_cnt==IMG_W-1）；
                                           // 内部流水仍以 beat 计数为主，上游不接（悬空）功能不受影响
    // 出侧简流（完整握手）
    output wire              out_valid,    // 窗口有效
    input  wire              out_ready,    // 下游可收
    output wire [N*N*DW-1:0] out_win_flat, // (行*N+列)*DW，行0=顶 列0=左
    output wire              out_sof, out_eol
);
```

### 4.5 验证方案

- **参考模型**：TB 内建 Verilog golden（整帧存二维数组，逐窗口生成 replicate-padded N×N 窗口期望），记分板逐拍比对，0 误差。
- **交叉验证（已取消）**：原计划用 BRAM pad 版做"双 DUT 位级全等"。经确认 pad 版存在既有缺陷且**后续不再使用**
  （用户决策：不用管它）⇒ 该判据取消，M1 判据改为"TB 内建 golden 模型 + 独立 Python 复算"双判据。
- **场景矩阵**：
  1. 连续流（valid 常 1、out_ready 常 1）
  2. 入侧气泡（in_valid 随机）
  3. **出侧反压（out_ready 随机拉低，含长时间拉低 > 一行）**
  4. 双向随机握手（最恶劣）
  5. 多帧连续（≥3 帧，验证造行后 stage1 循环读不污染下一帧）
  6. 参数组合：DW=10/IMG_W=640/N=3 与 N=5 各跑一遍；小图 8×6 烟雾测试（造行逻辑全覆盖）
- `verify_fifo_nxn.py`：解析 sim_log 的 RES 行，用 numpy 独立重算 padded 窗口比对。

**验收（M1）**：全部场景 0 误差 + 独立 Python 复算 0 误差 + 讲解文档完成。

### 4.6 执行结果（2026-09-18 完成 ✅）

**已实现**：`fwft_wrapper.v`、`line_buffer_fifo_nxn.v`、`tb_line_buffer_fifo_nxn.v`、`verify_fifo_nxn.py`、
`FIFO行缓存设计要点.md`。

**双判据验证结果**（TB 内建 golden 逐窗口 9 点 + sof/eol 校验；Python 独立用 numpy 重算 padded 窗口）：

| 参数组合 | TB golden | Python 独立复算 | 稳态吞吐 |
|---|---|---|---|
| IMG_W=16 IMG_H=12 N=3 | ✅ PASS（7 帧 × 192 窗口） | ✅ 1344 窗口 × 9 点 0 误差 | 1.01 拍/beat |
| IMG_W=16 IMG_H=12 N=5 | ✅ PASS | — | 1.01 拍/beat |
| IMG_W=8 IMG_H=6 N=3 | ✅ PASS | — | 1.01 拍/beat |
| IMG_W=640 IMG_H=8 N=5 | ✅ PASS（7 帧 × 5120 窗口） | ✅ 35840 窗口 × 25 点 0 误差 | **1.0003 拍/beat** |

**吞吐量化**（连续流场景，1 pixel/clock 是设计目标）：`(H×W + K×W+K)` 拍应跑完一帧 ——
16×12/N=3：211 拍跑完 209 beat ✅；640×8/N=5：6404 拍跑完 6402 beat ✅。
反压/气泡场景的额外开销：入侧气泡 30% → 约 1.46×；出侧随机 50% → 约 2×；长拉低（压满 FIFO）→ 约 9×。
**结论：反压冻结链无丢数、无乱序、恢复后无损续传；未冻结时满速 1 pixel/clock。**

**修掉的问题**：
1. **造行末拍电平清零竞态（RTL 真 bug，只在反压场景暴露）**：`flush_done` 是电平，反压卡在最后一拍时会持续
   为高，用它清 `ocr/occ` 会在"还没注入最后一拍"时把窗口坐标清零 → 帧末窗口内容/sof 全错。
   改用 `flush_last = flush_done && pipe_go`（真正推进那一拍才清）。
2. 窗口坐标不能用 `row_cnt/col_cnt` 推（造行期列计数回绕）→ 改用独立计数器 `ocr/occ`。
3. TB 侧：`$random` 是**有符号**的，`($random % 1000)` 会为负导致概率全错 → 一律用 `{$random} % 1000`（无符号）。

**已弃用**：BRAM pad 版 `line_buffer_nxn_pad`（自身 TB 超时，既有缺陷）+ 计划的"双 DUT 位级全等"判据
（用户决策：该版不再使用）。

---

## 五、阶段 2：BLC 工程（M2，ISP 第一级）✅ 2026-09-18 完成

**结果**：三套判据全过——①协议/场景（双形态直连/入端 FIFO × 四场景）TB golden 960/960 位级全等 + 断言零违例；②`verify_blc.py` numpy 独立复算 0 误差；③**图像对比验证**（仿 Demosaic 链：真图 112×103 → 加每通道黑电平 → RTL → `verify_blc_img.py`）：RTL vs Python 11536 像素位级全等，PSNR 对比 不校 19.47dB / 校准 inf（位级还原）/ OB 偏-16 校正 36.12dB（三个数字均与解析值吻合），四宫格对比图 `blc_compare.png`（不校整体发灰均值 499.5 vs 理想 405.6 一眼可见）。

**实现与计划的差异**：
1. 用户补充伪代码定稿了饱和减法**写法乙**（先比较再减：比较器 + DW 位减法器 + mux，省掉 DW+1 位通路），`blc_core` 采用
2. `ENTRY_FIFO_EN=1` 直接复用 M0.5 的 `axis_stream_fifo`（DW=12 原样装 tdata，侧带不丢语义）——集成时整体换官方 AXIS Data FIFO IP
3. `out_phase[1:0]` 已实现（DPC/Demosaic 免重算相位）
4. 相位计数器踩坑一处：sof 分支"清零 col"导致下一拍 (0,1) 读到 0、整帧相位斜一列——正确语义是"fire 拍读到的是**当前像素**相位，拍末推进"；sof 拍选择/输出强制 00 顺带解决跨帧行奇偶残留（H 奇时）。详见 `BLC/BLC黑电平校正实现.md`

### 5.1 目录

```
BLC/
├── blc_axis_adapter.v   # AXIS → 简流适配（第一级专属）
├── blc_core.v           # 黑电平校正核
├── blc_top.v            # 串联：adapter + core
├── tb_blc_top.v         # AXIS 全协议 TB
├── verify_blc.py
└── BLC黑电平校正实现.md
```

### 5.2 blc_axis_adapter（承上）

- 输入：`s_axis_tdata[11:0] / tvalid / tready / tlast / tuser`（**1 pixel/clock 配置**：tdata[9:0]=像素，tdata[11:10]=补零，AXIS 字节对齐）
- 扩展项（不做）：2 pixel/clock 对应 `tdata[23:0]` 低 20bit 装两个像素（README 契约表原文）——解包逻辑留到启用双路并行时
- 行为：**取低位 10bit**（`tdata[9:0]`）、tuser→`in_sof`、tlast→`in_eol`、tvalid/tready 透传给 blc_core 的握手
- 入端弹性 FIFO：预留参数 `ENTRY_FIFO_EN`（集成时开，吸收行缓存造行反压；单级仿真默认关）；集成时首尾弹性 FIFO 用 **AXI4-Stream Data FIFO IP**（原生带 tuser/tlast sideband，比 FIFO Generator 省侧带打包）
- tdest/tkeep 不接（README：链路内无意义）
- **M0.5 附加任务：手写 `axis_stream_fifo.v`（AXI4-Stream Data FIFO 的对齐实现）**，见阶段 0b

### 5.3 blc_core（简流）

- 算法：`p_out = max(p_in - OB[ch], 0)`，**逐通道偏置**：按 Bayer 相位 `(row&1, col&1)` 选 `OB_00/OB_01/OB_10/OB_11`（参数化，默认四通道同值）
- Bayer 排列参数 `BAYER_PATTERN`（RGGB 默认）；行内相位由列计数奇偶 + 行计数奇偶判定（行/列计数器由 in_sof/in_eol 驱动清零）
- 流水 1 级；饱和只 clamp 低边（减法无上溢）
- 输出：`out_valid/out_ready/out_data[9:0]/out_sof/out_eol`（+ `out_phase[1:0]` 可选，供 DPC/Demosaic 直接用，免重算）

### 5.4 验证

- TB：AXIS 驱动（含随机 tready 反压、多帧、SOF/EOL 检查）→ 适配 → core → 记分板（Verilog 内建 golden）+ `verify_blc.py` 二次校验
- 边界用例：减到负值（clamp 0）、四通道不同偏置、RAW10 满量程、反压丢数据检查（收发计数差）

**验收（M2）**：位级全等 0 误差；反压场景收发计数一致；SOF/EOL 每帧/每行计数正确。

---

## 六、阶段 3：DPC → Demosaic（M3，Bayer 域，RAW10）✅ 2026-09-20 完成

> 实际执行与原计划不同：DPC/Demosaic 旧源码已从备份恢复（非空），按用户决定**复用已验证算法核**（逻辑零改动、位宽参数化 8→DW + 接口适配），新链路代码在 `Bayer_DPC_Demosaic/`，未重写算法。
>
> **验收结果**：四套 TB 全 PASS——双线性/MHC × 协议(16×12×5 帧四场景)/图像(112×103 真图+60 坏点)，期望比对 0 误差 + 出侧稳定性断言零违例 + 收发计数一致（960/960、11536/11536）。输出位宽按用户架构决策定为**线性 RGB 域 10bit 直通（out_data[29:0]）**，位宽缩减统一推迟到 Gamma 出口（M4 的 1024×8 LUT，内容预存 round 值零成本无偏置；VDMA 契约 tdata[23:0] 由 Gamma 出口给出）。PSNR（Bayer/RGB 均为 10bit 口径）：Bayer 域 28.33→38.84dB（+10.51）；RGB 域双线性 30.30→40.38dB（+10.08）；MHC 32.64dB（坏点链上高通细节项放大 DPC 残留，低于双线性）。对比图 `dpc_demosaic_compare.png`。
>
> **本阶段新踩坑（已记录）**：① 核 LAT=1 输出寄存器必须配 `hold_in` 保持——行缓存弹出决策（ostall）滞后一拍，反压时窗口 m 的结果会被 m+1 覆盖丢数；② include 守卫补丁连带修改——给 async_fifo 加守卫后，fwft_wrapper 里旧的"`define ASYNC_FIFO_V_INC` 再 include"会把整个文件内容屏蔽（宏已置位），必须删掉过时 define；③ 相位计数器重构（与 blc_core 同构的完整行列计数 + sof/eol 显式同步）。

> ~~DPC/Demosaic 旧源码已被清空且无备份，按新接口重新实现~~（已被上方"复用已验证算法核"结论取代；原验收基准 26.43→31.91dB / 26.05dB / 29.23dB 保留作 8bit 旧版历史参照）。

- ~~**DPC/**：5×5 窗口包络检测（复用 `line_buffer_fifo_nxn` N=5，DW=10 → 窗口 250bit）；判决-替换输出同位宽简流 + phase 透传~~ → 已实现为 `Bayer_DPC_Demosaic/dpc_stage.v`（核参数化复用 + 窗口相位自算 + hold_in 反压保持）
- **Demosaic/**：5×5 窗口，双线性版先行 + MHC 版并列（两目录并存沿用项目"变体并存"文化）；输出 RGB888 简流（`DW=24` 打包或 3 通道拆分——**决策：打包 24bit 单流**，与出端 tdata[23:0] 一致省转换）
- 每级：自检 TB + Python 校验 + 中文文档；接口与 BLC 输出（简流 + phase + sof/eol）无缝

**验收（M3）**：各版本位级全等/PSNR 达到历史结论量级；相位判定经 Bayer 色卡测试图验证（R/B 位置插值正确）。

---

## 七、阶段 4：降噪 → CCM → Gamma（M4，线性 RGB 域 10bit）✅ 2026-10-08 完成

> 原计划含 AWB；**架构修订（2026-09-21）**：①WB 增益应用移到去马赛克之前的 Bayer 域（DPC 之后，工业主流）；②AWB 模块实现挪到链路最后（M6，需 MicroBlaze 软核决策交互），M4 期间 DPC→Demosaic 之间以 1.0 增益直通占位。

### M4-1 降噪：双边滤波 ✅ 2026-09-21 完成（`BilateralFilter/`）

> **执行修订**：原计划默认中值滤波，用户拍板先做**双边滤波**（保边证据更强、面试故事更完整）。中值版留作后续对比变体。

> **验收结果**：协议 TB 四场景 + IMG 模式全 PASS（收发计数 1536=1536、11536/11536，位级 0 误差）；Python 独立第二判据位级同构复算 0 误差；PSNR/SSIM 对比图 `denoise_compare.png`。
>
> **实测指标（10bit 线性 RGB，σ_n=48 注噪）**：
>
> | | PSNR(dB) | SSIM | 边缘区 PSNR | 边缘区 SSIM |
> |---|---|---|---|---|
> | 注噪图 | 26.51 | 0.7197 | 26.51 | 0.8738 |
> | 高斯降噪（同核参考） | 32.74 | 0.9216 | 31.42 | 0.9453 |
> | 双边降噪（RTL） | 32.03 | 0.9039 | 31.06 | **0.9464** |
>
> 结论：3×3 小窗 + 窄空间核下双边以少量平坦区降噪能力换边缘保真（边缘区 SSIM 反超高斯的固有取舍），优势随窗口增大而显著。
>
> **本阶段新踩坑（已记录进全局 README「已知问题」）**：① **`in_ready` 双驱动成 X**——子模块输出端口与上层 `assign` 接同一 wire → 值冲突成 X → 握手型上游被挂死数万拍（修法：行缓存 `in_ready` 接独立 wire）；② **bypass 不能"等延迟"实现**——处理路径含行缓存 W+1 拍窗口延迟，与 4 拍旁路链不等，帧中间切换会错位（改为链路排空点帧级切换，禁热切换）；③ **σ_r 必须与噪声一起标定**——σ_r≈4.9σ_n（L1 量纲），照抄 8bit 值×4 只适合 σ_n=24，失配会让双边 PSNR 反低于高斯 3.5dB。
>
> **附带修复**：`line_buffer_fifo_nxn` 造行期发射判据改为握手兼容（`flush_fire` 每拍必发窗口，不再依赖输入侧 `beat_cnt`），M1 回归 PASS。

### M4-2 CCM：色彩校正矩阵 ✅ 2026-10-08 完成（`CCM/`）

> **伪代码核对（`伪代码.c`，5 改 1 补强）**：① 输出 8bit → **10bit**（链路契约：缩减在 Gamma 出口）；② `>>>` 是 Java/JS 写法（Python 无此运算符；Verilog 里 `>>>` 才是算术右移且需 `signed`）；③ "acc 25bit" 按 8bit 输入算的（3×8192×255≈2^22.9），10bit 输入上界 3×2^15×1023≈**2^26.6** → 取 **28bit 有符号**；④ 系数 `round()` 是 Python **银行家舍入**，与运行时 `+2^(F-1)>>F`（round-half-up）不自洽 → 统一 `floor(x·2^F+0.5)`；⑤ "负系数钳 0" 真实含义是**结果钳 0**（矩阵负系数必须保留——那是 CCM 做通道解耦的本钱）；➕ **行和残差补对角项** ⇒ 行和精确 = 4096 ⇒ **灰阶逐位保持**。

> **验收结果**：协议 TB 6 场景 **[PASS]** 1728=1728；真图 TB **[PASS]** 11536/11536；色卡 TB **[PASS]** 6144/6144；Python 独立复算真图**位级全等 0 误差**。
>
> **实测指标**：
>
> | 判据 | 结果 |
> |---|---|
> | **灰阶保持**（CCM 核心判据） | 穷举 v=0..1023 **全部逐位不变**；RTL 真图上 262 个灰像素**全部保持** |
> | **ΔE76**（24 色卡，RTL 输出） | 校正前 **12.14**（最大 40.67）→ 校正后 **0.12**（最大 0.58）；灰阶 6 块 ≈ 0 |
>
> **本阶段新踩坑（已记录进全局 README）**：① **TB 稳定性断言用错拍**——写成"当拍 valid && !ready ⇒ 数据保持"报 183 个假违规；正确判据是"**上一拍** valid=1 且 ready=0（stall）⇒ 本拍字段不变"；② **复用 TB 模板时跨语言文件名约定没对齐**（Python 出 `ccm_img_out.hex`、TB 读 `exp_img.hex`）→ 期望全 0、11536 全错；③ 三个模式共用一个 dump 文件名互相覆盖 → 按模式区分。
>
> **架构增量**：**bypass 实现方式由"处理路径延迟"决定**——CCM 逐像素级、LAT=2 ⇒ **等延迟旁路**（两路延迟严格相等 ⇒ 可帧内热切换，TB 场景 F 实测通过）；降噪含行缓存（延迟上万拍）⇒ 只能排空点切换。

### M4-3 Gamma：伽马校正 ✅ 2026-10-08 完成（`Gamma/`）—— **M4 收官**

> **伪代码核对（`伪代码.c`，3 改 + 补强）**：① `8bit 地址 → 256×8 = 2048 bit → 半个 BRAM18` **算错**（2048/18432 ≈ **11%**，不是半个；第 2、3 行是对的）；② **漏算"三通道要三个并行读口"**——BRAM18 只有 2 个读口，RGB 同拍各查一次 ⇒ 必须 **3 份副本**（3×8192 = 24576 bit ≈ 1 个 BRAM36）；③ 输入位宽按 8bit 写的 `x/255`，本链路是 10bit；➕ `floor(x+0.5)` 舍入、端点 `LUT[0]=0`/`LUT[1023]=255`、**单调性穷举校验**、**静态 .coe**（用户拍板：曲线是确定值，不走 MicroBlaze）。

> **验收结果**：协议 TB 6 场景 **[PASS]** 1728=1728；**RAMP TB（穷举 x=0..1023，查表 + bypass 两轮）[PASS]** 2048/2048；真图 TB（M3→CCM→Gamma 三级串联）**[PASS]** 11536/11536。
>
> **实测指标**：
>
> | 判据 | 结果 |
> |---|---|
> | **① LUT 全表覆盖**（RTL 穷举 vs .coe 逐项） | **1024 项全覆盖，0 误差**（不是抽样） |
> | **② 单调性 + 端点** | 单调不减 ✓；`LUT[0]=0`、`LUT[1023]=255` ✓ |
> | **②b bypass 穷举**（1024 值 vs Python 独立算 `min(round(v/4),255)`） | **0 误差**（★ 补上饱和 bug 后新增的判据） |
> | ③ 真图位级全等 | 11536 像素全等 0 误差 |
> | **④ 亮度量化**（8bit 域） | 线性直通均值 **101.34** → Gamma 均值 **164.77**（**+62.6%**）；曲线 x=64/256/512/768 → 72/136/186/224（对比线性 >>2：16/64/128/192） |
>
> **本阶段新踩坑（已记录进全局 README）**：① **★ bypass 线性转换缺饱和 → 最亮的两个值回绕成黑**（`(v+2)>>2` 在 v=1022/1023 得 256，超 8bit 截位成 0）——**用户提问挖出的真 bug**；自检 TB 没抓到是因为**期望函数用了同一个表达式**（golden 与 DUT 共享 bug），已补"TB bypass 穷举落盘 + verify Python 独立算"判据；② **TB 里两个 `initial` 分开 `$fopen` 时后一个句柄写入全丢**（文件建了但 0 字节，`$fwrite` 计数却正常）→ 合并进同一个 `initial`；③ **iverilog：移位量用无宽度常量时拼接操作数被判"宽度不定"**（`{(v0+2)>>2,...}` 编译失败）→ 先算进定宽 `reg/wire` 再拼接；④ 伪代码资源估算要逐行核算（单位 + 器件原语容量对齐）。
>
> **设计增量**：**LAT=1 的冻结要"有使能用使能"**——BRAM 自带输出寄存器 + 读使能，`run_en` 直接接 EN 即可原地保持；**只有在没有现成使能可用时才需要 `hold_in`**（对比 M3 DPC）。

| 模块 | 类型 | 要点 |
|---|---|---|
| 降噪 ✅ | 3×3 窗口 | **双边滤波**（值域 LUT + 倒数 ROM + 3 DSP 乘法，10bit 域）；输入线性 RGB 10bit（3 通道打包 30bit 单流） |
| CCM ✅ | 逐像素 | **Q5.12 有符号定点**（系数 `floor(x·2^12+0.5)` + 行和残差补对角项）+ 9 乘法 + 加树 + round-half-up + **饱和**；LAT=2；等延迟 bypass |
| Gamma ✅ | 逐像素 | **1024×8 LUT ×3 副本**（三通道同拍并行读口）+ 同步读 LAT=1；**全链位宽缩减唯一出口**（10bit→RGB888）；bypass = 线性 10→8 |

每级独立目录（`Denoise/ CCM/ Gamma/`）+ TB + Python 校验 + 文档；输入输出统一简流（线性 RGB 域 3×10bit；Gamma 出口 3×8bit）。

**验收（M4）**：逐级位级全等（Python 参考 10bit 域同公式）+ 反压场景收发一致 + PSNR 对比图。
- 降噪选型：**双边滤波已实现**（M4-1 ✅）；中值版留作后续对比变体（历史椒盐场景 26.18dB）
- CCM：**全链唯一必须用乘法器/DSP 的一级**；系数 ×256 定点化（沿用 CSC 经验）、负系数钳 0、饱和限幅
- Gamma：**1024×8bit LUT**（10bit 进 8bit 出），BRAM 实现；3 通道各一块或合一块（地址拼通道），表内容软件预生成（含 round）

---

## 八、阶段 5：锐化 + 出端 AXIS 适配（M5）

### 8.1 M5.1 ✅ 2026-10-09 完成

- **`Sharpen/`**：USM 锐化 `out = clip(orig + k*(orig - blur))`，blur 用 3×3 高斯（复用 `line_buffer_fifo_nxn`，N=3）；强度 k 参数化（`k = k_gain/2^8`，10bit 端口）
- **`AxisOut/`**：出端适配器，简流(RGB888) → AXIS：`tdata[23:0] + tkeep=3'b111 + tuser(帧首) + tlast(行末) + tvalid/tready` + 弹性 FIFO（复用 `axis_stream_fifo`）；CDC 留集成阶段

**结果**：Sharpen 三模式 TB 全 PASS（协议四场景+bypass 三段 1536/1536、K64 1536/1536、真图四级串联 11536/11536）+ Python 位级全等；锐度 Tenengrad +9.3% / \|Laplacian\| +35.7%（PSNR 39.30dB）。AxisOut：S2MM 契约逐条通过（fire 3072=收 3072、帧 16、行 192、tkeep≡111、稳定性/复位断言零违例）+ Python 独立解析真实 AXIS 流复算通过。

**两个关键设计点（写进 README）**：① **修正量用"符号-幅值"两路**（`d=|orig−blur|`，`adj=(d·k_gain+2^7)>>8`，`out=orig±adj`）——消灭 Verilog"signed⊕无符号常量"翻转 + 负数算术右移 floor 与就近取整的歧义；② **k 与 bypass 同为帧级配置**，改动必须落在**排空点**（处理路径含行缓存、上千万拍延迟；帧中间改 k/切 bypass 必错位）。

**★ 时序收敛（M5.1 追加，2026-10-09）**：新增 `synth_ooc_timing.tcl`（Vivado OOC 预检，`xcvu19p-fsva3824-2-e` @150 MHz）后发现**功能 0 误差 ≠ 时序能收敛**——`sharpen_stage` 35 级/−1.930ns ❌、`denoise_stage` 40 级/−5.804ns ❌、`ccm_stage`（无行缓存）8 级/+4.748ns ✅。病因 = **行缓存 pad mux（组合）+ 吃窗口的核**挤在同一拍。修法（统一套路）：**stage 内对 `lb_win` 插窗口寄存器（不动共用件）+ 核内拆流水 + 算术表达式定宽**。结果：**锐化 15 级/+2.583ns ✅、降噪 13 级/+2.145ns ✅**（全程 TB 重跑位级 0 误差）。完整证据链见 [Sharpen/README.md](Sharpen/README.md)、[BilateralFilter/README.md](BilateralFilter/README.md) 的「时序收敛实战」。

### 8.2 M5.2 ✅ 2026-10-10 完成（RGB 三段链 + ★ 顺序可交换性实验）

> 用户拍板（2026-10-10）：**不做整链**，先把 `降噪 → CCM → Gamma` 三段串起来作为 M5.2，
> 并做"降噪 / CCM 顺序是否可交换、谁在前更好"的实验，为 8 级链路的**排序**提供量化论证（整链另开 M5.3）。

- **`Denoise_CCM_Gamma/`**：`rgb_chain_top.v`（三段串联，30bit 线性 RGB 进 → RGB888 出）+ `tb_rgb_chain.v` + `make_chain_data.py` + `verify_chain.py` + 四宫格对比图
- **实验设计（公平性三原则）**：① **单一变量**——只用一个参数 `SWAP_DC` 切换降噪/CCM 顺序，`generate` 两条分支，其余例化/参数/激励/判据**全部相同**；② **总延迟相等**（`7+2+1 = 2+7+1 = 10` 拍，加法交换律）⇒ 两种顺序的流**逐拍可对齐**，位级差异纯粹来自算法顺序；③ **客观靶子**——与**无噪声理想图** `Gamma(CCM(clean))` 比 PSNR/SSIM，另设**不降噪基线** `Gamma(CCM(noisy))` 量化降噪本身的收益
- **验证**：协议 TB 两种顺序各 **[PASS]**（small 1152/1152、真图 11536/11536，位级 0 误差 + 反压稳定零违例）；**两顺序收发计数完全相同**（实测佐证"总延迟与顺序无关"）；`verify_chain.py` 独立重算与 RTL 落盘**逐位 0 误差**

**★ 顺序实验结论（四类互相独立的证据）**

| 证据 | 无噪理想 | 不降噪基线 | **顺序0 降噪→CCM** | 顺序1 CCM→降噪 |
|---|---|---|---|---|
| 位级差异（vs 顺序0） | — | — | — | **98.2% 像素不同**（max 67，MAD 2.88）⇒ **不可交换** |
| PSNR / SSIM vs 理想 | ∞ / 1.0000 | 23.11 dB / 0.7918 | **28.67 dB / 0.9323** | 27.16 dB / 0.9147 |
| 色差 (R−G) 梯度 RMS | 17.263 | 48.441 | **17.812** | 26.316（比理想高 52%） |
| CCM 饱和样本数 | — | — | **75** | 381（**5.1×**） |

- **顺序0 优于顺序1 `1.51 dB`**；降噪本身收益 `+5.56 dB`（相对不降噪基线）
- **两条独立机理**（改一条都不够）：① **数值域**——CCM 含负系数、对角 >1，会放大并混合三通道噪声，把更多样本推到 `0/1023` **饱和**（75 → 381），裁掉即永久丢信息；② **算法域**——CCM 把通道独立噪声染成**通道相关的色噪声**，而双边滤波值域权重按 `|ΔR|+|ΔG|+|ΔB|` 判相似度，噪声被当成"边缘"保护起来 ⇒ 降噪退化
- **可复用性**：该"一参数切顺序 + 与理想图比 PSNR/SSIM + 双机理指标"模板可直接套用到 **BLC / DPC 先后**之争（后续实验），判据是①总延迟可交换 ②能造无缺陷理想图 ③能单参数隔离变量

**面试口径**：见 [面试故事集.md](面试故事集.md) 故事 3「降噪和 CCM 谁在前？—— 用一个参数切顺序，把"链路排序"从经验变成数据」。

### 8.3 M5.3 ⬜ 待做（8 级整链串联）

- **整链 TB**：AXIS 进（RAW10 帧流）→ 8 级（AWB 位直通占位）→ AXIS 出，全链 PSNR + 逐级插桩比对
- **验收（M5.3）**：整链输出 PSNR 报告（注明参考基准）+ 逐级插桩 0 误差 + S2MM 契约在全链尺度仍成立
- 注意：三段链的 per-stage 延迟账已清（降噪 7 / CCM 2 / Gamma 1；锐化 3），整链的逐级对齐有据可依

### 8.4 链路排序量化论证（追加实验，面试用）

> 用户点做（2026-10-10）：**用受控实验回答"8 级链路为什么这么排"**，而不是靠教科书印象。
> 统一模板：**一个参数切顺序 + 客观靶子 + 多类独立证据**；两个实验共用同一套方法论。

**实验一 · 降噪 vs CCM**（`Denoise_CCM_Gamma/`，参数 `SWAP_DC`）→ §8.2 已详述
结论：**不可交换**（98.2% 像素位级不同）；**降噪在前优 1.51 dB**（28.67 vs 27.16、SSIM 0.9323 vs 0.9147）；
色差 (R−G) 梯度 RMS 17.81 vs 26.32（理想 17.26）；CCM 饱和样本 75 vs 381（5.1×）。
两条独立机理：① 数值域——CCM 含负系数、对角 >1，放大并混合噪声、更多撞饱和；
② 算法域——CCM 把通道独立噪声染成**色噪声**，破坏双边滤波"按 `|ΔR|+|ΔG|+|ΔB|` 判相似"的前提。

**实验二 · BLC vs DPC**（`BLC_DPC/`，参数 `SWAP_BD`，2026-10-10 完成）
- 靶子换成 RAW 域该关心的：**传感级缺陷 60 个（亮点 1023/死点 0 各半）+ 低于黑电平像素 40 个**的刻意注入；
  **TP/FP/FN + 与光强真值的 PSNR/MAE + 黑电平残差**作判据
- 验证：两顺序、两模式 TB 全 `[PASS]`（`1152/1152`、`11536/11536`，位级 0 误差、**相位违例 0**、反压稳定零违例）；
  `verify_blc_dpc.py` 独立重算逐位 0 误差；出 `blc_dpc_compare.png`（6 格）
- **★ 三级递进（本实验最有价值的产出）**：

| 层级 | 判据 / 发现 | 结果 |
|---|---|---|
| 预测① | `diff ⊆ U`（自己低于黑电平） | **被实测证伪 8 个像素** |
| 预测② | `diff ⊆ reach(U)`（同相位邻居一跳闭包） | **仍证伪同一批** ⇒ 排除整个"传播型"假设类 |
| 诊断 | 越界 8 个**全是 G 相位**；G 占全图 50.0% 却占差异 88.0%；R/B 差异仅 3 且全在下溢处 | — |
| 根因 | DPC 把 **Gr/Gb 当"同色"邻居**，而 **`OB[Gr]=64 ≠ OB[Gb]=180`（差 116 LSB）** ⇒ 邻域内"按相位平移"不均匀 ⇒ 等变性对 **G 中心天然失效** | — |
| 修正 | 必要条件 `diff ⊆ { c : S(c) 内 OB 全相同 且 无像素低于自身 OB }`；R/B 满足 ⇒ 不下溢即可交换；**G 中心天然不满足** | ✅ |

- **结论**：**分相位看**，不能一概而论。质量上两者几乎等价（0.22% 像素、0.38 dB）
  ⇒ **顺序不能用"谁更好"回答，只能用"谁与契约/量纲一致"回答**：**BLC 必须在前**，
  因为它是唯一能把 Gr/Gb 拉到同一量纲的操作（否则 116 LSB 变"假台阶"，实测 TP 54→55、FN 6→5）
- **方法论教训（已记入全局 README 已知问题）**：
  ① **理论预测不是 pass/fail 判据**（`ok` 只由独立复算门控；预测被证伪是研究结论）；
  ② **指标的定义域与定义式都要审**（"近黑残差"第一版把缺陷/下溢像素算进去 → 假残差 74.5，修正后恒 0.00）；
  ③ 顶层例化两个不同目录的模块时 `-I` 要**两个都指到**

**两个实验合起来的方法论**：链路排序的论证有两种形态 ——
**"质量有差"（用 PSNR 判优）** 与 **"质量无差、但量纲/契约有差"（用不变性与量纲判优）**。
第二种更常见、也更容易被面试官追问（不能靠报一个 dB 数糊过去）。面试叙事见 [面试故事集.md](面试故事集.md) 故事 3 / 故事 4。

**验收（M5，已完成部分）**：S2MM 契约逐条核对（每帧首拍 tuser、每行末拍 tlast、tkeep=111、HSIZE/VSIZE 与分辨率一致）✅

---

## 八b、阶段 6：AWB 统计 + 增益 + 软核闭环（M6，链路最后实现）

> 用户拍板（2026-09-21）：AWB 涉及 MicroBlaze 软核决策交互（PL 暴露统计 → 裸机 C 算增益 → AXI-Lite 回写 → 下一帧生效），放到其它模块全部串联完成之后做。M5 完成时 DPC→Demosaic 之间为 1.0 增益直通占位。

- **awb_gain 应用级**（Bayer 域，DPC→Demosaic 之间）：与 `blc_core` 完全同构——按 `(row&1, col&1)` 相位从 `gain_00/01/10/11`（R/Gr/Gb/B）选一个做乘法，1 级流水可反压；增益寄存器可配（AXI-Lite），默认 1.0
- **awb_stat 统计级**（Bayer 域，接 DPC 出）：按相位分组统计 R/Gr/Gb/B 均值（复用直方图双 BRAM 乒乓经验：统计第 N 帧、增益应用于第 N+1 帧）
- **软核闭环**：MicroBlaze 裸机 C 读统计寄存器 → 算增益（灰世界/白点法）→ AXI-Lite 回写 → 下一帧生效（命中 JD"Vitis 裸机协同"，与 6month 计划 P3 W4 呼应）
- WB 在 demosaic 前的架构依据：Bayer 域每像素 1 次乘法（省 3×）、AWB 统计按相位分组天然在此、先平衡再插值伪彩少；**WB（对角阵）必须在 CCM（满阵）之前**——数学上 WB·CCM ≠ CCM·WB

**验收（M6）**：增益应用级位级全等（Python 同公式，双帧验证"第 N 帧统计 → 第 N+1 帧生效"行为）；软核闭环在上板阶段联调。

---

## 九、里程碑与执行顺序

| 里程碑 | 内容 | 前置 |
|---|---|---|
| **M0** ✅ | async_fifo 五阶段 [PASS]（2026-09-18） | 无（立即可做） |
| **M0.5** ✅ | axis_stream_fifo 手写（AXIS Data FIFO 对齐版，含侧带 + 协议断言）0 误差（2026-09-18） | M0 |
| **M1** ✅ | line_buffer_fifo_nxn：双判据 0 误差（4 组参数 PASS，含 640 宽图）+ 稳态 1 pixel/clock + 讲解文档（2026-09-18） | M0 |
| **M2** ✅ | BLC（AXIS 适配 + 核）位级全等，双形态双判据 0 误差（2026-09-19） | M0（行缓存不强依赖，BLC 是逐像素级） |
| **M3** ✅ | DPC→Demosaic 串联链：算法核参数化复用 + 简流反压 + hold_in 丢数修复；双核双判据 0 误差 + PSNR/对比图（2026-09-20） | M1 + M2 |
| **M4** ✅ | 降噪 ✅ / CCM ✅ / Gamma ✅（线性 RGB 域三模块全部完成；AWB 位 1.0 直通占位） | ✅ 2026-10-08 |
| **M5.1** ✅ | 锐化（USM，感知域 RGB888）+ 出端 AXIS 适配（S2MM 契约）：三模式 TB 全 PASS + 锐度量化 + 契约逐条核对；✅ 2026-10-09 | M4 |
| **M5.2** ✅ | RGB 三段链（降噪→CCM→Gamma，30bit→RGB888）+ **顺序可交换性实验**（`SWAP_DC` 单参数；不可交换 98.2%、顺序0 优 1.51dB）；✅ 2026-10-10 | M5.1 |
| **M5.3** | 8 级整链串联（AXIS(RAW10) 进 → RGB888 出，全链 PSNR + 逐级插桩比对） | M5.2 |
| **M6** | AWB 统计 + Bayer 域增益应用 + MicroBlaze 闭环（联调在上板阶段） | M5.3 |

每阶段由用户口头触发开工（"开始做 XX"），单阶段一次会话内完成 RTL+TB+文档闭环；**不越级预做后续阶段**。

## 十、假设与暂不定项

1. 链路集成（AXI-Lite 控制面、Microblaze、实机联调）不在本计划范围——各级参数先用 parameter/TB 端口配置，留 AXI-Lite 寄存器化到集成阶段。
2. 入端/出端弹性 FIFO 的 CDC 场景（CSI-2 像素时钟 vs 系统时钟）在单级仿真中用同频异步相位模拟，实机时序在集成阶段验证。
3. Demosaic MHC 版若时间紧可降级为"双线性单版本 + 文档记录 MHC 思路"。
4. DPC/Demosaic 重实现以 README 历史结论为基准，不追求逐位复刻旧实现（旧码已不可恢复）。
