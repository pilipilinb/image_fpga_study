# DPC 坏点校正实现计划（DPC，包络检测法）

## 背景与目标

按用户给定伪代码实现坏点校正（Defect Pixel Correction）：

```
输入：邻域 N（同色邻居，不含中心）、中心 P、阈值 thr；输出 P'
function replace(P, N, thr):
    mn = min(N); mx = max(N)
    if   P > mx + thr:  P' = mx    # 亮点 → 抄最亮的邻居
    elif P < mn - thr:  P' = mn    # 死点 → 抄最暗的邻居
    else:               P' = P     # 正常 → 原样通过
```

**关键决策（用户已确认）**：
1. **输入 = Bayer RAW（8bit 单通道）**——DPC 接在 Demosaic 之前（ISP 标准顺序）；"同色邻居"需按中心相位筛选
2. **G 通道合并**（Gr+Gb 都算绿）；阈值参数化 **THR 默认 32**

## 同色邻居集合（5×5 窗口，W[i][j]，中心 W22）

窗口内相对位置 (i,j) 的绝对相位 = 中心相位 ⊕ (i%2, j%2)（偏移 2 是偶数，不改变奇偶）→ 由此推出：

| 中心相位 | 同色条件 | 5×5 内同色位置（除中心） | 邻居个数 |
|---|---|---|---|
| **R** | 绝对 (偶,偶) | W00,W02,W04,W20,W24,W40,W42,W44（相对 i,j 都偶） | **8** |
| **B** | 绝对 (奇,奇) | 同上（相对 i,j 都偶） | **8** |
| **Gr / Gb**（合并） | 绝对 G（异奇偶） | 上面 8 个 + W11,W13,W31,W33（相对 i,j 同奇偶） | **12** |

注 1：推导要用「绝对相位 = 中心相位 XOR (i%2,j%2)」——判断同色 ⇔ 相对位置 (i,j) 都偶（R/B）或同奇偶（G）。
注 2（实施期修正，重要）：初稿把"相对奇奇"误当"绝对奇奇"，写成「B 相位 4 个对角、G 相位取 12 个异奇偶位置」——**RTL 与 TB 参考同时写错，TB 自检反而 PASS**，最后靠"Python 参考用绝对坐标独立实现"的交叉校验抓出（RTL/参考差 476 像素）。双参考的价值就在这里。
注 3：R/B 相位邻居集合相同（都是 8 个）→ 硬件上 even8 一组极值即可共用。

## 实现要点

- **窗口**：复用 `line_buffer_nxn.v`（N=5）；相位延迟 **PH_D=5**（Demosaic 工程已实测锁定：adly 链 4 拍 + matrix_valid 寄存 1 拍）
- **min/max 树**：三组并行算（R 组 **8** 点、角组 **4** 点、G 组 **12** 点），再按相位选一组输出——比"case 内串行比较链"组合深度浅、代码更清晰；组内 min/max 初值取该组第一个元素
- **阈值比较用加法避开负数**（关键）：
  ```
  亮点：P > mx + thr        （P+... 最大 510 → 9bit 比较）
  死点：P + thr < mn        （等价 P < mn − thr，但不需要有符号运算）
  ```
  这样只做无符号比较（同工程 CSC"正负分开"的思路）
- **替换**：亮点→mx、死点→mn、正常→P（一条 mux）
- **输出**：Bayer 进 Bayer 出、8bit 单通道，尺寸 crop 2 圈 (W-4)×(H-4)（与 Demosaic 一致）
- 流水：组合 min/max + 比较 + 1 级寄存输出（LAT=1）；若上板时序紧可把 min/max 树拆两级（面试点）

## 文件清单（全部在 DPC/）

```
DPC坏点校正实现计划.md   ★ 本计划（存入目录）
line_buffer_nxn.v        ⬅ 复用（N=5 窗口模板，源目录权威）
dpc_envelope.v           ★ 包络检测核（三组 min/max + 相位选择 + 双阈值替换）
top_dpc.v                ★ 顶层（窗口 + 相位计数/对齐 PH_D=5 + 核；Bayer 进 Bayer 出）
tb_dpc.v                 ★ 自检 TB（独立参考模型 + 均匀图坏点解析解 + 注入坏点 + 气泡 + VCD/超时）
tb_nxn_n5.v              ⬅ 复制（N=5 回归 + 延迟实测，已验证）
make_dpc_data.py         ★ 从 Bayer 生成"带坏点"输入 + Python 参考 + 对比图
verify_dpc.py            ★ 独立校验（全等）+ 坏点修复统计
bayer.hex / bayer_defect.hex / ref_dpc.hex / output.coe / *.png / sim_log.txt
README.md                ★ 原理 + 同色邻居表 + 双阈值技巧 + 验证数据 + 面试要点
```

