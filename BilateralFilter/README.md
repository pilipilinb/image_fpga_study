# BilateralFilter —— M4 双边滤波降噪（线性 RGB 域，10bit）

ISP 链第五级（M4 第一模块）：**双边滤波降噪**。输入 = M3 Demosaic 出的线性 RGB 10bit 简流（`in_data[29:0]`），输出同格式。算法来源 [工程要点.md](工程要点.md)（伪代码 + PGA 实现要点），本实现把其中的 8bit 数字按链路契约重推为 10bit 并补齐工程细节。

## 文件清单

| 文件 | 说明 |
|---|---|
| `denoise_bilateral_core.v` | 双边核：L1 距离 → 值域 LUT → 空间核加权 → 倒数 ROM 归一化（LAT=3，10bit 域） |
| `denoise_stage.v` | 行缓存(N=3, DW=30) + 核 + **bypass 旁路** + 反压冻结 |
| `tb_denoise_bilateral.v` | 自检 TB：协议四场景 + bypass 三段落切换 + IMG 模式，期望预生成逐拍比对 |
| `make_denoise_data.py` | LUT/倒数 ROM 系数生成 + M3 链出图注噪 + Python golden（与 RTL 位级同构） |
| `verify_denoise.py` | 独立复算（位级）+ PSNR/SSIM（全图 + 边缘区）+ 高斯对比 + 四宫格 |
| `range_lut.coe` / `inv_rom.coe` | 系数文件（Python 生成，RTL `$readmemh` 加载） |
| `denoise_compare.png` | 对比图：注噪 \| 高斯 \| 双边 \| 无噪 |

## 参数（10bit 域，与 8bit 版的换算关系已核对）

| 量 | 值 | 说明 |
|---|---|---|
| L1 距离 d | ≤ 3069（12bit） | \|ΔR\|+\|ΔG\|+\|ΔB\|，三通道一次算完，免开方 |
| **σ_r** | **240** | **按噪声标定**：σ_r ≈ 4.9 σ_n（L1 量纲下 ≈1.44×E[d]），σ_n=48 → 240 |
| CUT | 747 = ceil(3.11σ_r) | d>CUT 时 63·exp(−d²/2σ²)<0.5 → round 后恒 0，截断零精度损失 |
| 值域 LUT | 1024×6bit | 权重 0~63（1.0 → 63）；分布式 ROM，9 个读口由综合器自动 read-port replication |
| 空间核 | [1 2 1;2 4 2;1 2 1] | 移位实现，**0 乘法器** |
| den 范围 | [252, 1008] | 下界 = 中心项 4×63 恒存在 → `addr = den−252` |
| 倒数 ROM | 1024×13bit | `round(2^20/(addr+252))`，一次查表代替除法，**三通道共用** |
| num | 21bit（≤2^20） | num ≤ den×1023 |
| 输出 | `sat((num×inv + 2^19)>>20)` | round-half-up；乘积 <2^30（上界证明见 RTL 注释） |

## 验证结果

| 判据 | 结果 |
|---|---|
| 协议 TB（16×12×5 帧，四场景 + bypass 三段） | **[PASS]** fire 1536 = 收 1536，0 误差，断言零违例 |
| 图像 TB（112×103，M3 链出图 + 高斯噪声 σ=48） | **[PASS]** 11536/11536 |
| Python 独立复算（位级） | **全等 0 误差**（LUT/ROM 系数与 golden 同源生成） |
| bypass 场景 | 位级等于输入（直通）+ 核路径回归一致 |

**PSNR / SSIM（10bit 域，σ_n=48，MAX=1023）**：

| | PSNR(dB) | SSIM | 边缘区 PSNR | 边缘区 SSIM |
|---|---|---|---|---|
| 注噪图 | 26.51 | 0.7197 | 26.51 | 0.8738 |
| 高斯降噪 | **32.74** | 0.9216 | **31.42** | 0.9453 |
| 双边降噪（RTL） | 32.03 | 0.9039 | 31.06 | **0.9464** |

**读法（诚实结论）**：3×3 窗口 + 窄空间核（[1 2 1]，σ≈0.85）下，双边与高斯**基本打平**（PSNR 略低 0.7dB、边缘区 SSIM 略高 0.001）——这正是双边的固有取舍：**用一点点平坦区的降噪能力换边缘的保真**。优势随窗口增大而显著（5×5/7×7 才拉开差距），但 3×3 是硬件效率的标准选择。对比图 [denoise_compare.png](denoise_compare.png)。

## 设计要点

