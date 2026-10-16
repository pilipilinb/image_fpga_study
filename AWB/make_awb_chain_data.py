#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_awb_chain_data.py —— AWB 真增益整链实验：数据 + 闭环 golden（住在 AWB/ 下）

【为什么在这里】这是 AWB 的**算法实验**（真增益闭环在整链里跑），不属于链工程。
   本脚本借用 FpgaIspChain 的整链 Python 参考（chain_ref，-I 式 import），
   但所有产物（数据/系数/图）都落在 **AWB/ 本目录**，链工程保持干净。

生成物（全部在 AWB/）：
  awb_chain_in_img.hex    偏色传感级 RAW（R×13/20、B×27/20）× 4 帧（帧0/1 增益 1.0、帧2/3 收敛）
  awb_chain_exp_img.hex   闭环 golden（expa×2 + expb×2，供 tb_awb_chain 位级比对）
  awb_chain_gain.txt      收敛增益 + 统计 + baseline/converged PSNR（人工可查）
  range_lut.coe / inv_rom.coe / ccm_coef.coe / gamma_lut.coe
                          ★ 整链 RTL 的 $readmemh 走**运行目录**——在 AWB/ 跑 tb_awb_chain 时
                            必须在本目录能找到这 4 个系数（与 FpgaIspChain 同源生成）

