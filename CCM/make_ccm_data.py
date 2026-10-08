#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_ccm_data.py —— M4-2 CCM：系数定点化 + 输入数据 + golden 期望（与 RTL 位级同构）

三种模式：
  python make_ccm_data.py             # small：协议 TB（16×12×5 帧，伪随机 RGB 10bit）
  python make_ccm_data.py --img       # img  ：真图（M3 链出图）→ CCM 前后对比
  python make_ccm_data.py --chart     # chart：合成 24 色卡（ΔE 量化用）

生成物（通用）：ccm_coef.coe（9 个 Q5.12 有符号系数，RTL $readmemh 加载）
生成物（small）：src_small.hex / exp_small.hex
生成物（img）  ：ccm_in.hex / exp_img.hex
生成物（chart）：chart_sensor.hex / chart_ideal.hex / chart_exp.hex

与 RTL 的位级同构约定（两边注释必须一致）：
  * acc[i] = Σ_k M_int[i][k] · v_k          （有符号；i=输出通道=行，k=输入通道=列）
  * rnd    = acc + 2^(FRAC-1)               （round-half-up，对负数同样成立）
  * out    = clamp(rnd >>> FRAC, 0, 1023)   （算术右移；★ 饱和不可省：减法出负、增益溢出）
  * 系数   = floor(M·2^FRAC + 0.5) 后再把"行和残差"补到对角项 ⇒ 行和精确 = 2^FRAC
            ⇒ 灰阶输入逐位严格保持（消 1/4096 的直流偏色）
