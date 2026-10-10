# Denoise_CCM_Gamma —— M5.2 RGB 三段链（降噪 → CCM → Gamma）+ ★ 顺序可交换性实验

> **定位**：M5.2 交付物。把 M4 的三个模块按链路顺序串成一级工程件（30bit 线性 RGB 进 → RGB888 出），
> 并用**唯一一个参数**（`SWAP_DC`）切换"降噪 / CCM 谁在前"，做成一个可复现的对照实验
> —— 为"8 级 ISP 链路为什么这么排"提供量化论证，而不是靠想当然。
> 详细设计推导（为什么不可交换、为什么这个顺序更好、定点与延迟账）见
> [Denoise_CCM_Gamma实现计划.md](Denoise_CCM_Gamma实现计划.md)；
> 面试叙事版见 [../面试故事集.md](../面试故事集.md) 故事 3。

---

## 一句话结论（可背）

> 降噪与 CCM **不可交换**（98.2% 的像素位级不同），且 **降噪放在 CCM 之前明显更好**：
> 与"无噪声理想图"比，顺序0（降噪→CCM）**28.67 dB / SSIM 0.9323**，
> 顺序1（CCM→降噪）**27.16 dB / SSIM 0.9147**，差 **1.51 dB**。
> 原因：CCM 是含负系数、对角 >1 的矩阵，会把三通道噪声**混合并放大**（噪声直喂 CCM 时
> 饱和到量程边界的样本从 75 涨到 381，**5.1 倍**）；先降噪 = 在噪声还是"通道独立、未被放大"的
> 形态时就压掉，而且双边滤波的值域权重是按 `|ΔR|+|ΔG|+|ΔB|` 判相似度的，噪声一旦被矩阵
> 染成**通道相关的色噪声**，反而容易被当成"边缘"保护起来。

**色噪声残留（色差 (R−G) 水平梯度 RMS，越低越好）**：理想 **17.26** · 顺序0 **17.81** · 顺序1 **26.32**
⇒ 顺序0 几乎达到无噪声理想水平，顺序1 残留比理想高 **52%**。这条比 PSNR 更直观。

---

## 文件清单

| 文件 | 作用 |
|---|---|
| `rgb_chain_top.v` | **三段链顶层**：降噪 → CCM → Gamma，`SWAP_DC` 参数切换后两级顺序 |
| `tb_rgb_chain.v` | 自检 TB：两种顺序各编译一次（`-DSWAP`），协议三场景位级比对 |
| `make_chain_data.py` | 数据生成：small（协议）/ img（真图）；**两种顺序各一套 golden** + 理想图 + 不降噪基线 |
| `verify_chain.py` | 独立第二判据 + **顺序实验**（位级 / PSNR·SSIM / 噪声传播指标 / 四宫格图） |
| `chain_order_compare.png` | 四宫格：无噪声理想 · 不降噪基线 · 顺序0 · 顺序1（每格标 PSNR） |
| `range_lut.coe` `inv_rom.coe` `ccm_coef.coe` `gamma_lut.coe` | ★ **从各模块复制**（`$readmemh` 按运行目录相对寻址）。真源仍是各模块目录，重新生成后需再复制一次 |
| 生成物 `.hex` | `chain_in_small/img.hex`（30bit 入）· `exp_order0/1_{small,img}.hex`（24bit 出）· `ideal_img.hex` · `base_img.hex` |

## 接口

```verilog
module rgb_chain_top #(
    parameter DW = 10, IMG_W = 640, IMG_H = 480, N = 3,
    parameter FRAC = 12, OW = 8,
    parameter SWAP_DC = 0        // 0 = 降噪→CCM（本工程）; 1 = CCM→降噪（对照）
)(
    input  wire clk, rst_n,
    input  wire bp_denoise, bp_ccm, bp_gamma,     // bypass（语义见下）
    input  wire in_valid, output wire in_ready,
    input  wire [29:0] in_data, input wire in_sof, in_eol,      // 线性 RGB 3×10bit
    output wire out_valid, input wire out_ready,
    output wire [23:0] out_data, output wire out_sof, out_eol   // RGB888
);
```

- **打包顺序**：30bit = `{R[29:20], G[19:10], B[9:0]}`；24bit = `R[23:16] G[15:8] B[7:0]`
- **bypass 语义不统一（别混用）**：`bp_denoise` 含行缓存 ⇒ **帧级**（只能排空点切换）；
  `bp_ccm` / `bp_gamma` 是等延迟旁路 ⇒ **可任意拍**切换
