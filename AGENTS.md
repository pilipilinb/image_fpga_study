# AGENTS.md

本文件是 AI 协作本仓库的工作指引（面向 AI，人看工程全貌请读 [README.md](README.md)）。

> **项目定位**：换工作向 FPGA 图像处理学习项目。最终目标 2027 年 2 月底拿到图像 FPGA 岗 offer（20-35K），唯一标准是把手上项目讲透 40 分钟 + 量化证据 + 上板实物。
> **总路线**：[fpga-image-6month-plan-v2.md](fpga-image-6month-plan-v2.md)（P1 地基 → P2 四模块 RTL → P3 上板 → P4 定稿面试）；逐模块执行计划见 [fifo行缓存与8级ISP链路实施计划.md](fifo行缓存与8级ISP链路实施计划.md)（Month-2 里程碑 M0~M6）。
> **工程实况**：[README.md](README.md)（子系统清单、接口契约、验证数据、快速开始）——改代码时必须同步更新对应章节。

## 当前进度（2026-10-09）

- **P1 · Month-2 里程碑**：M0 ✅ async_fifo → M0.5 ✅ axis_stream_fifo → M1 ✅ line_buffer_fifo_nxn → M2 ✅ BLC → M3 ✅ DPC→Demosaic 串联链 → M4 ✅ 降噪（双边）+ CCM + Gamma → **M5.1 ✅ 锐化（USM，感知域 RGB888）+ 出端 AXIS 适配（S2MM 契约）**；**下一步 M5.2**（8 级整链串联：AXIS(RAW10) 进 → RGB888 出，全链 PSNR + 逐级插桩），之后 M6（AWB 统计 + Bayer 域增益 + MicroBlaze 闭环）
- **M5.1 关键结论**：① **USM 的修正量用"符号-幅值"两路**（`d=|orig−blur|`，`adj=(d·k_gain+2^7)>>8`，`out=a±adj`）——Verilog 里 signed⊕无符号常量会把整式翻成无符号、负数算术右移是 floor，幅值两路消灭歧义 ⇒ RTL 与 Python golden 天然位级同构；② **k（10bit 端口，k=k_gain/256）与 bypass 同为帧级配置**，处理路径含行缓存（上千拍）⇒ 改动必须落在**排空点**；③ blur 用 Σ=16 高斯核 = 纯加法 + `>>4`（**0 乘法器**），只有修正量那一项用乘法；④ 出端适配薄，硬件价值全在**弹性 FIFO**（复用 `axis_stream_fifo`，CDC 留集成）
- **★ M5.1 时序实测（重要）：功能 0 误差 ≠ 时序能收敛**。OOC 综合（Vivado 2021.2，`xcvu19p-fsva3824-2-e` @150MHz，脚本 [synth_ooc_timing.tcl](synth_ooc_timing.tcl)）发现：`sharpen_stage` **35 级 / WNS −1.930ns ❌**、`denoise_stage` **40 级 / −5.804ns ❌**、`ccm_stage`（**无行缓存**）**8 级 / +4.748ns ✅**。病因 = **行缓存 pad mux（`sel_row/sel_col`+9:1 mux，组合）+ 吃窗口的核**挤在同一拍（与用 function 无关）。修法统一为"**stage 内对 `lb_win` 插窗口寄存器 + 核内拆流水 + 算术表达式定宽**"，**三级现已全部收敛**：锐化 **15 级/+2.583ns**、降噪 **13 级/+2.145ns**、CCM 8 级/+4.748ns。降噪的三轮迭代全过程（含时序报告片段与 DSP 级联链分析）见 [BilateralFilter/README.md](BilateralFilter/README.md)「时序收敛实战」。**规矩：每级 RTL 交付前跑一次 OOC 预检，顶层取 `xxx_stage` 而非 `xxx_core`。**
- **M4 三模块的关键结论**：线性 RGB 域全程 10bit，**位宽缩减统一在 Gamma 出口**（1024×8 LUT 预存 round 值 → 零成本零偏置）；**bypass 实现方式由"处理路径延迟"决定**——降噪含行缓存（上万拍）只能排空点切换，CCM(2 拍)/Gamma(1 拍) 用等延迟旁路、可帧内热切换；Gamma 是**全链唯一换位宽的一级**（30bit 进 24bit 出）
- **Month-1 地基**全部完成：line_buffer（含 FIFO 版）/ CSC / bilinear v3+v4 / MeanFilter / GaussianFilter（MedianFilter 已恢复）
- **面试口径（ISP 分域，见 6month 计划开篇）**：RAW 域（BLC→DPC）→ 线性 RGB 域（Demosaic→降噪→CCM）→ 感知域（Gamma→锐化）
- 六个月计划规则：**每阶段由用户口头触发开工，AI 不越级预做后续阶段**；每周只看本周清单

