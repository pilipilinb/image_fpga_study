# bilinear_v3 · 双线性插值图像缩放（Verilog 手写实现）

> 学习项目 W3 产物：RGB888 输入 → **任意整数倍放大**（2/3/4…倍）→ RGB888 输出
> 纯 RTL 推断实现（不依赖任何 FPGA IP），iverilog 仿真验证，2 倍 / 3 倍均全像素比对通过

`Verilog` `双线性插值` `整数倍缩放` `纯 RTL 推断` `8 级流水` `PSNR 58.9dB` `自校验 TB` `iverilog`

---

## 目录

- [项目简介](#项目简介)
- [目录结构](#目录结构)
- [模块设计](#模块设计)
  - [数据流](#数据流)
  - [模块职责](#模块职责)
- [文件清单](#文件清单)
- [验证结果](#验证结果)
- [快速开始](#快速开始)
- [已知限制与后续](#已知限制与后续)

---

## 项目简介

把一张 RGB888 图像按**整数倍放大**（`OUT = IN × SCALE`，SCALE 可参数化），双线性插值，输出放大后的 RGB888 图像，并配套完整的验证闭环：

- **坐标生成**：定点累加器产生每个输出像素对应的源坐标 (sx,sy) 与插值权重 (u,v)，无运行期除法
- **插值计算**：2×2 邻域 4 像素按权重加权（8 级流水），定点舍入 + 饱和
- **验证闭环**：真实图片 → COE → 仿真 → 输出 COE → PSNR 校验 + 显示对比

**范围收敛（不做的事）**：缩小、非整数倍放大（如 ×2.56）留待后续版本。

---

## 目录结构

```
bilinear_v3/
├── bilinear_rgb_top.v              # 顶层：全链路组装（include 下面 3 个 RTL）
├── coord_gen.v                     # 定点累加坐标/权重生成器（含帧内防御）
├── bilinear_interp_8b.v            # 8bit 单通道插值核（LAT=8 流水）
├── image_rom.v                     # 推断式 BRAM ROM（$readmemh 初始化）
├── tb_bilinear_rgb.v               # 顶层全链路自检 TB（-DSMALL 小图 / -DSCALE3 三倍）
├── tb_coord_gen_defense.v          # coord_gen 帧内防御专项 TB
├── tb_bilinear_interp.v            # 插值核边界/随机/valid 链 TB
├── img_to_coe.py                   # 图像(jpg/png) → COE（替代 MATLAB 脚本）
├── make_tb_input.py                # COE → hex 桥接 + --synthetic 合成图
├── verify_scale.py                 # PSNR 校验 + 对比图渲染（log 输出）
├── matlab_img_coe_output.m         # MATLAB 版图像→COE（等价脚本，未用）
├── feibi.jpg                       # 测试原图（950×1092）
├── input.coe                       # 输入图 COE（112×103，权威像素格式）
├── input.hex                       # 仿真输入（$readmemh 格式，进 image_rom）
├── input_4x3.hex                   # 合成小图 4×3（接线验证用）
├── output.coe                      # 仿真输出（当前 2 倍 224×206）
├── resized_preview.jpg             # feibi resize 预览图
├── verify_scale_compare.png        # 2 倍放大对比图（左原图 | 右放大）
├── verify_scale_compare_s3.png     # 3 倍放大对比图
├── verify_scale.log                # 2 倍 PSNR 校验日志
├── verify_scale_scale3.log         # 3 倍 PSNR 校验日志
├── bilinear_rgb_top_datapath.html  # 顶层数据流图（浏览器打开）
├── 双线性插值缩放实现计划.md        # 实现计划（架构/步骤/风险）
└── README.md                       # 本文档
```

---

## 模块设计

### 数据流

```
 start/pixel_en
   │
   ▼
 coord_gen ── sx,sy ──────────────► 地址计算+钳位 ── addr00/10/01/11 ──► 4×image_rom
   (T拍)     ── u_frac,v_frac,valid0 ─┐                              (T+1拍输出 dout×4)
                                      ▼                                   │
                             对齐寄存+权重清零 ── u_core,v_core,valid_d1 ──┼─► 3×bilinear_interp_8b
  done ────────────────────────────────────────────────────────────────►│  (LAT=8, T+9拍)
                                                                         ▼
                                                          o_r / o_g / o_b + o_valid / o_done
```

时序：T 拍生成坐标 → T+1 拍 ROM 读出 4 邻居 → T+2..T+9 核流水 → T+9 拍输出像素。

完整数据流图见 **[bilinear_rgb_top_datapath.html](bilinear_rgb_top_datapath.html)**（浏览器打开）。

### 模块职责

#### coord_gen.v —— 定点累加坐标生成器

- 输入每个输出像素的推进信号 `pixel_en`，输出源坐标 `sx/sy` 和权重 `u_frac/v_frac`
- 核心：`STEP = (IN<<FB)/OUT` 编译期算好，每拍累加（加法免乘除），`整数部分=源坐标，小数部分=权重`
- 帧内防御：`frame_active` 标志，帧末后即使误拉 pixel_en 也不越界、valid_out 拉低

#### bilinear_interp_8b.v —— 8bit 单通道插值核

- 对 2×2 邻域 4 像素做加权：`out = p00(1-u)(1-v) + p01·u(1-v) + p10(1-u)v + p11·u·v`
- 8 级流水（LAT=8），像素路径 3 级旁路与权重路径对齐汇合
- 定点：u/v 8 位、1-u/1-v 9 位、权重 18 位、乘积 26 位、四项和 27 位、右移 16 + 舍入 + 饱和 255（9 位防回绕）
- 纯数据通路，无帧概念（帧边界由上游 coord_gen 负责）

#### image_rom.v —— 推断式 BRAM 只读 ROM

- 存输入图像（24bit/像素，`$readmemh` 从 input.hex 初始化），按地址同步读出（1 拍潜伏）
- 守 BRAM 铁律：存储阵列不可复位、读输出寄存器同步复位

#### bilinear_rgb_top.v —— 顶层

- 组装全链路：coord_gen + 邻居地址钳位 + 4 份 image_rom 并联 + 3 个插值核（R/G/B 各一）
- 边界处理：sx/sy 越界钳位 + 被钳位方向权重清零（退化为复制）
- 参数：`IN_WIDTH/IN_HEIGHT/SCALE/FRAC_BITS/INIT_FILE`（头部 include 上述 3 个模块）

---

## 文件清单

### RTL 源码（4 个）

| 文件 | 功能 |
|---|---|
| `coord_gen.v` | 定点累加坐标/权重生成器（含帧内防御） |
| `bilinear_interp_8b.v` | 8bit 单通道双线性插值核（8 级流水） |
| `image_rom.v` | 推断式 BRAM ROM，存输入图像 |
| `bilinear_rgb_top.v` | 顶层，组装全链路（头部 include 上述 3 个模块） |

### Testbench（3 个，各自验证不同功能）

| 文件 | 验证对象 | 验证内容 |
|---|---|---|
| `tb_coord_gen_defense.v` | coord_gen | 全帧坐标/权重逐拍比对；**帧末防御**（done 后误拉使能不越界）；start 重启 |
| `tb_bilinear_interp.v` | 插值核 | 边界用例（u/v 四角、纯色、舍入、饱和）；随机 2000 拍；**valid 链**（插气泡，无假/漏有效） |
| `tb_bilinear_rgb.v` | 顶层全链路 | 全帧逐像素比对 RGB 三通道；输出写 `output.coe`。编译选项：`-DSMALL` 跑 4×3 合成小图，`-DSCALE3` 跑 3 倍放大 |

### Python 脚本（验证链）

| 文件 | 功能 |
|---|---|
| `img_to_coe.py` | 图像(jpg/png/bmp) → COE 文件（替代 MATLAB 脚本，支持 `--resize` + 预览图） |
| `make_tb_input.py` | COE → `$readmemh` 兼容的 hex（去 header/逗号 + 尺寸校验）；`--synthetic` 生成合成梯度图 |
| `verify_scale.py` | 读 input.hex + output.coe → **PSNR 校验**（独立浮点参考，与 RTL 同坐标系）+ 对比图渲染（log 存 `--log` 指定文件） |
| `matlab_img_coe_output.m` | MATLAB 版图像→COE 脚本（无 MATLAB 环境时用 img_to_coe.py 替代） |

### 输入/输出数据文件

| 文件 | 含义 |
|---|---|
| `feibi.jpg` | 测试原图（950×1092，近灰度） |
| `input.coe` | feibi 缩放为 112×103 后的 COE（**权威像素格式**：两行 header + 每行 `RRGGBB,`） |
| `input.hex` | input.coe 转出的仿真输入（`$readmemh` 格式，进 image_rom 的就是它） |
| `input_4x3.hex` | 合成小图 4×3（RGB 三通道不同分量，用于 Step 8 接线验证） |
| `output.coe` | 仿真输出（当前为 2 倍 224×206 结果，TB 直接写出） |
| `resized_preview.jpg` | feibi resize 到 112×103 的预览图 |
| `verify_scale_compare.png` / `_s3.png` | 2 倍 / 3 倍放大对比图（左=原图，右=放大） |
| `verify_scale.log` / `verify_scale_scale3.log` | 2 倍 / 3 倍 PSNR 校验日志 |

### 文档

| 文件 | 含义 |
|---|---|
| `双线性插值缩放实现计划.md` | 实现计划（架构决策、步骤、风险、验证链设计） |
| `bilinear_rgb_top_datapath.html` | 顶层数据流图（SVG 内嵌 + 模块职责表 + 时序说明） |

---

## 验证结果（已跑通）

| 场景 | TB 自检 | PSNR（独立浮点参考） |
|---|---|---|
| 合成小图 4×3 → 8×6 | ✅ 48 像素全对 | — |
| 真图 2 倍 112×103 → 224×206 | ✅ 46144 像素全对 | **58.86 dB**，最大误差 0 LSB |
| 真图 3 倍 112×103 → 336×309 | ✅ 103824 像素全对 | **59.04 dB**，最大误差 0 LSB |

---

## 快速开始

```powershell
# 1. 图像 → COE（无 MATLAB，用 Python；--resize 与 RTL 参数匹配）
python img_to_coe.py --input feibi.jpg --output input.coe --resize 112x103

# 2. COE → hex（仿真输入）
python make_tb_input.py --coe input.coe --width 112 --height 103

# 3. 编译 + 仿真（iverilog，-I 指向本目录）
iverilog -I . -o tb.vvp tb_bilinear_rgb.v
vvp tb.vvp > sim_top.txt          # 2 倍；加 -DSCALE3 编 3 倍，-DSMALL 跑合成小图

# 4. PSNR 校验 + 对比图（log 存当前目录）
python verify_scale.py --in-hex input.hex --out-coe output.coe --in-w 112 --in-h 103 --scale 2 --log verify_scale.log

# 5. 波形查看
gtkwave tb_bilinear_rgb.vcd
```

---

## 已知限制与后续

- **只支持整数倍放大**：缩小、非整数倍留待 bilinear_v4+
- **ROM 随输入尺寸线性膨胀**：4 份 image_rom 并联（学习小图可接受），大图需行缓存方案（W4）
- 行缓存复用在 W4 卷积（`line_buffer_nxn`），本工程刻意不用（见计划文档修订记录）