# BLC 黑电平校正实现（M2，ISP 第一级）

> 目录：`BLC/` · 状态：**已完成（2026-09-18）**，双形态（直连 / 入端弹性 FIFO）× 双判据（TB golden + Python 独立复算）全部 0 误差
> 定位：8 级 ISP 链路第一级。入侧承接 CSI-2 RX 的 AXIS(RAW10)，出侧简流给 DPC。

## 一、为什么需要 BLC（原理一分钟）

CMOS 像素在无光照时并非输出 0——**暗电流 + 读出电路偏置**让遮光区（OB 区）也有一个非零底电平。不减掉它：

- 后级数字增益把这个底一起放大 → 暗部发灰
- AWB 的统计被底电平污染 → 白平衡不准
- 伽马（暗部拉伸最狠）把底电平的噪声放大得最明显

`p_out = max(p_in - OB, 0)`——**减法必须饱和**：无符号直接减，`3 - 5` 会环绕成 1021（RAW10），暗点变亮点。

## 二、两种等价 RTL 写法（本工程选乙）

```verilog
// 写法甲：扩 1 位有符号减（9/11bit 通路）
wire [DW:0] diff = {1'b0, in} - {1'b0, ob};
wire [DW-1:0] out_a = diff[DW] ? {DW{1'b0}} : diff[DW-1:0];

// 写法乙（blc_core 采用）：先比较再减
wire [DW-1:0] out_b = (in < ob) ? {DW{1'b0}} : (in - ob);
```

| | 写法甲 | 写法乙 |
|---|---|---|
| 减法通路位宽 | DW+1 位（带借位链） | DW 位（恒不借位：采用结果时 in≥ob） |
| 额外逻辑 | 1 个 DW+1 减法器 + 符号位 mux | 1 个 DW 比较器 + 1 个 DW 减法器 + 1 个 mux |
| 结论 | 正确但多一截进位链 | **省位宽、可读性好**，比较器本来就要有 |

## 三、四条实现要点（逐条落地）

1. **四通道各配一个 offset**：`ob_00/ob_01/ob_10/ob_11` 四个独立端口，按 Bayer 相位 `(row&1, col&1)` 选择。R/Gr/Gb/B 暗电流不同，共用一个值会让暗部偏色。
2. **寄存器可配、随增益分档**：OB 做成输入端口（集成时接 AXI-Lite 寄存器）；高增益下 OB 变大，由软件按增益档重写。硬件不感知增益，只提供"可写"的槽位。
3. **位宽**：全参数化 `DW`（RAW10 用 10，8bit sensor 传 8）；写法乙天然不需要 DW+1 位中间通路（要点③的"要么扩 1 位、要么先比较再减"选后者）。
4. **零行缓存、delay 1 拍**：BLC 是纯逐像素点运算（1 对 1 映射），数据通路 = 组合（选择 + 比较 + 减）+ 1 级输出寄存器。无窗口、无 BRAM。

## 四、相位生成（本模块唯一的对齐难点，踩了 1 个坑）

BLC 需要知道每个像素的 Bayer 相位来选 OB 通道。相位计数器语义必须是：

> **fire 拍读到的 `{row_cnt[0], col_cnt[0]}` == 当前正在消费像素的相位；拍末推进到下一像素。**

踩过的坑：最初把 sof 分支写成"清零 col"——本拍消费了 (0,0) 后拍末 col=0，**下一拍 (0,1) 读到的还是 0，整帧相位斜一列**（TB 场景 A 从 k=1 起全错，但收发计数正常、B/C/D 场景因数据重复侥幸无感）。正确写法（完整行列计数，与 DPC 同构；sof/eol 显式同步）：

```verilog
if (in_sof)      begin row_cnt <= 0; col_cnt <= 1; end              // 本拍是 (0,0)，下一拍 (0,1)
else if (in_eol) begin row_cnt <= row_cnt + 1; col_cnt <= 0; end    // 下一拍是新行第 0 列
else                  col_cnt <= (col_cnt==IMG_W-1) ? 0 : col_cnt+1;  // 回绕兜底 eol 丢失
```

