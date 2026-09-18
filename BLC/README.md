# BLC · 黑电平校正（M2，ISP 第一级）

> 8 级 ISP 链路（BLC → DPC → Demosaic → 降噪 → AWB → CCM → Gamma → 锐化）的第一级。
> 入侧承接 CSI-2 RX 的 AXIS(RAW10, 1 pixel/clock)，出侧简流给 DPC。
> 状态：**已完成（2026-09-18）**——三套判据全过（协议场景 / 位级 / 图像 PSNR）。

## 一句话原理

CMOS 像素无光照时也有暗电流底电平（OB），不减掉会被后级增益/AWB/伽马放大成"暗部发灰"。
`p_out = max(p_in - OB[ch], 0)`——纯逐像素点运算，**零行缓存、delay 1 拍**。

## 文件清单

| 文件 | 说明 |
|---|---|
| `blc_axis_adapter.v` | AXIS → 简流适配：取低位 10bit、tuser/tlast→sof/eol；`ENTRY_FIFO_EN` 预留入端弹性 FIFO（复用 `fifo/axis_stream_fifo.v`，集成时换官方 AXIS Data FIFO IP） |
| `blc_core.v` | 校正核：Bayer 相位计数 + 四通道 OB 选择 + **写法乙**饱和减（先比较再减，省 DW+1 位通路），1 级流水可反压，`out_phase[1:0]` 供 DPC/Demosaic 免重算 |
| `blc_top.v` | adapter + core 串联 |
| `tb_blc_top.v` | AXIS 全协议 TB：四场景（满速 2 帧 / 汇随机 50% / 长拉低 / 双向随机）+ golden 记分板 + 协议断言；`-DEFIFO` 切换集成形态 |
| `tb_blc_img.v` | 图像实验 TB：真实图（112×103）连续流过数据通路 → `output.coe` |
| `make_blc_data.py` | 生成图像实验数据：真图 → 理想 RAW10 + 加每通道黑电平（模拟 sensor 输出） |
| `verify_blc.py` | 协议 TB 的 numpy 独立复算（第二判据） |
| `verify_blc_img.py` | 图像链独立校验：位级全等 + PSNR 三组 + 四宫格对比图 |
| `blc_compare.png` | 对比图：理想 / 不校 / 校准 / 校偏 |
| `BLC黑电平校正实现.md` | ★ 详细讲解文档（原理、写法甲乙对比、四要点落地、相位不变式与踩坑、验证、面试讲点） |

## 验证结果

**① 协议/场景（双形态 × 双判据）**：直连与入端 FIFO 两形态下，四场景 960/960 像素
data/phase/sof/eol 四字段位级全等，AXIS 协议断言（s/m 侧稳定性、复位期 valid=0）零违例，
反压收发计数一致。

**② 图像对比（真图 112×103，PSNR vs 理想 RAW，MAX=1023）**：

| 场景 | PSNR | 说明 |
|---|---|---|
| 不校（带黑电平直接用） | **19.47 dB** | 黑电平被当信号，暗部发灰（解析值 19.45） |
| BLC 校正（OB 准确） | **inf** | 位级还原 |
| BLC 校正（OB 偏差 -16） | **36.12 dB** | 标定误差的代价：残留底电平（解析值 36.12） |

三个数字均与解析值吻合 → 两个结论：**不校损失 16.7dB；OB 标定偏 1.6% 就从 ∞ 掉到 36dB**——
OB 精标定/实时统计 + 随增益分档重写的定量依据。对比图 `blc_compare.png`（不校整体发灰，
均值 499.5 vs 理想 405.6，一眼可见）。

## 复现

```powershell
cd BLC
# 协议/场景 TB（直连 + 入端 FIFO 两形态）
iverilog -o tb_blc.vvp -I ..\fifo tb_blc_top.v;  vvp tb_blc.vvp > sim_log.txt
iverilog -o tb_blcf.vvp -DEFIFO -I ..\fifo tb_blc_top.v; vvp tb_blcf.vvp > sim_log_fifo.txt
python verify_blc.py blc_out.txt 16 12 5

# 图像对比链
python make_blc_data.py
iverilog -o tb_img.vvp -I ..\fifo tb_blc_img.v; vvp tb_img.vvp > sim_log_img.txt
python verify_blc_img.py
```

## 设计要点（详见 [BLC黑电平校正实现.md](BLC黑电平校正实现.md)）

- **饱和减写法乙**：`(in < ob) ? 0 : (in - ob)` —— 比较器 + DW 位减法器 + mux，无 DW+1 位借位链
- **四通道分 OB**：按 Bayer 相位选槽位；`BAYER_PATTERN` 只是软件填值的语义表（RGGB 下 00=R）
- **相位不变式**："fire 拍读到的寄存器值 == 当前像素相位，拍末推进"；sof 拍选择/输出强制 00
  （抹掉跨帧行奇偶残留）；eol 拍列清零行翻转——踩过的坑：sof 分支清零导致整帧相位斜一列
- **反压**：1 级流水 stall = `out_valid && !out_ready`，冻结零成本
- **图像实验必须留 headroom**：理想 RAW 均值过高时加 OB 会满阱钳位，BLC 减不回来，实验失真
