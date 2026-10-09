#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_gamma_data.py —— M4-3 Gamma：LUT 表 + 输入数据 + golden 期望（与 RTL 同源）

四种模式：
  python make_gamma_data.py           # small：协议 TB（16×12×5 帧，伪随机 RGB 10bit）
  python make_gamma_data.py --ramp    # ramp ：1024 值穷举斜坡（64×16）→ LUT 全表覆盖
  python make_gamma_data.py --img     # img  ：真图（M3 链 → CCM → Gamma 三级串联）

生成物（通用）：gamma_lut.coe（1024×8bit，RTL $readmemh 加载）
生成物（small）：gamma_small_in.hex（30bit）/ gamma_small_exp.hex（**24bit**）
生成物（ramp） ：gamma_ramp_in.hex / gamma_ramp_exp.hex
生成物（img）  ：gamma_in.hex（CCM 输出，30bit）/ exp_img.hex（Gamma 输出，24bit）

与 RTL 的位级同构约定：
  * LUT[x] = clamp(round(255·(x/1023)^(1/2.2)), 0, 255)，round = floor(t+0.5)
  * out = {LUT[R], LUT[G], LUT[B]}     —— 三通道同拍并行查表，1 拍出结果
  * ★ 本模块是**全链位宽缩减的唯一出口**：10bit 进、8bit 出（下游 VDMA tdata[23:0] 契约）
  * bypass 语义：只关 gamma 曲线，不关位宽缩减 → 线性 10→8 = (v+2)>>2（round-half-up）
"""
import math
import os
import sys

sys.path.append(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             '..', 'Bayer_DPC_Demosaic'))
sys.path.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'CCM'))
from make_dpc_demosaic_data import (W_IMG, H_IMG, MAXV, OB, load_hex, phase_of,
                                    dpc_ref, demosaic_bilinear_ref)  # noqa: E402
from make_ccm_data import quant_coef, ccm_ref as ccm_apply             # noqa: E402

DW    = 10                 # 输入单通道位宽（线性 RGB 域）
OW    = 8                  # 输出单通道位宽（RGB888）
GAMMA = 1.0 / 2.2          # 纯 2.2 幂（按伪代码）；变体见计划 §2
LUT_D = 1 << DW            # 1024 项

W_S, H_S, FRAMES = 16, 12, 5          # small 协议场景
W_R, H_R = 64, 16                     # ramp：1024 像素 = 全表覆盖


# ---------------------------------------------------------------------------
# LUT（RTL $readmemh 与 Python golden 同源）
# ---------------------------------------------------------------------------
def gen_lut():
    """LUT[x] = clamp(floor(255·(x/1023)^(1/2.2) + 0.5), 0, 255)"""
    return [min(int(math.floor(255.0 * ((x / float(MAXV)) ** GAMMA) + 0.5)), (1 << OW) - 1)
            for x in range(LUT_D)]


def save_hex(vals, path, width):
    with open(path, 'w') as f:
        for v in vals:
            f.write(f'{v & ((1 << width) - 1):0{(width + 3) // 4}X}\n')


def gamma_ref(pix, lut):
    """位级同构：out = {LUT[R], LUT[G], LUT[B]}（24bit 打包）"""
    out = []
    for p in pix:
        out.append((lut[(p >> 20) & MAXV] << 16) |
                   (lut[(p >> 10) & MAXV] << 8) |
                   lut[p & MAXV])
    return out


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main():
    mode = 'ramp' if '--ramp' in sys.argv else ('img' if '--img' in sys.argv else 'small')
    lut = gen_lut()
    save_hex(lut, 'gamma_lut.coe', OW)

    mono = all(lut[i] <= lut[i + 1] for i in range(LUT_D - 1))
    print(f'OK 表 gamma_lut.coe（{LUT_D}×{OW}bit）：LUT[0]={lut[0]} LUT[1023]={lut[1023]} '
          f'单调不减={mono}')
    print(f'   曲线样例 x=64/256/512/768 → {lut[64]}/{lut[256]}/{lut[512]}/{lut[768]}'
          f'（对比线性 >>2：{64 >> 2}/{256 >> 2}/{512 >> 2}/{768 >> 2}）')

    if mode == 'small':
        src = []
        for n in range(FRAMES * W_S * H_S):
            r, g, b = (n * 131 + 7) & 1023, (n * 57 + 11) & 1023, (n * 211 + 29) & 1023
            src.append((r << 20) | (g << 10) | b)
        exp = gamma_ref(src, lut)
        save_hex(src, 'gamma_small_in.hex', 30)
        save_hex(exp, 'gamma_small_exp.hex', 24)
        print(f'OK small：gamma_small_in.hex(30bit) + gamma_small_exp.hex(24bit)'
              f'（{FRAMES} 帧 × {W_S*H_S} 像素）')
        return

    if mode == 'ramp':
        # 输入 (x,x,x)，x=0..1023 → 输出 (LUT[x],LUT[x],LUT[x])：LUT 全表逐项覆盖
        src = [((x << 20) | (x << 10) | x) for x in range(LUT_D)]
        exp = gamma_ref(src, lut)
        save_hex(src, 'gamma_ramp_in.hex', 30)
        save_hex(exp, 'gamma_ramp_exp.hex', 24)
        print(f'OK ramp：gamma_ramp_in.hex + gamma_ramp_exp.hex（{W_R}×{H_R}={LUT_D} 像素，'
              f'穷举 0..{MAXV} → LUT 全表逐项验证）')
        return

    # ---------------- img：M3 链 → CCM → Gamma ----------------
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
    m3 = demosaic_bilinear_ref(dpc_ref(after_blc, W_IMG, H_IMG), W_IMG, H_IMG)   # M3 出线性 RGB 10bit
    lin = ccm_apply(m3, quant_coef())                                            # M4-2 CCM 输出
    exp = gamma_ref(lin, lut)                                                    # M4-3 Gamma 输出 8bit

    save_hex(lin, 'gamma_in.hex', 30)
    save_hex(exp, 'exp_img.hex', 24)
    print(f'OK img：gamma_in.hex（M3→CCM 的线性 RGB 10bit）+ exp_img.hex（Gamma 8bit，'
          f'{W_IMG}×{H_IMG}）')
    print('下一步：iverilog+vvp 跑 tb_gamma.v（RTL 输出 vs golden 逐位比对）→ verify_gamma.py')


if __name__ == '__main__':
    main()
