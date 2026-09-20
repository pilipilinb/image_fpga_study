# FIFO 行缓存与 8 级 ISP 链路实施计划

> 目标：以 `fifo/async_fifo.v` 为基础制作 **FIFO 版任意尺寸行缓存 `line_buffer_fifo_nxn`**（pad 输出 + 简流握手反压），作为未来 8 级 ISP 唯一行缓存复用件；随后按 **BLC → DPC → Demosaic → 降噪 → AWB → CCM → Gamma → 锐化** 逐级建工程，首级承接 MIPI CSI-2 RX 的 AXIS(RAW10)，末级对接 VDMA S2MM。
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
CSI-2 RX ─AXIS(RAW10)─► [AXIS适配+入端FIFO] ─简流─► BLC ─简流─► DPC ─简流─► Demosaic ─简流(RGB888)
                                                                      ─简流─► 降噪 ─► AWB ─► CCM ─► Gamma ─► 锐化
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
> **验收结果**：四套 TB 全 PASS——双线性/MHC × 协议(16×12×5 帧四场景)/图像(112×103 真图+60 坏点)，期望比对 0 误差 + 出侧稳定性断言零违例 + 收发计数一致（960/960、11536/11536）。PSNR（RAW10，THR=128）：Bayer 域 28.33→38.84dB（+10.51）；RGB 域双线性 30.30→40.38dB（+10.08）；MHC 32.64dB（坏点链上高通细节项放大 DPC 残留，低于双线性）。对比图 `dpc_demosaic_compare.png`。
>
> **本阶段新踩坑（已记录）**：① 核 LAT=1 输出寄存器必须配 `hold_in` 保持——行缓存弹出决策（ostall）滞后一拍，反压时窗口 m 的结果会被 m+1 覆盖丢数；② include 守卫补丁连带修改——给 async_fifo 加守卫后，fwft_wrapper 里旧的"`define ASYNC_FIFO_V_INC` 再 include"会把整个文件内容屏蔽（宏已置位），必须删掉过时 define；③ 相位计数器重构（与 blc_core 同构的完整行列计数 + sof/eol 显式同步）。

> ~~DPC/Demosaic 旧源码已被清空且无备份，按新接口重新实现~~（已被上方"复用已验证算法核"结论取代；原验收基准 26.43→31.91dB / 26.05dB / 29.23dB 保留作 8bit 旧版历史参照）。

- ~~**DPC/**：5×5 窗口包络检测（复用 `line_buffer_fifo_nxn` N=5，DW=10 → 窗口 250bit）；判决-替换输出同位宽简流 + phase 透传~~ → 已实现为 `Bayer_DPC_Demosaic/dpc_stage.v`（核参数化复用 + 窗口相位自算 + hold_in 反压保持）
- **Demosaic/**：5×5 窗口，双线性版先行 + MHC 版并列（两目录并存沿用项目"变体并存"文化）；输出 RGB888 简流（`DW=24` 打包或 3 通道拆分——**决策：打包 24bit 单流**，与出端 tdata[23:0] 一致省转换）
- 每级：自检 TB + Python 校验 + 中文文档；接口与 BLC 输出（简流 + phase + sof/eol）无缝

**验收（M3）**：各版本位级全等/PSNR 达到历史结论量级；相位判定经 Bayer 色卡测试图验证（R/B 位置插值正确）。

---

## 七、阶段 4：降噪 → AWB → CCM → Gamma（M4，RGB 域）

| 级 | 实现 | 要点 |
|---|---|---|
| 降噪 | 复用 MedianFilter/GaussianFilter 算法核 | DW 适配 RGB888、3×3 复用 `line_buffer_fifo_nxn`(N=3)；选型默认**中值**（椒盐 26.18dB 最优）|
| AWB | 帧级统计 + 增益 | 复用 histogram_tutorial 双 BRAM 乒乓经验：统计第 N 帧、增益应用于第 N+1 帧；增益寄存器可配 |
| CCM | 3×3 矩阵乘 | **全链唯一必须用乘法器/DSP 的一级**；系数 ×256 定点化（沿用 CSC 经验）、饱和限幅 |
| Gamma | 256×10bit LUT | BRAM 实现，表内容 TB 可改；3 通道各一块 |

每级独立目录（`Denoise/ AWB/ CCM/ Gamma/`）+ TB + Python 校验 + 文档；输入输出统一简流（DW=24）。

**验收（M4）**：逐级位级全等（AWB 增益延迟一帧的行为用双帧测试验证）。

---

## 八、阶段 5：锐化 + 出端 AXIS 适配（M5）

- **Sharpen/**：USM 锐化 `out = clip(orig + k*(orig - blur))`，blur 用 3×3（复用 line_buffer_fifo_nxn + 高斯核）；强度 k 参数化
- **出端适配器**：简流(RGB888) → AXIS：`tdata[23:0] + tkeep=3'b111 + tuser(帧首) + tlast(行末) + tvalid/tready`
- 出端弹性 FIFO + CDC（与入端对称）；反压回传：`tready=0 → FIFO 满 → 逐级 ready → 入端`
- 整链 TB：AXIS 进（RAW10 帧流）→ 8 级 → AXIS 出，全链 PSNR + 逐级插桩比对

**验收（M5）**：S2MM 契约逐条核对（每帧首拍 tuser、每行末拍 tlast、tkeep=111、HSIZE/VSIZE 与分辨率一致）；整链 PSNR 报告（注明参考基准）。

---

## 九、里程碑与执行顺序

| 里程碑 | 内容 | 前置 |
|---|---|---|
| **M0** ✅ | async_fifo 五阶段 [PASS]（2026-09-18） | 无（立即可做） |
| **M0.5** ✅ | axis_stream_fifo 手写（AXIS Data FIFO 对齐版，含侧带 + 协议断言）0 误差（2026-09-18） | M0 |
| **M1** ✅ | line_buffer_fifo_nxn：双判据 0 误差（4 组参数 PASS，含 640 宽图）+ 稳态 1 pixel/clock + 讲解文档（2026-09-18） | M0 |
| **M2** ✅ | BLC（AXIS 适配 + 核）位级全等，双形态双判据 0 误差（2026-09-19） | M0（行缓存不强依赖，BLC 是逐像素级） |
| **M3** ✅ | DPC→Demosaic 串联链：算法核参数化复用 + 简流反压 + hold_in 丢数修复；双核双判据 0 误差 + PSNR/对比图（2026-09-20） | M1 + M2 |
| **M4** | 降噪/AWB/CCM/Gamma 逐级通过 | M3（Demosaic 出 RGB888） |
| **M5** | 锐化 + 出端适配 + 8 级整链 | M1-M4 |

每阶段由用户口头触发开工（"开始做 XX"），单阶段一次会话内完成 RTL+TB+文档闭环；**不越级预做后续阶段**。

## 十、假设与暂不定项

1. 链路集成（AXI-Lite 控制面、Microblaze、实机联调）不在本计划范围——各级参数先用 parameter/TB 端口配置，留 AXI-Lite 寄存器化到集成阶段。
2. 入端/出端弹性 FIFO 的 CDC 场景（CSI-2 像素时钟 vs 系统时钟）在单级仿真中用同频异步相位模拟，实机时序在集成阶段验证。
3. Demosaic MHC 版若时间紧可降级为"双线性单版本 + 文档记录 MHC 思路"。
4. DPC/Demosaic 重实现以 README 历史结论为基准，不追求逐位复刻旧实现（旧码已不可恢复）。