## 代码库结构（按链路位置）

| 目录 | 定位 | 验证状态（关键指标） |
|---|---|---|
| `fifo/` | **手写 FIFO 基础件**：`async_fifo`（对齐 FIFO Generator，标准读模式）+ `axis_stream_fifo`（对齐 AXIS Data FIFO，FWFT + 侧带同拍打包） | 五阶段/四协议场景 [PASS]；与官方 IP 无缝替换路径已打通 |
| `line_buffer/` | 行缓存家族：`line_buffer_fifo_nxn`（★ M1 核心，pad 全尺寸 + 反压 + 帧间排空）为 ISP 链唯一复用行缓存；旧 BRAM 版（crop/pad/nxn）留作对比，`line_buffer_nxn_pad` 已弃用（有 bug） | 双判据 0 误差，4 组参数含 640 宽图，稳态 1 pixel/clock |
| `BLC/` | ISP 第一级黑电平校正：AXIS(RAW10) 入口适配 + 四通道 OB 饱和减（写法乙）+ `out_phase` 直供后级 | 双形态双判据 0 误差；图像链 PSNR 不校 19.47dB → 校准 inf / 校偏 36.12dB |
| `Bayer_DPC_Demosaic/` | M3 串联链：DPC 包络检测 → Demosaic（双线性/MHC 换核不改线），算法核参数化复用旧工程（8→DW 逻辑零改动） | 四套 TB 全 PASS（960/960、11536/11536）；Bayer 域 28.33→38.84dB（+10.51） |
| `BilateralFilter/` `CCM/` `Gamma/` | **M4 线性 RGB 域三模块**：双边降噪（值域 LUT + 倒数 ROM，核 LAT=6／stage 总延迟 7；拆流水后）/ CCM（Q5.12 有符号矩阵乘，LAT=2，全链唯一用 DSP）/ Gamma（1024×8 LUT ×3 副本，LAT=1，**全链位宽缩减出口** 10bit→RGB888） | 三者均：[PASS] 协议 6 场景 + 真图/色卡/穷举 TB，位级 0 误差；PSNR 32.03dB（降噪）/ 色卡 ΔE 12.14→0.12（CCM）/ 1024 项全表覆盖 + 亮度 +62.6%（Gamma）。**降噪 OOC 时序 40 级/−5.804ns → 13 级/+2.145ns ✅ @150MHz**（三轮拆流水，见其 README「时序收敛实战」） |
| `Sharpen/` | **M5.1 感知域锐化**：USM `orig+k·(orig−blur)`，blur 用 0 乘法器 3×3 高斯（复用 `line_buffer_fifo_nxn`）；修正量"符号-幅值"两路消灭 signed/算术右移歧义；k 10bit 端口；核 LAT=2／stage 总延迟 3（窗口寄存器 + 核拆分），bypass 排空点切换 | 三模式 TB 全 [PASS]（1536/1536、K64 1536/1536、真图四级串联 11536/11536），位级 0 误差；Tenengrad +9.3% / \|Laplacian\| +35.7% / PSNR 39.30dB；**OOC 时序 35 级/−1.930ns → 15 级/+2.583ns ✅ @150MHz** |
| `AxisOut/` | **M5.1 出端适配**：简流(RGB888) → AXIS（`tdata` + `tkeep=111` + `tuser=帧首` + `tlast=行末`）+ 弹性 FIFO（复用 `axis_stream_fifo`）；CDC 留集成 | [PASS] S2MM 契约逐条（fire 3072=收 3072、帧 16、行 192、tkeep≡111、稳定性/复位零违例）+ Python 独立解析真实 AXIS 流复算通过 |
| `DPC/` `Demosaic/` | 8bit 旧版（已验证，历史指标 26.43→31.91 / 26.05·29.23dB），M3 已参数化升级，旧版保留作参照 | 保留不动 |
| `CSC/` `bilinear/` `MeanFilter/` `GaussianFilter/` `MedianFilter/` | Month-1 算法子系统（各含多版本变体 + 中文文档 + .svg 时序图） | 均已验证 |
| `filter_csc_bilinear/` | Month-1 四模块串链路（帧闸方案） | 已验证 |

