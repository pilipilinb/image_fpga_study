# line_buffer_fifo_nxn —— FIFO 版 N×N 行缓存设计要点

> 目录：`line_buffer/line_buffer_fifo_nxn/`
> 定位：8 级 ISP 链路（BLC→DPC→Demosaic→降噪→AWB→CCM→Gamma→锐化）每一级复用的唯一行缓存形态。
> 文件：`fwft_wrapper.v`（标准 FIFO→FWFT）、`line_buffer_fifo_nxn.v`（主模块）、`tb_line_buffer_fifo_nxn.v`（自检 TB）。

## 一、为什么 FIFO 也能做行缓存（核心原理）

一个 FIFO 的"延迟"= **它内部当前的占用字数**。要让第 m 级 FIFO 的输出等于"m 行之前、同一列"的像素，
就必须让它恒有 `IMG_W` 个字的占用：

| 阶段 | 写 | 读 | 占用 |
|---|---|---|---|
| 预热（前 IMG_W 个 beat） | 每拍写 | 不读 | 0 → IMG_W |
| 稳态 | 每拍写 | 每拍读（**与写严格配对**） | 恒 IMG_W |
| 冻结（反压/气泡） | 停 | 停 | 不变（数据原地保留） |

于是"第 n 个 beat 写进去的字，在第 n+IMG_W 个 beat 被读出"；而**相隔 IMG_W 个 beat** 在行光栅扫描里
恰好就是"上一行的同一列"。级联 N-1 级即得 N-1 行延迟（第 m 级输出滞后 m 行）。

**铁律**：预热结束后写读必须同拍配对 —— 只读不写会让占用下降、延迟变小 → 行错位；只写不读同理。
FIFO 深度取 `≥ IMG_W+1`（占用恒 IMG_W < 深度）保证永不 full、push 永不丢。

`fwft_wrapper` 负责把 `async_fifo`（标准读：rd_en 下一拍出数）包成 FWFT（首字直通）：
`std_rd = !empty && (!vld_r || pop)` —— 输出寄存器空或正被消费时就预取，保证"数据与 valid 同拍"。

**FWFT 是必须的、不是可选项**：标准读模式下 valid 当拍传、数据晚 1 拍，每级就斜 1 像素；
FWFT 让第 m 级输出与本拍输入落在同一列、只差行号 —— 这也是**本版不需要 BRAM 版的 adly 对齐延迟链**的原因。

## 二、窗口相位（推导结论，TB 用 golden 模型逐点验证）

- 第 m 级 FIFO 输出 = 本拍输入的前 m 行、同列
- 列向量 `col_vec[i]` = 行 `(r-(N-1)+i)`、列 `c`（i=0 顶 … i=N-1 底 = 本拍输入像素）
- 横向移位窗在"移位后一拍"给出完整窗口，其中心 = 当前 beat **往前第 K 拍**那个 beat 的坐标
  （列跨行回绕时自然对应到上一行末端的中心）
- ⇒ 按 beat 顺序恰好是光栅序：第 `K*W+K+1` 个 beat 出中心 (0,0) 的窗口，最后一个出中心 (H-1,W-1)，
  共 H×W 个。造行注入拍数 = `K*W + K`

**帧首 K 行/列窗口为什么也是对的**：越界格由输出级 mux 钳位到"边界格"取值，而被钳位选中的那些格子
恰好都是真实 beat 位置；FIFO 预热期的脏数据只出现在永远不会被钳位选中的位置（窗口左上 K×K 区域）。

## 三、帧末造行（pad 的代价）与反压冻结

**造行**：最后 K 行/列的窗口需要"还不存在的未来行 / 越界的列"。FIFO 版做法是把第 1 级 FIFO 的输出
**原地回写**（pop 一个字、同拍 push 回同一个字）→ FIFO 内容原地旋转 → 天然按列循环吐出最后一行数据。
（BRAM 版是用 `fcol` 地址循环扫实现的同构操作。）造行期 `in_ready=0` 持续 `K*W+K` 拍，上游靠入端弹性
FIFO 吸收 —— 模块本身刻意不做入端 FIFO（单一职责）。

**反压冻结链**：`out_ready=0` 且输出寄存器里已有窗口（stall）→ 所有 FIFO 停写停读、移位窗停、
计数器停、`in_ready=0` → 反压逐级上传；恢复时无损续传（FIFO 保序）。
⇒ 模块内部没有"输入弹性"，反压直达上游；弹性由链路首尾的 AXIS Data FIFO 承担。

## 四、踩坑记录（本轮实际触发，都已修）

### 1. 造行末拍的"电平清零"竞态（**RTL 真 bug**）
`flush_done = flush_active && (fc == FLUSH_BEATS)` 是**电平**：下游反压正好卡在最后一拍时它会持续为高，
而 beat 注入要等 `pipe_go`。用它去清 `ocr/occ` 窗口坐标计数，就会在"还没注入最后一拍"时把坐标清零
→ 帧末窗口内容与 sof 全错（只在反压场景暴露，连续流跑不出来）。
**修法**：清零点一律用 `flush_last = flush_active && (fc == FLUSH_BEATS) && pipe_go`（真正推进那一拍）。

