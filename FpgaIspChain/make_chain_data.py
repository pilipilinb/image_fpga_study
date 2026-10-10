#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_chain_data.py —— M5.3 八级 ISP 整链：输入数据 + golden 期望 + 系数表

两种模式：
  python make_chain_data.py           # small：协议 TB（16×12 × 6 帧，平滑 Bayer 底图 + OB + 噪声 + 坏点）
  python make_chain_data.py --img     # img  ：真图（112×103，传感级 Bayer RAW：OB + 高斯噪声 + 注入坏点）

链路（与 isp_chain_top.v 逐字对应）：
  raw(含 OB 的 Bayer RAW10) → BLC → DPC → AWB(gain=1.0) → Demosaic → 降噪 → CCM → Gamma → 锐化 → RGB888

生成物：
  通用系数（RTL $readmemh 同源）：range_lut.coe(512×6) / inv_rom.coe(1024×13)
                                 ccm_coef.coe(9×16bit 有符号) / gamma_lut.coe(1024×8)
  small：chain_in_small.hex(10bit) / exp_small.hex(末端 24bit)
  img  ：chain_in_img.hex(10bit，含 OB + 噪声 + 坏点) / exp_img.hex(末端 24bit)
         ideal_in_img.hex(10bit，无噪声无坏点的理想 Bayer → PSNR 靶子的输入)

★ 位级同构的三个关键约定（TB 期望与 RTL 必须一字不差）：
  ① BLC  = max(v − OB[phase], 0)
  ② AWB  = clamp((v·gain[phase] + 2^(GF−1)) >> GF) ；gain=1.0(=2^GF) 时恒等
  ③ Gamma 是全链唯一换位宽的一级：30bit 进 → 24bit 出（RGB888）
  逐级中间结果**不落 golden 文件**：verify_isp_chain.py 会自己从 chain_in 重算
  （独立第二判据的精神——不复用 TB/生成器的期望），只需落末端 golden 供 TB 自检。