顶层接口：`din[7:0]/din_valid → o_dout[7:0]/o_valid`；参数 IMG_W/IMG_H/THR/PH_D。

## 验证计划

| 用例 | 输入 | 验收 |
|---|---|---|
| 步骤 0：N=5 模板回归 | tb_nxn_n5.v | PASS（复制自 Demosaic，已验证，跑一次确认） |
| **解析解**：均匀图 + 单点坏点 | TB 内构造（全 0x80 + 中心附近置 255/0） | 亮点/死点所在像素被替换为 0x80；其余不变 |
| **干净图基线（审查补强）**：真 Bayer 过 DPC | bayer.hex | 统计**被改像素数与占比（误伤率）**——包络法最该量化的指标，THR=32 实测值写入 README |
| **注入坏点**：真 Bayer + 随机坏点 | bayer_defect.hex（**固定 seed，可复现**） | TB 全等 + **修复率统计**（注入点被替换的比例） |
| TB 参考模型全等 | 真图 2 帧 | 0 误差（10692 窗口） |
| 独立校验（RTL vs Python） | output.coe vs ref_dpc.hex | 逐像素全等 0 误差 |
| **效果量化** | 坏点图/DPC 输出 vs 干净 Bayer | DPC 前 vs 后 PSNR（应显著提升）+ **误伤率**（干净图上被误改的像素比例，用 THR=32 实测） |

命令（DPC/）：
```powershell
python make_dpc_data.py            # 注入坏点（固定 seed）+ Python 参考 + 对比图
iverilog -I . -o tb.vvp tb_dpc.v; vvp tb.vvp > sim_log.txt
python verify_dpc.py               # 全等校验 + 修复率/误伤率统计
```

**与 Demosaic 的衔接（尺寸链，审查补强）**：
```
输入 Bayer 112×103 → DPC（crop 2 圈）108×99 → Demosaic（再 crop 2 圈）104×95
```
两站各裁 2 圈（都是 5×5 窗口），串联后累计 4 圈——后续若要全尺寸链，需把两站都换 pad 版（记入 README 已知限制）。

**副本维护约定（审查补强）**：line_buffer_nxn.v 在 DPC/ 又是副本（权威版在 line_buffer/line_buffer_nxn/，另有 Demosaic/ 副本）——只改源目录再同步副本；tb_nxn_n5.v 同样处理（复制后跑一次确认）。

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| 同色邻居选错（相位/相对位置） | 用"相位 ⊕ 相对奇偶"推导表 + TB 解析解（均匀图单坏点）逐点验证 |
| **强边缘被误判为坏点**（包络法固有缺陷） | 阈值 THR 参数化；verify 统计误伤率并写入 README（面试点：工程上会加多方向判定/双阈值/仅在孤立极值时替换） |
| 邻居里还有坏点 → 包络被拉宽漏检 | 记录为已知局限（多坏点相邻场景）；后续可做"次大/次小包络"改进 |
| 相位对齐 | PH_D=5 复用 Demosaic 实测值；TB 全等立刻暴露错位 |
| min/max 树组合深度 | 三组并行 + 说明"上板可拆两级流水" |

## 实施步骤（含依赖）

1. 计划入 DPC/ + 复制 line_buffer_nxn.v、tb_nxn_n5.v、bayer.hex（源：Demosaic/）
2. dpc_envelope.v（三组 min/max + 相位选择 + 双阈值 + 替换）
3. top_dpc.v（窗口 + 相位计数/对齐 + 核）
4. tb_dpc.v（参考模型 + 均匀图坏点解析解 + 注入坏点用例）
5. make_dpc_data.py（注入坏点 + Python 参考 + 三格对比图：干净 | 带坏点 | DPC 后）
6. 跑通 + verify_dpc.py（全等 + 修复率/误伤率 + PSNR 提升）
7. README + 根 README/AGENTS 同步（新增 DPC 子系统，说明与 Demosaic 的衔接顺序）

## 被否决的替代方案

1. **RGB888 输入（全 24 邻居）**：用户确认 Bayer RAW；且"同色邻居"本身暗示 Bayer
2. **Gr/Gb 严格分开**：用户确认合并（同为绿通道响应一致）；严格版可后续加参数
3. **pad 全尺寸输出**：与 Demosaic 保持一致用 crop 2 圈（链路累计裁剪可接受）；全尺寸需求后续做 pad 版
4. **多方向/多级检测（更鲁棒的 DPC）**：本轮严格按用户伪代码单级包络；改进方向写入 README 已知局限