1. **三个定点技巧**（面试主线）：① 值域核查 LUT 而不算 exp，且 3.11σ 截断让 1024 项表（1 个 BRAM）覆盖全部有效范围；② 归一化除法 → 倒数 ROM + 1 次乘法，三通道共用同一 den；③ round-half-up（+2^19）消除截断偏置。
2. **LAT = 3 拍**：T0 组合（d → LUT 异步读 → 加权累加）→ T1 num/den 寄存 → T2 倒数 ROM 同步读（★num 三路同拍打）→ T3 乘+round+移位+饱和。上板时序紧时把 LUT 改同步读拆成 LAT=4。
3. **bypass 旁路（M4 三模块统一接口）**：`bypass=1` 时数据经 `axis_stream_fifo`（M0.5 现成件）直通输出，**处理路径整体冻结**（行缓存 `in_valid=0`，保住"FIFO 占用恒 = IMG_W"的不变式）。
   **切换必须发生在链路排空点**——bypass 路径延迟（FIFO 4 拍）与处理路径（行缓存 K·W+K + 核 3 拍）差 W+1 个像素量级，帧中间热切换必然错位。场景价值：半导体检测关降噪/CCM、检测后单独走显示通路——算法边界的产品化表达。
4. **两条路径完全解耦**：`in_ready = bypass ? byp_ready : lb_inready`。bypass 期不被行缓存造行反压无谓阻塞，处理路径不被 bypass FIFO 拖累。

## 踩坑记录（三条，都有实证）

1. **`in_ready` 双驱动 → X 态挂死**：stage 自己 `assign in_ready` 的同时又把行缓存的 `in_ready` 输出端口接到同一 wire —— 造行期两者值不同（0 vs 1）→ 冲突成 X → 握手型上游被 X 挂死数万拍。**修法**：行缓存的 `in_ready` 接独立 wire `lb_inready`，参与 stage 的 assign 运算。（M1 的 TB 源不握手，掩盖了这个接口缺陷；M3 因无 bypass 恰好没触发，但同类写法是隐患。）
2. **bypass 与处理路径延迟不等**：最初按"等延迟旁路"设计（bypass 打 3 拍与核对齐），忽略了行缓存的 K·W+K 窗口延迟——帧中间切换时两条流错位 W+1 像素。**修法**：改为"排空点切换"（停源 → 等出口清空 → 切换 → 再发），并在文档中明确"bypass 是帧级配置，禁止运行中热切换"。
3. **σ_r 标定失配导致"双边不如高斯"**：照抄 8bit 的 σ_r=30 ×4 = 120，只适合 σ_n=24；本实验注入 σ_n=48 → 值域核过窄、中心权重过大 → 降噪不足（PSNR 反低于高斯 3.5dB）。**修法**：按 σ_r ≈ 4.9σ_n 重标定为 240（CUT 747、LUT 1024 项）。**教训：σ_r 是"噪声尺度"参数，必须与实际噪声一起标定，不能只做位宽等比换算。**

## 复现命令

```powershell
cd BilateralFilter
# 1) 生成系数 + golden（协议场景）
python make_denoise_data.py
# 2) 协议 TB（四场景 + bypass）
iverilog -o tb_s.vvp -DNOVCD -I . -I ..\line_buffer\line_buffer_fifo_nxn -I ..\fifo tb_denoise_bilateral.v
vvp tb_s.vvp
# 3) 图像链：真图 → M3 链 → 注噪 → golden + PSNR/SSIM + 对比图
python make_denoise_data.py --img
iverilog -o tb_i.vvp -DNOVCD -DIMG -I . -I ..\line_buffer\line_buffer_fifo_nxn -I ..\fifo tb_denoise_bilateral.v
vvp tb_i.vvp
python verify_denoise.py
```

## 面试点清单

1. **为什么保边**：值域核让"与中心差得远的邻居"权重→0——边缘两侧互不污染；高斯（纯空间核）会糊边
2. **FPGA 为什么不算 exp**：查表 + 3.11σ 截断（超截断点后 round 恒 0，零精度损失；不截断 88% 表项是浪费）
3. **倒数 ROM 技巧**：除法→查表+乘法，一次除法三通道共用（den 只开一个）
4. **两个同步读对齐点**：值域 LUT 异步读省一级、倒数 ROM 同步读时 num 必须同拍打
5. **与高斯的资源差异**：多一个 LUT + 倒数 ROM + 3 个乘法 vs 纯加法树；换来看保边
6. **σ_r 怎么定**：噪声尺度参数（σ_r ≈ 4.9σ_n），随 sensor 增益档位重标定（AXI-Lite 动态写表，硬件不变）
7. **bypass 的工程含义**：等延迟不可行 → 排空点切换；半导体检测场景的算法边界
