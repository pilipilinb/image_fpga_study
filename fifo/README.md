# fifo —— 手写 FIFO 基础件（async_fifo + axis_stream_fifo）

> 定位：跨时钟域传数据 + 速率匹配/背压缓冲的通用基础件。`async_fifo` 是双时钟版（M1 的 `line_buffer_fifo_nxn` 内部例化它做行延迟）；`axis_stream_fifo` 是单时钟 AXIS 版（链路首尾弹性 FIFO，M2 的 BLC 出入两端直接用）。
> 两者接口分别对齐 **Xilinx FIFO Generator（Independent Clocks）** 与 **AXI4-Stream Data FIFO IP**，集成时可被官方 IP 无缝替换（替换缝见文末）。

## 文件清单

| 文件 | 说明 |
|---|---|
| `async_fifo.v` | 双时钟 FIFO RTL（格雷码指针，`ram_style="block"` 推 BRAM） |
| `tb_async_fifo.v` | 五阶段自检 TB（同步/写快读慢/写慢读快/满空/复位） |
| `axis_stream_fifo.v` | 单时钟 AXIS FIFO RTL（tuser/tlast 侧带打包，FWFT 输出级） |
| `tb_axis_stream_fifo.v` | 四阶段自检 TB（满速/双侧随机/满空/复位 + 协议断言） |
| `fifo接口说明` | async_fifo 单时钟（同频同相）使用时的例化片段 |
| `sim_log.txt` / `sim_log_axis.txt` | 最新仿真产物（2026-09-18 双双 [PASS]） |

## 接口

| 信号 | 方向 | 说明 |
|---|---|---|
| `wr_clk` / `rd_clk` | in | 写/读时钟，可异步可同频（同频同相即单时钟用法） |
| `rst` | in | **高有效**（同 Xilinx），两域各自同步释放 |
| `din[DW-1:0]` / `wr_en` | in | 写口，`wr_en && !full` 才真正写入 |
| `rd_en` | in | 读口，`rd_en && !empty` 才真正读走 |
| `dout[DW-1:0]` | out | **标准读模式**：rd_en 拉高的**下一拍**出数 |
| `full` / `empty` | out | 满/空，**寄存一拍输出**（Cummings 标准，原因见踩坑 1） |
| `data_count` | out | 读时钟域视角的"可读字数"（0..DEPTH），跨域同步有 2~3 拍延迟，**偏保守** |
| `wr_rst_busy` / `rd_rst_busy` | out | 复位同步期间为高，此时该域不工作 |

参数：`DW`（数据位宽，默认 8）、`DEPTH`（深度，必须 2 的幂，默认 512）。

## 核心设计决策（为什么这么写）

1. **格雷码指针 + 2 拍同步**：两域各维护自己的指针（二进制做加减、格雷码跨域）。格雷码相邻值只变 1 位，跨域采样最多"采旧或采新"、不会采出乱码——这是异步 FIFO 安全判空满的核心技巧。
2. **指针位宽 AW+1（绕圈位）**：满判断 = 写指针下一个值 == {同步读指针高 2 位取反, 其余位}；空判断 = 读指针下一个值 == 同步写指针。多出的最高位区分"空"和"满"。
3. **空满判断用 `*_next`（前瞻值）且寄存一拍输出**：第 DEPTH 个写进行的那一拍 full_val 置 1、下一拍 full=1 挡住第 DEPTH+1 个写——所以**从空到满恰好写入 DEPTH 个字**（TB 阶段 D 的判据）。不寄存一拍会构成组合环，见踩坑 1。
4. **复位**：异步断言、各域同步释放（busy 期间该域指针清零、不工作）；BRAM 存储阵列**不可复位**（物理限制），指针清零后 empty=1 天然读不到残留数据。
5. **data_count 放读域**：= 同步过来的写指针 − 本地读指针。跨域同步延迟导致它比真实剩余字数略保守（偏小），做"剩多少水"的水线判断够用；要绝对精确只能在单时钟域用。

## 踩坑记录 1：组合逻辑环 → vvp 吃 22.6GB（2026-09-18，重要）

