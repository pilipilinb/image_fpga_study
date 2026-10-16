#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# noise_add.py —— 给输入图像加高斯噪声，并对比高斯滤波前后效果（GaussianFilter 工程，复用均值去噪脚本）
#
# 用法：
#   1. 生成噪声仿真输入（读 input.hex → 高斯噪声 → noise.hex + noise_preview.png）：
#      python noise_add.py --sigma 20
#   2. 仿真后拼对比图（原图 | 噪声图 | 滤波后）+ PSNR 去噪量化：
#      python noise_add.py --compare --out-coe output.coe
#
# 说明：
#   - 输入/输出都是 24bit RGB888 hex（每行一个像素，R 最高字节）
#   - 高斯噪声：每个通道独立加 N(0, sigma)，四舍五入后钳到 [0,255]
#   - PSNR：噪声图 vs 原图（噪声水平）、滤波后 vs 原图（去噪恢复度）
#     滤波后 PSNR 明显高于噪声图 PSNR，即证明均值滤波抑制了高斯噪声
#   - 依赖：仅 Python 标准库 + Pillow（pip install pillow）
import argparse
import math
import random
from PIL import Image


def load_hex(path):
    """读 hex：每行一个 24bit 值"""
    px = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                px.append(int(line, 16))
    return px


def save_hex(px, path):
    """写 hex：每行一个 24bit 值（%06X，R 最高字节）"""
    with open(path, 'w') as f:
        for p in px:
            f.write(f'{p:06X}\n')


def add_gaussian(px, sigma):
    """每通道独立加高斯噪声 N(0, sigma)，四舍五入后钳到 [0,255]"""
    out = []
    for p in px:
        r = (p >> 16) & 0xFF
        g = (p >> 8) & 0xFF
        b = p & 0xFF
        r = min(255, max(0, round(r + random.gauss(0, sigma))))
        g = min(255, max(0, round(g + random.gauss(0, sigma))))
        b = min(255, max(0, round(b + random.gauss(0, sigma))))
        out.append((r << 16) | (g << 8) | b)
    return out


def add_salt_pepper(px, prob):
    """椒盐噪声：每个像素以概率 prob 变极端值（三通道同时变，
    一半概率置 255 白点/盐，一半概率置 0 黑点/椒）
    中值滤波的专属靶子——极值像素在 3×3 窗口内少于 5 个时，
    中值输出必为真实像素，直接剔除脉冲"""
    out = []
    for p in px:
        if random.random() < prob:
            v = 0xFFFFFF if random.random() < 0.5 else 0x000000
            out.append(v)
        else:
            out.append(p)
    return out


def pix_diff(a, b):
    """两像素 24bit 的三通道平方误差和"""
    return ((a >> 16 & 0xFF) - (b >> 16 & 0xFF)) ** 2 + \
           ((a >> 8 & 0xFF) - (b >> 8 & 0xFF)) ** 2 + \
           ((a & 0xFF) - (b & 0xFF)) ** 2


def psnr(a, b):
    """两幅 24bit 图像的 PSNR"""
    mse = sum(pix_diff(x, y) for x, y in zip(a, b)) / (len(a) * 3)
    return 10 * math.log10(255 * 255 / mse) if mse > 0 else float('inf')


def preview(px, path, w, h):
    """像素列表 → PNG"""
    img = Image.new('RGB', (w, h))
    img.putdata([((p >> 16) & 0xFF, (p >> 8) & 0xFF, p & 0xFF) for p in px])
    img.save(path)


