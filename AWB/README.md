# AWB —— M6 自动白平衡（四相位统计 + Bayer 域增益应用 + 软核闭环）

> **定位**：8 级 ISP 链路的 AWB 级（`BLC → DPC → **AWB** → Demosaic → …`，Bayer 域）。
> 增益应用在去马赛克**之前**（此时 R/Gr/Gb/B 各自独立，每像素只乘 1 次）；
> 统计 tap 在 DPC 出（原始 RAW 域，先修坏点再统计、不受增益漂移影响）。
> **详细设计（PL/PS 分工、AXI-Lite 选型、闭环节拍 N+2、伪代码审查）见 [M6实施计划.md](M6实施计划.md)**。
>
> **当前进度：Step 0~3 ✅（2026-10-15）**——数据/golden + 统计级 + 增益级 + **闭环联调（N+2 一次 PASS）**；
> 整链已换上真 AWB（`FpgaIspChain/` 回归全 PASS、真增益模式 **PSNR 15.73→34.28 dB**）；
> Step 4（AXI-Lite 从机）/ 5（上板）待开工。

## 文件清单（大白话：每个文件是干嘛的）

| 文件 | 大白话 |
|---|---|
| `awb_stat.v` | **把每帧四种颜色的像素分别加起来**（R、Gr、Gb、B 各记一个总数），给软核算白平衡增益提供依据。像素流从它这里原样路过——不挡、不拦、不减速。一帧数完，把四个总数存成快照放一边（放着不动，随时能读）；新一帧在旁边重新开始数。 |
| `awb_gain.v` | **给每个像素乘一个增益**：按颜色挑——红的乘红的增益，绿的乘绿的。乘完四舍五入，超过 1023 就顶格在 1023（例：900 × 1.5 = 1350，按 1023 算）。增益随时可改，但硬件只在**每帧第一个像素**那一拍把新值收进来——保证一帧内所有像素用同一个增益，绝不中途换。 |
| `awb_top.v` | **把上面两级打包成一级**：像素先过统计、再乘增益，对外接口 = 老占位的接口 + 统计快照组（总数 + 帧号 + 每帧一次的通知脉冲）。总延迟仍是 1 拍，所以整链直接换上去、下游完全无感。 |
| `tb_awb_stat.v` | `awb_stat.v` 的自动考试：喂 8 帧数据，模拟全速、随机停顿、下游卡住、半路复位等情况；判卷标准 = 它数出来的四个总数与 Python 预先算好的答案一个字都不差。 |
| `tb_awb_gain.v` | `awb_gain.v` 的自动考试：逐个像素核对乘出来的结果与标准答案；重点考两条——帧中途改增益：本帧不受影响、下一帧第一个像素就用新值；增益拉满（饱和）时结果顶格不绕回（另含复位场景）。 |
| `tb_awb_loop.v` | **闭环联调考试**：TB 里写了个"假软核"（轮询帧号→读总数→算增益→写回），喂 6 帧偏色图跑完整闭环——判"统计第 N 帧 → **帧 N+2 生效**"位级全对；再故意让假软核慢一拍，验证"生效滑到 N+3、系统不崩、随后恢复正常"。 |
| `make_awb_data.py` | 出题人：生成测试输入 + Python 标准答案（按和硬件一模一样的公式先算一遍）；另生成一张偏色图，供以后的软核闭环实验用。 |
| `verify_awb.py` | 阅卷第二人（不采信 TB 的自评）：拿输入数据从头独立算一遍，和硬件实际输出逐项核对，全一致才通过。 |
| `make_awb_chain_data.py` | **整链实验的出题人**：造"偏色传感图 + 同噪声/坏点的未偏色版"，用 Python 整链参考算出闭环 golden（帧0/1 基线、帧2/3 收敛）；顺手把 4 个 `.coe` 也生成在本目录（RTL 的 `$readmemh` 走运行目录）。 |
| `tb_awb_chain.v` | **整链闭环考试**：把 8 级整链（借 `FpgaIspChain/isp_chain_top.v`）喂偏色图跑 4 帧，假软核收敛；逐帧位级比对 + S2MM 契约。 |
| `verify_awb_chain.py` | 整链实验的阅卷第二人：4 帧独立复算 0 误差 + PSNR 报告 + 通道均值 + 出对比图 `awb_chain_compare.png`。 |

## 验证结果（Step 0~3，全部 [PASS]）

