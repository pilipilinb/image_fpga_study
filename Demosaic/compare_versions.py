#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# compare_versions.py —— 双线性 vs MHC 两版去马赛克对比（Demosaic 工程）
#
# 干什么：
#   1. 算两版各自的 PSNR（vs 原图对应区域）—— 谁更接近原图
#   2. 算两版之间的差异（PSNR / 平均绝对差 / 最大差 / 有多少像素不一样）
#   3. 拼一张四宫格对比图：原图 | 双线性 | MHC | 两版差异图（放大 4 倍看）
#
# 用法：python compare_versions.py
#   前置：先跑两次仿真生成两个输出文件
#     iverilog -I . -o tb.vvp tb_demosaic.v;                vvp tb.vvp     → output.coe（双线性）
#     iverilog -DMHC -I . -o tb_mhc.vvp tb_demosaic.v;      vvp tb_mhc.vvp → output_mhc.coe（MHC）
import math
from PIL import Image, ImageDraw, ImageFont

W, H = 112, 103
MW, MH = W - 4, H - 4     # 108×99

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


def load_coe(path):
    out = []
    for l in open(path):
        l = l.strip().rstrip(',')
        if l and all(c in '0123456789abcdefABCDEF' for c in l):
            out.append(int(l, 16))
    return out


def ch(px, k):
    return (px >> k) & 0xFF


def psnr(a, b):
    mse = sum((ch(x, 16) - ch(y, 16)) ** 2 + (ch(x, 8) - ch(y, 8)) ** 2 + (ch(x, 0) - ch(y, 0)) ** 2
              for x, y in zip(a, b)) / (len(a) * 3)
    return 10 * math.log10(255 * 255 / mse) if mse > 0 else float('inf')


def to_img(px, w, h):
    img = Image.new('RGB', (w, h))
    img.putdata([(ch(p, 16), ch(p, 8), ch(p, 0)) for p in px])
    return img


def main():
    bl  = load_coe('output.coe')          # 双线性版
    mhc = load_coe('output_mhc.coe')      # MHC 版
    orig = load_hex('input.hex')
    if len(bl) != MW * MH or len(mhc) != MW * MH:
        raise SystemExit(f'错误: 输出尺寸不对（双线性={len(bl)} MHC={len(mhc)}，期望 {MW*MH}）')

    # 原图对应区域（去掉四周 2 圈）
    orig_in = [orig[(r + 2) * W + (c + 2)] for r in range(MH) for c in range(MW)]

    # 1. 两版各自 vs 原图
    p_bl, p_mhc = psnr(bl, orig_in), psnr(mhc, orig_in)
    # 2. 两版互相差异
    p_diff = psnr(bl, mhc)
    diff_cnt = sum(1 for a, b in zip(bl, mhc) if a != b)
    abs_sum = 0
    max_d = 0
    for a, b in zip(bl, mhc):
        for k in (16, 8, 0):
            d = abs(ch(a, k) - ch(b, k))
            abs_sum += d
            if d > max_d:
                max_d = d
    mean_abs = abs_sum / (len(bl) * 3)

    print('========================================')
    print(f'双线性 vs 原图 : PSNR = {p_bl:.2f} dB')
    print(f'MHC    vs 原图 : PSNR = {p_mhc:.2f} dB   （差 {p_mhc - p_bl:+.2f} dB，正数说明 MHC 更接近原图）')
    print(f'两版互相差异   : PSNR = {p_diff:.2f} dB，'
          f'不同像素 {diff_cnt}/{len(bl)}（{diff_cnt*100.0/len(bl):.1f}%），'
          f'平均绝对差 {mean_abs:.2f} LSB，最大差 {max_d} LSB')
    print('========================================')

    # 3. 四宫格对比图：原图 | 双线性 | MHC | 差异图（放大4倍）
    dw, dh = MW * 2, MH * 2
    gap, top = 8, 30
    canvas = Image.new('RGB', (dw * 4 + gap * 5, dh + top + 10), (24, 24, 30))
    draw = ImageDraw.Draw(canvas)

    # 差异图：|MHC − 双线性| ×4 放大（不然看不清），灰度显示
    diff_px = []
    for a, b in zip(bl, mhc):
        d = max(abs(ch(a, 16) - ch(b, 16)), abs(ch(a, 8) - ch(b, 8)), abs(ch(a, 0) - ch(b, 0)))
        v = min(255, d * 4)
        diff_px.append((v << 16) | (v << 8) | v)

    labels = ['原图（对应区域）', '双线性版', 'MHC 版（带细节校正）', '两版差异 ×4（越亮差越大）']
    imgs = [to_img(orig_in, MW, MH).resize((dw, dh), Image.BILINEAR),
            to_img(bl, MW, MH).resize((dw, dh), Image.BILINEAR),
            to_img(mhc, MW, MH).resize((dw, dh), Image.BILINEAR),
            to_img(diff_px, MW, MH).resize((dw, dh), Image.NEAREST)]
    subs = [f'PSNR {p_bl:.2f} dB', f'PSNR {p_mhc:.2f} dB', f'两版互差 {p_diff:.2f} dB', '']
    for i, (im, t) in enumerate(zip(imgs, labels)):
        x = gap + i * (dw + gap)
        canvas.paste(im, (x, top))
        draw.text((x, 6), t, font=font(15), fill=(255, 255, 255))
        if subs[i]:
            draw.text((x, top + dh + 4), subs[i], font=font(13), fill=(150, 230, 150))
    canvas.save('demosaic_bl_vs_mhc.png')
    print('对比图已保存: demosaic_bl_vs_mhc.png（原图 | 双线性 | MHC | 差异×4）')


if __name__ == '__main__':
    main()