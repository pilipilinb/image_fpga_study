#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# verify_demosaic.py —— 独立校验 RTL 去马赛克输出（Demosaic 工程）
#
# 干什么：
#   1. 把 RTL 仿真输出（output.coe）和 Python 参考（ref_rgb.hex）逐像素比对
#      —— 两边用的是同一套整数公式，所以期望是"完全相等（0 误差）"
#   2. 算一下去马赛克结果 vs 原图的 PSNR（这个只作参考：Bayer 采样本身就丢了
#      2/3 的彩色信息，PSNR 不可能很高，别把它当"正确性"指标）
#   3. 拼一张对比图：原图 | Python 参考 | RTL 输出（三张都放大到同尺寸看）
#
# 用法：python verify_demosaic.py      （先跑完 tb_demosaic.v 生成 output.coe）
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
    return 10 * __import__('math').log10(255 * 255 / mse) if mse > 0 else float('inf')


def to_img(px, w, h):
    img = Image.new('RGB', (w, h))
    img.putdata([(ch(p, 16), ch(p, 8), ch(p, 0)) for p in px])
    return img


def main():
    rtl = load_coe('output.coe')
    ref = load_hex('ref_rgb.hex')
    if len(rtl) != MW * MH or len(ref) != MW * MH:
        raise SystemExit(f'错误: RTL={len(rtl)} 参考={len(ref)}，期望 {MW}×{MH}={MW*MH}')

    # 1. 逐像素全等比对（这是正确性判据）
    diff_cnt = 0
    first_diff = None
    for i, (a, b) in enumerate(zip(rtl, ref)):
        if a != b:
            diff_cnt += 1
            if first_diff is None:
                first_diff = (i, a, b)
    print('========================================')
    if diff_cnt == 0:
        print(f'[PASS] RTL 与 Python 参考逐像素全等：{len(rtl)} 像素，0 误差')
    else:
        i, a, b = first_diff
        print(f'[FAIL] 差异 {diff_cnt}/{len(rtl)} 个像素；首个差异 #{i}（行{i//MW} 列{i%MW}）：'
              f'RTL={a:06X} 参考={b:06X}')

    # 2. 与原图的 PSNR（仅作参考量）
    orig = load_hex('input.hex')
    orig_in = [orig[(r + 2) * W + (c + 2)] for r in range(MH) for c in range(MW)]  # 原图对应区域
    print(f'参考去马赛克 vs 原图: PSNR = {psnr(ref, orig_in):.2f} dB（CFA 采样本身有损，仅供参考）')
    print('========================================')

    # 3. 对比图：原图 | Python 参考 | RTL 输出（统一放大 2 倍便于看）
    gap, top = 8, 30
    dw, dh = MW * 2, MH * 2
    cw = dw * 3 + gap * 4
    canvas = Image.new('RGB', (cw, dh + top + 10), (24, 24, 30))
    draw = ImageDraw.Draw(canvas)
    labels = ['原图（对应区域，放大2倍）', 'Python 参考去马赛克', 'RTL 去马赛克输出']
    imgs = [to_img(orig_in, MW, MH).resize((dw, dh), Image.BILINEAR),
            to_img(ref, MW, MH).resize((dw, dh), Image.BILINEAR),
            to_img(rtl, MW, MH).resize((dw, dh), Image.BILINEAR)]
    for i, (im, t) in enumerate(zip(imgs, labels)):
        x = gap + i * (dw + gap)
        canvas.paste(im, (x, top))
        draw.text((x, 6), t, font=font(15), fill=(255, 255, 255))
    canvas.save('demosaic_rtl_compare.png')
    print('对比图已保存: demosaic_rtl_compare.png（原图 | 参考 | RTL）')


if __name__ == '__main__':
    main()