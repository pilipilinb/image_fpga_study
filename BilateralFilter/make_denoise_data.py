#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_denoise_data.py —— M4 双边降噪：LUT/ROM 系数文件 + 注噪输入 + golden 期望

两种模式：
  python make_denoise_data.py           # small：协议 TB（16×12×5 帧，伪随机 RGB）
  python make_denoise_data.py --img     # img：图像链（M3 链输出 + 高斯噪声）

生成物（通用）：range_lut.coe（512×6bit）/ inv_rom.coe（1024×13bit）
  —— RTL $readmemh 与 Python golden 同源生成，天然消除浮点 vs 定点不一致
生成物（small）：exp_small.hex（30bit 期望，双边 golden）
生成物（img）  ：denoise_in.hex（30bit 注噪输入）/ clean_rgb.hex（无噪基准）/ exp_img.hex（golden）

与 RTL 的位级同构约定（两边注释必须一致）：
  * 窗口 3×3，clamp replicate（line_buffer_fifo_nxn pad 语义）
  * d = |ΔR|+|ΔG|+|ΔB|（L1，≤3069）；wr = (d>CUT)?0:LUT[d]，LUT[d]=round(63·exp(−d²/2σ_r²))
  * σ_r=120（8bit 彩色 30 的 10bit 等比 ×4）；CUT=374=ceil(3.11σ_r)
  * w = spatial[i][j]×wr，spatial=[1 2 1;2 4 2;1 2 1]（Σ=16）
  * den ∈ [252,1008]（下界 = 中心项 4×63 恒存在）；inv = ROM[den−252] = round(2^20/den)
  * out = sat_1023( (num×inv + 2^19) >> 20 )   ← round-half-up + 饱和（防御）