def main():
    ap = argparse.ArgumentParser(description='噪声（高斯/椒盐）+ 滤波前后对比（复用于均值/高斯/中值工程）')
    ap.add_argument('--in-hex', default='input.hex', help='原图 hex（默认 input.hex）')
    ap.add_argument('--out-hex', default='noise.hex', help='噪声图 hex 输出（默认 noise.hex；椒盐建议 salt_pepper.hex）')
    ap.add_argument('--sigma', type=int, default=20, help='高斯噪声标准差（默认 20）')
    ap.add_argument('--salt', type=float, default=0.0, help='椒盐噪声概率（>0 启用椒盐模式，如 0.10 = 10% 像素变 0/255）')
    ap.add_argument('--w', type=int, default=112, help='图像宽')
    ap.add_argument('--h', type=int, default=103, help='图像高')
    ap.add_argument('--compare', action='store_true', help='对比模式：拼 原图|噪声|滤波后 图 + PSNR')
    ap.add_argument('--full', action='store_true', help='滤波输出为全尺寸（pad 版，H×W，直接逐像素比）')
    ap.add_argument('--out-coe', default='output.coe', help='仿真输出 COE（对比模式用）')
    ap.add_argument('--png', default='median_filter_compare.png', help='对比图输出路径')
    args = ap.parse_args()

    if args.compare:
        # ---- 对比模式：原图 | 噪声图 | 滤波后 ----
        orig = load_hex(args.in_hex)
        noise = load_hex(args.out_hex)
        # 读仿真输出 COE（跳过 header/逗号，与 make_tb_input.parse_coe 同规则）
        filt = []
        with open(args.out_coe) as f:
            for line in f:
                line = line.strip().rstrip(',')
                if line and all(c in '0123456789abcdefABCDEF' for c in line):
                    filt.append(int(line, 16))
        # 尺寸校验：crop 版 (H-2)*(W-2)，pad 版 H*W 全尺寸
        if args.full:
            expect_f = args.w * args.h
        else:
            expect_f = (args.w - 2) * (args.h - 2)
        if len(filt) != expect_f:
            raise SystemExit(f'错误: 滤波输出 {len(filt)} 像素，期望 {expect_f}')

        # PSNR 量化：噪声图 vs 原图（噪声水平）、滤波后 vs 原图（去噪恢复）
        psnr_noise = psnr(orig, noise)
        if args.full:
            # pad 版：全尺寸输出，与原图直接逐像素比（边缘 replicate 已处理）
            psnr_filt = psnr(orig, filt)
        else:
            # crop 版：滤波输出第 k 个 = 右下角 (wr,wc) 窗口的均值，代表窗口中心 (wr-1,wc-1)
            center = []
            for idx in range(len(filt)):
                wr = idx // (args.w - 2) + 2
                wc = idx % (args.w - 2) + 2
                center.append(orig[(wr - 1) * args.w + (wc - 1)])
            psnr_filt = psnr(center, filt)

        # 拼图：三幅并排（原图 | 噪声图 | 滤波后），高度对齐
        # pad 版滤波输出已是全尺寸；crop 版放大回全尺寸便于并排
        canvas = Image.new('RGB', (args.w * 3, args.h), (0, 0, 0))
        img_orig = Image.new('RGB', (args.w, args.h))
        img_orig.putdata([((p >> 16) & 0xFF, (p >> 8) & 0xFF, p & 0xFF) for p in orig])
        img_noise = Image.new('RGB', (args.w, args.h))
        img_noise.putdata([((p >> 16) & 0xFF, (p >> 8) & 0xFF, p & 0xFF) for p in noise])
        if args.full:
            img_filt = Image.new('RGB', (args.w, args.h))
            img_filt.putdata([((p >> 16) & 0xFF, (p >> 8) & 0xFF, p & 0xFF) for p in filt])
        else:
            img_filt = Image.new('RGB', (args.w - 2, args.h - 2))
            img_filt.putdata([((p >> 16) & 0xFF, (p >> 8) & 0xFF, p & 0xFF) for p in filt])
            img_filt = img_filt.resize((args.w, args.h), Image.BILINEAR)
        canvas.paste(img_orig, (0, 0))
        canvas.paste(img_noise, (args.w, 0))
        canvas.paste(img_filt, (args.w * 2, 0))
        canvas.save(args.png)

        mode = 'pad 全尺寸' if args.full else 'crop（中心对齐）'
        noise_tag = f'椒盐 p={args.salt:.2f}' if args.salt > 0 else f'高斯 σ={args.sigma}'
        print('========================================')
        print(f'[{mode}] 噪声图 vs 原图 : PSNR = {psnr_noise:.2f} dB（噪声水平，{noise_tag}）')
        print(f'[{mode}] 滤波后 vs 原图 : PSNR = {psnr_filt:.2f} dB（去噪恢复度）')
        print(f'PSNR 提升: {psnr_filt - psnr_noise:+.2f} dB')
        print(f'对比图已保存: {args.png}（左=原图 | 中=噪声图 | 右=滤波后）')
        print('========================================')
    else:
        # ---- 噪声生成模式：原图 hex → 高斯或椒盐噪声 hex + 预览图 ----
        orig = load_hex(args.in_hex)
        if len(orig) != args.w * args.h:
            raise SystemExit(f'错误: 原图 {len(orig)} 像素，期望 {args.w}x{args.h}')
        if args.salt > 0:
            noisy = add_salt_pepper(orig, args.salt)
            tag = f'椒盐噪声 p={args.salt:.2f}'
        else:
            noisy = add_gaussian(orig, args.sigma)
            tag = f'高斯噪声 sigma={args.sigma}'
        save_hex(noisy, args.out_hex)
        preview(noisy, 'noise_preview.png', args.w, args.h)
        psnr_noise = psnr(orig, noisy)
        print(f'OK: {args.in_hex} → {args.out_hex}（{tag}）')
        print(f'噪声图 vs 原图 PSNR = {psnr_noise:.2f} dB')
        print(f'预览图已保存: noise_preview.png')
        print('下一步: iverilog -DNOISE -I . -o tb.vvp tb_median_filter.v → vvp → python noise_add.py --compare')


if __name__ == '__main__':
    main()