**现象**：vvp 跑起来后内存以 ~600MB/s 疯涨，用户机上积累到 **22.6GB、系统内存 98%**；sim_log.txt 和 VCD 都是 0 字节；TB 里的 `#20_000_000` 超时兜底**完全失效**（仿真时间冻结，走不到那一句）。

**根因**：空满判断原本是裸 assign：

```verilog
// 错误写法（当时）：
assign full  = (wgray_next == {...rgray_s2...});   // wgray_next 又被 full 门控！
wire wbin_next = wbin + ((wr_en && !full) ? 1 : 0); // full → wbin_next → wgray_next → full 环
```

`full` 参与 `wbin_next` 的写门控，`wbin_next` 又反过来决定 `full`——**组合逻辑环**。当占用数=DEPTH-1 且 wr_en=1 时方程无稳定解（empty 同理，占用数=1 时震荡）：vvp 对环做零延迟的无限事件迭代，事件队列无限膨胀；看门狗实测 0.0s 15MB → 0.3s 190MB → 0.5s 321MB 被杀、零输出。这种代码**综合也是非法的**（combinational loop），属于必须消灭的写法。

**修复**：Cummings 标准写法——判断照用前瞻值，但**寄存一拍再输出**：

```verilog
reg  full_r;
wire full_val = (wgray_next == {~rgray_s2[AW:AW-1], rgray_s2[AW-2:0]});
always @(posedge wr_clk) full_r <= wr_rst_busy ? 1'b0 : full_val;
assign full = full_r;                                  // empty 对称，读域
```

**教训**：凡是"参与自身门控的状态判断信号"（空/满/几乎空满等），一律寄存器化输出；TB 里也要留心——这种环会让超时兜底形同虚设，**跑 vvp 养成带看门狗的习惯**（内存/时间硬上限）。

## 踩坑记录 2：TB 激励的三类竞态（本次跑通实际触发）

1. **流程里直接写 `wr_en=0` 无效**：激励由 always 块每拍持续驱动，下一拍就被覆盖 → "想让读停但读没停"，排空/写满检查全错。**修法：加 `wr_stop/rd_stop` 从激励源头关断**。
2. **激励带 `if(!rst)` 门控反而危险**：复位期间 wr_en "保持复位前的值 1"，释放沿（busy 恰好已清）可能吃进 1 个计划外写入而记分板没记 → 数据全错位。**修法：去掉门控**——激励每拍无条件驱动，值完全由 stop/cont 决定；复位期间多出的激励无害（DUT 写口与记分板都带 `wr_rst_busy` 条件）。同时 `wr_stop=1` 要在 `rst=0` **之前几拍**就位，封死释放沿的同拍竞态。
3. **排空判据不能用定值**：B/C 阶段收尾若等 `r_cnt` 到某个 r_mark，收尾时读侧本来就滞后写侧几个字（FIFO 里还压着字没排空）→ 下一个"必须从空开始"的检查（阶段 D 写满）假错。**修法：排空判据用 `r_cnt == w_cnt`**（每个已写字都被读走才是真空）。

## 标准读 vs FWFT，以及换 Xilinx IP

- **本模块是标准读模式**（同 Xilinx IP 默认）：`rd_en` 下一拍 `dout` 才有效。"每字一拍"的连续读：rd_en 常 1 配合 `!empty`，dout 晚 1 拍但不掉字。
- **FWFT（First Word Fall Through）**：empty=0 时 dout 已持有最老的字，读走即出下一个。本模块改 FWFT 只需加一级预取寄存器——M1 的 `line_buffer_fifo_nxn` 会做 `fwft_wrapper` 包装（行缓存逐拍取窗需要 FWFT 语义，否则每行斜一拍）。
- **替换为官方 IP**：Vivado FIFO Generator 选 *Independent Clocks*，信号一一对应（rst 高有效、busy、data_count 全同名）；要 FWFT 就在 IP 里勾选 *First Word Fall Through*。手写版先在 iverilog 上把链路逻辑验证完，集成阶段整体换 IP 再上 xsim 复跑，是本工程"手写理解 → IP 量产"的既定路线。

## axis_stream_fifo（单时钟 AXIS 版，2026-09-18 M0.5 新增）

