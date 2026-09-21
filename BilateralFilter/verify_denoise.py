#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_denoise.py —— M4 双边降噪独立校验（第二判据）

干什么（四步）：
  1. 位级全等：读 RTL 输出 denoise_out.txt 与 Python golden（exp_img.hex）逐像素比对
  2. PSNR：注噪图 / 高斯参考 / RTL 双边  vs 无噪基准（10bit 域，MAX=1023）
  3. SSIM：同上三方（按 luma 折算灰度，11×11 高斯窗 σ=1.5）——**保边能力的量化证据**
  4. 边缘区专项：用 Sobel 梯度选出强边缘像素，单独统计该子集的 PSNR/SSIM
     （双边的价值不在平坦区，而在"降噪同时不糊边"——必须分区域看）
  5. 四宫格对比图：注噪 | 高斯 | 双边(RTL) | 无噪基准

用法：python verify_denoise.py      （需先在 BilateralFilter/ 跑过 vvp tb_i.vvp）
"""
import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFont

W, H = 112, 103
MAXV = 1023
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


def unpack(px):
    """30bit 打包 → (H,W,3) float 数组"""
    a = np.array(px, dtype=np.int64)
    r = (a >> 20) & MAXV
    g = (a >> 10) & MAXV
    b = a & MAXV
    return np.stack([r, g, b], axis=1).reshape(H, W, 3).astype(np.float64)


def psnr(a, b, mask=None):
    """a/b: (H,W,3)。mask 可选（bool (H,W)），只统计该区域"""
    d = (a - b) ** 2
    if mask is not None:
        d = d[mask]
    mse = d.mean()
    return 10 * math.log10(MAXV * MAXV / mse) if mse > 0 else float('inf')


def gauss_kernel(n=11, sigma=1.5):
    x = np.arange(n) - (n - 1) / 2.0
    k = np.exp(-(x ** 2) / (2 * sigma * sigma))
    k /= k.sum()
    return k


def conv_sep(img, k):
    """可分离卷积（reflect 边界），img: 2D"""
    n = len(k)
    pad = n // 2
    p = np.pad(img, pad, mode='reflect')
    tmp = np.zeros_like(img)
    for i, kv in enumerate(k):                      # 水平
        tmp += kv * p[pad:pad + img.shape[0], i:i + img.shape[1]]
    out = np.zeros_like(img)
    p2 = np.pad(tmp, pad, mode='reflect')
    for i, kv in enumerate(k):                      # 垂直
        out += kv * p2[i:i + img.shape[0], pad:pad + img.shape[1]]
    return out


def ssim_map_luma(a, b):
    """a/b: (H,W,3) → 按 luma 折算后的 SSIM 图（11×11 高斯窗 σ=1.5）"""
    lw = np.array([0.299, 0.587, 0.114])
    x = a @ lw
    y = b @ lw
    k = gauss_kernel()
    mx, my = conv_sep(x, k), conv_sep(y, k)
    mxx, myy, mxy = conv_sep(x * x, k), conv_sep(y * y, k), conv_sep(x * y, k)
    vx = mxx - mx * mx
    vy = myy - my * my
    vxy = mxy - mx * my
    C1 = (0.01 * MAXV) ** 2
    C2 = (0.03 * MAXV) ** 2
    return ((2 * mx * my + C1) * (2 * vxy + C2)) / ((mx * mx + my * my + C1) * (vx + vy + C2))


def ssim_luma(a, b, mask=None):
    """全图 SSIM；mask 给定时只统计该区域（边缘区专项）"""
    m = ssim_map_luma(a, b)
    return float(m[mask].mean()) if mask is not None else float(m.mean())


def edge_mask(a, thr=120.0):
    """Sobel 梯度幅值 > thr 的像素（强边缘子集）——双边 vs 高斯的分水岭"""
    lw = np.array([0.299, 0.587, 0.114])
    y = a @ lw
    p = np.pad(y, 1, mode='reflect')
    gx = (p[0:-2, 2:] + 2 * p[1:-1, 2:] + p[2:, 2:]) - (p[0:-2, 0:-2] + 2 * p[1:-1, 0:-2] + p[2:, 0:-2])
    gy = (p[2:, 0:-2] + 2 * p[2:, 1:-1] + p[2:, 2:]) - (p[0:-2, 0:-2] + 2 * p[0:-2, 1:-1] + p[0:-2, 2:])
    return np.hypot(gx, gy) > thr


def to_img(a):
    """(H,W,3) 10bit → PIL RGB（>>2 折 8bit 显示）"""
    u8 = np.clip(a / 4.0, 0, 255).astype(np.uint8)
    return Image.fromarray(u8, 'RGB')


def main():
    for f in ('denoise_out.txt', 'exp_img.hex', 'denoise_in.hex', 'clean_rgb.hex', 'gauss_ref.hex'):
        if not os.path.exists(f):
            raise SystemExit(f'缺少 {f}——请先跑：python make_denoise_data.py --img  &&  vvp tb_i.vvp')

    rtl = load_hex('denoise_out.txt')
    exp = load_hex('exp_img.hex')
    noisy = unpack(load_hex('denoise_in.hex'))
    clean = unpack(load_hex('clean_rgb.hex'))
    gauss = unpack(load_hex('gauss_ref.hex'))

    print('========================================')
    print(f'RTL 输出 {len(rtl)} 像素，Python golden {len(exp)} 像素')
    n = min(len(rtl), len(exp))
    bad = sum(1 for i in range(n) if rtl[i] != exp[i])
    print(f'[判据1] RTL vs Python golden 位级比对：{"全等（0 误差）" if bad == 0 else f"{bad} 个像素不一致 [FAIL]"}')
    if bad:
        for i in range(n):
            if rtl[i] != exp[i]:
                print(f'  首个不一致 #{i} ({i//W},{i%W}): rtl={rtl[i]:08X} exp={exp[i]:08X}')
                break
    rtl_a = unpack(rtl[:n])

    # ---- 指标 ----
    em = edge_mask(clean)
    rows = []
    for name, img in (('注噪图', noisy), ('高斯降噪', gauss), ('双边降噪(RTL)', rtl_a)):
        rows.append((name, psnr(img, clean), ssim_luma(img, clean),
                     psnr(img, clean, em) if em.any() else float('nan'),
                     ssim_luma(img, clean, em) if em.any() else float('nan')))

    print('----------------------------------------')
    print(f'{"":16s} {"PSNR(dB)":>9s} {"SSIM":>8s} │ {"边缘区PSNR":>10s} {"边缘区SSIM":>10s}')
    for name, p, s, pe, se in rows:
        print(f'{name:16s} {p:9.2f} {s:8.4f} │ {pe:10.2f} {se:10.4f}')
    print('----------------------------------------')
    print('说明：平坦区高斯平均更强（PSNR 高）；边缘区双边的优势体现在 SSIM 与边缘区 PSNR')
    print('      上——"降噪同时不糊边"正是双边值域核（差异大的邻居权重→0）的作用')
    print(f'边缘像素占比 {em.mean()*100:.1f}%（Sobel 幅值 > 120）')
    print('========================================')

    # ---- 四宫格 ----
    gap, top = 8, 30
    dw, dh = W * 2, H * 2
    canvas = Image.new('RGB', (dw * 4 + gap * 5, dh + top + 10), (24, 24, 30))
    draw = ImageDraw.Draw(canvas)
    items = [(noisy, f'注噪 σ=48  {rows[0][1]:.2f}dB'),
             (gauss, f'高斯降噪  {rows[1][1]:.2f}dB / SSIM {rows[1][2]:.3f}'),
             (rtl_a, f'双边降噪(RTL)  {rows[2][1]:.2f}dB / SSIM {rows[2][2]:.3f}'),
             (clean, '无噪基准（参考）')]
    for i, (img, t) in enumerate(items):
        x = gap + i * (dw + gap)
        canvas.paste(to_img(img).resize((dw, dh), Image.NEAREST), (x, top))
        draw.text((x, 6), t, font=font(15), fill=(255, 255, 255))
    canvas.save('denoise_compare.png')
    print('对比图已保存: denoise_compare.png（注噪 | 高斯 | 双边 | 无噪）')


if __name__ == '__main__':
    main()