三条关键约定（与 tb_awb_chain / verify_awb_chain / 软核 C 位级同构）：
  ① 统计在 DPC 出（原始域）· cnt 用 W·H/4 均匀口径
  ② 软核：mean=sum/cnt；mg=(m01+m10)>>1；g=clamp((mg<<8)//max(m,1),128,1023)
  ③ 帧0/1 增益 1.0、帧2/3 收敛（N+2：帧0 统计 → 帧2 生效）
"""
import os
import random
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.append(os.path.join(_HERE, '..', 'FpgaIspChain'))

from make_chain_data import (chain_ref, gen_range_lut, gen_inv_rom, quant_coef,  # noqa: E402
                             gen_lut, save_hex, save_coe, psnr8, blc, dpc_ref,
                             phase_of, load_hex, W_IMG, H_IMG, MAXV, OB, THR,
                             N_DEFECT, SEED, SIGMA_N)

TINT = {0: (13, 20), 1: (1, 1), 2: (1, 1), 3: (27, 20)}   # R×0.65 / B×1.35（与模块级实验一致）


def main():
    # ---- 系数表（$readmemh 同源；在 AWB/ 运行 tb_awb_chain 必须有本目录这一份）----
    lut, inv, mint, glut = gen_range_lut(), gen_inv_rom(), quant_coef(), gen_lut()
    save_hex(lut,  'range_lut.coe', 6)
    save_hex(inv,  'inv_rom.coe', 13)
    save_coe(mint, 'ccm_coef.coe')
    save_hex(glut, 'gamma_lut.coe', 8)
    print('OK 系数（AWB/ 运行目录）：range_lut.coe / inv_rom.coe / ccm_coef.coe / gamma_lut.coe')

    # ---- ① 与整链 --img 同源重建 clean/noisy（同种子 ⇒ 噪声/坏点逐位一致）----
    rgb = load_hex(os.path.join(_HERE, '..', 'Demosaic', 'input.hex'))
    assert len(rgb) == W_IMG * H_IMG, f'input.hex 像素数 {len(rgb)} != {W_IMG*H_IMG}'
    clean = []
    for r in range(H_IMG):
        for c in range(W_IMG):
            p = rgb[r * W_IMG + c]
            v = ((p >> 16) & 0xFF) if (r % 2 == 0 and c % 2 == 0) else \
                ((p & 0xFF) if (r % 2 == 1 and c % 2 == 1) else ((p >> 8) & 0xFF))
            clean.append(min(v << 1, MAXV))                  # 8bit → 10bit 光强

    # ---- ② 偏色版：光强乘色偏（round-half-up）后再加 OB/噪声/坏点 ----
    tinted = []
    for i, v in enumerate(clean):
        num, den = TINT[phase_of(i // W_IMG, i % W_IMG)]
        tinted.append(min((2 * v * num + den) // (2 * den), MAXV))
    raw_t = [min(v + OB[phase_of(i // W_IMG, i % W_IMG)], MAXV)
             for i, v in enumerate(tinted)]
    rnd = random.Random(SEED)
    noisy_t = [min(max(v + round(rnd.gauss(0, SIGMA_N)), 0), MAXV) for v in raw_t]
    pos = []
    while len(pos) < N_DEFECT:
        r = rnd.randrange(2, H_IMG - 2)
        c = rnd.randrange(2, W_IMG - 2)
        if any(p[0] == r and p[1] == c for p in pos):
            continue
        noisy_t[r * W_IMG + c] = MAXV if len(pos) % 2 == 0 else 0
        pos.append((r, c))

    # ---- ③ 未偏色版复现（同种子同抽签顺序）——PSNR 靶子 + 一致性断言 ----
    raw_i = [min(v + OB[phase_of(i // W_IMG, i % W_IMG)], MAXV)
             for i, v in enumerate(clean)]
    rnd2 = random.Random(SEED)
    noisy = [min(max(v + round(rnd2.gauss(0, SIGMA_N)), 0), MAXV) for v in raw_i]
    pos2 = []
    while len(pos2) < N_DEFECT:
        r = rnd2.randrange(2, H_IMG - 2)
        c = rnd2.randrange(2, W_IMG - 2)
        if any(p[0] == r and p[1] == c for p in pos2):
            continue
        noisy[r * W_IMG + c] = MAXV if len(pos2) % 2 == 0 else 0
        pos2.append((r, c))
    chain_img = os.path.join(_HERE, '..', 'FpgaIspChain', 'chain_in_img.hex')
    if os.path.exists(chain_img):
        assert load_hex(chain_img) == noisy, \
            '与 chain_in_img.hex 不一致（噪声/坏点复现失败——种子或抽签顺序变了）'

    # ---- ④ 软核同构：统计（DPC 出）→ 收敛增益（cnt 用 W·H/4 均匀口径）----
    s2t = dpc_ref(blc(noisy_t, W_IMG, H_IMG), W_IMG, H_IMG, THR)
    cnt = W_IMG * H_IMG // 4
    sums = [0, 0, 0, 0]
    for i, v in enumerate(s2t):
        sums[phase_of(i // W_IMG, i % W_IMG)] += v
    m = [s // cnt for s in sums]
    mg = (m[1] + m[2]) >> 1
    g = [min(max((mg << 8) // max(mi, 1), 128), 1023) for mi in m]

    # ---- ⑤ golden：帧0/1 = 增益 1.0；帧2/3 = 收敛增益；靶子 = 未偏色整链输出 ----
    expa = chain_ref(noisy_t, W_IMG, H_IMG, lut, inv, mint, glut)['s8']
    expb = chain_ref(noisy_t, W_IMG, H_IMG, lut, inv, mint, glut,
                     awb_gains=tuple(g))['s8']
    ideal = chain_ref(noisy, W_IMG, H_IMG, lut, inv, mint, glut)['s8']

    save_hex(noisy_t * 4, 'awb_chain_in_img.hex', 10)
    save_hex(expa * 2 + expb * 2, 'awb_chain_exp_img.hex', 24)
    pb, pc = psnr8(expa, ideal), psnr8(expb, ideal)
    with open('awb_chain_gain.txt', 'w') as f:
        f.write(f'收敛增益 g = {g}（Q2.8；帧2/3 生效；由帧0 的 DPC 出统计算出，N+2 口径）\n')
        f.write(f'统计 sums = {sums}（cnt={cnt}，W·H/4 均匀口径）\n')
        f.write(f'mean = {m}，mg = (Gr+Gb)/2 = {mg}\n')
        f.write(f'baseline  PSNR（增益1.0 vs 未偏色整链）= {pb:.2f} dB\n')
        f.write(f'converged PSNR（收敛增益 vs 未偏色整链） = {pc:.2f} dB\n')
    print('========================================')
    print(f'awb-chain：偏色 RAW（R×13/20、B×27/20）×4 帧；收敛增益 g={g}')
    print(f'     baseline  PSNR（无 AWB vs 未偏色整链）  = {pb:6.2f} dB')
    print(f'     ★ converged PSNR（AWB 收敛 vs 未偏色整链）= {pc:6.2f} dB')
    print('OK：awb_chain_in_img.hex / awb_chain_exp_img.hex / awb_chain_gain.txt（均在 AWB/）')
    print('下一步：iverilog 编译 tb_awb_chain.v（-I 指到 FpgaIspChain 及各模块）→ verify_awb_chain.py')


if __name__ == '__main__':
    main()