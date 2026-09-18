#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# verify_blc_img.py —— BLC 图像实验的独立校验（位级 + PSNR + 四宫格对比图）
#
# 判据与产出：
#   1. 位级全等：RTL output.coe vs Python 重算 max(p - OB[相位], 0)（正确性判据）
#   2. PSNR（vs 理想无黑电平 RAW，MAX=1023）三组：
#        不校（带黑电平直接用）  —— 黑电平被当信号，暗部发灰
#        BLC 校正（OB 配置准确） —— 理论上位级还原（PSNR=∞）
#        BLC 校正（OB 偏 -16）   —— 标定误差的代价：残留底电平
#   3. 四宫格对比图 blc_compare.png（灰度显示 Bayer 帧）
#
# 用法：python verify_blc_img.py     （先 make_blc_data.py → vvp tb_blc_img.v）
from PIL import Image, ImageDraw, ImageFont
import math

W, H = 112, 103
OB_TRUE = {0: 100, 1: 64, 2: 180, 3: 32}    # 真实黑电平（make_blc_data.py 加的）
OB_CFG  = {k: max(v - 16, 0) for k, v in OB_TRUE.items()}   # 偏差场景：配置少 16（标定误差）
MAXV = 1023                                  # RAW10 满量程

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


def phase(i):
    r, c = divmod(i, W)
    return (r & 1) * 2 + (c & 1)


def blc(px, ob):
    """Python 参考 BLC：max(p - OB[相位], 0)（与 RTL 写法乙同公式）"""
    return [max(v - ob[phase(i)], 0) for i, v in enumerate(px)]


def psnr(a, b):
    mse = sum((x - y) ** 2 for x, y in zip(a, b)) / len(a)
    return 10 * math.log10(MAXV * MAXV / mse) if mse > 0 else float('inf')


def main():
    ideal = load_hex('blc_ideal.hex')     # 理想无黑电平 RAW
    rin = load_hex('blc_in.hex')          # 带黑电平的 sensor RAW（RTL 输入）
    rtl = load_hex('output.coe')          # RTL BLC 输出
    if not (len(ideal) == len(rin) == len(rtl) == W * H):
        raise SystemExit(f'错误: ideal={len(ideal)} in={len(rin)} rtl={len(rtl)}，期望 {W*H}')

    # ---- 1. 位级全等（正确性判据）----
    exp = blc(rin, OB_TRUE)
    diff = sum(1 for a, b in zip(rtl, exp) if a != b)
    print('========================================')
    if diff == 0:
        print(f'[PASS] RTL 与 Python 参考逐像素全等：{len(rtl)} 像素，0 误差')
    else:
        first = next(i for i, (a, b) in enumerate(zip(rtl, exp)) if a != b)
        print(f'[FAIL] 差异 {diff}/{len(rtl)}；首个 #{first}（行{first//W} 列{first%W}）：'
              f'RTL={rtl[first]} 参考={exp[first]}')

    # ---- 2. PSNR（vs 理想 RAW）----
    fixed_bad = blc(rin, OB_CFG)          # OB 配置偏差 -16 的校正结果（确定性减法，Python 与 RTL 位级等价）
    p_no = psnr(rin, ideal)               # 不校
    p_ok = psnr(rtl, ideal)               # 校准
    p_bad = psnr(fixed_bad, ideal)        # 校偏
    print(f'PSNR（vs 理想 RAW，MAX={MAXV}）：')
    print(f'  不校（带黑电平直接用）   : {p_no:7.2f} dB   ← 黑电平被当信号，暗部发灰')
    print(f'  BLC 校正（OB 配置准确）  : {p_ok:7.2f} dB   ← 位级还原（∞ 是位级全等的另一面）')
    print(f'  BLC 校正（OB 偏差 -16）  : {p_bad:7.2f} dB   ← 标定误差的代价：残留底电平')

    # ---- 3. 四宫格对比图（灰度显示 Bayer 帧）----
    def gray_img(px):
        img = Image.new('L', (W, H))
        img.putdata([v >> 2 for v in px])   # 显示折 8bit
        return img

    gap, top = 8, 34
    dw, dh = W * 2, H * 2
    cw = dw * 4 + gap * 5
    canvas = Image.new('RGB', (cw, dh + top + 46), (24, 24, 30))
    draw = ImageDraw.Draw(canvas)
    panels = [
        (gray_img(ideal),     '理想 RAW（无黑电平）',            '基准'),
        (gray_img(rin),       '带黑电平 RAW（不校）',            f'PSNR {p_no:.2f} dB'),
        (gray_img(rtl),       'BLC 校正（OB 准确）',             f'PSNR {p_ok:.2f} dB' if p_ok != float("inf") else 'PSNR inf（位级还原）'),
        (gray_img(fixed_bad), 'BLC 校正（OB 偏差 -16）',         f'PSNR {p_bad:.2f} dB'),
    ]
    for i, (im, t, s) in enumerate(panels):
        x = gap + i * (dw + gap)
        canvas.paste(im.resize((dw, dh), Image.BILINEAR), (x, top))
        draw.text((x, 8), t, font=font(15), fill=(255, 255, 255))
        draw.text((x, top + dh + 4), s, font=font(14), fill=(160, 220, 160))
    # 均值标注（暗部发灰最直观的量化）
    for i, px in enumerate([ideal, rin, rtl, fixed_bad]):
        m = sum(px) / len(px)
        draw.text((gap + i * (dw + gap), top + dh + 24), f'均值 {m:.1f}/1023', font=font(13), fill=(200, 200, 200))
    canvas.save('blc_compare.png')
    print('========================================')
    print('对比图已保存: blc_compare.png（理想 | 不校 | 校准 | 校偏，各含 PSNR 与均值）')


if __name__ == '__main__':
    main()
