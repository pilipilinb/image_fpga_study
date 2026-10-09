#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_sharpen.py —— M5.1 锐化独立校验（第二判据）

四条判据：
  1. **位级全等**：RTL 输出 sharpen_out.txt（24bit）vs Python golden exp_img.hex 逐像素
  2. **锐度提升量化**：Tenengrad（平均梯度幅值）+ 平均 |Laplacian| —— 锐化后应显著上升
     （这是锐化的"目的指标"，PSNR 不是）
  3. **改动强度（PSNR）**：原图（Gamma 出）vs 锐化图 —— 锐化必然降低与原图的 PSNR，
     报告出来是为了给出"改动幅度"的量化（harsh 不代表错，但过大＝过锐/halo）
  4. 对比图：原图 | 锐化图 + 强边缘区局部放大（看 halo/边缘增强）

用法（需先跑 IMG 模式 TB）：
  python make_sharpen_data.py --img && iverilog -DIMG ... && vvp tb_i.vvp
  python verify_sharpen.py
"""
import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFont

W, H = 112, 103
MAXO = 255
FONTS = [r'C:\Windows\Fonts\msyh.ttc', r'C:\Windows\Fonts\simhei.ttf', r'C:\Windows\Fonts\simsun.ttc']


def font(size):
    for fp in FONTS:
        try:
            return ImageFont.truetype(fp, size)
        except OSError:
            continue
    return ImageFont.load_default()


def load_hex(path):
    return [int(l.strip(), 16) for l in open(path) if l.strip()]


def unpack24(px):
    """24bit 打包 → (H,W,3) float 数组（R 在高位）"""
    a = np.array(px, dtype=np.int64)
    r = (a >> 16) & MAXO
    g = (a >> 8) & MAXO
    b = a & MAXO
    return np.stack([r, g, b], axis=1).reshape(H, W, 3).astype(np.float64)


def to_img(a):
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), 'RGB')


def luma(a):
    return a @ np.array([0.299, 0.587, 0.114])


def tenengrad(y):
    """Sobel 梯度幅值均值（锐度经典度量：越大越锐）"""
    p = np.pad(y, 1, mode='reflect')
    gx = (p[0:-2, 2:] + 2 * p[1:-1, 2:] + p[2:, 2:]) - (p[0:-2, 0:-2] + 2 * p[1:-1, 0:-2] + p[2:, 0:-2])
    gy = (p[2:, 0:-2] + 2 * p[2:, 1:-1] + p[2:, 2:]) - (p[0:-2, 0:-2] + 2 * p[0:-2, 1:-1] + p[0:-2, 2:])
    return float(np.hypot(gx, gy).mean())


def lap_energy(y):
    """4 邻域 Laplacian 幅值均值（高频能量）"""
    p = np.pad(y, 1, mode='reflect')
    lap = 4 * p[1:-1, 1:-1] - p[0:-2, 1:-1] - p[2:, 1:-1] - p[1:-1, 0:-2] - p[1:-1, 2:]
    return float(np.abs(lap).mean())


def psnr(a, b):
    d = (a - b) ** 2
    mse = d.mean()
    return 10 * math.log10(MAXO * MAXO / mse) if mse > 0 else float('inf')


def edge_mask(y, thr=60.0):
    p = np.pad(y, 1, mode='reflect')
    gx = (p[0:-2, 2:] + 2 * p[1:-1, 2:] + p[2:, 2:]) - (p[0:-2, 0:-2] + 2 * p[1:-1, 0:-2] + p[2:, 0:-2])
    gy = (p[2:, 0:-2] + 2 * p[2:, 1:-1] + p[2:, 2:]) - (p[0:-2, 0:-2] + 2 * p[0:-2, 1:-1] + p[0:-2, 2:])
    return np.hypot(gx, gy) > thr


def main():
    for f in ('sharpen_out.txt', 'exp_img.hex', 'sharpen_in.hex'):
        if not os.path.exists(f):
            raise SystemExit(f'缺少 {f}——请先跑：python make_sharpen_data.py --img && vvp tb_i.vvp')

    rtl = load_hex('sharpen_out.txt')
    exp = load_hex('exp_img.hex')
    src = load_hex('sharpen_in.hex')
    ok = True

    print('========================================')
    print(f'RTL 输出 {len(rtl)} 像素，Python golden {len(exp)} 像素')

    # ---------------- 判据 1：位级全等 ----------------
    n = min(len(rtl), len(exp))
    bad = [i for i in range(n) if rtl[i] != exp[i]]
    print(f'[判据1] RTL vs Python golden 位级比对：'
          f'{"全等（0 误差）" if not bad else f"{len(bad)} 个像素不一致 [FAIL]"}')
    if bad:
        ok = False
        i = bad[0]
        print(f'  首个不一致 #{i} ({i//W},{i%W}): rtl={rtl[i]:06X} exp={exp[i]:06X}')

    a_src = unpack24(src[:n])
    a_rtl = unpack24(rtl[:n])
    y_src, y_rtl = luma(a_src), luma(a_rtl)

    # ---------------- 判据 2：锐度提升 ----------------
    tg0, tg1 = tenengrad(y_src), tenengrad(y_rtl)
    lp0, lp1 = lap_energy(y_src), lap_energy(y_rtl)
    print('----------------------------------------')
    print(f'[判据2] 锐度（8bit 域）：Tenengrad  {tg0:7.3f} → {tg1:7.3f}  '
          f'(+{(tg1/tg0-1)*100:.1f}%)')
    print(f'                       |Laplacian| {lp0:7.3f} → {lp1:7.3f}  '
          f'(+{(lp1/lp0-1)*100:.1f}%)')
    if not (tg1 > tg0 and lp1 > lp0):
        ok = False
        print('  [FAIL] 锐化后高频能量未上升（核实现可疑）')

    # ---------------- 判据 3：改动强度 PSNR ----------------
    p = psnr(a_src, a_rtl)
    print(f'[判据3] PSNR(原图, 锐化图) = {p:.2f} dB（锐化必然低于 ∞，越小＝改动越大）')

    # ---------------- 边缘区专项（锐化的作用区）----------------
    em = edge_mask(y_src)
    if em.any():
        d = np.abs(a_rtl - a_src)
        print(f'[边缘区] 强边缘像素占比 {em.mean()*100:.1f}%，'
              f'该区平均 |Δ| = {d[em].mean():.2f} vs 全图 {d.mean():.2f}'
              f'（锐化主要作用在边缘）')

    # ---------------- 判据 4：对比图 + 局部放大 ----------------
    # 选边缘最密的一块做放大（16×16 检视窗，放大 8×）
    bw = 16
    best, bxy = -1, (0, 0)
    for yy in range(0, H - bw + 1, 4):
        for xx in range(0, W - bw + 1, 4):
            s = em[yy:yy + bw, xx:xx + bw].sum()
            if s > best:
                best, bxy = s, (xx, yy)
    xx, yy = bxy
    sc, gap, top = 3, 8, 30
    dw, dh = W * sc, H * sc
    zsc = 8
    zw, zh = bw * zsc, bw * zsc
    cv = Image.new('RGB', (dw * 2 + gap * 3 + zw + gap, max(dh, zh) + top + 10), (24, 24, 30))
    dr = ImageDraw.Draw(cv)
    for i, (im, t) in enumerate([(a_src, '原图（Gamma 出，未锐化）'),
                                 (a_rtl, f'锐化输出（RTL, k=0.5）  TG +{(tg1/tg0-1)*100:.0f}%')]):
        x = gap + i * (dw + gap)
        cv.paste(to_img(im).resize((dw, dh), Image.NEAREST), (x, top))
        dr.text((x, 6), t, font=font(15), fill=(255, 255, 255))
        # 在整图上框出放大区
        dr.rectangle([x + xx * sc, top + yy * sc, x + (xx + bw) * sc, top + (yy + bw) * sc],
                     outline=(255, 80, 60), width=2)
    zx = gap * 3 + dw * 2
    crop = a_rtl[yy:yy + bw, xx:xx + bw]
    cv.paste(to_img(crop).resize((zw, zh), Image.NEAREST), (zx, top))
    dr.text((zx, 6), f'放大 {bw}×{bw}（锐化，框内）', font=font(15), fill=(255, 255, 255))
    cv.save('sharpen_compare.png')
    print('对比图：sharpen_compare.png（原图 | 锐化 | 边缘放大）')

    print('========================================')
    print('[PASS] Sharpen 独立校验全部通过' if ok else '[FAIL] 见上方不一致项')


if __name__ == '__main__':
    main()
