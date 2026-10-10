# BLC_DPC —— BLC 与 DPC 顺序可交换性实验（★ 预测被证伪 → 定位根因）

> **定位**：为"8 级 ISP 为什么把 BLC 放在最前"提供量化论证。做法与
> [Denoise_CCM_Gamma](../Denoise_CCM_Gamma/README.md) 同模板（**一个参数切顺序 + 客观靶子 + 多类证据**），
> 但判优靶子与指标换成 RAW 域该关心的东西：**缺陷检测的 TP/FP/FN**、**与光强真值的 PSNR/MAE**、**黑电平残差**。
> 详细推导见 [BLC_DPC实现计划.md](BLC_DPC实现计划.md)；面试叙事版见 [../面试故事集.md](../面试故事集.md) 故事 4。

---

## 一句话结论（可背）

> **不能一概而论 —— 要分相位看。** 可交换性的**必要条件**是"像素及其同相位邻居闭包 S(c) 内 OB 全相同，
> 且无像素低于自身 OB"：
> - **R/B 中心**：邻居全是同色（同 OB）⇒ **只要不下溢就位级完全可交换** ✓（实测差异仅 3/25 且全在下溢处）
> - **G 中心**：DPC 把 **Gr 与 Gb 当"同色"邻居**（它们光谱响应确实相同），
>   但 **OB[Gr]=64 ≠ OB[Gb]=180，差 116 LSB** ⇒ "按相位平移"在邻域内**不均匀**
>   ⇒ 等变性 `D(x+c_p)=D(x)+c_p` **天然失效 ⇒ 不可交换** ✓
>
> **⇒ 工程结论：BLC 必须在前** —— 它是唯一能把 Gr/Gb 拉到同一量纲的操作。若 DPC 先做，
> 116 LSB 的 Gr/Gb 黑电平差会变成混进缺陷判据的"假台阶"（实测 TP 54→55、FN 6→5），
> 让同一套 RTL 换个顺序就判出不同结果 —— 这是**可维护性风险**。
>
> **质量上两者几乎等价**（位级差异仅 25/11536 = 0.22%，顺序0 保真度高 0.38 dB）
> ⇒ 这个顺序问题**不能用"谁更好"回答，只能用"谁与契约/量纲一致"回答**。

## 文件清单

| 文件 | 作用 |
|---|---|
| `blc_dpc_top.v` | 顶层：BLC 与 DPC 串联，`SWAP_BD` 参数切换顺序 |
| `tb_blc_dpc.v` | 自检 TB：两种顺序各编译一次（`-DSWAP`），协议三场景位级比对 + **相位一致性检查** |
| `make_blc_dpc_data.py` | 数据生成：含 OB 的 sensor RAW + 传感级缺陷 + "低于黑电平"像素 + 两套顺序 golden |
| `verify_blc_dpc.py` | 独立第二判据 + **预测校验**（三级递进）+ TP/FP/FN + PSNR/MAE + 黑电平残差 + 6 格对比图 |
| `blc_dpc_compare.png` | 输入 RAW / 只做BLC / 真值 / 顺序0 / 顺序1 / 放大差异 |
| 生成物 `.hex` | `bd_in_{small,img}.hex` · `exp_order0/1_{small,img}.hex` · `truth_blc_img.hex` · `clean_bayer_img.hex` |
| `below_pos.txt` / `defect_pos.txt` | 注入的"低于黑电平"像素与缺陷像素位置（verify 用来验预测） |

## 接口

```verilog
module blc_dpc_top #(
    parameter DW = 10, IMG_W = 640, IMG_H = 480, N = 5, THR = 128,
    parameter SWAP_BD = 0        // 0 = BLC→DPC（本工程）; 1 = DPC→BLC（对照）
)(
    input  wire clk, rst_n,
    input  wire [DW-1:0] ob_00, ob_01, ob_10, ob_11,   // 四通道黑电平 R/Gr/Gb/B
    input  wire in_valid, output wire in_ready,
    input  wire [DW-1:0] in_data, input wire in_sof, in_eol,
    output wire out_valid, input wire out_ready,
    output wire [DW-1:0] out_data, output wire out_sof, out_eol,
    output wire [1:0] out_phase                        // Bayer 相位，顺序换了也不能丢
);
```

- **相位编码**：`phase = (row&1)*2 + (col&1)` → 00=R、01=Gr、10=Gb、11=B
- **黑电平**（与 BLC/tb_blc_top 一致）：`OB = {R:100, Gr:64, Gb:180, B:32}`
- 例化参数：BLC `LAT=1`（无行缓存）；DPC 含 5×5 行缓存（复用 `line_buffer_fifo_nxn`），`THR=128`
- **总延迟 = 1 + D_DPC，与顺序无关**（加法交换律）⇒ 两流逐拍可对齐比较
- **DPC 的邻居定义**：R/B 中心用 8 个同色邻居（行列都偶）；**G 中心用 12 个（含 ±1,±1 的另一个 G 子相位）**

## 实验设计

| 要点 | 做法 |
|---|---|
| **单一变量** | 只用 `SWAP_BD` 切顺序，其余例化/参数/激励/判据全同 |
| **刻意的两类注入** | ① 传感级缺陷 60 个（亮点 1023 / 死点 0 各半）② "低于黑电平"像素 40 个（`raw = OB − 30`） |
| **客观靶子** | `clean_bayer_img.hex`（无 OB 无缺陷的光强真值）→ 比 PSNR/MAE；缺陷位置真值已知 → 比 TP/FP/FN |
| **数据复用** | 直接复用 M3 管线的 Bayer 构造方式（`Demosaic/input.hex` → Bayer 采样 → `min(v<<1, MAXV)`），保证与既有模块可比 |

