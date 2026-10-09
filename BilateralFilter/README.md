# BilateralFilter —— M4 双边滤波降噪（线性 RGB 域，10bit）

ISP 链第五级（M4 第一模块）：**双边滤波降噪**。输入 = M3 Demosaic 出的线性 RGB 10bit 简流（`in_data[29:0]`），输出同格式。算法来源 [工程要点.md](工程要点.md)（伪代码 + PGA 实现要点），本实现把其中的 8bit 数字按链路契约重推为 10bit 并补齐工程细节。

## 文件清单

| 文件 | 说明 |
|---|---|
| `denoise_bilateral_core.v` | 双边核：L1 距离 → 值域 LUT → 空间核加权 → 倒数 ROM 归一化（核 **LAT=6**，10bit 域；拆流水后） |
| `denoise_stage.v` | 行缓存(N=3, DW=30) + **窗口寄存器** + 核 + **bypass 旁路** + 反压冻结（处理路径总延迟 = 窗口 1 + 核 6 = 7） |
| `tb_denoise_bilateral.v` | 自检 TB：协议四场景 + bypass 三段落切换 + IMG 模式，期望预生成逐拍比对 |
| `make_denoise_data.py` | LUT/倒数 ROM 系数生成 + M3 链出图注噪 + Python golden（与 RTL 位级同构） |
| `verify_denoise.py` | 独立复算（位级）+ PSNR/SSIM（全图 + 边缘区）+ 高斯对比 + 四宫格 |
| `range_lut.coe` / `inv_rom.coe` | 系数文件（Python 生成，RTL `$readmemh` 加载） |
| `denoise_compare.png` | 对比图：注噪 \| 高斯 \| 双边 \| 无噪 |

## 参数（10bit 域，与 8bit 版的换算关系已核对）

| 量 | 值 | 说明 |
|---|---|---|
| L1 距离 d | ≤ 3069（12bit） | \|ΔR\|+\|ΔG\|+\|ΔB\|，三通道一次算完，免开方 |
| **σ_r** | **240** | **按噪声标定**：σ_r ≈ 4.9 σ_n（L1 量纲下 ≈1.44×E[d]）σ_n为噪声标准差、，σ_n=48 → 240 |
| CUT | 747 = ceil(3.11σ_r) | d>CUT 时 63·exp(−d²/2σ²)<0.5 → round 后恒 0，截断零精度损失 |
| 值域 LUT | 1024×6bit | 权重 0~63（1.0 → 63）；分布式 ROM，9 个读口由综合器自动 read-port replication |
| 空间核 | [1 2 1;2 4 2;1 2 1] | 移位实现，**0 乘法器** |
| den 范围 | [252, 1008] | 下界 = 中心项 4×63 恒存在 → `addr = den−252` |
| 倒数 ROM | 1024×13bit | `round(2^20/(addr+252))`，一次查表代替除法，**三通道共用** |
| num | 21bit（≤2^20） | num ≤ den×1023 |
| 输出 | `sat((num×inv + 2^19)>>20)` | round-half-up；乘积 <2^30（上界证明见 RTL 注释） |

### σ_r 怎么定（工业界的实际做法）

**结论：是的，"先估噪声 σ_n、再换算 σ_r"是主流路径；但工业上更常见的是"离线标定成表 + 随增益档位换表"，而不是逐帧实时估计。**

**做法 A · 噪声标定驱动（工程/研究主流）**

1. 用**均匀灰面 / 灰阶卡**在多档 ISO（增益）下拍摄；
2. 软件（Imatest / MATLAB / Python）算平坦区标准差得 σ_n；更规范的是 **PTC（光子转移曲线）** 法——分离**散粒噪声**（∝√信号，随亮度变）与**读出噪声**（固定），得到 `σ_n(亮度, 增益)`；
3. 换算到与 d 相同的量纲（本工程 d = 三通道 L1 和，10bit 域）：`σ_r ≈ 4.9 σ_n`；
4. 做成档位表 `ISO/增益 → σ_r`；
5. 上板微调系数（在"噪点残留 vs 涂抹感"之间取平衡）。

