# Bayer_DPC_Demosaic —— M3：DPC → Demosaic 串联链（Bayer 域，RAW10）

ISP 链第三/四级：**坏点校正（DPC）→ 去马赛克（Demosaic）**，输入接 BLC 输出（Bayer RAW10 简流），输出 **RGB888 简流**（`out_data[23:0]` = {r,g,b} 各 8bit，对齐 VDMA S2MM `tdata[23:0]` 契约；RAW10→8bit 在 Demosaic 出口 `>>2` 折算）。算法核来自已验证的 `DPC/`、`Demosaic/` 工程（8bit 版），**算法逻辑零改动**，仅做位宽参数化（8→DW）与接口适配（简流握手 + `line_buffer_fifo_nxn` 行缓存）。

## 文件清单

| 文件 | 来源 | 说明 |
|---|---|---|
| `dpc_envelope_dw.v` | `DPC/dpc_envelope.v` | 5×5 包络检测坏点校正核，DW 参数化 + `hold_in` 保持 |
| `demosaic_bilinear_dw.v` | `Demosaic/demosaic_bilinear.v` | 双线性去马赛克核，DW 参数化 + `hold_in` |
| `demosaic_mhc_dw.v` | `Demosaic/demosaic_mhc.v` | MHC 核（均值+高通细节校正），DW 参数化 + `hold_in` |
| `dpc_stage.v` | 新写 | 行缓存 + 窗口相位自计数 + DPC 核 + 反压 |
| `demosaic_stage.v` | 新写 | 同构；`DEMOSAIC_SEL` 参数选 bilinear/mhc（换核不改线） |
| `bayer_dpc_demosaic_top.v` | 新写 | 两级串联顶层 |
| `tb_bayer_dpc_demosaic.v` | 新写 | 自检 TB（协议/图像双模式 + 期望预生成比对） |
| `make_dpc_demosaic_data.py` | 新写 | 数据/期望生成 + PSNR + 对比图 |
| `dpc_demosaic_compare.png` | 产物 | 两行六宫格对比图 |

## 验证矩阵（全部 PASS，err=0）

| TB（编译宏） | 数据 | 判据 |
|---|---|---|
| 默认（bilinear） | 16×12×5 帧伪随机 | 四场景（满速/汇 50%/长拉低/双向随机），Python 期望逐拍全等 + 断言零违例 + 收发 960=960 |
| `-DMHC` | 同上 | 同上，MHC 核 |
| `-DIMG` | 真图 112×103（BLC 后+60 坏点） | 11536 像素位级全等 |
| `-DIMG -DMHC` | 同上 | 11536 像素位级全等 |

## PSNR 对比（RAW10 域 Bayer / RGB888 域，THR=128，注入 60 坏点 seed=20260918）

| 口径 | 无 DPC | DPC 后 | 提升 |
|---|---|---|---|
| Bayer 域（10bit，vs 干净 BLC 后） | 28.33 dB | **38.84 dB** | +10.51 dB |
| RGB888 域·双线性（vs 干净直接 DM） | 30.28 dB | **40.37 dB** | +10.09 dB |
| RGB888 域·MHC | — | 32.60 dB | — |

注意：**无坏点时 MHC 优于双线性**（历史 8bit 基准 29.23 > 26.05 dB），但坏点链上 MHC 反而低——MHC 的细节校正项（高通）会把 DPC 的残留（修复率非 100% 的漏网/边缘误伤）放大，双线性的平均则将其抹平。这正好演示了"算法要和链路上下游一起看"：DPC 之后应该用保守的插值核，或 DPC 阈值/修复策略要更彻底。

## 设计要点（与旧工程的关键差别）

1. **接口适配**：旧 top 是 `din/din_valid` 无握手 + crop 行缓存（输出缩水 108×99）；本链是简流 `valid/ready + sof/eol` + `line_buffer_fifo_nxn`（pad 全尺寸 H×W 输出 + 反压）。
2. **窗口相位自算**（不再用旧 top 的"相位打 5 拍延迟链"）：窗口输出序列天然是光栅序，用 `out_valid/out_sof/out_eol` 驱动一个与 `blc_core` 同构的中心坐标计数器（sof 清零/eol 行进列清），任意反压/气泡下与窗口严格同拍，还天然免掉"窗口中心 = 输入相位延迟 K*(W+1) 拍"这种和气泡相关的对齐。
3. **跨帧语义 = 帧间排空**：`line_buffer_fifo_nxn` 帧末造行把行缓存读空，下一帧从空开始——每帧独立（窗口边缘 replicate），Python 期望逐帧切片处理与之一致。
4. **`hold_in` 保持（本工程新抓的丢数 bug）**：核的 LAT=1 输出寄存器最初无条件覆盖，而行缓存弹出决策滞后一拍（`ostall` 基于上一拍的核输出 valid）——窗口 m 弹出后若下游反压，下一拍核寄存器被窗口 m+1 覆盖，**m 丢失**（TB 断言"valid 未 ready 时撤销"海量触发、收发卡死）。修法：核加 `hold_in` 端口（= stage 的 ostall），hold 时输出寄存器整组保持。教训：**"LAT=1 核直接当输出寄存器"必须配保持语义，否则上游弹出与下游取走之间的时序差会丢数**。
5. **位宽转换点在 Demosaic 出口**：Bayer 域全程保持 RAW10（DPC 判定/插值都在 10bit 精度上做，中间不加噪），`demosaic_stage` 出口 `>>2` 折 RGB888（`OW` 参数，=DW 时直通）——对应"去马赛克后进入 RGB888 域"的 ISP 分域语义，且与出端 `tdata[23:0]` 一致。
6. **THR 等比**：8bit 的 THR=32 是满量程的 12.5%，RAW10 等比取 128。
7. **pad vs crop 的算法行为差异**：边缘窗口用 replicate padding 的像素参与极值/插值判定（旧 crop 版直接不输出边缘）——全尺寸输出是链路串联的必须（下一级还要用），Python 参考用 clamp 与之对齐。

## 复现命令

```powershell
cd Bayer_DPC_Demosaic
# 1) 生成期望（协议场景）
python make_dpc_demosaic_data.py
# 2) 协议 TB（默认双线性；-DMHC 换核）
iverilog -o tb_s_b.vvp -DNOVCD -I . -I ..\line_buffer\line_buffer_fifo_nxn -I ..\fifo tb_bayer_dpc_demosaic.v
vvp tb_s_b.vvp
# 3) 图像链：生成真图数据+期望+PSNR+对比图，再跑 RTL 比对
python make_dpc_demosaic_data.py --img
iverilog -o tb_i_b.vvp -DNOVCD -DIMG -I . -I ..\line_buffer\line_buffer_fifo_nxn -I ..\fifo tb_bayer_dpc_demosaic.v
vvp tb_i_b.vvp
```

## 依赖

`line_buffer/line_buffer_fifo_nxn/`（fwft_wrapper + async_fifo，均已加 include 守卫）；编译需 `-I` 指向该目录与 `fifo/`。