"""
import math
import os
import random
import sys

sys.path.append(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             '..', 'Bayer_DPC_Demosaic'))
from make_dpc_demosaic_data import (W_IMG, H_IMG, MAXV, OB, load_hex, phase_of,
                                    dpc_ref, demosaic_bilinear_ref)  # noqa: E402

DW       = 10                      # 单通道位宽
# 【σ_r 的标定逻辑（关键，别照抄 8bit 数字）】
#   σ_r 是"值域核宽度"，物理含义 = 噪声尺度：σ_r ≈ 1.44 × E[d_noise]（L1 量纲）
#   三通道独立高斯噪声：E[|Δ|]=σ√(2/π)≈0.8σ ⇒ E[d]=3×0.8σ√2 ≈ 3.39σ
#   ⇒ σ_r ≈ 1.44 × 3.39σ_n ≈ 4.9 σ_n
#   本实验注入 σ_n=48（10bit）⇒ σ_r ≈ 235 → 取 240
#   （工程要点.md 的 8bit σ_r=30 对应 σ_n≈6(8bit)；直接 ×4 得 120 只适合 σ_n=24，
#     与 σ_n=48 失配会让值域核过窄、中心权重过大 → 降噪不足，实测 PSNR 反低于高斯）
SIGMA_R  = 240                     # 值域 σ（按 σ_n=48 标定）
CUT      = 747                     # ceil(3.11×240)：d>CUT 时 63·exp<0.5，round 后为 0
LUT_AW   = 10                      # 值域 LUT 地址位宽（1024 项，1 个 BRAM 仍够）
LUT_D    = 1 << LUT_AW
ROM_AW   = 10                      # 倒数 ROM 地址位宽（1024 项）
ROM_D    = 1 << ROM_AW
INV_SH   = 20                      # inv = round(2^20 / den)
DEN_OFF  = 252                     # den 下界 = 中心项 spatial4×wr63
SPATIAL  = [[1, 2, 1], [2, 4, 2], [1, 2, 1]]
W_S, H_S, FRAMES = 16, 12, 5       # small 协议场景
SEED     = 20260921
SIGMA_N  = 48                      # 注入高斯噪声 σ（10bit，≈8bit 的 12）


# ---------------------------------------------------------------------------
# 系数表（RTL $readmemh 与 Python golden 同源）
# ---------------------------------------------------------------------------
def gen_range_lut():
    """值域 LUT：round(63·exp(−d²/2σ²))，d=0..511；d>CUT 的项 round 后自然为 0"""
    return [round(63 * math.exp(-(d * d) / (2.0 * SIGMA_R * SIGMA_R)))
            for d in range(LUT_D)]


def gen_inv_rom():
    """倒数 ROM：round(2^20/(addr+252))；addr ∈[0,756] 被实际寻址（den≤1008）"""
    return [round((1 << INV_SH) / (a + DEN_OFF)) for a in range(ROM_D)]


def save_hex(vals, path, width):
    with open(path, 'w') as f:
        for v in vals:
            f.write(f'{v & ((1 << width) - 1):0{(width + 3) // 4}X}\n')


# ---------------------------------------------------------------------------
# 双边滤波位级同构参考（3×3 clamp 窗口 + L1 + LUT + 倒数 ROM 定点）
# ---------------------------------------------------------------------------
def bilateral_ref(rgb_pack, w, h, lut, inv):
    out = []
    for R in range(h):
        for C in range(w):
            def px(i, j):
                return rgb_pack[min(max(R + i - 1, 0), h - 1) * w +
                                min(max(C + j - 1, 0), w - 1)]
            ctr = px(1, 1)
            cR, cG, cB = (ctr >> 20) & MAXV, (ctr >> 10) & MAXV, ctr & MAXV
            numR = numG = numB = den = 0
            for i in range(3):
                for j in range(3):
                    p = px(i, j)
                    vR, vG, vB = (p >> 20) & MAXV, (p >> 10) & MAXV, p & MAXV
                    d = abs(vR - cR) + abs(vG - cG) + abs(vB - cB)
                    wr = 0 if d > CUT else lut[d]
                    wgt = SPATIAL[i][j] * wr
                    numR += wgt * vR
                    numG += wgt * vG
                    numB += wgt * vB
                    den += wgt
            inv_q = inv[den - DEN_OFF]

            def norm(num):
                v = (num * inv_q + (1 << (INV_SH - 1))) >> INV_SH
                return MAXV if v > MAXV else v
            out.append((norm(numR) << 20) | (norm(numG) << 10) | norm(numB))
    return out


def gaussian_ref(rgb_pack, w, h):
    """高斯参考（同 10bit 域、同 spatial 核 /16，round-half-up）——保边对比用"""
    out = []
    for R in range(h):
        for C in range(w):
            def px(i, j):
                return rgb_pack[min(max(R + i - 1, 0), h - 1) * w +
                                min(max(C + j - 1, 0), w - 1)]
            def norm(x):
                v = (x + 8) >> 4                       # /16 round-half-up
                return MAXV if v > MAXV else v
            r_o = g_o = b_o = 0
            for i in range(3):
                for j in range(3):
                    p = px(i, j)
                    s = SPATIAL[i][j]
                    r_o += s * ((p >> 20) & MAXV)
                    g_o += s * ((p >> 10) & MAXV)
                    b_o += s * (p & MAXV)
            out.append((norm(r_o) << 20) | (norm(g_o) << 10) | norm(b_o))
    return out


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main():
    mode = 'img' if '--img' in sys.argv else 'small'
    lut, inv = gen_range_lut(), gen_inv_rom()
    save_hex(lut, 'range_lut.coe', 6)
    save_hex(inv, 'inv_rom.coe', 13)
    print(f'OK 系数：range_lut.coe（{LUT_D}×6，CUT={CUT} 处 LUT 值={lut[CUT]}，'
          f' lut[CUT+1]={lut[CUT+1]}）· inv_rom.coe（{ROM_D}×13）')

    if mode == 'small':
        w, h, frames = W_S, H_S, FRAMES
        # 伪随机 RGB 三通道独立序列（跨帧连续），30bit 打包
        src = []
        for n in range(frames * w * h):
            r, g, b = (n * 131 + 7) & 1023, (n * 57 + 11) & 1023, (n * 211 + 29) & 1023
            src.append((r << 20) | (g << 10) | b)
        exp = []
        for f_i in range(frames):                      # 行缓存帧间排空 → 逐帧独立
            fr = src[f_i * w * h:(f_i + 1) * w * h]
            exp += bilateral_ref(fr, w, h, lut, inv)
        save_hex(exp, 'exp_small.hex', 30)
        save_hex(src, 'src_small.hex', 30)
        print(f'OK small: 输入 src_small.hex + 期望 exp_small.hex'
              f'（{frames} 帧 × {w * h}，RGB 10bit 打包）')
        return

    # ---------------- img 模式：M3 链出图 + 高斯噪声 ----------------
    rgb = load_hex('../Demosaic/input.hex')
    assert len(rgb) == W_IMG * H_IMG, f'input.hex 像素数 {len(rgb)} != {W_IMG*H_IMG}'
    ideal = []
    for r in range(H_IMG):
        for c in range(W_IMG):
            p = rgb[r * W_IMG + c]
            v = ((p >> 16) & 0xFF) if (r % 2 == 0 and c % 2 == 0) else \
                ((p & 0xFF) if (r % 2 == 1 and c % 2 == 1) else ((p >> 8) & 0xFF))
            ideal.append(min(v << 1, MAXV))
    with_ob = [min(v + OB[phase_of(i // W_IMG, i % W_IMG)], MAXV)
               for i, v in enumerate(ideal)]
    after_blc = [max(v - OB[phase_of(i // W_IMG, i % W_IMG)], 0)
                 for i, v in enumerate(with_ob)]
    dpc_out = dpc_ref(after_blc, W_IMG, H_IMG)             # 链路一致（无坏点注入）
    clean = demosaic_bilinear_ref(dpc_out, W_IMG, H_IMG)   # 线性 RGB 10bit（无噪基准）

    rnd = random.Random(SEED)
    noised = []
    for p in clean:
        r = min(max(((p >> 20) & MAXV) + round(rnd.gauss(0, SIGMA_N)), 0), MAXV)
        g = min(max(((p >> 10) & MAXV) + round(rnd.gauss(0, SIGMA_N)), 0), MAXV)
        b = min(max((p & MAXV) + round(rnd.gauss(0, SIGMA_N)), 0), MAXV)
        noised.append((r << 20) | (g << 10) | b)

    exp = bilateral_ref(noised, W_IMG, H_IMG, lut, inv)
    gauss = gaussian_ref(noised, W_IMG, H_IMG)
    save_hex(noised, 'denoise_in.hex', 30)
    save_hex(clean, 'clean_rgb.hex', 30)
    save_hex(exp, 'exp_img.hex', 30)
    save_hex(gauss, 'gauss_ref.hex', 30)

    def psnr10(a, b, rgb=True):
        sh0, nch = (20, 3) if rgb else (0, 1)
        mse, n = 0, len(a) * nch
        for x, y in zip(a, b):
            for k in range(nch):
                sh = sh0 - 10 * k
                mse += (((x >> sh) & MAXV) - ((y >> sh) & MAXV)) ** 2
        return 10 * math.log10(MAXV * MAXV * n / mse) if mse > 0 else float('inf')

    print('========================================')
    print(f'高斯噪声 σ={SIGMA_N}（10bit，≈8bit 的 {SIGMA_N/4:.0f}），seed={SEED}')
    print(f'[RGB 域] 注噪图   vs 无噪基准 : {psnr10(noised, clean):7.2f} dB')
    print(f'[RGB 域] 高斯降噪 vs 无噪基准 : {psnr10(gauss, clean):7.2f} dB')
    print(f'[RGB 域] 双边降噪 vs 无噪基准 : {psnr10(exp, clean):7.2f} dB（Python golden，RTL 应位级全等）')
    print('========================================')
    print('下一步：iverilog+vvp 跑 tb（RTL 输出 vs exp 逐位比对）→ verify_denoise.py')


if __name__ == '__main__':
    main()
