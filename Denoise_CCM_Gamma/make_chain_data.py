#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_chain_data.py —— M5.2 RGB 三段链（降噪 → CCM → Gamma）数据生成 + **两种串联顺序**的 golden

两种模式：
  python make_chain_data.py           # small：协议 TB（16×12 × 5 帧，平滑底图 + 高斯噪声）
  python make_chain_data.py --img     # img：真图（复用 BilateralFilter 的注噪输入与干净基准）

★ 本脚本的核心目的：为"降噪 / CCM 顺序是否可交换"这个实验造**两套 golden**，其余条件完全相同：
  顺序0（本工程链路）: out = Gamma( CCM( 降噪(noisy) ) )      ← 降噪在前
  顺序1（对照）      : out = Gamma( 降噪( CCM(noisy) ) )      ← CCM 在前
  两者只有"谁在前"这一个差异 → 位级对比 + 与"无噪声理想"的 PSNR 对比 ⇒ 定量回答顺序问题。

生成物（small）: chain_in_small.hex(30bit) / exp_order0_small.hex(24bit) / exp_order1_small.hex(24bit)
生成物（img）  : chain_in_img.hex(30bit) / exp_order0_img.hex / exp_order1_img.hex (24bit)
                 ideal_img.hex(24bit，**无噪声理想** = Gamma(CCM(clean))，顺序实验的参考基准)
                 base_img.hex (24bit，**不降噪基线** = Gamma(CCM(noisy))，用来量化"降噪带来多少改善")

逐级接口契约（与 RTL / 各模块 README 一致）：
  * 线性 RGB 10bit，30bit 打包 = {R[29:20], G[19:10], B[9:0]}（R 在高位）
  * Gamma 是全链唯一换位宽的一级：30bit 进 → 24bit 出（RGB888）
"""
import os
import random
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.normpath(os.path.join(_HERE, '..'))
for _d in ('Bayer_DPC_Demosaic', 'BilateralFilter', 'CCM', 'Gamma'):
    sys.path.append(os.path.join(_ROOT, _d))

from make_dpc_demosaic_data import W_IMG, H_IMG, MAXV, load_hex            # noqa: E402
from make_denoise_data import (bilateral_ref, gen_range_lut, gen_inv_rom,  # noqa: E402
                               save_hex, SIGMA_N, SEED, W_S, H_S, FRAMES)
from make_ccm_data import quant_coef, ccm_ref                              # noqa: E402
from make_gamma_data import gen_lut, gamma_ref                            # noqa: E402


def _pack(r, g, b):
    return (r << 20) | (g << 10) | b


# ---------------------------------------------------------------------------
# 三段链 golden：两种顺序（逐帧独立，与 RTL 的 sof 分帧语义一致）
# ---------------------------------------------------------------------------
def chain_order0(frames, w, h, lut, inv, mint, glut):
    """降噪 → CCM → Gamma（本工程链路顺序）"""
    out = []
    for f in frames:
        d = bilateral_ref(f, w, h, lut, inv)
        out += gamma_ref(ccm_ref(d, mint), glut)
    return out


def chain_order1(frames, w, h, lut, inv, mint, glut):
    """CCM → 降噪 → Gamma（对照顺序）"""
    out = []
    for f in frames:
        c = ccm_ref(f, mint)
        out += gamma_ref(bilateral_ref(c, w, h, lut, inv), glut)
    return out


# ---------------------------------------------------------------------------
# small：平滑底图 + 高斯噪声（让双边滤波"有东西可平滑"，比纯随机更接近真实场景）
# ---------------------------------------------------------------------------
def make_small_frames():
    rnd = random.Random(SEED + 7)
    frames = []
    for fi in range(FRAMES):
        fr = []
        for r in range(H_S):
            for c in range(W_S):
                # 低频渐变底图（每帧偏移，保证帧间不同）+ 三通道独立高斯噪声
                base = (200 + c * 600 // max(W_S - 1, 1),
                        400 + r * 400 // max(H_S - 1, 1),
                        300 + fi * 100)
                p = [min(max(int(b) + round(rnd.gauss(0, SIGMA_N)), 0), MAXV) for b in base]
                fr.append(_pack(p[0], p[1], p[2]))
        frames.append(fr)
    return frames


def main():
    mode = 'img' if '--img' in sys.argv else 'small'

    lut  = gen_range_lut()          # 值域 LUT（RTL $readmemh 同源）
    inv  = gen_inv_rom()            # 倒数 ROM
    mint = quant_coef()             # CCM Q5.12 有符号系数矩阵
    glut = gen_lut()                # Gamma 1024×8 LUT

    if mode == 'small':
        frames = make_small_frames()
        flat   = [p for fr in frames for p in fr]
        save_hex(flat, 'chain_in_small.hex', 30)
        save_hex(chain_order0(frames, W_S, H_S, lut, inv, mint, glut),
                 'exp_order0_small.hex', 24)
        save_hex(chain_order1(frames, W_S, H_S, lut, inv, mint, glut),
                 'exp_order1_small.hex', 24)
        print(f'OK small：chain_in_small.hex（{FRAMES} 帧 × {W_S*H_S}，30bit）'
              f' + exp_order0_small.hex / exp_order1_small.hex（24bit）')
        return

    # ---------------- img：复用 BilateralFilter 的注噪输入与干净基准 ----------------
    # 为什么直接复用而不再造一遍：保证链的输入与单模块 TB **逐字节一致**，
    #   这样"四段链"的结果可以直接和 M4 已公布的降噪指标（PSNR 32.03dB）对齐比较。
    noisy = load_hex(os.path.join(_ROOT, 'BilateralFilter', 'denoise_in.hex'))
    clean = load_hex(os.path.join(_ROOT, 'BilateralFilter', 'clean_rgb.hex'))
    assert len(noisy) == W_IMG * H_IMG, f'denoise_in.hex {len(noisy)} != {W_IMG*H_IMG}'
    assert len(clean) == W_IMG * H_IMG, f'clean_rgb.hex {len(clean)} != {W_IMG*H_IMG}'

    save_hex(noisy, 'chain_in_img.hex', 30)
    save_hex(chain_order0([noisy], W_IMG, H_IMG, lut, inv, mint, glut),
             'exp_order0_img.hex', 24)
    save_hex(chain_order1([noisy], W_IMG, H_IMG, lut, inv, mint, glut),
             'exp_order1_img.hex', 24)
    save_hex(gamma_ref(ccm_ref(clean, mint), glut), 'ideal_img.hex', 24)   # 无噪声理想
    save_hex(gamma_ref(ccm_ref(noisy, mint), glut), 'base_img.hex', 24)    # 不降噪基线

    print(f'OK img：chain_in_img.hex（30bit，{W_IMG}×{H_IMG}）'
          f' + exp_order0_img.hex / exp_order1_img.hex（24bit）'
          f' + ideal_img.hex（无噪声理想）/ base_img.hex（不降噪基线）')
    print('下一步：iverilog+vvp 跑 tb_rgb_chain.v（两种顺序各自位级比对）→ verify_chain.py')


if __name__ == '__main__':
    main()