对齐 Xilinx **AXI4-Stream Data FIFO IP**：`aclk/aresetn`（低有效）+ `s_axis_*`/`m_axis_*`，参数 `DW/DEPTH/TLAST_EN/TUSER_EN/TUSER_W`（链路默认 tuser 1bit=帧首 SOF）。用途：ISP 链路首尾弹性 FIFO（CSI-2 RX→BLC 入端、锐化→VDMA 出端）。

### 设计决策

1. **单时钟不用格雷码**：跨域归 CDC 层，指针直接本域比较。空满判断比较**当前指针值**（不前瞻、不参与自身门控）→ 结构上不存在组合环（对 async_fifo 踩坑的规避）；代价是 full 滞后一拍，效果恰好是"从空写满 DEPTH 个 BRAM 字"。
2. **侧带打包**：`{tuser, tlast, tdata}` 拼宽字进同一块 BRAM，数据与语义逐拍对位不错位——官方 IP 相对"FIFO Generator + 手动侧带"的核心优势，手写同样做到。
3. **FWFT 输出级（不是可选项）**：AXIS 规范要求 `m_axis_tvalid=1` 时 `tdata` 必须有效，BRAM 同步读做不到"tvalid 当拍才出数"，必须**输出寄存器 + 自动预取**——把最老字提前搬进输出寄存器，`tvalid` 就是输出寄存器 valid。同拍"消费+预取"使连续流零气泡。副作用：**总容量 = DEPTH+1**（与 Xilinx FWFT 模式容量语义一致），TB 阶段 C 的写满判据就是 17（DEPTH=16）。
4. **AXIS 协议自检**（TB 内建断言，违例计 err）：tvalid 未 ready 时字段保持稳定、valid 不提前撤销；复位期间 m_axis_tvalid=0。

### TB 四阶段

A 满速背靠背 500 字（8×6 帧语义流，tuser=帧首/tlast=行末全程对位比对）/ B 源随机 70% + 汇随机 50% 共 1000 字 + 真排空 / C 空读（空时 tvalid 必为 0）→ 读停写满（容量恰 DEPTH+1、tready=0）→ 全读出 / D 运行中复位（旧字丢弃、复位后重收 200 字）。

**最新结果**：`[PASS]`，三元组（data/tlast/tuser）逐拍 0 误差，协议断言零违例，水线峰值 17。日志 `sim_log_axis.txt`。

### TB 踩坑（本次实际触发）

1. **模式变量声明成 1bit reg**：`reg src_mode` 赋值 2（随机模式）被截断成 0（停止）→ 阶段 B 死等超时。多值控制变量用 `integer`。
2. **源载入上限基准用错计数器**：源模型有两个计数——`ngen`（已载入）与 `snd_cnt`（已被 fire），写满/反压场景下二者不相等（字会停在 valid 上等 ready）。设"发 N 字"的目标必须以 `ngen` 为基准，否则源停摆。
3. **DUT 例化忘了写**：s_tready 悬空为 Z，`tvalid && tready` 永假、snd_cnt 恒 0——TB 骨架先写激励后补 DUT 时的高发错误。

## 单时钟用法（同频同相，async_fifo）

见 `fifo接口说明`：`wr_clk`/`rd_clk` 接同一个 clk 即可。注意 **`.rst(!rst_n)` 极性要反转**（本模块高有效，工程习惯低有效）；格雷码/双域同步机制在同频下照常工作，只是多余但无害。

## 仿真

```powershell
cd fifo
iverilog -o tb_fifo.vvp tb_async_fifo.v         # async_fifo（TB 头部已 include DUT）
vvp tb_fifo.vvp > sim_log.txt                   # 建议 Start-Process + 内存/时间看门狗跑
iverilog -o tb_axis.vvp tb_axis_stream_fifo.v   # axis_stream_fifo
vvp tb_axis.vvp > sim_log_axis.txt
gtkwave tb_async_fifo.vcd / tb_axis_stream_fifo.vcd
```

五阶段：A 同频连续 1000 字 / B 写快读慢+随机气泡 3000 字（撞 full）/ C 写慢读快 3000 字（撞 empty）/ D 从空写满（恰好 DEPTH 个写）再读空 / E 运行中复位后重收 500 字。

**最新结果（2026-09-18）**：`[PASS] async_fifo：五个阶段全部通过`，err=0，水线峰值 512 = DEPTH，vvp 0.8s 跑完。