- **总延迟与顺序无关**：`7+2+1 = 2+7+1 = 10` 拍（加法交换律）⇒ 两种顺序的流可以直接逐拍对齐比较，
  这也是本实验能"只改一个参数、其余全同"的前提

## 验证结果（全部 [PASS]）

| 项 | 结果 |
|---|---|
| 协议 TB · 顺序0（降噪→CCM） | **[PASS]** 1152/1152，位级 0 误差 + 反压稳定性零违例 |
| 协议 TB · 顺序1（CCM→降噪） | **[PASS]** 1152/1152，同上 |
| 真图 TB · 顺序0 / 顺序1 | **[PASS]** 各 11536/11536，位级 0 误差 |
| 收发计数 | 两顺序**完全相同**（1152/1152、11536/11536）⇒ 总延迟与顺序无关（实测佐证） |
| 独立第二判据 | `verify_chain.py` 自己重算 golden，与 RTL 落盘**逐位 0 误差**（两顺序都是 11536/11536） |

### ★ 顺序实验（`verify_chain.py`）

| 证据 | 顺序0 降噪→CCM | 顺序1 CCM→降噪 | 说明 |
|---|---|---|---|
| 位级差异 | — | 98.2% 像素不同（max 67，MAD 2.88） | **不可交换**（非线性 ∘ 线性） |
| PSNR vs 无噪声理想 | **28.67 dB** | 27.16 dB | 顺序0 高 **1.51 dB** |
| SSIM vs 无噪声理想 | **0.9323** | 0.9147 | 同上 |
| 色差 (R−G) 梯度 RMS | **17.81**（理想 17.26） | 26.32（比理想高 52%） | 色噪声残留 |
| CCM 饱和样本数 | 75 | **381（5.1×）** | 噪声被矩阵推出量程 |
| （参考）不降噪基线 | 23.11 dB / SSIM 0.7918 / 色差 RMS 48.44 | — | 量化"降噪一共带来多少改善"（+5.56 dB） |

> ⚠️ **别把这里的 PSNR 和 M4 的 32.03 dB 直接比**：那个是降噪输出在**线性 10bit 域**（峰值 1023）
> 对 `clean_rgb`，这里是**三段链输出在 RGB888 域**（峰值 255）对无噪声理想图——域和参考都不同。

## 复现命令

```powershell
# 1) 造数据（small 两套顺序 golden + img 真图两套 + 理想/基线图）
python make_chain_data.py
python make_chain_data.py --img
# 2) 4 个 .coe（$readmemh 相对运行目录；首次或系数重生成后需复制）
Copy-Item ..\BilateralFilter\range_lut.coe, ..\BilateralFilter\inv_rom.coe, ..\CCM\ccm_coef.coe, ..\Gamma\gamma_lut.coe . -Force
# 3) 协议 TB：两种顺序各编译一次
iverilog -o tb_o0.vvp -DNOVCD         -I . -I ..\BilateralFilter -I ..\CCM -I ..\Gamma -I ..\line_buffer\line_buffer_fifo_nxn -I ..\fifo tb_rgb_chain.v
iverilog -o tb_o1.vvp -DNOVCD -DSWAP  -I . -I ..\BilateralFilter -I ..\CCM -I ..\Gamma -I ..\line_buffer\line_buffer_fifo_nxn -I ..\fifo tb_rgb_chain.v
python ..\CCM\_run_wd.py vvp tb_o0.vvp      # [PASS] SWAP_DC=0
python ..\CCM\_run_wd.py vvp tb_o1.vvp      # [PASS] SWAP_DC=1
# 4) 真图 TB（同上加 -DIMG）+ 顺序实验
iverilog -o tb_i0.vvp -DNOVCD -DIMG         -I . -I ..\BilateralFilter -I ..\CCM -I ..\Gamma -I ..\line_buffer\line_buffer_fifo_nxn -I ..\fifo tb_rgb_chain.v
iverilog -o tb_i1.vvp -DNOVCD -DIMG -DSWAP  -I . -I ..\BilateralFilter -I ..\CCM -I ..\Gamma -I ..\line_buffer\line_buffer_fifo_nxn -I ..\fifo tb_rgb_chain.v
python ..\CCM\_run_wd.py vvp tb_i0.vvp
python ..\CCM\_run_wd.py vvp tb_i1.vvp
python verify_chain.py                      # 出 chain_order_compare.png + 顺序结论
```

## 与后续实验的关系

本套"一个参数切顺序 + 与理想图比 PSNR/SSIM"的方法可以**原样复用**到其他两级顺序之争
（如 BLC 与 DPC 的先后）：只要两级的主路延迟不同但**总延迟可交换**、
且能造出"无该缺陷的理想图"作参考，就能给出量化结论而不是空谈。