## AI 协作硬规则

1. **禁删文件**：未经用户明确同意，不得删除/清空 .md / .c / .v / .sv 文件（曾发生源码被清空靠 git 备份恢复的事故）
2. **不越级**：用户说"开始做 M4"才做 M4；计划文件里下一阶段怎么写以实施计划为准，但执行细节可按最新工程现实调整（如 M3 从"重实现"改为"复用参数化"）
3. **文档三件套**：每个新算法目录 = `README.md`（入口概览）+ 详细中文讲解文档（为什么这么设计 > 怎么用）+ 与全局 README 同任务内更新；踩坑必须记进文档和全局 README「已知问题」
4. **验证规范（图像算法强制）**：TB 自检记分板（[PASS]/[FAIL] + 计数 + 超时兜底）+ Python 独立第二判据 + **对比图 + PSNR**（仿 BLC/Demosaic 链：真图 → hex → RTL → coe → PIL 出图）；TB 期望与 DUT 参数必须一致，优先层次引用 `dut.*`
5. **跑 vvp 一律带看门狗**（内存/时间硬上限，PowerShell Start-Process + 轮询 WorkingSet64）——22.6GB 事件教训
6. **git 备份**：**本机到 `github.com` 的 TLS 时通时断**（实测 `curl https://github.com/` 20s 超时、HTTP 000，而 `api.github.com` 稳定 200 —— 同网段不同 IP，属常见限速/阻断）。推送策略：**能通时直接用 `git push`**（本地 `main` 已跟踪 `origin/main`，凭据缓存在 Windows 凭据管理器，无需 token）；**超时/连不上时用 REST 兜底**：`python _gh_push_files.py <提交信息文件> <文件...>`（走 api.github.com 的 Git Data API，实测稳定）。注意 REST 推送产生的提交与本地提交**内容相同但 SHA 不同**，网络恢复后 `git fetch` + `git reset --mixed origin/main` 即对齐。推送前确认 `.gitignore` 已覆盖 `*.vvp/*.vcd/*.txt` 与 `synth_rpt/`、`.trae/`（已配）；PS1 脚本零中文字面量（PS5.1 无 BOM 会把中文读乱）
7. **通信**：中文；解释简洁直接（用户反感含糊）；逐模块详细中文注释（含定点化推导、踩坑记录）
8. **波形调试**：优先用 wave-mcp（已装全局 MCP，`prepare_session`/`open_session` + ~27 个分析工具），别只靠断点
9. **禁止请教专家**：用户要求时，必须自己解决，不能请专家。

## RTL 设计铁律（改代码不可破坏）

- **BRAM 阵列不可复位**：读输出寄存器用同步复位；上电脏数据靠 valid/坐标门控屏蔽
- **打拍对齐**：BRAM/同步读潜伏 1 拍，din/col/valid 逐级打拍；漏一级错一行/列
- **valid 链与数据链分离**：valid 自由传递，数据仅在 valid/握手时更新
- **反压 = 冻结 + 保持**：`stall = out_valid && !out_ready` → in_ready=0 + 全部输出字段/计数器保持；**"LAT=1 核直接当输出寄存器"必须配 `hold_in` 保持**，否则上游弹出（决策滞后一拍）与下游取走之间会丢数（M3 实锤）
- **相位/坐标计数器不变式**：fire 拍读到的是当前像素/窗口中心坐标，拍末推进；sof 拍不能"清零了事"（sof 拍本身在消费 (0,0)，拍末必须推进到 1）；sof 强制 00 抹跨帧残留；**有显式 sof/eol 就不要靠 IMG_H/IMG_W 盲数数回绕**（丢 1 拍永久错位无自愈）
- **空满判断必须寄存一拍**（Cummings 标准）：裸 assign 且参与自身门控 = 组合逻辑环 → vvp 零延迟事件风暴（22.6GB）+ 综合非法
- **吃窗口的核必须与行缓存 pad mux 之间插窗口寄存器**：行缓存的 `sel_row/sel_col` + 9:1 pad mux 是**组合**逻辑，直连核会与核内加法树/乘法/饱和叠成一整条长路径（锐化实测 35 级 / WNS −1.930ns @150MHz）。修法：在 `*_stage` 里对 `lb_win` 打一拍（**不改共用的 `line_buffer_fifo_nxn`**，保护 M1/M3 占用不变式），并让 sof/eol 对齐链深度 = 窗口拍数 + 核 LAT
- **算术表达式先算进定宽中间量**：`2*(...)`、`4*p4`、`x+(1<<F-1)`、`res>255` 里的字面常量是 **32bit**，会把整条表达式撑到 32 位（宽加法器/宽比较器）。乘 2/4 用**移位**，round 常量做 `localparam [W-1:0]`，饱和比较用"高位是否非零"（`|res[hi:DW]`）
- 复位风格：DUT 计数器/流水线异步复位同步释放；简流输出在 valid 未 ready 时字段不变

