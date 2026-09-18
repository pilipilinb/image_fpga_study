#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# make_bayer.py —— 生成 Bayer 测试输入 + Python 参考去马赛克 + 对比图（Demosaic 工程）
#
# 干什么（三步）：
#   1. 把彩色原图（24bit RGB hex）按 RGGB 排列"每像素只留一个通道"→ bayer.hex
#      （模拟真实传感器：一个感光点只能测 R 或 G 或 B，其他通道靠猜）
#   2. 用 Python 做一遍双线性去马赛克（和 RTL 同一套整数公式，含 >> 截断），
#      结果写 ref_rgb.hex —— 给 RTL 输出做"位级全等"比对用
#   3. 拼一张对比图：原图 | Bayer 图（灰度看马赛克） | 去马赛克结果
#
# 用法：python make_bayer.py            （默认读 input.hex，112×103）
#
# RGGB 排列（本工程用的）：
#   行0: R G R G ...      行1: G B G B ...
#   → (行偶,列偶)=R  (行偶,列奇)=Gr  (行奇,列偶)=Gb  (行奇,列奇)=B
from PIL import Image, ImageDraw, ImageFont

W, H = 112, 103          # 原图尺寸
MW, MH = W - 4, H - 4    # 去马赛克输出尺寸（5×5 窗口 → 上/下/左/右各裁 2 圈）

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


def save_hex8(px, path):
    """8bit 单通道 hex（每行一个字节）"""
    with open(path, 'w') as f:
        for p in px:
            f.write(f'{p & 0xFF:02X}\n')


def save_hex24(px, path):
    with open(path, 'w') as f:
        for p in px:
            f.write(f'{p:06X}\n')


def ch(px, k):
    return (px >> k) & 0xFF


# ---------------------------------------------------------------------------
# 第 1 步：RGGB 采样 —— 每个位置只留它"该测"的那个通道
# ---------------------------------------------------------------------------
def make_bayer(rgb, w, h):
    bayer = []
    for r in range(h):
        for c in range(w):
            p = rgb[r * w + c]
            if r % 2 == 0 and c % 2 == 0:
                bayer.append(ch(p, 16))      # R
            elif r % 2 == 1 and c % 2 == 1:
                bayer.append(ch(p, 0))       # B
            else:
                bayer.append(ch(p, 8))       # G（Gr / Gb 都用绿通道）
    return bayer


# ---------------------------------------------------------------------------
# 第 2 步：双线性去马赛克（与 RTL 完全同一套整数公式，>> 截断不舍入）
#   对输出图上的每个点（对应原图中心 (R+2, C+2)），取它周围 5×5 的 Bayer 值，
#   按中心相位选公式：
#     R 相位  ：R=中心   G=十字4个G均值   B=对角4个B均值
#     B 相位  ：B=中心   G=十字4个G均值   R=对角4个R均值
#     Gr 相位 ：G=中心   R=左右2个R均值   B=上下2个B均值
#     Gb 相位 ：G=中心   B=左右2个B均值   R=上下2个R均值
# ---------------------------------------------------------------------------
def demosaic_bilinear(bayer, w, h):
    out = []
    for R in range(2, h - 2):            # 窗口中心（输出点）的行
        for C in range(2, w - 2):        # 窗口中心（输出点）的列
            def v(rr, cc):
                return bayer[rr * w + cc]
            ctr = v(R, C)
            if R % 2 == 0 and C % 2 == 0:          # 中心是 R
                r_o = ctr
                g_o = (v(R-1, C) + v(R+1, C) + v(R, C-1) + v(R, C+1)) >> 2
                b_o = (v(R-1, C-1) + v(R-1, C+1) + v(R+1, C-1) + v(R+1, C+1)) >> 2
            elif R % 2 == 1 and C % 2 == 1:        # 中心是 B
                b_o = ctr
                g_o = (v(R-1, C) + v(R+1, C) + v(R, C-1) + v(R, C+1)) >> 2
                r_o = (v(R-1, C-1) + v(R-1, C+1) + v(R+1, C-1) + v(R+1, C+1)) >> 2
            elif R % 2 == 0 and C % 2 == 1:        # 中心是 Gr（左右是 R、上下是 B）
                g_o = ctr
                r_o = (v(R, C-1) + v(R, C+1)) >> 1
                b_o = (v(R-1, C) + v(R+1, C)) >> 1
            else:                                  # 中心是 Gb（左右是 B、上下是 R）
                g_o = ctr
                b_o = (v(R, C-1) + v(R, C+1)) >> 1
                r_o = (v(R-1, C) + v(R+1, C)) >> 1
            out.append((r_o << 16) | (g_o << 8) | b_o)
    return out


def to_img(px, w, h, gray=False):
    img = Image.new('RGB', (w, h))
    if gray:
        img.putdata([(ch(p, 0), ch(p, 0), ch(p, 0)) for p in px])
    else:
        img.putdata([(ch(p, 16), ch(p, 8), ch(p, 0)) for p in px])
    return img


def main():
    rgb = load_hex('input.hex')
    if len(rgb) != W * H:
        raise SystemExit(f'错误: input.hex 有 {len(rgb)} 像素，期望 {W}×{H}')

    # 1. Bayer 采样
    bayer = make_bayer(rgb, W, H)
    save_hex8(bayer, 'bayer.hex')
    print(f'OK: input.hex → bayer.hex（RGGB 采样，{W}×{H}，8bit 单通道）')

    # 2. Python 参考去马赛克（给 RTL 位级全等比对）
    ref = demosaic_bilinear(bayer, W, H)
    save_hex24(ref, 'ref_rgb.hex')
    print(f'OK: 参考去马赛克 → ref_rgb.hex（{MW}×{MH} = {len(ref)} 像素，与 RTL 同公式）')

    # 3. 对比图：原图 | Bayer（灰度看） | 去马赛克结果
    gap, top = 8, 30
    cw = (W * 3 + gap * 4)
    chh = max(H, MH) + top + 10
    canvas = Image.new('RGB', (cw, chh), (24, 24, 30))
    draw = ImageDraw.Draw(canvas)
    labels = ['原图（RGB 彩色）', 'Bayer RAW（RGGB，每点只留一个通道）', '双线性去马赛克结果（裁掉两圈边缘）']
    imgs = [to_img(rgb, W, H), to_img(bayer, W, H, gray=True), to_img(ref, MW, MH)]
    for i, (im, t) in enumerate(zip(imgs, labels)):
        x = gap + i * (W + gap)
        canvas.paste(im, (x, top))
        draw.text((x, 6), t, font=font(15), fill=(255, 255, 255))
    canvas.save('demosaic_compare.png')
    print('OK: 对比图 → demosaic_compare.png（原图 | Bayer | 去马赛克结果）')


if __name__ == '__main__':
    main()