**做法 B · 主观 tuning 档位（消费级 ISP 最常见的落地形式）**

不显式估 σ_n，调参师直接按 **noise level 档位**调 σ_r/σ_s，每个 ISO 档配一组参数——本质还是"噪声越大、σ_r 越大"，只是把估计环节换成了经验档位。

**两个工程要点**

- **σ_r 应随增益（ISO）变，严格说还随亮度变**（散粒噪声 ∝√信号）；工业实现常用"增益一维表"近似（够用），讲究的用"亮度分段 + 增益"二维表。
- **硬件上"σ_r 变"= 值域 LUT 内容变，结构一行不改**：多套 LUT 由软核切换，或 AXI-Lite 动态写表（本项目留到集成阶段，见 `双边滤波实现计划.md` 边界与范围）。
- 本工程是**单档标定的简化版**：离线固定注入 σ_n=48 → 手算 σ_r=240（对应做法 A 的第 2~3 步），验证的是算法与定点链正确性。

## 验证结果

| 判据 | 结果 |
|---|---|
| 协议 TB（16×12×5 帧，四场景 + bypass 三段） | **[PASS]** fire 1536 = 收 1536，0 误差，断言零违例 |
| 图像 TB（112×103，M3 链出图 + 高斯噪声 σ=48） | **[PASS]** 11536/11536 |
| Python 独立复算（位级） | **全等 0 误差**（LUT/ROM 系数与 golden 同源生成） |
| bypass 场景 | 位级等于输入（直通）+ 核路径回归一致 |
| **OOC 时序**（Vivado 2021.2，`xcvu19p-fsva3824-2-e`，150 MHz） | **40 级 / −5.804ns ❌ → 13 级 / +2.145ns ✅**（三轮迭代拆流水；每轮 TB 重跑仍 0 误差）详见「时序收敛实战」 |

**PSNR / SSIM（10bit 域，σ_n=48，MAX=1023）**：

| | PSNR(dB) | SSIM | 边缘区 PSNR | 边缘区 SSIM |
|---|---|---|---|---|
| 注噪图 | 26.51 | 0.7197 | 26.51 | 0.8738 |
| 高斯降噪 | **32.74** | 0.9216 | **31.42** | 0.9453 |
| 双边降噪（RTL） | 32.03 | 0.9039 | 31.06 | **0.9464** |

**读法（诚实结论）**：3×3 窗口 + 窄空间核（[1 2 1]，σ≈0.85）下，双边与高斯**基本打平**（PSNR 略低 0.7dB、边缘区 SSIM 略高 0.001）——这正是双边的固有取舍：**用一点点平坦区的降噪能力换边缘的保真**。优势随窗口增大而显著（5×5/7×7 才拉开差距），但 3×3 是硬件效率的标准选择。对比图 [denoise_compare.png](denoise_compare.png)。

## 设计要点

1. **三个定点技巧**（面试主线）：① 值域核查 LUT 而不算 exp，且 3.11σ 截断让 1024 项表（1 个 BRAM）覆盖全部有效范围；② 归一化除法 → 倒数 ROM + 1 次乘法，三通道共用同一 den；③ round-half-up（+2^19）消除截断偏置。
2. **核 LAT = 6 拍（拆流水后）**：E1 `wr`/窗口寄存 → E2 加树两段寄存 → E3 num/den 寄存 → E4 倒数 ROM 同步读（★num 三路同拍打）→ E5 乘积寄存 → E6 round/移位/饱和 → 输出寄存。**原设计 LAT=3、OOC 实测 40 级 / WNS −5.804ns @150MHz 不收敛**，经三轮迭代拆到 **13 级 / +2.145ns ✅**——全过程带时序报告片段见下面「时序收敛实战」。
3. **bypass 旁路（M4 三模块统一接口）**：`bypass=1` 时数据经 `axis_stream_fifo`（M0.5 现成件）直通输出，**处理路径整体冻结**（行缓存 `in_valid=0`，保住"FIFO 占用恒 = IMG_W"的不变式）。
   **切换必须发生在链路排空点**——bypass 路径延迟（FIFO 4 拍）与处理路径（行缓存 K·W+K + 核 3 拍）差 W+1 个像素量级，帧中间热切换必然错位。场景价值：半导体检测关降噪/CCM、检测后单独走显示通路——算法边界的产品化表达。
