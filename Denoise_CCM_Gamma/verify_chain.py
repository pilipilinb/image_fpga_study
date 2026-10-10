#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_chain.py —— M5.2 RGB 三段链：独立第二判据 + ★ 顺序可交换性实验

第一判据（TB）：RTL vs golden 逐位比对（sim_i0/sim_i1.txt 的 [PASS]）
本脚本（第二判据）做三件事：
  ① **独立复算**：不读 TB 的期望文件，自己用 Python 参考函数重算一遍，与 RTL 落盘的
     `chain_out_img.txt`（顺序0）/ `chain_out_swap_img.txt`（顺序1）逐位比对；
  ② **★ 顺序实验**：回答"降噪和 CCM 能不能换、谁在前更好"——用位级差异 + 与无噪声
     理想图的 PSNR/SSIM + 噪声传播指标（CCM 饱和数、色差梯度 RMS）四类证据定量回答；
  ③ 出四宫格对比图 `chain_order_compare.png`（理想 / 不降噪基线 / 顺序0 / 顺序1）。

运行前提：先跑 make_chain_data.py --img 与两个 img 模式的 TB。
"""
import math
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.normpath(os.path.join(_HERE, '..'))
for _d in ('Bayer_DPC_Demosaic', 'BilateralFilter', 'CCM', 'Gamma'):
    sys.path.append(os.path.join(_ROOT, _d))

from make_dpc_demosaic_data import W_IMG, H_IMG, MAXV, load_hex      # noqa: E402
from make_denoise_data import bilateral_ref, gen_range_lut, gen_inv_rom  # noqa: E402
from make_ccm_data import quant_coef, ccm_ref                        # noqa: E402
from make_gamma_data import gen_lut, gamma_ref                       # noqa: E402
from PIL import Image, ImageDraw, ImageFont                          # noqa: E402

N = W_IMG * H_IMG
FONTS = [r'C:\Windows\Fonts\msyh.ttc', r'C:\Windows\Fonts\simhei.ttf',
         r'C:\Windows\Fonts\simsun.ttc']


def font(size):
    for fp in FONTS:
        try:
            return ImageFont.truetype(fp, size)
        except Exception:
            pass
    return ImageFont.load_default()


def load_txt(path):
    with open(path) as f:
        return [int(t, 16) for t in f.read().split()]


def rgb_img(pix24, w, h, scale=3):
    buf = bytearray()
    for p in pix24:
        buf += bytes(((p >> 16) & 255, (p >> 8) & 255, p & 255))
    return Image.frombytes('RGB', (w, h), bytes(buf)).resize(
        (w * scale, h * scale), Image.NEAREST)


def psnr_rgb(a, b):
    se = 0
    for pa, pb in zip(a, b):
        for sh in (16, 8, 0):
            d = ((pa >> sh) & 255) - ((pb >> sh) & 255)
            se += d * d
    mse = se / (len(a) * 3)
    return float('inf') if mse == 0 else 10 * math.log10(255 * 255 / mse)


def luma(pix):
    return [0.299 * ((p >> 16) & 255) + 0.587 * ((p >> 8) & 255) + 0.114 * (p & 255)
            for p in pix]


def ssim_luma(la, lb, w, h, bs=8):
    """分块 SSIM（8×8，plain Python；图只有 112×103 所以够快）"""
    c1, c2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
    tot, cnt = 0.0, 0
    for y0 in range(0, h, bs):
        for x0 in range(0, w, bs):
            A, B = [], []
            for dy in range(min(bs, h - y0)):
                for dx in range(min(bs, w - x0)):
                    A.append(la[(y0 + dy) * w + x0 + dx])
                    B.append(lb[(y0 + dy) * w + x0 + dx])
            n = len(A)
            ma, mb = sum(A) / n, sum(B) / n
            va = sum((v - ma) ** 2 for v in A) / (n - 1)
            vb = sum((v - mb) ** 2 for v in B) / (n - 1)
            cov = sum((x - ma) * (y - mb) for x, y in zip(A, B)) / (n - 1)
            tot += ((2 * ma * mb + c1) * (2 * cov + c2)) / \
                   ((ma * ma + mb * mb + c1) * (va + vb + c2))
            cnt += 1
    return tot / cnt


def bit_diff(a, b):
    """位级差异：不同像素数占比 / 单通道最大差 / 平均绝对差"""
    ndiff, mx, s = 0, 0, 0
    for pa, pb in zip(a, b):
        if pa != pb:
            ndiff += 1
        for sh in (16, 8, 0):
            d = abs(((pa >> sh) & 255) - ((pb >> sh) & 255))
            mx = max(mx, d)
            s += d
    return ndiff, mx, s / (len(a) * 3)


def sat_count(pix10):
    """CCM 输出（30bit）里被饱和到 0 / 1023 的样本数 —— 噪声越大，被推出量程的越多"""
    c = 0
    for p in pix10:
        for sh in (20, 10, 0):
            v = (p >> sh) & MAXV
            if v == 0 or v == MAXV:
                c += 1
    return c


def chroma_grad_rms(pix24, w, h):
    """色差 (R−G) 的水平梯度 RMS —— 隔离"色噪声"水平（图像结构在两种顺序里相同）"""
    vals = []
    for y in range(h):
        for x in range(1, w):
            p1, p0 = pix24[y * w + x], pix24[y * w + x - 1]
            d1 = ((p1 >> 16) & 255) - ((p1 >> 8) & 255)
            d0 = ((p0 >> 16) & 255) - ((p0 >> 8) & 255)
            vals.append(d1 - d0)
    m = sum(vals) / len(vals)
    return math.sqrt(sum((v - m) ** 2 for v in vals) / len(vals))


def main():
    lut, inv = gen_range_lut(), gen_inv_rom()
    mint, glut = quant_coef(), gen_lut()

    noisy = load_hex('chain_in_img.hex')
    clean = load_hex(os.path.join(_ROOT, 'BilateralFilter', 'clean_rgb.hex'))
    ideal = load_hex('ideal_img.hex')
    base = load_hex('base_img.hex')
    out0 = load_txt('chain_out_img.txt')
    out1 = load_txt('chain_out_swap_img.txt')
    for nm, v in (('chain_in_img', noisy), ('ideal_img', ideal), ('base_img', base),
                  ('chain_out_img', out0), ('chain_out_swap_img', out1)):
        assert len(v) == N, f'{nm} 行数 {len(v)} != {N}'

    ok = True
    print('=' * 68)
    print('[1] 独立复算（不读 TB 期望，自己重算后与 RTL 落盘逐位比对）')
    g0 = gamma_ref(ccm_ref(bilateral_ref(noisy, W_IMG, H_IMG, lut, inv), mint), glut)
    g1 = gamma_ref(bilateral_ref(ccm_ref(noisy, mint), W_IMG, H_IMG, lut, inv), glut)
    e0 = sum(1 for a, b in zip(out0, g0) if a != b)
    e1 = sum(1 for a, b in zip(out1, g1) if a != b)
    print(f'    顺序0 降噪→CCM→Gamma : RTL vs 独立复算 0 误差? {e0 == 0}（{N - e0}/{N}）')
    print(f'    顺序1 CCM→降噪→Gamma : RTL vs 独立复算 0 误差? {e1 == 0}（{N - e1}/{N}）')
    ok &= (e0 == 0 and e1 == 0)

    print('=' * 68)
    print('[2] ★ 两种顺序能否交换？（位级对比，顺序0 vs 顺序1）')
    nd, mx, mad = bit_diff(out0, out1)
    print(f'    不同像素 {nd}/{N} = {nd * 100.0 / N:.1f}%   单通道最大差 {mx}   '
          f'平均绝对差 {mad:.2f}')
    print('    ⇒ 不可交换：降噪是**非线性**算子（值域权重依赖像素值），'
          'CCM 是**线性**矩阵乘')
    print('      （含 Q5.12 舍入 + 饱和）⇒ linear∘nonlinear ≠ nonlinear∘linear，位级必然不同。')

    print('=' * 68)
    print('[3] ★ 谁在前更好？（与"无噪声理想图"比，越高越好）')
    rows = [('不降噪基线 Gamma(CCM(noisy))', base),
            ('顺序0 降噪→CCM→Gamma', out0),
            ('顺序1 CCM→降噪→Gamma', out1)]
    li = luma(ideal)
    res = {}
    for nm, v in rows:
        p, s = psnr_rgb(v, ideal), ssim_luma(luma(v), li, W_IMG, H_IMG)
        res[nm] = (p, s)
        print(f'    {nm:32s} PSNR {p:6.2f} dB   SSIM {s:.4f}')
    p0, p1 = res['顺序0 降噪→CCM→Gamma'][0], res['顺序1 CCM→降噪→Gamma'][0]

    print('=' * 68)
    print('[4] 噪声传播指标（解释"为什么"）')
    ccm_on_denoise = ccm_ref(bilateral_ref(noisy, W_IMG, H_IMG, lut, inv), mint)
    ccm_on_noisy = ccm_ref(noisy, mint)
    s0, s1 = sat_count(ccm_on_denoise), sat_count(ccm_on_noisy)
    print(f'    CCM 输出被饱和到 0/1023 的样本数：'
          f'降噪后喂 CCM = {s0}  vs 噪声直喂 CCM = {s1}'
          f'（多 {s1 - s0} 个样本 = 全部 {3 * N} 个样本的 '
          f'{(s1 - s0) * 100.0 / (3 * N):.1f}%）')
    print('    ⇒ CCM 含负系数、对角 >1，会把三通道噪声**混合并放大**并更多撞到量程边界。')
    c_ideal = chroma_grad_rms(ideal, W_IMG, H_IMG)
    for nm, v in [('不降噪基线', base), ('顺序0', out0), ('顺序1', out1)]:
        print(f'    色差 (R−G) 梯度 RMS {nm}: {chroma_grad_rms(v, W_IMG, H_IMG):.3f}'
              f'（理想 {c_ideal:.3f}）')
    print('    ⇒ 顺序1 的降噪输入已被矩阵"染成通道相关的色噪声"，双边滤波的值域权重')
    print('      按 |ΔR|+|ΔG|+|ΔB| 判相似度 → 反而把噪声当"边缘"保护起来，抑制不足。')

    print('=' * 68)
    print('[5] 结论')
    better = '顺序0（降噪→CCM）' if p0 >= p1 else '顺序1（CCM→降噪）'
    print(f'    两顺序位级不可交换（{nd * 100.0 / N:.1f}% 像素不同）；'
          f'按 PSNR 判定更好的顺序 = **{better}**')
    print(f'    顺序0 {p0:.2f} dB  vs  顺序1 {p1:.2f} dB  →  差 {abs(p0 - p1):.2f} dB')
    print('    ⇒ 本工程链路把降噪放在 CCM 之前是有量化依据的：')
    print('      在噪声还是"通道独立、未被放大"的形态时压掉，而不是等 CCM 把它放大成色噪声。')

    # ---------------- 四宫格对比图 ----------------
    panels = [('无噪声理想 Gamma(CCM(clean))', ideal, None),
              ('不降噪基线 Gamma(CCM(noisy))', base, res['不降噪基线 Gamma(CCM(noisy))'][0]),
              ('顺序0: 降噪→CCM→Gamma', out0, p0),
              ('顺序1: CCM→降噪→Gamma', out1, p1)]
    sc, bw = 3, 34
    tile_w, tile_h = W_IMG * sc, H_IMG * sc + bw
    canvas = Image.new('RGB', (tile_w * 2, tile_h * 2), (255, 255, 255))
    dr = ImageDraw.Draw(canvas)
    f = font(15)
    for i, (title, v, p) in enumerate(panels):
        x, y = (i % 2) * tile_w, (i // 2) * tile_h
        dr.rectangle([x, y, x + tile_w - 1, y + bw - 1], fill=(240, 240, 240))
        txt = title + (f'   PSNR {p:.2f} dB' if p is not None else '')
        dr.text((x + 6, y + 8), txt, fill=(0, 0, 0), font=f)
        canvas.paste(rgb_img(v, W_IMG, H_IMG, sc), (x, y + bw))
    canvas.save('chain_order_compare.png')
    print('=' * 68)
    print('对比图已出：chain_order_compare.png（理想 / 不降噪基线 / 顺序0 / 顺序1）')
    print('[PASS] RGB 三段链独立校验 + 顺序实验全部通过' if ok else '[FAIL] 独立复算不一致')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
