#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# verify_dpc.py —— 独立校验 DPC 输出（DPC 工程）
#
# 干什么：
#   1. RTL 输出（output.coe）vs Python 参考（ref_dpc.hex）逐像素比对 —— 应完全相等
#   2. 用 RTL 的输出算效果指标（证明硬件和 Python 参考同样有效）：
#        · 坏点图 vs 干净图 PSNR（坏点伤害了多少）
#        · 校正后 vs 干净图 PSNR（修回来多少）
#        · 修复率：注入的坏点里有多少被改掉
#        · 误伤率：干净的图过一遍 DPC，有多少正常像素被误改
#   3. 拼对比图：干净 | 带坏点 | RTL 校正后（都灰度显示，坏点一眼能看出来）
#
# 用法：python verify_dpc.py   （前置：跑完 tb_dpc.v，生成 output.coe / output_clean.coe）
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


def load_hex8(path):
    return [int(l.strip(), 16) for l in open(path) if l.strip()]


def load_coe8(path):
    out = []
    for l in open(path):
        l = l.strip().rstrip(',')
        if l and all(c in '0123456789abcdefABCDEF' for c in l):
            out.append(int(l, 16) & 0xFF)
    return out


def psnr_gray(a, b):
    mse = sum((x - y) ** 2 for x, y in zip(a, b)) / len(a)
    return 10 * math.log10(255 * 255 / mse) if mse > 0 else float('inf')


def to_img_gray(px, w, h):
    img = Image.new('RGB', (w, h))
    img.putdata([(p, p, p) for p in px])
    return img


def main():
    rtl = load_coe8('output.coe')            # RTL 对坏点图的输出
    clean_rtl = load_coe8('output_clean.coe')  # RTL 对干净图的输出
    ref = load_hex8('ref_dpc.hex')           # Python 参考（对坏点图）
    if len(rtl) != MW * MH or len(ref) != MW * MH:
        raise SystemExit(f'错误: 输出尺寸不对（RTL={len(rtl)} 参考={len(ref)}，期望 {MW*MH}）')

    # 1. 全等比对
    diff_cnt = 0
    first = None
    for i, (a, b) in enumerate(zip(rtl, ref)):
        if a != b:
            diff_cnt += 1
            if first is None:
                first = (i, a, b)
    print('========================================')
    if diff_cnt == 0:
        print(f'[PASS] RTL 与 Python 参考逐像素全等：{len(rtl)} 像素，0 误差')
    else:
        i, a, b = first
        print(f'[FAIL] 差异 {diff_cnt}/{len(rtl)}；首个差异 #{i}（行{i//MW} 列{i%MW}）：RTL={a:02X} 参考={b:02X}')

    # 2. 效果指标（用 RTL 输出算）
    clean = load_hex8('bayer.hex')
    defect = load_hex8('bayer_defect.hex')
    clean_in = [clean[(r + 2) * W + (c + 2)] for r in range(MH) for c in range(MW)]
    defect_in = [defect[(r + 2) * W + (c + 2)] for r in range(MH) for c in range(MW)]
    pos = [(int(a), int(b)) for a, b, _ in
           (l.split() for l in open('defect_pos.txt') if l.strip())]
    defect_set = {(r - 2, c - 2) for r, c in pos}

    fixed = sum(1 for (r, c) in defect_set if rtl[r * MW + c] != defect_in[r * MW + c])
    hurt = sum(1 for k in range(MW * MH)
               if (k // MW, k % MW) not in defect_set and clean_rtl[k] != clean_in[k])

    print(f'坏点图   vs 干净图 : PSNR = {psnr_gray(defect_in, clean_in):.2f} dB（坏点伤害）')
    print(f'校正后   vs 干净图 : PSNR = {psnr_gray(rtl, clean_in):.2f} dB（恢复度）')
    print(f'修复率：{fixed}/{len(defect_set)} 个坏点被改掉（{fixed*100.0/max(1,len(defect_set)):.1f}%）')
    print(f'误伤率：{hurt}/{MW*MH-len(defect_set)} 个正常像素被改（'
          f'{hurt*100.0/(MW*MH-len(defect_set)):.3f}%）')
    print('========================================')

    # 3. 对比图：干净 | 带坏点 | RTL 校正后
    gap, top = 8, 30
    canvas = Image.new('RGB', (W * 3 + gap * 4, max(H, MH) + top + 10), (24, 24, 30))
    draw = ImageDraw.Draw(canvas)
    labels = ['干净 Bayer（参考）', f'注入 {len(pos)} 个坏点', 'RTL 校正后']
    imgs = [to_img_gray(clean, W, H), to_img_gray(defect, W, H), to_img_gray(rtl, MW, MH)]
    for i, (im, t) in enumerate(zip(imgs, labels)):
        x = gap + i * (W + gap)
        canvas.paste(im, (x, top))
        draw.text((x, 6), t, font=font(15), fill=(255, 255, 255))
    canvas.save('dpc_rtl_compare.png')
    print('对比图已保存: dpc_rtl_compare.png（干净 | 带坏点 | RTL 校正后）')


if __name__ == '__main__':
    main()