4. **两条路径完全解耦**：`in_ready = bypass ? byp_ready : lb_inready`。bypass 期不被行缓存造行反压无谓阻塞，处理路径不被 bypass FIFO 拖累。

## 踩坑记录（三条，都有实证）

1. **`in_ready` 双驱动 → X 态挂死**：stage 自己 `assign in_ready` 的同时又把行缓存的 `in_ready` 输出端口接到同一 wire —— 造行期两者值不同（0 vs 1）→ 冲突成 X → 握手型上游被 X 挂死数万拍。**修法**：行缓存的 `in_ready` 接独立 wire `lb_inready`，参与 stage 的 assign 运算。（M1 的 TB 源不握手，掩盖了这个接口缺陷；M3 因无 bypass 恰好没触发，但同类写法是隐患。）
2. **bypass 与处理路径延迟不等**：最初按"等延迟旁路"设计（bypass 打 3 拍与核对齐），忽略了行缓存的 K·W+K 窗口延迟——帧中间切换时两条流错位 W+1 像素。**修法**：改为"排空点切换"（停源 → 等出口清空 → 切换 → 再发），并在文档中明确"bypass 是帧级配置，禁止运行中热切换"。
3. **σ_r 标定失配导致"双边不如高斯"**：照抄 8bit 的 σ_r=30 ×4 = 120，只适合 σ_n=24；本实验注入 σ_n=48 → 值域核过窄、中心权重过大 → 降噪不足（PSNR 反低于高斯 3.5dB）。**修法**：按 σ_r ≈ 4.9σ_n 重标定为 240（CUT 747、LUT 1024 项）。**教训：σ_r 是"噪声尺度"参数，必须与实际噪声一起标定，不能只做位宽等比换算。**

## ★ 时序收敛实战：40 级 / −5.804ns → 13 级 / +2.145ns（面试主线）

> 数据来自 Vivado 2021.2 OOC 综合（器件 `xcvu19p-fsva3824-2-e`，约束 150 MHz = 6.667 ns），
> 顶层取 **`denoise_stage`**（不是 `denoise_bilateral_core`）；脚本 [synth_ooc_timing.tcl](../synth_ooc_timing.tcl)，报告生成在 `synth_rpt/`（本地产物，未入库）。
> **功能侧全程 0 误差**（每轮都重跑 TB：协议 1536/1536、真图 11536/11536）——拆流水是**纯 retiming**，输出序列一位不变。

### 迭代 0 · 现象：功能 100% 正确，时序差 5.8 ns

| 顶层 | 逻辑级数 | WNS @150MHz |
|---|---|---|
| `denoise_stage` | **40** | **−5.804 ns** ❌（隐含上限 ≈80 MHz） |
| `ccm_stage`（**无行缓存**、LAT=2） | 8 | +4.748 ns ✅ |

**先做对照实验再改代码**：同样"逐像素核 + 乘加 + 饱和"，唯独带**行缓存**的这一层炸了 ⇒ 嫌疑锁死在"行缓存输出 → 核"这段接口上。（同时排除了"用了 function / 乘法器太多"这类直觉猜测。）

### 迭代 1 · 病因 ①：行缓存 pad mux 是**组合**逻辑，与核叠在同一拍

