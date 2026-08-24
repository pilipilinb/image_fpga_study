# Sobel 边缘检测（RGB888 输入，复用 CSC 灰度化 + 零乘法器核 + AMBM 幅值）

RGB888 流式 Sobel 边缘检测：CSC（复用 3stage 工程，取 Y 通道灰度化）→ 行缓存（pad 版）
→ 3×3 窗口 → Gx/Gy 差分 → AMBM 幅值估算 → 双输出（幅值图 + 阈值二值化边缘图）。
全程 0 乘法器（Sobel 核），灰度链路直接复用工程已有的 rgb_to_ycbcr_3stage。

## 模块与接口

| 文件 | 说明 |
|------|------|
| `rgb_to_ycbcr_3stage.v` | 复用 CSC 3stage 工程（BT.601，Y = 0.183R+0.614G+0.062B+16，系数×256 定点 47/157/16） |
| `line_buffer_3x3_pad.v` | 复用 pad 版行缓存（replicate padding，H×W 全尺寸窗口），详见 line_buffer/pad_verison/ |
| `sobel_3x3_8b.v` | Sobel 核：LAT=3 流水（差分 → 幅值 → 归一化/阈值） |
| `top_sobel.v` | 顶层：CSC + 行缓存 + 核，`din[23:0]/din_valid/thresh[7:0] → o_mag[7:0]/o_edge[7:0]/o_valid` |
| `tb_sobel.v` | 自检 TB（参考模型用 CSC 同系数灰度化 + 全等比对 + VCD） |
| `verify_sobel.py` | numpy 独立整数重算验证（含 CSC 同款 Y 系数）+ 对比图 `sobel_compare.png` |

数据流：

```
din[23:0]/din_valid ──► rgb_to_ycbcr_3stage（RGB→Y 灰度，4 拍流水）
                                │ o_y_8b / o_data_en
                                ▼
                          line_buffer_3x3_pad（BRAM 存 2 行 + 窗口移位，每像素一窗口）
                                │ w11..w33
                                ▼
                          sobel_3x3_8b（Gx/Gy → AMBM → >>2 饱和/阈值）
                                │
                          o_mag[7:0] / o_edge[7:0] + o_valid（H×W 个窗口）
```

全链路延迟 11 拍 = CSC 4 拍（含同步复位释放 2 拍） + 行缓存 4 拍 + 核 3 拍。

## 算法要点

**灰度化（为什么用 CSC 的 Y）**：亮度 Y 即灰度。CSC 3stage 是 BT.601 带 offset
公式（Y 范围约 16~235，含 +16 偏移）——Sobel 是差分卷积，梯度 = 灰度差值，
+16 偏移在差值中相互抵消，直接用 Y 做梯度无影响。Cb/Cr 悬空不用
（只取 Y 通道，避免重复造灰度模块）。

**Sobel 差分卷积**（与均值/高斯的平滑卷积相对：核系数和为 0，平坦区输出 0）：

- Gx = (p02 + 2·p12 + p22) − (p00 + 2·p10 + p20) —— 左右列加权差，出垂直边缘
- Gy = (p20 + 2·p21 + p22) − (p00 + 2·p01 + p02) —— 上下行加权差，出水平边缘

**零乘法器**：系数只有 0/±1/±2 → ×2 用 `<<1`，整个核只有加减和移位，0 DSP。

**Alpha-Max-Beta-Min（α=1，β=0.5）**：`mag = max(|Gx|,|Gy|) + (min(|Gx|,|Gy|) >> 1)`
——用 1 个比较器 + 移位替代开方器：

| r = min/max | 精确幅值 | AMBM | 误差 |
|-------------|---------|------|------|
| 0（水平/垂直边） | M | M | 0% |
| 1（45° 对角） | 1.414·M | 1.5·M | +6.07% |
| 最差点（≈0.57） | — | — | ≈ +6.5% |

只偏大不偏小，阈值粗筛场景可接受；若追求精确可换 IP 或 CORDIC。

**位宽链**：像素 8bit → 单侧和 11bit → Gx/Gy 11bit signed（±1020）→ abs 11bit → mag 12bit（≤1530）→ >>2 后 9bit（≤382）→ 饱和 8bit。

## 验证结果

| 项目 | 结果 |
|------|------|
| 真实图 112×103 ×2 帧（thresh=64/48） | [PASS]，23072 窗口全等 0 错误 |
| 小图 4×3 冒烟（四边 replicate） | [PASS]，24 窗口全等 |
| numpy 独立整数重算 vs RTL | 全等 0 错误，PSNR ∞ |
| 纯色帧零梯度 | mag=edge=0 恒成立 |

测试输入为 RGB888 真实图（与 CSC/滤波工程同一张图），TB 参考模型与 DUT 内置 CSC
同系数同源（47/157/16 + 4096，右移 8 位 + 四舍五入），逐位全等比对。

## 运行

```powershell
cd d:\FPGA_proj\image_fpga_test\sobel
iverilog -o tb_sobel.vvp tb_sobel.v
vvp tb_sobel.vvp > sim_log.txt          # [PASS]
python verify_sobel.py                  # 独立重算比对 + 对比图
iverilog -DSMALL -o tb_sobel_small.vvp tb_sobel.v
vvp tb_sobel_small.vvp >> sim_log.txt   # 小图冒烟
```

注意（pad 版行缓存特性）：输入流必须带 blanking——行末 din_valid 拉低 ≥1 拍、
帧末拉低 ≥ IMG_W+8 拍，否则 rflush/bflush 插不进去，右边/下边 padding 失败。
注意（CSC 复用特性）：rgb_to_ycbcr_3stage 是异步复位同步释放，上电后要先等
复位同步释放（至少 2 拍）再喂数据，否则第一拍像素被丢弃导致整帧错位
（TB 里 repeat(16) 等待，此为实测踩坑）。

## 面试讲点

1. **为什么 RGB 输入先 CSC 再 Sobel**：Sobel 是差分卷积，输入必须是灰度（单通道），否则梯度是张量没法二值化；直接用工程已有的 CSC 取 Y 通道，一条链路完成"RGB → 灰度 → 边缘"，模块复用是加分项（不带 offset 的 Y 也行，+16 偏移在差分里抵消）
2. **为什么 AMBM 而不用 sqrt**：FPGA 开方要 IP 或迭代器，AMBM 一个比较器 + 移位搞定，误差 ≤6.5% 且只偏大，阈值筛选不受影响
3. **为什么零乘法器**：Sobel 核系数 0/±1/±2，×2 左移 1 位，9 个乘变成 0 个，纯 LUT 实现（对比高斯核对称性用 pre-adder 减到 4 个乘法器，Sobel 更极端）
4. **Sobel vs Canny**：Sobel 一阶差分 + 阈值，快、简单、对噪声敏感；Canny = 高斯平滑 + Sobel + 非极大值抑制 + 双阈值滞后连接，慢但边缘细且连续。工程里预处理足够时 Sobel 够用
5. **为什么行缓存用 pad 版**：全尺寸输出（H×W 每像素一窗口）可直接叠加原图显示边缘，代价是输入需要 blanking 空拍做右/下边 padding——视频流天然有 h-blank/v-blank，白送
6. **边缘 = 灰度变化率**：Sobel 是差分算子，系数和 0 → 平坦区输出 0，灰度突变处非 0（对比均值滤波系数和 1，平坦区不变）