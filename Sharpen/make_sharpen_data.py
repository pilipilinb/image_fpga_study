#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_sharpen_data.py —— M5.1 锐化（USM）：输入数据 + golden 期望（与 RTL 位级同构）

三种模式：
  python make_sharpen_data.py           # small：协议 TB（16×12×5 帧，伪随机 RGB888）
  python make_sharpen_data.py --img     # img  ：真图（M3 → CCM → Gamma → 锐化 四级串联）

生成物（small）：src_small.hex（24bit 输入）
                exp_small.hex（kg=128 期望）/ exp_small_k64.hex（kg=64 期望）
生成物（img）  ：sharpen_in.hex（Gamma 输出，24bit）/ exp_img.hex（锐化输出，24bit）

与 RTL 的位级同构约定（两边注释必须一致）：
  * 3×3 高斯模糊（核 [1 2 1;2 4 2;1 2 1]，Σ=16，等价 noise 级的 spatial 核）：
        sum  = (p00+p02+p20+p22) + 2·(p01+p10+p12+p21) + 4·p11     （≤16×255=4080）
        blur = (sum + 8) >> 4                                       （round-half-up）
  * USM（★ 用"符号-幅值"两路，避免有符号乘/算术右移的舍入歧义）：
        d   = |orig − blur|                     （无符号，≤255）
        adj = (d·kg + 2^(KF−1)) >> KF           （幅值 round-half-up）
        out = (orig >= blur) ? orig + adj : orig − adj   → 饱和到 [0,255]
  * k = kg / 2^KF（KF=8）→ kg=128 ⇒ k=0.5；kg=64 ⇒ k=0.25
  * 通道打包 R[23:16] G[15:8] B[7:0]（与 Gamma 出口 / VDMA tdata[23:0] 契约一致）
"""
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.append(os.path.join(_HERE, '..', 'Bayer_DPC_Demosaic'))
sys.path.append(os.path.join(_HERE, '..', 'CCM'))
sys.path.append(os.path.join(_HERE, '..', 'Gamma'))
from make_dpc_demosaic_data import (W_IMG, H_IMG, MAXV, OB, load_hex, phase_of,
                                    dpc_ref, demosaic_bilinear_ref)  # noqa: E402
from make_ccm_data import quant_coef, ccm_ref as ccm_apply            # noqa: E402
from make_gamma_data import gen_lut, gamma_ref                        # noqa: E402

DW      = 8                  # 单通道位宽（RGB888，感知域）
MAXO    = (1 << DW) - 1      # 255
KF      = 8                  # k 的小数位数：k = kg / 2^KF
KG_DEF  = 128                # 默认强度 k = 0.5
KG_K64  = 64                 # 弱强度 k = 0.25（验证 k 端口）
W_S, H_S, FRAMES = 16, 12, 5  # small 协议场景


def ch_of(p, ch):
    """从 24bit 打包像素取第 ch 通道（0=R,1=G,2=B）"""
    return (p >> (DW * (2 - ch))) & MAXO


def pack(r, g, b):
    return ((r & MAXO) << 16) | ((g & MAXO) << 8) | (b & MAXO)


def save_hex(vals, path, width):
    with open(path, 'w') as f:
        for v in vals:
            f.write(f'{v & ((1 << width) - 1):0{(width + 3) // 4}X}\n')


# ---------------------------------------------------------------------------
# 锐化位级同构参考（3×3 clamp replicate + 高斯模糊 + USM 幅值两路）
# ---------------------------------------------------------------------------
def sharpen_ref(pixels, w, h, kg, kf=KF):
    out = []
    rnd = 1 << (kf - 1)
    for R in range(h):
        for C in range(w):
            def px(i, j):
                return pixels[min(max(R + i - 1, 0), h - 1) * w +
                              min(max(C + j - 1, 0), w - 1)]
            res = []
            for ch in range(3):
                p = [[ch_of(px(i, j), ch) for j in range(3)] for i in range(3)]
                orig = p[1][1]
                s = (p[0][0] + p[0][2] + p[2][0] + p[2][2]) \
                    + 2 * (p[0][1] + p[1][0] + p[1][2] + p[2][1]) + 4 * p[1][1]
                blur = (s + 8) >> 4                       # round-half-up /16
                d = abs(orig - blur)
                adj = (d * kg + rnd) >> kf
                v = (orig + adj) if orig >= blur else (orig - adj)
                res.append(min(max(v, 0), MAXO))
            out.append(pack(res[0], res[1], res[2]))
    return out


def gen_lut_coe():
    """Gamma LUT（与 Gamma 模块同一个 .coe 语义，本模块仅 img 链需要）"""
    return gen_lut()


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main():
    mode = 'img' if '--img' in sys.argv else 'small'

    if mode == 'small':
        src = []
        for n in range(FRAMES * W_S * H_S):
            r, g, b = (n * 131 + 7) & MAXO, (n * 57 + 11) & MAXO, (n * 211 + 29) & MAXO
            src.append(pack(r, g, b))
        # 逐帧独立做 golden（行缓存帧间排空 → 帧间无耦合）
        exp128, exp64 = [], []
        for f_i in range(FRAMES):
            fr = src[f_i * W_S * H_S:(f_i + 1) * W_S * H_S]
            exp128 += sharpen_ref(fr, W_S, H_S, KG_DEF)
            exp64 += sharpen_ref(fr, W_S, H_S, KG_K64)
        save_hex(src, 'src_small.hex', 24)
        save_hex(exp128, 'exp_small.hex', 24)
        save_hex(exp64, 'exp_small_k64.hex', 24)
        print(f'OK small：src_small.hex（{FRAMES} 帧 × {W_S*H_S}，24bit）'
              f' + exp_small.hex（kg={KG_DEF}，k={KG_DEF/(1<<KF):.3f}）'
              f' + exp_small_k64.hex（kg={KG_K64}，k={KG_K64/(1<<KF):.3f}）')
        return

    # ---------------- img：M3 链 → CCM → Gamma → 锐化 ----------------
    rgb = load_hex(os.path.join(_HERE, '..', 'Demosaic', 'input.hex'))
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
    m3 = demosaic_bilinear_ref(dpc_ref(after_blc, W_IMG, H_IMG), W_IMG, H_IMG)  # 线性 RGB 10bit
    lin = ccm_apply(m3, quant_coef())                                           # CCM 输出
    gam8 = gamma_ref(lin, gen_lut_coe())                                        # M4-3 Gamma 出 RGB888
    exp = sharpen_ref(gam8, W_IMG, H_IMG, KG_DEF)                               # M5.1 锐化输出

    save_hex(gam8, 'sharpen_in.hex', 24)
    save_hex(exp, 'exp_img.hex', 24)
    print(f'OK img：sharpen_in.hex（Gamma 输出 24bit）+ exp_img.hex（锐化 24bit，'
          f'kg={KG_DEF}，{W_IMG}×{H_IMG}）')
    print('下一步：iverilog+vvp 跑 tb_sharpen.v（RTL vs golden 逐位比对）→ verify_sharpen.py')


if __name__ == '__main__':
    main()