### 2. 窗口坐标不能用 `row_cnt/col_cnt` 推
造行期列计数会回绕（真实列 `W-1+K` 被记成 `K-1`），坐标会算错。改用**独立计数器** `ocr/occ`
（每吐一个窗口 +1、帧首/造行末归零）—— 干净的光栅坐标。

### 3. TB 的三类竞态（同 M0 的教训）
- 激励直接用随机 always 驱动时，流程里写 `in_valid=0` 会被覆盖 → 用 mode 变量从源头控制
- 排空/等待判据要用"真正完成"（收到 H×W 个窗口），不能用拍数估算
- iverilog 不支持任务内 `break` → 用 `done` 标志位
- `$display` 里 `%` 要写 `%%`（否则报 unknown format）

### 4. 已弃用的对照件：BRAM pad 版（**不用管，也不再用**）
`line_buffer_nxn_pad` 当前**自身 TB 也超时**（`-DSMALL` 与默认 img.hex 两跑均 `win=11309/23072 err=0` 后挂死）。
根因（仅供参考，不必修）：其 `row_cnt/col_cnt` 复位条件用了裸 `din_sof`（未与 valid 门控），首个 beat 的
计数被复位吃掉 → 帧末造行触发条件 `(row==H-1 && col==W-1)` 永不满足 → 造行不启动。
**用户决策：该版有 BUG 且以后不会用 ⇒ 计划里的"双 DUT 位级全等"判据取消**，M1 判据为下面两把独立的尺子。

### 5. TB 侧：`$random` 是有符号的
`($random % 1000)` 会因负值而恒小于阈值 → 概率完全走样（曾把"2% 长拉低"变成"几乎全程拉低"，
单帧拍数从 1.5 万涨到 4.8 万）。**一律写成 `{$random} % 1000`**（拼接成无符号）。

## 五、验证情况（双判据）

TB 六场景：①连续流单帧 ②连续流 2 帧 ③入侧气泡（随机 30%）④出侧反压（随机 50%）
⑤出侧长拉低（>一行，压满 FIFO）⑥双向随机。每个场景逐窗口 N² 点比对 + sof/eol 位置校验。

判据一：TB 内建 golden（整帧图像 + replicate padding 逐点重算）。
判据二：`verify_fifo_nxn.py` —— 独立用 numpy 从"输入图像生成规则 + padding 定义"重算期望窗口，
逐点比对 TB 落盘的 `fifo_wins.txt`（不复用 TB 任何比对逻辑）。

| 参数组合 | TB golden | Python 独立复算 | 稳态吞吐 |
|---|---|---|---|
| 16×12 N=3 DW=10 | ✅ PASS（7 帧 × 192 窗口） | ✅ 1344 窗口 × 9 点 0 误差 | 1.01 拍/beat |
| 16×12 N=5 | ✅ PASS | — | 1.01 拍/beat |
| 8×6 N=3 | ✅ PASS | — | 1.01 拍/beat |
| 640×8 N=5 | ✅ PASS（7 帧 × 5120 窗口） | ✅ 35840 窗口 × 25 点 0 误差 | **1.0003 拍/beat** |

**吞吐量化**（设计目标 1 pixel/clock）：连续流下每帧应耗 `H×W + K×W+K` 拍 ——
16×12/N=3 实测 211 拍（理论 209）✅；640×8/N=5 实测 6404 拍（理论 6402）✅。
反压/气泡的额外开销：入侧气泡 30% → ~1.46×；出侧随机 50% → ~2×；长拉低（压满 FIFO）→ ~9×。
⇒ **未冻结时满速 1 pixel/clock；冻结/恢复无丢数、无乱序。**

### 复现命令

```powershell
cd line_buffer\line_buffer_fifo_nxn
# 小图（16×12 N=3），带 VCD
iverilog -o tb_a.vvp -DTB_W=16 -DTB_H=12 -DTB_N=3 -I ../../fifo tb_line_buffer_fifo_nxn.v
vvp tb_a.vvp > sim_log.txt
python verify_fifo_nxn.py fifo_wins.txt 16 12 3 10 7

# 宽图（640×8 N=5），关 VCD 加速
iverilog -o tb_d.vvp -DTB_W=640 -DTB_H=8 -DTB_N=5 -DNOVCD -I ../../fifo tb_line_buffer_fifo_nxn.v
vvp tb_d.vvp > sim_log.txt
python verify_fifo_nxn.py fifo_wins.txt 640 8 5 10 7
```

## 六、换官方 IP 的路径

1. `fwft_wrapper` + `async_fifo` → Vivado **FIFO Generator**（Independent Clocks + **First Word Fall
   Through**）：端口同名同义（rst 高有效/rst_busy/empty/full/din/wr_en/rd_en/dout），删掉 wrapper 与
   async_fifo 后同名直连，主模块零改动。
2. 链路首尾的弹性 FIFO → **AXI4-Stream Data FIFO IP**（原生带 tuser/tlast sideband），即 `fifo/axis_stream_fifo.v`
   的替换目标（M0.5 已做对齐版）。
3. 注意：IP 仿真模型加密，iverilog 编不了；替换后必须用**同一套 TB 在 Vivado xsim 复跑**。