"""
import math
import os
import random
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.normpath(os.path.join(_HERE, '..'))
for _d in ('Bayer_DPC_Demosaic', 'BilateralFilter', 'CCM', 'Gamma', 'Sharpen'):
    sys.path.append(os.path.join(_ROOT, _d))

from make_dpc_demosaic_data import (W_IMG, H_IMG, MAXV, OB, THR, phase_of,  # noqa: E402
                                    load_hex, dpc_ref, demosaic_bilinear_ref)
from make_denoise_data import (bilateral_ref, gen_range_lut, gen_inv_rom,   # noqa: E402
                               SIGMA_N, SEED)
from make_ccm_data import quant_coef, ccm_ref, save_coe                     # noqa: E402
from make_gamma_data import gen_lut, gamma_ref                             # noqa: E402
from make_sharpen_data import sharpen_ref, KG_DEF, KF                      # noqa: E402

DW      = 10                       # Bayer 域单通道位宽
GF      = 8                        # AWB 增益小数位：1.0 = 2^GF = 256
GAIN1   = 1 << GF                  # 1.0 增益
W_S, H_S, FRAMES = 16, 12, 6       # small：6 帧 = 3 个场景 × 2 帧（与 TB 逐一对应）
N_DEFECT = 60                      # img 模式注入的传感级缺陷个数
SEED_D  = 20260918


def save_hex(vals, path, width):
    with open(path, 'w') as f:
        for v in vals:
            f.write(f'{v & ((1 << width) - 1):0{(width + 3) // 4}X}\n')


# ---------------------------------------------------------------------------
# 逐级位级同构参考
# ---------------------------------------------------------------------------
def blc(raw, w, h, ob=OB):
    """BLC：out = max(v − OB[phase], 0)"""
    return [max(v - ob[phase_of(i // w, i % w)], 0) for i, v in enumerate(raw)]


def awb(pix, w, gains=(GAIN1, GAIN1, GAIN1, GAIN1), gf=GF):
    """AWB 增益：out = clamp((v·gain[phase] + 2^(gf−1)) >> gf)；全 1.0 时恒等"""
    out = []
    for i, v in enumerate(pix):
        g = gains[phase_of(i // w, i % w)]
        x = (v * g + (1 << (gf - 1))) >> gf
        out.append(MAXV if x > MAXV else x)
    return out


def chain_ref(raw, w, h, lut, inv, mint, glut, kg=KG_DEF, kf=KF,
              bp_denoise=False, skip_dpc_denoise=False):
    """单帧整链参考；返回逐级结果字典 {s1..s8}。
       bp_denoise=True 时降噪段旁路（等延迟恒等）——用于"不降噪基线"；
       skip_dpc_denoise=True 时同时跳过 DPC 与降噪——用于"DPC/降噪都关"的最差基线。"""
    s1 = blc(raw, w, h)                                     # 10bit
    s2 = s1 if skip_dpc_denoise else dpc_ref(s1, w, h, THR)  # 10bit
    s3 = awb(s2, w)                                         # 10bit（gain=1.0 → 恒等）
    s4 = demosaic_bilinear_ref(s3, w, h)                    # 30bit
    s5 = s4 if (bp_denoise or skip_dpc_denoise) else bilateral_ref(s4, w, h, lut, inv)
    s6 = ccm_ref(s5, mint)                                  # 30bit
    s7 = gamma_ref(s6, glut)                                # 24bit（换位宽）
    s8 = sharpen_ref(s7, w, h, kg, kf)                      # 24bit
    return {'s1': s1, 's2': s2, 's3': s3, 's4': s4,
            's5': s5, 's6': s6, 's7': s7, 's8': s8}


# ---------------------------------------------------------------------------
# small：平滑 Bayer 底图 + OB + 小幅噪声 + 少量坏点（确定性，便于复现）
# ---------------------------------------------------------------------------
def small_frame(fi):
    w, h = W_S, H_S
    fr = []
    for r in range(h):
        for c in range(w):
            p = phase_of(r, c)
            base = 180 + p * 90 + (r * 7 + c * 5 + fi * 13) % 50
            noise = ((r * 31 + c * 17 + fi * 29) % 33) - 16        # ±16 确定性"噪声"
            v = min(max(base + noise, 0), MAXV)
            fr.append(min(v + OB[p], MAXV))                        # 叠加黑电平
    # 注入少量坏点（亮点/死点各半）——让 DPC 有活干
    rnd = random.Random(SEED_D + fi)
    pos = set()
    while len(pos) < 6:
        pos.add((rnd.randrange(1, h - 1), rnd.randrange(1, w - 1)))
    for k, (r, c) in enumerate(sorted(pos)):
        fr[r * w + c] = MAXV if k % 2 == 0 else 0
    return fr


def main():
    mode = 'img' if '--img' in sys.argv else 'small'

    # 系数表：与各模块 RTL 的 $readmemh 同源生成（确保链目录里的 .coe 与 golden 一致）
    lut  = gen_range_lut()
    inv  = gen_inv_rom()
    mint = quant_coef()
    glut = gen_lut()
    save_hex(lut,  'range_lut.coe', 6)
    save_hex(inv,  'inv_rom.coe', 13)
    save_coe(mint, 'ccm_coef.coe')
    save_hex(glut, 'gamma_lut.coe', 8)
    print(f'OK 系数：range_lut.coe / inv_rom.coe / ccm_coef.coe / gamma_lut.coe')

    if mode == 'small':
        frames = [small_frame(fi) for fi in range(FRAMES)]
        flat_in, flat_exp = [], []
        for fr in frames:
            r = chain_ref(fr, W_S, H_S, lut, inv, mint, glut)
            flat_in += fr
            flat_exp += r['s8']                                  # 末端 24bit
        save_hex(flat_in,  'chain_in_small.hex', DW)
        save_hex(flat_exp, 'exp_small.hex', 24)
        print(f'OK small：chain_in_small.hex（{FRAMES} 帧 × {W_S*H_S}，RAW10 含 OB + 噪声 + 坏点）'
              f' + exp_small.hex（末端 RGB888）')
        return

    # ---------------- img：传感级 Bayer RAW（OB + 高斯噪声 + 坏点）----------------
    rgb = load_hex(os.path.join(_ROOT, 'Demosaic', 'input.hex'))
    assert len(rgb) == W_IMG * H_IMG, f'input.hex 像素数 {len(rgb)} != {W_IMG*H_IMG}'
    clean = []
    for r in range(H_IMG):
        for c in range(W_IMG):
            p = rgb[r * W_IMG + c]
            v = ((p >> 16) & 0xFF) if (r % 2 == 0 and c % 2 == 0) else \
                ((p & 0xFF) if (r % 2 == 1 and c % 2 == 1) else ((p >> 8) & 0xFF))
            clean.append(min(v << 1, MAXV))                      # 8bit → 10bit 光强
    raw_ideal = [min(v + OB[phase_of(i // W_IMG, i % W_IMG)], MAXV)
                 for i, v in enumerate(clean)]                   # 无噪声无坏点（PSNR 靶子输入）

    rnd = random.Random(SEED)
    noisy = [min(max(v + round(rnd.gauss(0, SIGMA_N)), 0), MAXV) for v in raw_ideal]
    # 注入传感级缺陷（亮点 1023 / 死点 0 各半，只注内部区）
    pos = []
    while len(pos) < N_DEFECT:
        r = rnd.randrange(2, H_IMG - 2)
        c = rnd.randrange(2, W_IMG - 2)
        if any(p[0] == r and p[1] == c for p in pos):
            continue
        noisy[r * W_IMG + c] = MAXV if len(pos) % 2 == 0 else 0
        pos.append((r, c))

    exp    = chain_ref(noisy,     W_IMG, H_IMG, lut, inv, mint, glut)   # 整链 golden（TB 自检）
    ideal  = chain_ref(raw_ideal, W_IMG, H_IMG, lut, inv, mint, glut)   # 理想靶子
    base_d = chain_ref(noisy,     W_IMG, H_IMG, lut, inv, mint, glut, bp_denoise=True)      # 不降噪
    base_n = chain_ref(noisy,     W_IMG, H_IMG, lut, inv, mint, glut, skip_dpc_denoise=True)  # 全关

    save_hex(noisy,     'chain_in_img.hex', DW)
    save_hex(raw_ideal, 'ideal_in_img.hex', DW)
    save_hex(exp['s8'], 'exp_img.hex', 24)

    def psnr8(a, b):
        mse, n = 0, len(a)
        for x, y in zip(a, b):
            for sh in (16, 8, 0):
                mse += (((x >> sh) & 0xFF) - ((y >> sh) & 0xFF)) ** 2
        n *= 3
        return 10 * math.log10(255.0 * 255.0 * n / mse) if mse > 0 else float('inf')

    print('========================================')
    print(f'img：{W_IMG}×{H_IMG}，注入高斯噪声 σ={SIGMA_N}（10bit）+ {len(pos)} 个坏点，OB={OB}')
    print(f'[端到端 RGB888 vs 理想靶子]')
    print(f'    DPC/降噪全关（最差）      : {psnr8(base_n["s8"], ideal["s8"]):6.2f} dB')
    print(f'    仅降噪关（DPC 开）        : {psnr8(base_d["s8"], ideal["s8"]):6.2f} dB')
    print(f'    ★ 整链（DPC + 降噪都开）  : {psnr8(exp["s8"], ideal["s8"]):6.2f} dB')
    print('========================================')
    print(f'OK img：chain_in_img.hex（含 OB+噪声+坏点）/ ideal_in_img.hex（理想靶子输入）')
    print(f'        exp_img.hex（整链末端 golden，24bit）')
    print('下一步：iverilog+vvp 跑 tb_isp_chain.v（位级比对 + 协议）→ verify_isp_chain.py')


if __name__ == '__main__':
    main()