## 结果（全部 [PASS]，exit=0）

| 项 | 结果 |
|---|---|
| 协议 TB · 顺序0（BLC→DPC） | **[PASS]** 1152/1152，位级 0 误差 + **相位违例 0** + 反压稳定零违例 |
| 协议 TB · 顺序1（DPC→BLC） | **[PASS]** 1152/1152，同上 |
| 真图 TB · 顺序0 / 顺序1 | **[PASS]** 各 11536/11536，位级 0 误差、相位违例 0 |
| 独立第二判据 | 自己重算 golden 与 RTL 落盘**逐位 0 误差**（两顺序） |

### ★ 三级递进：预测 → 被证伪 → 定位根因（本节是最有价值的部分）

| 层级 | 内容 | 结果 |
|---|---|---|
| **预测①** | `diff ⊆ U`（**自己**低于黑电平的像素） | **被实测证伪 8 个像素** |
| **预测②** | `diff ⊆ reach(U)`（同相位邻居一跳闭包） | **仍被证伪同一批 8 个** ⇒ 漏掉的机理**不是沿邻域传播**的 |
| **诊断** | 越界 8 个**全是 G 相位**（Gr 6 + Gb 2）；G 相位占全图 50.0%，却占差异 **88.0%**（22/25）；R/B 差异仅 3 个且**全在下溢处**（与预测①吻合） | — |
| **根因** | DPC 把 **Gr 与 Gb 当同色邻居**，而 **OB[Gr]=64 ≠ OB[Gb]=180（差 116 LSB）** ⇒ 对 G 中心"按相位平移"**不均匀** ⇒ 等变性天然失效，**与下溢无关** | — |
| **修正** | 必要条件：`diff ⊆ { c : S(c) 内 OB 全相同 且 无像素低于自身 OB }`；R/B 中心满足 ⇒ 可交换；**G 中心天然不满足 ⇒ 不可交换** | ✅ |

### 其它指标

| 指标 | 只做 BLC | **顺序0 BLC→DPC** | 顺序1 DPC→BLC |
|---|---|---|---|
| 改动像素 / TP / FP / FN | — | 87 / **54 / 33 / 6** | 88 / 55 / **33** / 5 |
| PSNR vs 光强真值 | 27.40 dB | **35.25 dB** | 34.87 dB |
| MAE vs 光强真值 | 3.87 | **1.09** | 1.25 |
| 黑电平残差（近黑像素，输出−真值） | **0.00（恒 0）** | **0.00** | **0.00** |
| 两顺序位级差异 | — | — | **25/11536 = 0.22%**（max 190，平均 95.4） |

> 两顺序的 **FP 完全相同（33）** —— "正常像素"上的判定不受顺序影响；TP/FN 各差 1 个，来自 G 通道。

## 复现命令

```powershell
python make_blc_dpc_data.py                 # small 两套 golden
python make_blc_dpc_data.py --img           # 真图两套 + 真值 + 位置清单
# 注意 -I 要含 BLC（blc_core.v）与 Bayer_DPC_Demosaic（dpc_stage.v）+ 行缓存/FIFO
$inc = "-I . -I ..\BLC -I ..\Bayer_DPC_Demosaic -I ..\line_buffer\line_buffer_fifo_nxn -I ..\fifo"
iverilog -o tb_o0.vvp -DNOVCD         $inc.Split(' ') tb_blc_dpc.v
iverilog -o tb_o1.vvp -DNOVCD -DSWAP  $inc.Split(' ') tb_blc_dpc.v
iverilog -o tb_i0.vvp -DNOVCD -DIMG         $inc.Split(' ') tb_blc_dpc.v
iverilog -o tb_i1.vvp -DNOVCD -DIMG -DSWAP  $inc.Split(' ') tb_blc_dpc.v
python ..\CCM\_run_wd.py vvp tb_o0.vvp; python ..\CCM\_run_wd.py vvp tb_o1.vvp
python ..\CCM\_run_wd.py vvp tb_i0.vvp; python ..\CCM\_run_wd.py vvp tb_i1.vvp
python verify_blc_dpc.py                    # 出 blc_dpc_compare.png + 预测校验 + TP/FP/FN
```

## 踩坑

**坑 1 · 指标定义错了会得出"假结论"**：第一版"黑电平残差"直接用"近黑像素的输出均值"，
结果读到 **74.5**（像是没清掉黑电平）。根因是"近黑样本"按**真值**筛，却把**被我人为写成 1023 的缺陷像素**、
以及**本来就低于黑电平的下溢像素**也算进来了。修法：样本必须**同时排除缺陷与下溢像素**，
并且指标要定义成"**输出 − 真值**"（残差），而不是"输出均值"——修正后恒 **0.00**，才是"黑电平被彻底清掉"的正确证据。

**坑 2 · 理论预测不该当 pass/fail 判据**：预测被证伪时脚本退出码为 1，容易误读成"实验失败"。
其实独立复算与 TB 都是 0 误差 —— **预测被证伪是研究结论，不是错误**。
修法：`ok` 只由独立复算门控，预测部分作为分析文本输出。

**坑 3 · 跨模块串联的 `-I` 链**（同 `Denoise_CCM_Gamma` 坑 1，但这次多一个坑）：
顶层同时例化 **两个不同目录**的模块 —— `blc_core.v` 在 `BLC/`、`dpc_stage.v` 在 `Bayer_DPC_Demosaic/`，
`-I` 少一个就报 `Include file xxx not found`；而 `$readmemh` 仍走**运行目录**（本实验无 `$readmemh`，故不受影响）。