| 判据 | 结果 |
|---|---|
| 统计级 TB（五场景，含复位） | **[PASS]** 透传恒等每拍零违例；10 个封存点 vs 期望 0 误差；irq 恰 1 拍宽；复位期逐拍归零；收发 1920/1920 |
| 增益级 TB（含饱和/极值/复位/反压） | **[PASS]** 位级 1920/1920 0 误差；帧首实证"下个 SOF 起从首像素就用新值"；复位后恒等恢复 |
| 独立复算（`verify_awb.py`） | stat_out 1920 行、封存 10 点、make golden 交叉 32 项、gain_out 1920 行 —— **全 0 误差** |
| 手算样例（人工可查） | 帧 1 首像素 `0x247×384 → 0x36B`；帧 2 首像素 `0x087×128 → 0x044`；帧 6 饱和 `0x187×1023 → 0x3FF` |
| **闭环 TB（`tb_awb_loop.v`）** | **[PASS]** N+2 位级 0 误差（fc=2 写入 `(391,252,258,185)`）；软核推迟 1 帧 → 滑到 N+3 不崩、恢复后 0 误差；两遍均含随机反压；收发 138432/138432 |
| **整链真增益（实验全在本目录）** | 回归全 PASS（`verify_isp_chain` 逐级 8 级 0 误差）；**端到端 PSNR 15.73 → 34.28 dB（+18.55）**；通道均值 R/B 100/202 → 160/166（靶子 162/169）；图 `awb_chain_compare.png`；**整链 OOC 复检 +1.589ns/17 级 ✅**（修掉"反压链串进乘法器"后的基线恢复） |

## 三条关键设计（为什么这么写）

1. **统计旁挂、数据通路零改动**：`awb_stat` 是 0 拍组合透传 + fire 拍累加，
   加一级不改整链总延迟与 golden；只在 `in_valid && in_ready` 拍累加，
   反压期（数据冻结、valid 保持）不会把同一像素数很多次。
2. **封存语义"shadow ← work 且 work ← 本拍像素"**：SOF 拍原子搬家一拍完成；
   若照"清零重启"写会吞掉每帧第一个像素；`fc/shadow/irq` 同拍更新、下一拍同时可见。
3. **★ 增益帧边界采样与首像素同拍**（评审实锤的坑）：`gsel = fire&&sof ? 写口 : active`
   ——否则首像素会拿到上一帧 active；复位默认 = 2^GF（1.0）保证复位后天然恒等。

## 复现命令

```powershell
cd AWB
python make_awb_data.py            # small 数据 + golden（含手算样例打印）
python make_awb_data.py --img      # img 偏色实验数据（Step 3 用）

iverilog -o tb_stat.vvp -DNOVCD tb_awb_stat.v
python ..\CCM\_run_wd.py vvp tb_stat.vvp     # ★ 看门狗下跑；日志 sim_log.txt
Copy-Item sim_log.txt sim_log_stat.txt -Force

iverilog -o tb_gain.vvp -DNOVCD tb_awb_gain.v
python ..\CCM\_run_wd.py vvp tb_gain.vvp
Copy-Item sim_log.txt sim_log_gain.txt -Force

python verify_awb.py               # 独立第二判据（期望 [PASS]）

iverilog -o tb_loop.vvp -DNOVCD tb_awb_loop.v
python ..\CCM\_run_wd.py vvp tb_loop.vvp     # 闭环联调（Pass1 正常 + Pass2 推迟演练）
Copy-Item sim_log.txt sim_log_loop.txt -Force
```

整链联动（**实验全在 AWB/ 下跑**：`-I` 借链顶层，数据/日志/图都不出本目录）：

```powershell
cd AWB
python make_awb_chain_data.py              # 偏色数据 + 闭环 golden + 4 个 .coe（本目录）
$inc = "-I . -I ..\FpgaIspChain -I ..\BLC -I ..\Bayer_DPC_Demosaic -I ..\BilateralFilter -I ..\CCM -I ..\Gamma -I ..\Sharpen -I ..\AxisOut -I ..\line_buffer\line_buffer_fifo_nxn -I ..\fifo"
iverilog -o tb_awb_chain.vvp -DNOVCD $inc.Split(' ') tb_awb_chain.v
python ..\CCM\_run_wd.py vvp tb_awb_chain.vvp
python verify_awb_chain.py                 # 独立复算 + PSNR + awb_chain_compare.png（本目录）
```

## 下一步（Step 4~5，见 [M6实施计划.md](M6实施计划.md) 第五节）

- **Step 4**：`awb_axi_lite.v`（AXI-Lite 从机寄存器文件，仿真可验）。
- **Step 5**：上板联调（BD + MicroBlaze 裸机 C，P3 阶段）。