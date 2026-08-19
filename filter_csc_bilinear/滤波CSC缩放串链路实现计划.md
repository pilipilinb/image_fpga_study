# 滤波+CSC+缩放 串链路实现计划（filter_csc_bilinear，W4 收尾）

## 背景与目标

W4 计划原文"均值+高斯+CSC+缩放四模块串链路"。用户指定实际链路（已确认差异）：**真图 112×103 加入高斯噪声和椒盐噪声（混合在同一张图）→ 高斯滤波 → 中值滤波 → CSC(RGB→YCbCr) → 双线性放大 2 倍**。

- 设计意图：两级滤波各司其职——高斯滤波灭高斯噪声（强项）、中值滤波灭椒盐脉冲（强项）；随后 CSC 演示 24bit RGB→YCbCr 流式转换；缩放复用 bilinear_v4 行缓存版（流式输入，与链路匹配）放大 2 倍。核心算法全链路串起来，学习价值最高。
- 尺寸链（crop 收缩，注明即可）：112×103 → 高斯 110×101 → 中值 108×99 → CSC 108×99 → **放大 2 倍 = 216×198**

## 链路架构

```
din(RGB888, 24bit+valid) ──► gaussian_top（复用，3×gaussian_3x3_8b + 行缓存）
   → median_top（复用，3×median_3x3_8b + 行缓存）
   → rgb_to_ycbcr_3stage（CSC 复用，拆 R/G/B 输入，Y/Cb/Cr 输出 + o_data_en）
   → 打包 24bit = {Y, Cb, Cr}（3通道独立插值，数学等价）
   → axis_fifo（★ 速率匹配，见关键决策 2）
   → bilinear_lb_top（复用 v4，SCALE_N=2，放大 2 倍）
   → out = YUV 24bit + o_valid + o_done（216×198）
```

## 关键决策

1. **混合噪声（用户解读）**：一张噪声图同时含高斯（σ 可配，默认 20）与椒盐（p 可配，默认 0.10）——noise_add.py 新增 `--mix sigma p` 模式生成 noise_mix.hex；**添加顺序：先高斯后椒盐**（椒盐最后覆盖，生成确定性，两种噪声量独立可调）。两级滤波各灭一类噪声，视觉与数值上都可验证。
2. **FIFO 速率匹配（本链路的核心工程点）**：放大 2 倍时缩放模块读侧消费慢（输出像素 = 输入×4），`in_ready` 必然周期性拉低反压；而高斯/中值/CSC 均为无背压纯流水模块，直接级联会丢数据。解法：CSC 与缩放之间插一个**同步 FIFO**（`axis_fifo.v`，推断 BRAM，**深度 2^14=16384×24bit**，写侧连续、读侧由 in_ready 门控）——任意时刻占用 ≤ 累计写入 ≤ 一帧像素数 10692 < 深度，写侧永不溢出（读侧至少消费 0）。
   - 这是系统级联的经典问题与标准答案（帧缓冲/速率匹配），写入 README 面试要点。
   - **CSC 行场同步**：链路无行场概念，`i_h_sync/i_v_sync 接 0`（内部仅打拍透传，o_h_sync/o_v_sync 忽略），仅用 i_data_en/o_data_en 数据有效链。
3. **YUV 打包缩放**：双线性插值对 3 个通道独立运算，Y/Cb/Cr 打包成 24bit 与 RGB 数学等价，直接复用 v4 的 3 核；最终输出即 YUV 放大图（YCbCr 域插值是标准做法，色度重采样是另一议题，README 注明）。
4. **crop 收缩接受**：高斯/中值各 -2 边缘（复用 crop 版行缓存），尺寸链如上；如需全尺寸另用 pad 版（不在本次范围）。
5. start/done 帧协议：链路顶层透传 `frame_start`（TB 每帧拉 1 拍启动）与缩放 `o_done`（帧结束判定）；各级 valid 直接级联（高斯/中值 o_valid → CSC i_data_en → FIFO 写使能；CSC o_data_en → FIFO 写；FIFO 读 → v4 din_valid）。

## 文件清单（全部在 filter_csc_bilinear/）