第二个隐蔽点：**跨帧行奇偶残留**——上帧末 `row_cnt=H`，H 为奇时下一帧 sof 拍读到 1。解法：**sof 拍的 OB 选择与 out_phase 强制 00**（sof 拍像素恒为 (0,0)），`row_cnt` 拍末同时清零。从此任意帧宽/帧高、任意反压时序下相位严格对齐。

（重构说明：计数器最终采用与 `DPC/top_dpc.v` 同构的**完整行列计数 + 组合译码**风格——`{row_cnt[0], col_cnt[0]}` 即当前像素相位，可读性更好；但保留 sof/eol 显式同步，这正是与 DPC 老写法"靠 IMG_H/IMG_W 盲数数回绕"的本质差别：盲数数在丢 1 拍时永久错位无自愈，显式同步最多错到下一个 eol/sof。）

与行缓存类模块的区别：BLC 的相位**本质依赖行结构**，上游必须给 sof/eol（契约中 CSI-2 RX 恒给 tuser/tlast）；不像 line_buffer 那样"eol 悬空也能跑"。

## 五、结构与接口

```
CSI-2 RX ─AXIS(tdata[11:0],1ppc)─► blc_axis_adapter ─简流(DW=10)─► blc_core ─简流─► DPC
                                    │ 取低 10bit                     │ 相位选 OB
                                    │ tuser→sof tlast→eol            │ 写法乙饱和减
                                    │ ENTRY_FIFO_EN=1 时内插          │ 1 级流水+反压冻结
                                    │ axis_stream_fifo(M0.5 成果)     ▼
                                    └────────────────────────── out_data/sof/eol/phase
```

| 文件 | 职责 |
|---|---|
| `blc_axis_adapter.v` | AXIS→简流：取低位 10bit、tuser/tlast→sof/eol；`ENTRY_FIFO_EN` 预留入端弹性 FIFO（复用 `fifo/axis_stream_fifo.v`，集成时换官方 AXIS Data FIFO IP） |
| `blc_core.v` | 校正核：相位计数 + OB 选择 + 写法乙饱和减，1 级流水，`out_phase[1:0]` 供 DPC/Demosaic 免重算 |
| `blc_top.v` | adapter + core 串联 |
| `tb_blc_top.v` | AXIS 全协议 TB（见下） |
| `verify_blc.py` | numpy 独立复算（第二判据） |
| `BLC黑电平校正实现.md` | 本文档 |

反压设计：1 级流水 + 输出寄存器，下游 `out_ready=0` 且输出有字（stall）→ `in_ready=0`，输出字段保持（简流稳定性）。冻结零成本（无窗口状态要保）。

## 六、验证（三套判据：协议场景 × 位级 × 图像 PSNR）

### 6.1 协议/场景验证（双形态 × 双判据）

TB 四场景（16×12 小图、DW=10、四通道 OB={100,64,180,32}、像素 `(n*131+7)&1023` 满量程覆盖）：
A 满速连续 2 帧（多帧 sof/eol 重同步）/ B 汇随机 ready 50% / C 汇长拉低压满 / D 双向随机。
AXIS 协议断言：s 侧稳定性（源自检）、简流出侧稳定性（valid 未 ready 时四字段不变）、复位期 out_valid=0。

| 配置 | TB golden | Python 独立复算 |
|---|---|---|
| `ENTRY_FIFO_EN=0`（直连，单级仿真） | ✅ PASS，960/960 像素，0 误差 | ✅ 960 × 4 字段 0 误差 |
| `ENTRY_FIFO_EN=1`（入端 FIFO，集成形态） | ✅ PASS，960/960 像素，0 误差 | ✅ 960 × 4 字段 0 误差 |

边界用例覆盖：减到负值 clamp 0（像素序列大量 < OB）、四通道不同偏置（相位选对通道由 golden 的相位字段验证）、RAW10 满量程、反压丢数检查（收发计数 960=960 一致）。

复现：

```powershell
cd BLC
iverilog -o tb_blc.vvp -I ..\fifo tb_blc_top.v;  vvp tb_blc.vvp > sim_log.txt          # 直连
iverilog -o tb_blcf.vvp -DEFIFO -I ..\fifo tb_blc_top.v; vvp tb_blcf.vvp > sim_log_fifo.txt  # 带入端 FIFO
python verify_blc.py blc_out.txt 16 12 5
```