"""
import math
import os
import sys

sys.path.append(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             '..', 'Bayer_DPC_Demosaic'))
from make_dpc_demosaic_data import (W_IMG, H_IMG, MAXV, OB, load_hex, phase_of,
                                    dpc_ref, demosaic_bilinear_ref)  # noqa: E402

DW   = 10                  # 单通道位宽（线性 RGB 域）
FRAC = 12                  # 系数定点小数位（Q5.12）
ONE  = 1 << FRAC           # 4096
RND  = 1 << (FRAC - 1)     # 2048 = 0.5 LSB，round-half-up 加数

# 设计矩阵（`伪代码.c` 的示例 CCM：行和 = 1 保中性、含负系数做通道解耦、对角 > 1）
M = [[ 1.72, -0.62, -0.10],
     [-0.24,  1.44, -0.20],
     [ 0.05, -0.51,  1.46]]

W_S, H_S, FRAMES = 16, 12, 5          # small 协议场景
CH_P, CH_N = 16, 6                    # chart：patch 边长 / 每行 patch 数（24 色卡 = 6×4）


# ---------------------------------------------------------------------------
# 系数定点化（与运行时同一套舍入规则 + 行和残差补偿）
# ---------------------------------------------------------------------------
def quant_coef():
    """返回 M_int[3][3]（整数）。

    ① 逐项 floor(M·2^F + 0.5)：与运行时 `+2^(F-1) 再 >>F` 同为 round-half-up，
       避免 Python `round()` 的银行家舍入造成 golden 与 RTL 规则不一致；
    ② 行和补偿：残差补到对角项（|系数| 最大 → 相对误差最小），行和精确 = 2^F。
    """
    mi = [[int(math.floor(M[i][k] * ONE + 0.5)) for k in range(3)] for i in range(3)]
    for i in range(3):
        mi[i][i] += ONE - sum(mi[i])
    return mi


def save_coe(mint, path):
    """ccm_coef.coe：按行优先（i*3+k）写 9 行 16bit 有符号十六进制"""
    with open(path, 'w') as f:
        for i in range(3):
            for k in range(3):
                f.write(f'{mint[i][k] & 0xFFFF:04X}\n')


def save_hex(vals, path, width):
    with open(path, 'w') as f:
        for v in vals:
            f.write(f'{v & ((1 << width) - 1):0{(width + 3) // 4}X}\n')


# ---------------------------------------------------------------------------
# golden（位级同构）
# ---------------------------------------------------------------------------
def ccm_ref(pix, mint):
    out = []
    for p in pix:
        v = [(p >> 20) & MAXV, (p >> 10) & MAXV, p & MAXV]
        o = []
        for i in range(3):
            acc = sum(mint[i][k] * v[k] for k in range(3))
            x = (acc + RND) >> FRAC          # Python >> 对负数即算术右移（向下取整）
            o.append(0 if x < 0 else (MAXV if x > MAXV else x))
        out.append((o[0] << 20) | (o[1] << 10) | o[2])
    return out


def inv3(m):
    """3×3 求逆（伴随矩阵法）"""
    a, b, c = m[0]
    d, e, f = m[1]
    g, h, i = m[2]
    det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    return [[(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det],
            [(f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det],
            [(d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]]


# ---------------------------------------------------------------------------
# 色差（ΔE76）：线性 RGB(10bit) → sRGB 编码 → XYZ(D65) → Lab
# ---------------------------------------------------------------------------
def _linear_to_srgb(c):
    c = 0.0 if c < 0.0 else (1.0 if c > 1.0 else c)
    return c * 12.92 if c <= 0.0031308 else 1.055 * (c ** (1 / 2.4)) - 0.055


def _rgb2lab(rgb10):
    r, g, b = [_linear_to_srgb(v / MAXV) for v in rgb10]
    x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
    y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
    z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b
    xn, yn, zn = 0.95047, 1.0, 1.08883

    def f(t):
        return t ** (1 / 3) if t > (6 / 29) ** 3 else t / (3 * (6 / 29) ** 2) + 4 / 29

    fx, fy, fz = f(x / xn), f(y / yn), f(z / zn)
    return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))


def delta_e76(p1, p2):
    """两个 30bit 打包像素的 ΔE76"""
    l1 = _rgb2lab([(p1 >> 20) & MAXV, (p1 >> 10) & MAXV, p1 & MAXV])
    l2 = _rgb2lab([(p2 >> 20) & MAXV, (p2 >> 10) & MAXV, p2 & MAXV])
    return math.sqrt(sum((a - b) ** 2 for a, b in zip(l1, l2)))


# 24 色卡标准 sRGB 值（X-Rite ColorChecker，广泛引用值）
CHART_SRGB = [
    (115, 82, 68), (194, 150, 130), (98, 122, 157), (87, 108, 67), (133, 128, 177), (103, 189, 170),
    (214, 126, 44), (80, 91, 166), (193, 90, 99), (94, 60, 108), (157, 188, 64), (224, 163, 46),
    (56, 61, 150), (70, 148, 73), (175, 54, 60), (231, 199, 31), (187, 86, 149), (8, 133, 161),
    (243, 243, 242), (200, 200, 200), (160, 160, 160), (122, 122, 121), (85, 85, 85), (52, 52, 52),
]


def srgb8_to_linear10(v):
    """sRGB 8bit → （去 gamma 后）线性 10bit"""
    c = v / 255.0
    lin = c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    return min(round(lin * MAXV), MAXV)


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main():
    mode = 'img' if '--img' in sys.argv else ('chart' if '--chart' in sys.argv else 'small')
    mint = quant_coef()
    save_coe(mint, 'ccm_coef.coe')
    print('OK 系数 ccm_coef.coe（Q5.12）：')
    for i in range(3):
        print(f'   行{i}: {mint[i]}  行和={sum(mint[i])}（应 = {ONE}）')

    if mode == 'small':
        w, h, frames = W_S, H_S, FRAMES
        src = []
        for n in range(frames * w * h):
            r, g, b = (n * 131 + 7) & 1023, (n * 57 + 11) & 1023, (n * 211 + 29) & 1023
            src.append((r << 20) | (g << 10) | b)
        exp = ccm_ref(src, mint)
        save_hex(src, 'src_small.hex', 30)
        save_hex(exp, 'exp_small.hex', 30)
        print(f'OK small：src_small.hex + exp_small.hex（{frames} 帧 × {w*h} 像素）')
        return

    if mode == 'img':
        rgb = load_hex('../Demosaic/input.hex')
        assert len(rgb) == W_IMG * H_IMG, f'input.hex 像素数 {len(rgb)} != {W_IMG*H_IMG}'
        clean = []
        for r in range(H_IMG):
            for c in range(W_IMG):
                p = rgb[r * W_IMG + c]
                v = ((p >> 16) & 0xFF) if (r % 2 == 0 and c % 2 == 0) else \
                    ((p & 0xFF) if (r % 2 == 1 and c % 2 == 1) else ((p >> 8) & 0xFF))
                clean.append(min(v << 1, MAXV))
        with_ob = [min(v + OB[phase_of(i // W_IMG, i % W_IMG)], MAXV) for i, v in enumerate(clean)]
        after_blc = [max(v - OB[phase_of(i // W_IMG, i % W_IMG)], 0) for i, v in enumerate(with_ob)]
        dpc_out = dpc_ref(after_blc, W_IMG, H_IMG)
        ideal = demosaic_bilinear_ref(dpc_out, W_IMG, H_IMG)   # M3 链出图（线性 RGB 10bit）

        src = ccm_ref(ideal, mint)          # 真图直接过 CCM（视觉前后对比用）
        save_hex(ideal, 'ccm_in.hex', 30)
        save_hex(src, 'exp_img.hex', 30)    # golden（RTL 位级同等方式）——命名与 TB 约定一致
        print(f'OK img：ccm_in.hex（M3 链出图）+ exp_img.hex（golden，{W_IMG}×{H_IMG}）')
        return

    # ---------------- chart：合成 24 色卡（ΔE 量化） ----------------
    # 「理想目标」= 色卡 sRGB 去 gamma 后的线性 10bit；
    # 「传感器响应」= M⁻¹ × 理想（模拟一颗需要本校正矩阵的 sensor）→ clamp 到 10bit。
    # ⇒ 用 M 校正后应回到理想，ΔE 显著下降；残余 ΔE 反映定点量化 + 越界裁剪。
    minv = inv3(M)
    ideal, sensor = [], []
    for (sr, sg, sb) in CHART_SRGB:
        tgt = [srgb8_to_linear10(sr), srgb8_to_linear10(sg), srgb8_to_linear10(sb)]
        sens = []
        for i in range(3):
            v = round(sum(minv[i][k] * tgt[k] for k in range(3)))
            sens.append(0 if v < 0 else (MAXV if v > MAXV else v))
        ideal.append((tgt[0] << 20) | (tgt[1] << 10) | tgt[2])
        sensor.append((sens[0] << 20) | (sens[1] << 10) | sens[2])

    exp = ccm_ref(sensor, mint)
    save_hex(sensor, 'chart_sensor.hex', 30)
    save_hex(ideal, 'chart_ideal.hex', 30)
    save_hex(exp, 'chart_exp.hex', 30)

    # 把 24 块拼成 96×64 图像（每块 16×16），供 RTL 直接跑（ΔE 用 RTL 数据算，更硬）
    tile = []
    for pr in range(4):
        for rr in range(CH_P):
            for pc in range(CH_N):
                idx = pr * CH_N + pc
                tile += [sensor[idx]] * CH_P
    save_hex(tile, 'chart_in.hex', 30)
    tile_exp = []
    for pr in range(4):
        for rr in range(CH_P):
            for pc in range(CH_N):
                idx = pr * CH_N + pc
                tile_exp += [exp[idx]] * CH_P
    save_hex(tile_exp, 'chart_exp_tile.hex', 30)
    print(f'OK chart：chart_sensor.hex/chart_ideal.hex/chart_exp.hex（24 块）+ '
          f'chart_in.hex/chart_exp_tile.hex（{CH_N*CH_P}×{4*CH_P} 拼接图，RTL 用）')

    de_before = [delta_e76(sensor[i], ideal[i]) for i in range(len(ideal))]
    de_after = [delta_e76(exp[i], ideal[i]) for i in range(len(ideal))]
    # 灰阶保持判据（色卡最后一行 6 块是灰阶）
    print('========================================')
    print('24 色卡 ΔE76（golden，RTL 应位级全等）：')
    print(f'  校正前（传感器响应 vs 理想）：均值 {sum(de_before)/len(de_before):6.2f}'
          f'  最大 {max(de_before):6.2f}')
    print(f'  校正后（CCM 输出   vs 理想）：均值 {sum(de_after)/len(de_after):6.2f}'
          f'  最大 {max(de_after):6.2f}')
    print(f'  灰阶块（后 6 块）校正前 ΔE = {[round(x,2) for x in de_before[18:]]}')
    print(f'  灰阶块（后 6 块）校正后 ΔE = {[round(x,2) for x in de_after[18:]]}  ← 行和=1 ⇒ 应≈0')
    print('========================================')
    print('下一步：iverilog+vvp 跑 tb_ccm.v（RTL 输出 vs golden 逐位比对）→ verify_ccm.py')


if __name__ == '__main__':
    main()
