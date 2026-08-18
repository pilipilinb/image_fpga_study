#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# compare_grid.py —— 三滤波器 × 两噪声 滤波结果拼图（MedianFilter 工程，W4）
#
# 用法：python compare_grid.py   （在 MedianFilter/ 目录下运行）
#
# 输出图 median_3way_compare.png 布局（3 行 × 3 列）：
#   列：原图 | 椒盐噪声图(p=0.10) | 高斯噪声图(σ=40)
#   行：均值滤波 | 高斯滤波 | 中值滤波（该滤波器在该噪声下的滤波输出）
# 每幅图下方标注 PSNR（滤波输出 vs 原图内部区域，自动重算不硬编码）
#   椒盐列/高斯列顶部即噪声度（13.96 dB / 17.56 dB），与滤波后对比直观
#
# 输入依赖（6 份滤波输出 + 3 份参考）：
#   参考：input.hex（原图）、salt_pepper.hex、noise.hex（当前目录）
#   滤波：../MeanFilter/output_salt_mean.coe、../MeanFilter/output.coe
#         ../GaussianFilter/output_salt_gaussian.coe、../GaussianFilter/output.coe
#         output_salt_median.coe、output.coe（当前目录）
# 依赖：Pillow（pip install pillow）
import math
from PIL import Image, ImageDraw, ImageFont

W, H = 112, 103          # 原图尺寸
CW, CH = W - 2, H - 2    # crop 滤波输出尺寸 (110×101)

FONTS = [
    r'C:\Windows\Fonts\msyh.ttc',    # 微软雅黑
    r'C:\Windows\Fonts\simhei.ttf',  # 黑体
    r'C:\Windows\Fonts\simsun.ttc',  # 宋体
]


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
    vals = []
    for l in open(path):
        l = l.strip().rstrip(',')
        if l and all(c in '0123456789abcdefABCDEF' for c in l):
            vals.append(int(l, 16))
    return vals


def psnr(a, b):
    mse_sum = 0
    for x, y in zip(a, b):
        mse_sum += ((x >> 16 & 0xFF) - (y >> 16 & 0xFF)) ** 2
        mse_sum += ((x >> 8 & 0xFF) - (y >> 8 & 0xFF)) ** 2
        mse_sum += ((x & 0xFF) - (y & 0xFF)) ** 2
    mse = mse_sum / (len(a) * 3)
    return 10 * math.log10(255 * 255 / mse) if mse > 0 else float('inf')


def to_img(px, w, h):
    img = Image.new('RGB', (w, h))
    img.putdata([((p >> 16) & 0xFF, (p >> 8) & 0xFF, p & 0xFF) for p in px])
    return img


def main():
    # ---- 读参考 ----
    orig  = load_hex('input.hex')
    salt  = load_hex('salt_pepper.hex')
    gauss = load_hex('noise.hex')

    # ---- 读 6 份滤波输出（crop 版，均 110×101）----
    filt = {
        ('mean', 'salt'):  load_coe('../MeanFilter/output_salt_mean.coe'),
        ('mean', 'gauss'): load_coe('../MeanFilter/output.coe'),
        ('gaussian', 'salt'):  load_coe('../GaussianFilter/output_salt_gaussian.coe'),
        ('gaussian', 'gauss'): load_coe('../GaussianFilter/output.coe'),
        ('median', 'salt'):  load_coe('output_salt_median.coe'),
        ('median', 'gauss'): load_coe('output.coe'),
    }
    for k, v in filt.items():
        if len(v) != CW * CH:
            raise SystemExit(f'错误: {k} 输出 {len(v)} 像素，期望 {CW}x{CH}')

    # ---- 原图内部区域（crop 对齐参考，与 noise_add.py --compare 同法）----
    # 滤波输出第 k 个 = 右下角 (wr,wc) 窗口的均值/中值，代表窗口中心 (wr-1,wc-1)
    # wr ∈ [2, H-1]（H-2 个）、wc ∈ [2, W-1]（W-2 个）→ 共 (H-2)*(W-2) 与输出严格对齐；
    # 缩成 range(2, H-1) 会少一行一列且错位 → PSNR 虚低（本脚本踩过的坑）
    center = [orig[(r - 1) * W + (c - 1)]
              for r in range(2, H)
              for c in range(2, W)]

    # ---- 拼图：3 行（滤波器）× 3 列（原图/椒盐/高斯）----
    M, T, B, PS = 16, 26, 22, 8        # 边距/标题条/PSNR条/行距
    col_w = W + 2
    x0 = M + 78                        # 行名栏宽度（子图起始 x）
    canvas_w = x0 + col_w * 3 + M      # 注意：宽度从 x0 起算，漏加行名栏会裁掉第三列！
    row_h = T + H + PS + B
    canvas_h = 6 + row_h * 3 + 6
    canvas = Image.new('RGB', (canvas_w, canvas_h), (24, 24, 30))
    draw = ImageDraw.Draw(canvas)
    f_title = font(15)
    f_psnr = font(13)

    # 列标题（与图 x 同偏移 x0）
    for j, t in enumerate(['原图', '椒盐噪声图  p=0.10', '高斯噪声图  σ=40']):
        draw.text((x0 + j * col_w, 4), t, font=f_title, fill=(255, 255, 255))

    # 每行：行标题 + 3 幅图（原图 / 椒盐滤波 / 高斯滤波）+ PSNR
    rows = [('均值滤波', ('mean',)), ('高斯滤波', ('gaussian',)), ('中值滤波', ('median',))]
    for i, (rname, key) in enumerate(rows):
        y0 = 6 + i * row_h
        # 行标题（左侧）
        draw.text((M, y0 + T + 18), rname, font=f_title, fill=(255, 210, 90))
        for j in range(3):
            x = x0 + j * col_w
            if j == 0:
                img = to_img(orig, W, H)
                tag = '—'
            elif j == 1:
                img = to_img(filt[key + ('salt',)], CW, CH).resize((W, H), Image.BILINEAR)
                tag = f'{psnr(filt[key + ("salt",)], center):.2f} dB'
            else:
                img = to_img(filt[key + ('gauss',)], CW, CH).resize((W, H), Image.BILINEAR)
                tag = f'{psnr(filt[key + ("gauss",)], center):.2f} dB'
            canvas.paste(img, (x, y0 + T))
            draw.text((x, y0 + T + H + 4), tag, font=f_psnr, fill=(150, 230, 150))

    # 脚注
    draw.text((M + 78, canvas_h - 24),
              '每格下方 PSNR = 该滤波输出 vs 原图（内部区域）；噪声列顶部即噪声度',
              font=font(12), fill=(170, 170, 180))

    out = 'median_3way_compare.png'
    canvas.save(out)
    print(f'OK: 拼图已保存 {out}（3 滤波器 × 椒盐/高斯，含 PSNR 标注）')


if __name__ == '__main__':
    main()