报告片段（迭代 0）：
```
Slack (VIOLATED) : -5.804ns
  Source:      u_lb/lc_r_reg[0]/C          ← 行缓存"窗口中心行"坐标寄存器（不是数据寄存器！）
  Destination: u_core/nB__6/DSP_OUTPUT_INST/ALU_OUT[0]
  Data Path Delay: 12.451ns (logic 8.580 (68.9%) route 3.871 (31.1%))
  Logic Levels: 40 (CARRY8=3 DSP_A_B_DATA=1 DSP_ALU=9 DSP_M_DATA=1 DSP_MULTIPLIER=1
                   DSP_OUTPUT=8 DSP_PREADD_DATA=1 LUT2=1 LUT3=2 LUT4=3 LUT5=5 LUT6=4 MUXF7=1)
```
`Source` 竟是**窗口中心坐标寄存器**而不是数据寄存器——因为 `out_win_flat` 的 pad 选择器是真组合逻辑（见 `line_buffer_fifo_nxn.v`）：
```verilog
assign win_out_flat[(oi*N+oj)*DW +: DW] = win_reg[sel_row(oi,lc_r)*N + sel_col(oj,lc_c)];
```
`sel_row/sel_col`（带 clamp 的整数运算）→ 9:1 mux → **核内加法树/乘法/饱和** → 输出寄存器，全部压在一个时钟周期里。

**修法**：在 `denoise_stage` 里对 `lb_win` 插一级窗口寄存器（`valid` 同行，`sof/eol` 走等深对齐链）：
```verilog
always @(posedge clk or negedge rst_n)
    if (!rst_n)      begin win_q <= 0; wv_q <= 1'b0; end
    else if (!ostall) begin win_q <= lb_win; wv_q <= lb_valid; end   // ostall 时同步冻结
```
> **为什么不直接改 `line_buffer_fifo_nxn`？** 它被 M1/M3/M4 共用，且"内部 FIFO 占用恒 = IMG_W"是已验证的不变式；在 stage 里打拍是**局部、零风险**的改法（共用件一行不动）。

**效果**：40 → **34 级**，−5.804 → **−4.258 ns**（路径起点由 `lc_r` 变成 `win_q` ✓ 证明 pad mux 确已切出去）。

### 迭代 2 · 病因 ②：9 项加树被映射成 **DSP 级联链（8 跳）**

报告片段（迭代 1 后）：
```
Slack (VIOLATED) : -0.520ns
  Source:      u_core/g_px[8].wr_r_reg[8][0]/C     ← 已是我新加的 wr 寄存器 ✓
  Destination: u_core/nB__6/DSP_OUTPUT_INST/ALU_OUT[0]
  Data Path Delay: 7.167ns (logic 6.873 (95.9%)  route 0.294 (4.1%))   ← 几乎全是逻辑，路由只占 4%！
  Logic Levels: 21 (DSP_A_B_DATA=1 DSP_ALU=9 DSP_M_DATA=1 DSP_MULTIPLIER=1
                   DSP_OUTPUT=8 DSP_PREADD_DATA=1)
```
逐级看出这是 **DSP48 的 PCIN→PCOUT 级联链**（每跳的固定开销）：
```
DSP_ALU(nB0)    0.546  →PCOUT
DSP_OUTPUT(nB0) 0.122
   ↓ 路由 0.014
DSP_ALU(nB )    0.546  → 每跳 ≈0.68ns，9 项加树 = 8 跳 ≈5.5ns
DSP_OUTPUT(nB ) 0.122
   …（重复到 nB__6）
```
即：`Σ w_k·v_k`（每通道 9 个乘法 + 加树）被综合器塞进**一串级联的 DSP**，跳了 8 次。**route 只占 4% ⇒ 纯 DSP 内部延迟 6.87 ns**，与布线拥塞无关。

**修法（一刀拆成三处）**：
1. **LUT 出口寄存**：值域权重 `wr` 与窗口像素 `W_r` 各打一拍（像素必须**同拍延迟**，否则乘法两边错拍）→ 切掉 `d9`（三通道 L1 绝对差）+ 分布 ROM 读。
2. **乘积寄存**：`pr_r <= numR_q * inv_r;` 单独一拍 → 把 round/饱和从 DSP 组合 ALU 里赶出去（此前 `DSP_OUTPUT=8` 就是在算这个）。
3. **加树中间切开**：`nR =（taps0-4 的和寄存）+（taps5-8 的和寄存）` → 每段最多 4 跳 DSP 级联。