## 已知坑速查（高频重犯，详见全局 README「已知问题」）

- `$random` 有符号：一律 `{$random} % N`，否则概率完全走样
- include 守卫：给无守卫文件补守卫时，同步删除其他文件里"`define 同名宏` 再 include"的旧写法（会把整个文件内容屏蔽）
- FWFT：AXIS 规范要求 tvalid=1 ⇒ tdata 有效 → 必须预取输出级，容量 = DEPTH+1；行缓存级联用 FWFT 免对齐延迟链
- 行缓存 pad 版边缘窗口用 replicate 像素参与判定（crop 版直接不输出边缘）——Python 参考必须 clamp 对齐
- 黑电平实验必须留满量程 headroom（否则满阱钳位让 PSNR 对比失真）
- 时钟半周期用 real（reg[31:0] 会截断 5.5ns）

## 常用命令

```powershell
# iverilog + vvp 三件套（TB 头部 `include 被测模块，只编译 TB）
iverilog -o tb_x.vvp -DNOVCD [-D宏] -I ..\fifo [-I ..\line_buffer\line_buffer_fifo_nxn] tb_x.v
vvp tb_x.vvp > sim_log.txt          # ★ 一律在看门狗下跑
python verify_xxx.py                # 独立第二判据（有脚本时）
gtkwave tb_x.vcd                    # 波形（或 wave-mcp 直读 VCD/FST）
```

多级链路编译要 `-I` 指到 `fifo/` 与 `line_buffer/line_buffer_fifo_nxn/`（include 链：top→stage→核→行缓存→fwft_wrapper→async_fifo，全链已有 include 守卫）。

## 时序预检（OOC 综合，交付前必跑）

```powershell
# 顶层必须取 xxx_stage（含行缓存 pad mux），只综合 xxx_core 会漏掉半条关键路径
# 脚本里 cd 到各模块目录是为了让 denoise/ccm 的 $readmemh 相对 .coe 找得到
mkdir synth_rpt; Set-Location synth_rpt
vivado -mode batch -source ../synth_ooc_timing.tcl -log synth_ooc_timing.log   # ★ 需非沙箱：Vivado 要写 %APPDATA%\Xilinx
# 看日志里的 RESULT 行：WNS_NS / LOGIC_LEVELS / LUT / FF / DSP48
# 报告落在 synth_rpt/：timing_<top>.rpt（含逐级 path）、util_<top>.rpt
```

- 器件/时钟在脚本头部两行（当前 `xcvu19p-fsva3824-2-e` / 6.667 ns = 150 MHz）
- **判据**：WNS < 0 就要拆流水；`LOGIC_LEVELS` 是拆几级的依据（每级 ≤ ~15 且 < 时钟周期才稳）

## 关键资源

牟新刚《基于 FPGA 的数字图像处理原理及应用》（行缓存/CSC/缩放/滤波）· 冈萨雷斯《数字图像处理》（算法理论）· openISP（ISP 各级 Python 参考）· Imatest 文档（MTF/ΔE 评测）· Xilinx UG949（时序/CDC）· HDLBits（每日一题）
