# AxisOut 出端 AXIS 适配实现计划（M5.1）

> 定位：8 级 ISP 链路的**出端适配 + 出端弹性 FIFO**（架构图上写作 `[出端适配+出端FIFO]`）。
> 上游计划：[fifo行缓存与8级ISP链路实施计划.md](../fifo行缓存与8级ISP链路实施计划.md) §八（M5）。
> 本文只覆盖 **M5.1 的出端适配**；"整链串联（RAW10 进 → RGB888 出，全链 PSNR）"留 **M5.2**。

---

## 一、要解决的问题

链路内部各级用统一**简流**：`valid/ready + data + sof/eol`。
但链路**出口**要对接 **VDMA S2MM**（AXI4-Stream 汇），它要求标准 AXIS：

| 简流 | AXIS | 说明 |
|---|---|---|
| `in_data[23:0]` | `m_axis_tdata[23:0]` | RGB888 打包 |
| `in_valid / in_ready` | `m_axis_tvalid / m_axis_tready` | 握手语义一致（同拍消费） |
| `in_sof` | `m_axis_tuser` | 帧首（1 拍） |
| `in_eol` | `m_axis_tlast` | 行末（1 拍） |
| — | `m_axis_tkeep` | **RGB888 ⇒ 恒 `3'b111`**（每拍 3 个满字节，纯常数） |

**真正的硬件需求是"弹性缓冲"**（速率匹配 + 反压缓冲），协议转换本身只是接线。
所以本模块 = `axis_stream_fifo`（M0.5 现成件，FWFT + sideband 打包 + 反压）**外面套一层字段映射**。

## 二、架构

```
锐化出（简流 RGB888） ──► [字段映射: sof→tuser / eol→tlast / tkeep=111] ──► axis_stream_fifo ──► VDMA S2MM
                                    in_ready ◄──────────── tready（反压末端一级）
```

- **弹性 FIFO**：容量 = `DEPTH+1`（FWFT 输出寄存器）；实机可取 1024/2048。VDMA 侧 `tready` 拉低时把反压平滑回传到链路（"反压通路"的末端一级）。
- **侧带同拍打包**：`{tuser, tlast, tdata}` 进出同一块 BRAM ⇒ 数据与语义天然不错位（官方 AXIS Data FIFO 的省事点）。
- **AXIS 稳定性**由 `axis_stream_fifo` 的"输出寄存器 + 预取"结构保证（`tvalid=1` 时 `tdata` 已有效且未 consume 前不变）。

## 三、S2MM 侧契约（M5 验收逐条）

| # | 契约 | 实现/验证 |
|---|---|---|
| 1 | 每帧首拍 `tuser=1`，其余 0 | `in_sof → tuser` 透传；TB + Python 双查 |
| 2 | 每行末拍 `tlast=1`，其余 0 | `in_eol → tlast` 透传；TB + Python 双查 |
| 3 | `tkeep ≡ 3'b111` | 常数赋值；每个 `tvalid` 拍断言 |
| 4 | 每帧像素数 = `H×W`（HSIZE/VSIZE 与分辨率一致） | 帧计数/行计数 = `NFRAME` / `NFRAME×H` |
| 5 | `tvalid=1 && tready=0` 时载荷稳定 | 稳定性断言（用**上一拍** `tready`） |
| 6 | 复位期 `tvalid=0` | AXIS 标准 `aresetn`；断言覆盖 |
| 7 | 反压零丢数 | 随机/长拉低场景下 `fire == recv` |

## 四、边界与范围（诚实声明）

- **CDC（像素时钟 vs 系统时钟）留集成阶段**（本计划 §十 假设 2）：单级仿真用**同频**；上板时把 `axis_stream_fifo` 换成"AXIS Data FIFO IP + 独立时钟"即得异步弹性，本模块的字段映射逻辑**零改动**。
- 不做**帧缓存**（VDMA 侧自带），不做 tdest/tid 等未用 sideband。
- `DEPTH` 在 TB 取 **16**（故意取小以便快速撞满、触发并验证反压路径）；实机按 VDMA 突发长度调大。

## 五、验证方案

**TB（`tb_axis_out_adapter.v`）**：五场景 —— A 满速 4 帧 / B 汇随机 50% / C 汇长拉低（撞满反压）/ D 源气泡 70% + 汇随机 / E 复位断言。记分板逐拍核对 7 条契约。

**独立第二判据（`verify_axis_out.py`）**：独立解析 RTL 落盘的真实 AXIS 流（`tdata tkeep tuser tlast`），逐条复算契约 + 数据序列（4 场景各重放一遍源序列）。