### 6.2 图像对比验证（真实图 + PSNR + 四宫格，仿 Demosaic 验证链）

数据链（与 Demosaic 同一张真图 112×103）：

```
input.hex(RGB24) --make_blc_data.py--> blc_ideal.hex(理想RAW10, 无黑电平)
                                      -> blc_in.hex  (加每通道黑电平 OB={100,64,180,32}, 模拟 sensor 输出)
blc_in.hex --tb_blc_img.v(RTL)--> output.coe --verify_blc_img.py--> 位级校验 + PSNR + blc_compare.png
```

PSNR 对比（vs 理想 RAW，MAX=1023）：

| 场景 | PSNR | 说明 |
|---|---|---|
| 不校（带黑电平直接用） | **19.47 dB** | 黑电平被当信号，暗部发灰（解析值 19.45） |
| BLC 校正（OB 配置准确） | **inf** | 位级还原——与 6.1 位级全等互为印证 |
| BLC 校正（OB 偏差 -16） | **36.12 dB** | 标定误差的代价：残留底电平（解析值 36.12） |

→ **两个面试级结论**：① 不校损失 16.7dB，BLC 必须做；② OB 标定偏 16/1023（1.6%）就从 ∞ 掉到 36dB——这是"OB 要精标定/实时统计 + 随增益分档重写"（要点②）的定量依据。

对比图 `blc_compare.png`：理想 RAW | 不校 | 校准 | 校偏，每格标注 PSNR 与均值（不校均值 499.5 vs 理想 405.6，整体抬亮发灰一眼可见）。

**数据生成踩坑**：理想 RAW 最初 `8bit<<2`（均值 811/1023），加 OB 后高光大量被**满阱钳位**到 1023——BLC 减不回来，"校准后 vs 理想"PSNR 只有 25.3dB 且"校偏"反而比"校准"高，实验失真。改 `<<1`（均值 406，加最大 OB=180 后 690<1023，零钳位，等价于低增益暗场景）后数字才符合解析值。教训：**构造黑电平实验时必须给满量程留 OB 的 headroom**。

图像链复现：

```powershell
cd BLC
python make_blc_data.py                                   # input.hex -> blc_ideal/blc_in.hex
iverilog -o tb_img.vvp -I ..\fifo tb_blc_img.v; vvp tb_img.vvp > sim_log_img.txt
python verify_blc_img.py                                  # 位级 + PSNR + blc_compare.png
```

## 七、TB 调通过程踩的坑（记录）

1. **相位斜一列**（见第四节①）：sof 分支清零 vs 推进语义混淆。教训：写相位计数器先写下"不变式"再动手。
2. **include 守卫宏同名冲突**：`blc_top` 与 `blc_axis_adapter` 用了同一个守卫宏名，前者定义后后者内部的 `axis_stream_fifo.v` include 被跳过——直连模式编译通过（不需要 FIFO），EFIFO=1 才爆。教训：**每个文件的守卫宏必须独立命名，且守卫包住整个文件**。
3. **数据序列口径**：源模型最初用帧内序号生成数据（每帧重复），Python 按"跨帧连续 n"重算 → 帧 0 巧合一致、帧 1 起全错。教训：**TB 与 Python 校验脚本的输入约定必须一字不差地写进两边注释**（现两边均为 `p(n)=(n*131+7)&1023，n 跨帧连续`）。
4. reg 声明被 assign 驱动（TB 骨架低级失误，改 wire）。

## 八、面试讲点

- 为什么 BLC 是逐像素点运算、零行缓存：1 对 1 映射，无邻域依赖——与后面 5×5 DPC 的行缓存需求形成对比
- 为什么四通道分 OB：暗电流通道差异 → 共用值暗部偏色；OB 槽位按**相位**而非颜色命名，BAYER_PATTERN 只是软件填值的语义表
- 饱和减法的两种写法与取舍（比较器 + 短进位链 vs 扩位减法器）
- 反压：1 级流水的 stall = `out_valid && !out_ready`，冻结即 ready 拉低，无状态保存成本
- 相位生成的"不变式"思维：先定义"fire 拍寄存器值 == 当前像素相位"，再推每个分支
