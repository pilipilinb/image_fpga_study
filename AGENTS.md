# AGENTS.md

本文件是 AI 协作本仓库的工作指引（面向 AI，人看工程全貌请读 [README.md](README.md)）。

> **项目定位**：换工作向 FPGA 图像处理学习项目。最终目标 2027 年 2 月底拿到图像 FPGA 岗 offer（20-35K），唯一标准是把手上项目讲透 40 分钟 + 量化证据 + 上板实物。
> **总路线**：[fpga-image-6month-plan-v2.md](fpga-image-6month-plan-v2.md)（P1 地基 → P2 四模块 RTL → P3 上板 → P4 定稿面试）；逐模块执行计划见 [fifo行缓存与8级ISP链路实施计划.md](fifo行缓存与8级ISP链路实施计划.md)（Month-2 里程碑 M0~M5）。
> **工程实况**：[README.md](README.md)（子系统清单、接口契约、验证数据、快速开始）——改代码时必须同步更新对应章节。

## 当前进度（2026-09-20）

- **P1 · Month-2 里程碑**：M0 ✅ async_fifo → M0.5 ✅ axis_stream_fifo → M1 ✅ line_buffer_fifo_nxn → M2 ✅ BLC → M3 ✅ DPC→Demosaic 串联链；**下一步 M4**（降噪/AWB/CCM/Gamma），之后 M5（锐化 + 出端 AXIS + 整链）
- **Month-1 地基**全部完成：line_buffer（含 FIFO 版）/ CSC / bilinear v3+v4 / MeanFilter / GaussianFilter（MedianFilter 已恢复）
- **面试口径（ISP 分域，见 6month 计划开篇）**：RAW 域（BLC→DPC）→ 线性 RGB 域（Demosaic→降噪→AWB→CCM）→ 感知域（Gamma→锐化）
- 六个月计划规则：**每阶段由用户口头触发开工，AI 不越级预做后续阶段**；每周只看本周清单

## 代码库结构（按链路位置）

| 目录 | 定位 | 验证状态（关键指标） |
|---|---|---|
| `fifo/` | **手写 FIFO 基础件**：`async_fifo`（对齐 FIFO Generator，标准读模式）+ `axis_stream_fifo`（对齐 AXIS Data FIFO，FWFT + 侧带同拍打包） | 五阶段/四协议场景 [PASS]；与官方 IP 无缝替换路径已打通 |
| `line_buffer/` | 行缓存家族：`line_buffer_fifo_nxn`（★ M1 核心，pad 全尺寸 + 反压 + 帧间排空）为 ISP 链唯一复用行缓存；旧 BRAM 版（crop/pad/nxn）留作对比，`line_buffer_nxn_pad` 已弃用（有 bug） | 双判据 0 误差，4 组参数含 640 宽图，稳态 1 pixel/clock |
| `BLC/` | ISP 第一级黑电平校正：AXIS(RAW10) 入口适配 + 四通道 OB 饱和减（写法乙）+ `out_phase` 直供后级 | 双形态双判据 0 误差；图像链 PSNR 不校 19.47dB → 校准 inf / 校偏 36.12dB |
| `Bayer_DPC_Demosaic/` | M3 串联链：DPC 包络检测 → Demosaic（双线性/MHC 换核不改线），算法核参数化复用旧工程（8→DW 逻辑零改动） | 四套 TB 全 PASS（960/960、11536/11536）；Bayer 域 28.33→38.84dB（+10.51） |
| `DPC/` `Demosaic/` | 8bit 旧版（已验证，历史指标 26.43→31.91 / 26.05·29.23dB），M3 已参数化升级，旧版保留作参照 | 保留不动 |
| `CSC/` `bilinear/` `MeanFilter/` `GaussianFilter/` `MedianFilter/` | Month-1 算法子系统（各含多版本变体 + 中文文档 + .svg 时序图） | 均已验证 |
| `filter_csc_bilinear/` | Month-1 四模块串链路（帧闸方案） | 已验证 |

## AI 协作硬规则

1. **禁删文件**：未经用户明确同意，不得删除/清空 .md / .c / .v / .sv 文件（曾发生源码被清空靠 git 备份恢复的事故）
2. **不越级**：用户说"开始做 M4"才做 M4；计划文件里下一阶段怎么写以实施计划为准，但执行细节可按最新工程现实调整（如 M3 从"重实现"改为"复用参数化"）
3. **文档三件套**：每个新算法目录 = `README.md`（入口概览）+ 详细中文讲解文档（为什么这么设计 > 怎么用）+ 与全局 README 同任务内更新；踩坑必须记进文档和全局 README「已知问题」
4. **验证规范（图像算法强制）**：TB 自检记分板（[PASS]/[FAIL] + 计数 + 超时兜底）+ Python 独立第二判据 + **对比图 + PSNR**（仿 BLC/Demosaic 链：真图 → hex → RTL → coe → PIL 出图）；TB 期望与 DUT 参数必须一致，优先层次引用 `dut.*`
5. **跑 vvp 一律带看门狗**（内存/时间硬上限，PowerShell Start-Process + 轮询 WorkingSet64）——22.6GB 事件教训
6. **git 备份**：用户要求推送时走 GitHub REST Git Data API（blob→tree→commit，token 读自 mcp.json）；PS1 脚本零中文字面量（PS5.1 无 BOM 会把中文读乱），用目录枚举规避；排除 `*.vvp/*.vcd/*.txt`
7. **通信**：中文；解释简洁直接（用户反感含糊）；逐模块详细中文注释（含定点化推导、踩坑记录）
8. **波形调试**：优先用 wave-mcp（已装全局 MCP，`prepare_session`/`open_session` + ~27 个分析工具），别只靠断点

## RTL 设计铁律（改代码不可破坏）

- **BRAM 阵列不可复位**：读输出寄存器用同步复位；上电脏数据靠 valid/坐标门控屏蔽
- **打拍对齐**：BRAM/同步读潜伏 1 拍，din/col/valid 逐级打拍；漏一级错一行/列
- **valid 链与数据链分离**：valid 自由传递，数据仅在 valid/握手时更新
- **反压 = 冻结 + 保持**：`stall = out_valid && !out_ready` → in_ready=0 + 全部输出字段/计数器保持；**"LAT=1 核直接当输出寄存器"必须配 `hold_in` 保持**，否则上游弹出（决策滞后一拍）与下游取走之间会丢数（M3 实锤）
- **相位/坐标计数器不变式**：fire 拍读到的是当前像素/窗口中心坐标，拍末推进；sof 拍不能"清零了事"（sof 拍本身在消费 (0,0)，拍末必须推进到 1）；sof 强制 00 抹跨帧残留；**有显式 sof/eol 就不要靠 IMG_H/IMG_W 盲数数回绕**（丢 1 拍永久错位无自愈）
- **空满判断必须寄存一拍**（Cummings 标准）：裸 assign 且参与自身门控 = 组合逻辑环 → vvp 零延迟事件风暴（22.6GB）+ 综合非法
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

## 关键资源

牟新刚《基于 FPGA 的数字图像处理原理及应用》（行缓存/CSC/缩放/滤波）· 冈萨雷斯《数字图像处理》（算法理论）· openISP（ISP 各级 Python 参考）· Imatest 文档（MTF/ΔE 评测）· Xilinx UG949（时序/CDC）· HDLBits（每日一题）
