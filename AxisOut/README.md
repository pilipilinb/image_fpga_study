# AxisOut —— M5.1 出端 AXIS 适配（简流 RGB888 → VDMA S2MM）

8 级 ISP 链路的**出口一级**：把链路内部的**简流**（`valid/ready + data + sof/eol`）转成 **标准 AXI4-Stream**，并带一块**弹性 FIFO** 做速率匹配与反压缓冲。对应架构图上的 `[出端适配+出端FIFO]` 方块。设计与契约逐条见 [AxisOut实现计划.md](AxisOut实现计划.md)。

## 文件清单

| 文件 | 说明 |
|---|---|
| `axis_out_adapter.v` | 出端适配器：字段映射（sof→tuser / eol→tlast / `tkeep≡111`）+ 弹性 FIFO（复用 `axis_stream_fifo`） |
| `tb_axis_out_adapter.v` | 自检 TB：五场景 + **S2MM 契约逐条记分板**（tuser/tlast/tkeep/HSIZE/VSIZE/稳定性/复位） |
| `make_axis_out_data.py` | 源序列 `ao_src.hex`（4 帧 × 16×12 个 24bit 像素） |
| `verify_axis_out.py` | 独立第二判据：解析 RTL 落盘的真实 AXIS 流，逐条复算契约 |

## 接口

```verilog
axis_out_adapter #(.DW(24), .DEPTH(512))
  // 简流入（锐化出，RGB888）
  in_data[23:0], in_valid, in_ready, in_sof, in_eol
  // AXIS Master 出（→ VDMA S2MM）
  m_axis_tdata[23:0], m_axis_tkeep[2:0], m_axis_tvalid, m_axis_tready, m_axis_tlast, m_axis_tuser
```

## S2MM 契约（验收条目）

| # | 契约 | 结果 |
|---|---|---|
| 1 | 每帧首拍 `tuser=1` | ✅ |
| 2 | 每行末拍 `tlast=1` | ✅ |
| 3 | `tkeep ≡ 3'b111`（RGB888 = 3 满字节） | ✅ |
| 4 | 帧数 = NFRAME、行数 = NFRAME×H（HSIZE/VSIZE 与分辨率一致） | ✅ |
| 5 | `tvalid=1 && tready=0` 时 `tdata/tkeep/tuser/tlast` 稳定 | ✅ |
| 6 | 复位期 `m_axis_tvalid=0` | ✅ |
| 7 | 反压零丢数（源序列逐字全等） | ✅ |

## 验证结果

| 判据 | 结果 |
|---|---|
| TB（`DEPTH=16` 故意取小，四数据场景 + 复位场景） | **[PASS]** fire **3072** = 收 **3072**；帧 **16** = 4 场景×4 帧；行 **192** = 帧数×12；断言零违例 |
| `verify_axis_out.py` 独立解析真实 AXIS 流 | **全过**：`tdata` 序列全等 0 误差、`tkeep` 恒 111、`tuser`/`tlast` 位置全对 |

生成/校验命令：

```powershell
cd AxisOut
python make_axis_out_data.py
iverilog -o tb_ao.vvp -DNOVCD -I . -I ..\fifo tb_axis_out_adapter.v
python ..\CCM\_run_wd.py vvp tb_ao.vvp          # ★ 一律在看门狗下跑
python verify_axis_out.py
```

## 设计要点

1. **转换本身很薄，硬件价值全在弹性 FIFO**：简流与 AXIS 只差字段命名 + sideband，握手语义一致（同拍消费）⇒ 真正要硬件的是缓冲，故直接复用 `axis_stream_fifo`（FWFT + `{tuser,tlast,tdata}` 同拍打包 ⇒ 数据与语义不错位）。
2. **`tkeep` 是常数**：RGB888 每拍都是 3 个满字节 ⇒ `tkeep ≡ 3'b111`，无逻辑。
3. **集成时整体换 IP**：与 `async_fifo→FIFO Generator`、`axis_stream_fifo→AXIS Data FIFO IP` 同一条路线——把 FIFO 换成"IP + 独立时钟"就得到 **CDC 异步弹性**，字段映射逻辑零改动（CDC 留集成阶段，单级仿真同频）。
4. **反压通路末端**：`VDMA.tready → 出端 FIFO → 逐级 ready → 入端 FIFO → CSI-2 RX.tready`，本模块是这条链的起点。

## 面试点清单

1. **简流 vs AXIS 的差别**：只在字段命名与 sideband；握手（valid/ready 同拍消费）语义完全一致
2. **tuser/tlast 的语义**：tuser = 帧首（SOF）、tlast = 行末（EOL）——VDMA S2MM 靠它们切行/切帧
3. **tkeep 什么时候不是常数**：位宽非整数倍字节、或最后拍不满字节时才需要；RGB888 恒 111
4. **弹性 FIFO 的作用**：速率匹配 + 反压缓冲；本工程用 FWFT + 侧带打包，集成换 AXIS Data FIFO IP（CDC 由 IP 的独立时钟域负责）
5. **怎么验"契约"**：不是只看数据对——要逐条断言 tuser/tlast/tkeep 的**位置**、帧/行计数、反压稳定性（用上一拍 ready）
