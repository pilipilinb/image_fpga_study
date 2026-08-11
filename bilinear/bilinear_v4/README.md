# bilinear_v4 · 行缓存版双线性缩放（大图/实时视频升级版）

> 学习项目 W3 延伸：用 **3 行环形行缓存** 替代 v3 的 4 份整图 ROM，支持**流式像素输入**（din/din_valid），存储恒定、可上大图/实时视频流
> 复用 v3 的 coord_gen / bilinear_interp_8b / 验证链（零改动），缩放能力与 v3 一致（放大/缩小整数倍）
> 原理图解：**先看 [line_buffer_principle.html](line_buffer_principle.html)**（浏览器打开，讲透行缓存原理）

`Verilog` `行缓存` `流式输入` `反压` `整数倍缩放` `BRAM 恒定` `自校验 TB`

---

## 目录

- [与 v3 对比](#与-v3-对比)
- [架构与核心机制](#架构与核心机制)
  - [反压两条判定式](#反压两条判定式)
- [文件清单](#文件清单)
- [验证结果](#验证结果)
- [调试记录](#调试记录)
- [使用方法](#使用方法)
- [大图升级路径](#大图升级路径)

---

## 与 v3 对比

| 维度 | v3 整图 ROM | v4 行缓存 |
|---|---|---|
| 存储 | 整帧 × 4 份（随图像尺寸线性膨胀） | **3 行 × 行宽**（恒定，随行宽） |
| 输入方式 | 整帧就绪（$readmemh）再随机读 | **流式输入**（din/din_valid，边进边出） |
| 读侧 | 任意随机读，零等待 | 行未就绪要等（rd_ready 反压） |
| 写侧 | 无（只读） | 槽位冲突要等（wr_ready 反压） |
| 适用 | 小图学习、整帧可用 | 大图、实时视频流（1920×1080 可行） |

**1920×1080 存储对比**：v3 ≈ 5500 块 BRAM（爆）｜ v4 ≈ 3 块 BRAM（恒定）

---

## 架构与核心机制

```
din[23:0]/din_valid（流式输入） ──► line_cache2（3 行环形）
                                      │ 写侧：光栅顺序，槽位冲突检查反压
  coord_gen（pixel_en = rd_ready）──►│ 读侧：按源坐标 (sy,sx) 组合读 4 邻居
                                      ▼
                              钳位/权重清零 ──► 3×bilinear_interp_8b ──► o_rgb + o_valid
```

### 反压两条判定式（核心）

```verilog
// 写侧：槽位 w%3 的旧行(w-3)已被读侧滑过才允许覆盖（读侧停滞后仍能写完剩余行）
assign wr_ready = ((w < 3) || (sy00 > w - 3)) && (w < IN_HEIGHT);
// 读侧：窗口顶行 sy+1 已写完
assign rd_ready = (sy01 < w);
```

- 放大（写快读慢）：写侧追上读窗口后暂停，等读侧滑动释放槽位
- 缩小（写慢读快）：读侧等行写完，输出暂停
- 帧末排空：读侧完成后写侧仍能写完剩余行（旧行已被滑过）——不会死锁

---

## 文件清单

| 文件 | 说明 |
|---|---|
| `line_buffer_principle.html` | 行缓存原理图解（浏览器打开，理解本工程前提） |
| `行缓存版双线性缩放实现计划.md` | 实现计划（架构/反压规则/风险） |
| `coord_gen.v` | ⬅ 复用 v3（零改动） |
| `bilinear_interp_8b.v` | ⬅ 复用 v3（零改动） |
| `line_cache2.v` | ★ 3 行环形缓冲 + 行就绪/槽位冲突反压 |
| `bilinear_lb_top.v` | ★ 行缓存版顶层（include 上述 3 模块） |
| `tb_bilinear_lb.v` | ★ 流式输入自检 TB（随机气泡 + 行末延时） |
| `verify_scale.py` | ⬅ 复用 v3（零改动） |
| `make_tb_input.py` | ⬅ 复用 v3（零改动） |
| `img_to_coe.py` | ⬅ 复用 v3（零改动） |
| `input.hex` / `output.coe` | 仿真输入/输出（就地生成） |
| `sim_*.txt` / `verify_*.log` | 仿真与 PSNR 日志 |
| `compare_*.png` | 对比图（原图 \| 缩放后） |

---

## 验证结果（已跑通，含随机气泡反压压力）

| 场景 | 配置 | TB 自检 | PSNR（独立浮点参考） |
|---|---|---|---|
| 合成小图放大 2 倍 | 4×3 → 8×6 | ✅ 48 像素全对 | — |
| 真图放大 2 倍 | 112×103 → 224×206 | ✅ 46144 像素全对 | **58.86 dB**（与 v3 一致） |
| 真图缩小 1/2 | 112×103 → 56×51 | ✅ 2856 像素全对 | **59.41 dB**（与 v3 一致） |

TB 每行随机插入气泡 + 行末 0~3 拍延时，压力验证行就绪/槽位冲突反压逻辑。

---

## 调试记录（重要）

1. **帧末排空死锁（已修）**：初版 `wr_ready = (w <= sy01)` 在缩小场景读侧先完成、`sy` 停住时卡死写侧（输入未喂完）。改为**槽位冲突检查**（`w-3` 旧行是否被滑过）后，读侧停顿写侧仍能写完剩余行。
2. **输出 COE 竞态（已修）**：TB 写 COE 用记分板 `out_cnt` 判断，与计分板跨 always 竞态导致最后一个像素漏写。改为独立写计数 `w_cnt`。（v3 TB 存在同款隐患，建议同步修复。）

---

## 使用方法

```powershell
# 1. 输入数据（从 v3 复制或重新生成）
#    python img_to_coe.py --input feibi.jpg --output input.coe --resize 112x103
#    python make_tb_input.py --coe input.coe --width 112 --height 103

# 2. 编译 + 仿真（iverilog，-I 指向本目录）
iverilog -I . -o tb.vvp tb_bilinear_lb.v          # 默认放大 2 倍
vvp tb.vvp > sim_2x.txt
# -DDOWN2 缩小 1/2，-DSCALE3 放大 3 倍，-DSMALL 合成小图

# 3. PSNR 校验 + 对比图
python verify_scale.py --in-hex input.hex --out-coe output.coe --in-w 112 --in-h 103 --scale-n 2 --scale-d 1 --log verify_2x.log

# 4. 波形
gtkwave tb_bilinear_lb.vcd
```

---

## 大图升级路径

学习版用寄存器数组（分布式 RAM，组合读）；大图换 BRAM 时（注释已注明）：

- 每行 1W2R 需双块 BRAM 或分拍读（sx/sx+1 两列）
- BRAM 读变同步（1 拍潜伏），顶层需补对齐寄存（弥补 v3 已去的"对齐寄存 1 拍"）
- 行就绪/槽位冲突反压逻辑不变