**效果**：34 → 21 → **13 级**，−4.258 → −0.520 → **+2.145 ns ✅**

最终报告片段：
```
Slack (MET) : 2.145ns
  Logic Levels: 13 (DSP_A_B_DATA=1 DSP_ALU=5 DSP_M_DATA=1 DSP_MULTIPLIER=1
                   DSP_OUTPUT=4 DSP_PREADD_DATA=1)
  Data Path Delay: 4.502ns (logic 4.201 (93.3%) route 0.301 (6.7%))
```

### 三轮汇总

| 迭代 | 动作 | 级数 | WNS | FF |
|---|---|---|---|---|
| 0 | —（原设计，核 LAT=3） | 40 | −5.804 ❌ | 744 |
| 1 | stage 窗口寄存器（切行缓存 pad mux） | 34 | −4.258 ❌ | 1014 |
| 2 | 核内 LUT 出口寄存 + 乘积寄存 + 加树中间切 | **13** | **+2.145 ✅** | 1421 |

**代价**：核 LAT 3 → **6**（stage 处理路径总延迟 4 → **7** = 窗口 1 + 核 6，对齐链 7 级）；FF 744 → 1421；LUT 3146 → 3051（几乎不变）；DSP 33 → 30。**输出一位没变。**

### 面试问答（预演）

- **Q：这个问题你怎么发现的？** 功能 TB 全过、PSNR/SSIM 也漂亮，是我主动做 **OOC 综合预检**时发现的——**仿真只验功能、不验时序**，这一步不能省。同批扫描还发现锐化同样超时（见 `Sharpen/README.md`）。
- **Q：怎么快速定位到"行缓存接口"？** 拿一个结构相近但**没有行缓存**的模块做对照（`ccm_stage`：8 级 / +4.748ns ✅），差别只有行缓存 ⇒ 一眼锁定。**有对照实验，就不用猜。**
- **Q：为什么行缓存会让路径变长？** 它的 pad 选择器（`sel_row/sel_col` + 9:1 mux）是**组合**逻辑，直连核时与核内逻辑叠成一条超长路径；关键路径的起点甚至不是数据寄存器，而是窗口**中心坐标**寄存器。
- **Q：拆流水的次序怎么定？** 读 `report_timing` 的 `Logic Levels` 构成：`CARRY8` 多 ⇒ 加法器树太长；`DSP_ALU/DSP_OUTPUT` 多 ⇒ 逻辑被吸进了 DSP 组合旁路。哪项占比大就先切哪一刀。
- **Q：DSP 不是应该帮忙吗？为什么不直接用它？** DSP48 的 ALU/输出级既能当逻辑用也能当寄存器用；**不给显式寄存器时，综合器倾向于把整条"乘加 + round + 饱和"塞进级联的 DSP**，而级联每跳约 0.68ns，9 项加树 = 8 跳 ≈ 5.5ns，反而成了瓶颈。修法就是在乘法/加树中间**显式写寄存器**，逼综合器在那里断链。
- **Q：改了 LAT 会不会改功能？** 不会——纯 retiming，输出序列不变。但有个必踩的连带项：`stage` 的 `sof/eol` 对齐链深度必须同步改成 `LAT_WIN + LAT_CORE`，**少一级/多一级都会让 sof/eol 与数据错位**（本模块因此从 4 级改到 7 级）。
- **Q：行缓存的造行反压/占用不变式有没有被破坏？** 没有——窗口寄存器在 stage 层，共用件 `line_buffer_fifo_nxn` 一行未改；`ostall` 时窗口寄存器与行缓存**同步冻结**，占用恒 `IMG_W` 的不变式原样保住。

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