```
滤波CSC缩放串链路实现计划.md ★ 本计划文档（存入目录）
gaussian_3x3_8b.v     ⬅ 复制 GaussianFilter/（零改动）
median_3x3_8b.v       ⬅ 复制 MedianFilter/（零改动）
line_buffer_3x3.v     ⬅ 复制（两核共用，权威版 line_buffer3x3/）
rgb_to_ycbcr_3stage.v ⬅ 复制 CSC/3stage/（零改动）
coord_gen.v / bilinear_interp_8b.v / line_cache2.v ⬅ 复制 bilinear_v4/
axis_fifo.v           ★ 新写：同步 FIFO（**深度取 2 的幂 2^14=16384** × 24bit，
                      推断 BRAM ≈22 块 18Kb；不溢出证明：任意时刻占用 ≤ 累计写入
                      ≤ 一帧像素数 10692 < 16384；写侧连续、读侧 valid/ready 握手）
top_chain.v           ★ 新写：链路顶层（四模块 + FIFO 例化 + valid 串联）
tb_chain.v            ★ 新写：喂 noise_mix.hex；输出 4 份中间结果 COE
                      （gaussian_out/median_out/csc_out）+ 最终 chain_out.coe
noise_add.py          ⬅ 复制 MedianFilter/ 版 + 新增 --mix 模式
verify_chain.py       ★ 新写：逐级 Python 浮点参考 PSNR（高斯/中值/CSC/缩放四级
                      定位）+ 最终 YUV→RGB 显示对比图（原图 vs 链路结果）
input.hex / noise_mix.hex / *.png / sim_log.txt
README.md             ★ 链路图 + 尺寸链 + FIFO 速率匹配讲解 + 逐级验证数据
```

## 验证计划

| 层级 | 方法 | 验收 |
|---|---|---|
| 单级回归 | 复制文件后先跑各级原 TB（gaussian/median 各 1 次） | PASS（确保复制的文件自身完好） |
| 链路级联 | tb_chain 喂 noise_mix.hex（112×103），观察各级 valid 计数 | 各级窗口数 = 110×101 / 108×99，无丢拍 |
| 端到端精度 | verify_chain.py：浮点参考链（高斯 σ=20 核 / 中值排序 / BT.601 ×256 / 双线性 STEP 累加舍入）逐级 PSNR | 每级 ≥ **35dB**（审查修正：四级定点误差累积约 1~2 LSB → 42dB 是理论值，35dB 留裕量；逐级数值与单站验证一致时通过），最终 YUV 同标准 |
| 视觉 | YUV→RGB 显示对比图（原图 | 噪声图 | 链路结果放大 2 倍） | 人眼可读：噪声被滤、图像放大 |
| FIFO 压力 | 帧内随机气泡（TB 激励） | 输出像素数不丢（与无气泡一致） |

命令（filter_csc_bilinear/）：
```powershell
python noise_add.py --mix 20 0.10           # 生成 noise_mix.hex
iverilog -I . -o tb.vvp tb_chain.v; vvp tb.vvp > sim_log.txt
python verify_chain.py                       # 逐级 PSNR + 显示对比图
```

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| FIFO 深度不足/溢出 | 深度 = 一帧像素数（10692），参数化并留裕量；TB 计数校验不丢像素 |
| v4 放大时 in_ready 反压导致前级丢数据 | FIFO 隔离写/读速率；验证在无气泡与随机气泡两种激励下像素数一致 |
| CSC 输出 Y/Cb/Cr 与 v4 通道顺序错位 | 打包 {Y,Cb,Cr} 与拆包对应写死并注释；verify_chain 用同一约定 |
| 参考模型坐标系（crop 两级 + 双线性 STEP） | 逐级 PSNR 的 crop 对齐沿用各级已验证规则；verify_chain.py 逐级独立可定位 |
| v4 start/done 帧协议误用 | 链路 top 透传 frame_start；o_done 只用于 TB 收尾计数 |

## 实施步骤（含依赖）

1. 计划文档入 filter_csc_bilinear/ + 复制全部复用文件（含各级原 TB 用于第 2 步回归）
2. 复制文件回归：gaussian/median 各自 iverilog 原 TB → PASS（确认复制完好）
3. noise_add.py 加 --mix 模式 → 生成 noise_mix.hex
4. axis_fifo.v（同步 FIFO，参数深度，推断 BRAM，读侧 valid/ready）
5. top_chain.v（四模块 + FIFO + 逐级 valid 串联 + 中间级 COE 探针输出）
6. tb_chain.v（喂帧 + 随机气泡 + 超时兜底 + 4 份中间 COE + 最终 COE，守 TB 铁律）
7. 仿真 → 逐级 PSNR 验证（verify_chain.py）→ 显示对比图
8. 文档：README.md（链路/尺寸/FIFO/结果）+ 根 README W4 收尾状态更新 + AGENTS.md 同步

## 与 W4 计划原文差异说明（用户已确认）

- 原文"均值+高斯"→ 用户指定"**高斯+中值**"（两级滤波各灭一类噪声，均值不参与本次链路；均值存在 MeanFilter 独立工程）
- 原文"四模块串链路"→ 实际五级（含 axis_fifo 速率匹配），FIFO 是流式级联的必需件，属于本任务的工程增量
- 噪声：原文未指定 → 混合噪声（高斯 σ=20 + 椒盐 p=0.10 同图）