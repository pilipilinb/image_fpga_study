#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# verify_chain.py —— 滤波+CSC+缩放 链路逐级验证（filter_csc_bilinear，W4 收尾）
#
# 用法：python verify_chain.py   （在 filter_csc_bilinear/ 下，需先跑 tb_chain）
#
# 原理：逐级独立参考（每级用 RTL 前级输出作参考输入，隔离误差、逐级定位）：
#   ① 高斯参考：噪声图窗口 [1 2 1;2 4 2;1 2 1]/16 浮点 → gaussian_out.coe
#   ② 中值参考：gaussian_out.coe 窗口排序取第 5 → median_out.coe
#   ③ CSC 参考：median_out.coe 按 BT.601 ×256 定点（47/157/16/4096 同 RTL）→ csc_out.coe
#   ④ 缩放参考：csc_out.coe 双线性放大（坐标模拟累加舍入，同 verify_scale 思路）→ chain_out.coe
#   每级 PSNR ≥ 35dB 判定 PASS（四级定点误差累积的理论值约 42dB，35dB 留裕量）
#
# 另外：最终 YUV→RGB（BT.601 逆变换）显示对比图 chain_compare.png
#       （左=原图放大2倍 | 中=混合噪声图放大2倍 | 右=链路结果 YUV→RGB）
import math
import sys
from PIL import Image, ImageDraw, ImageFont

W, H = 112, 103
GW, GH = W - 2, H - 2     # 高斯输出 110×101
MW, MH = GW - 2, GH - 2   # 中值/CSC 输出 108×99
OW, OH = MW * 2, MH * 2   # 缩放输出 216×198

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
    vals = []
    for l in open(path):
        l = l.strip().rstrip(',')
        if l and all(c in '0123456789abcdefABCDEF' for c in l):
            vals.append(int(l, 16))
    return vals


def ch(px, k):
    return (px >> k) & 0xFF


def psnr(a, b):
    mse = sum((ch(x, 16) - ch(y, 16)) ** 2 + (ch(x, 8) - ch(y, 8)) ** 2 + (ch(x, 0) - ch(y, 0)) ** 2
              for x, y in zip(a, b)) / (len(a) * 3)
    return 10 * math.log10(255 * 255 / mse) if mse > 0 else float('inf')


def rnd_half_up(v):
    """与 RTL (x+2^(N-1))>>N 同构的半进位（审查修正：Python round() 是银行家舍入 half-even）"""
    return (v + 8) >> 4


# ---------------------------------------------------------------------------
# ① 高斯参考：窗口加权 [1 2 1;2 4 2;1 2 1]/16（定点半进位），输出 = 窗口中心位置
#    输出第 k 个 = 右下角 (wr,wc) 窗口（wr∈[2,H-1]），窗口覆盖 rows wr-2..wr
#    比对点 = 窗口中心 (wr-1, wc-1)（注意：dr 取 -2..0，不是中心 ±1）
# ---------------------------------------------------------------------------
def gauss_ref(px, w, h, pad=False):
    # pad=True：全尺寸每像素一窗口（wr∈[0,H)），越界钳位（replicate）
    out = []
    rng_r = range(h) if pad else range(2, h)
    rng_c = range(w) if pad else range(2, w)
    for wr in rng_r:
        for wc in rng_c:
            r = g = b = 0
            drs = (-1, 0, 1) if pad else (-2, -1, 0)
            dcs = (-1, 0, 1) if pad else (-2, -1, 0)
            for dr in drs:
                for dc in dcs:
                    rr = max(0, min(h-1, wr+dr)) if pad else wr+dr
                    cc = max(0, min(w-1, wc+dc)) if pad else wc+dc
                    k = (1, 2, 1)[dr + (1 if pad else 2)] * (1, 2, 1)[dc + (1 if pad else 2)]   # 可分离系数（pad=中心模型）
                    p = px[rr * w + cc]
                    r += k * ch(p, 16); g += k * ch(p, 8); b += k * ch(p, 0)
            out.append((min(255, rnd_half_up(r)) << 16) | (min(255, rnd_half_up(g)) << 8) | min(255, rnd_half_up(b)))
    return out


# ---------------------------------------------------------------------------
# ② 中值参考：逐通道独立排序取第 5（注意：RTL 是 3 个单通道 8bit 核，
#    R/G/B 分别取中值再合成——不能对 24bit 整体排序！）
#    窗口覆盖 rows wr-2..wr，同 ① 的坐标约定
# ---------------------------------------------------------------------------
def median_ref(px, w, h, pad=False):
    # pad=True：全尺寸每像素一窗口，越界钳位（replicate）
    out = []
    rng_r = range(h) if pad else range(2, h)
    rng_c = range(w) if pad else range(2, w)
    for wr in rng_r:
        for wc in rng_c:
            win = []
            for dr in ((-1, 0, 1) if pad else (-2, -1, 0)):
                for dc in ((-1, 0, 1) if pad else (-2, -1, 0)):
                    rr = max(0, min(h-1, wr+dr)) if pad else wr+dr
                    cc = max(0, min(w-1, wc+dc)) if pad else wc+dc
                    win.append(px[rr * w + cc])
            r = sorted([ch(p, 16) for p in win])[4]
            g = sorted([ch(p, 8) for p in win])[4]
            b = sorted([ch(p, 0) for p in win])[4]
            out.append((r << 16) | (g << 8) | b)
    return out


# ---------------------------------------------------------------------------
# ③ CSC 参考：BT.601 ×256 定点，末级与 RTL 同构的"加 bit7 半进位"((x+128)>>8)
#    （审查修正：初版截断 >>8 与 RTL 的 result[17:8]+result[7] 不符，51dB 缺口
#     正是参考自己的舍入错误；与 RTL 对齐后可位级全等）
# ---------------------------------------------------------------------------
def csc_ref(px):
    out = []
    for p in px:
        r, g, b = ch(p, 16), ch(p, 8), ch(p, 0)
        y  = (47 * r + 157 * g + 16 * b + 4096 + 128) >> 8
        cb = (112 * b - 26 * r - 86 * g + 32768 + 128) >> 8
        cr = (112 * r - 102 * g - 10 * b + 32768 + 128) >> 8
        y  = max(0, min(255, y)); cb = max(0, min(255, cb)); cr = max(0, min(255, cr))
        out.append((y << 16) | (cb << 8) | cr)
    return out


# ---------------------------------------------------------------------------
# ④ 双线性缩放参考：坐标模拟累加舍入（同 verify_scale 思路）；权重浮点，
#    舍入用 floor(x+0.5)（审查修正：Python round() half-even 与 RTL 半进位不符）
#    STEP 四舍五入与 RTL (IN<<FB + OUT/2)/OUT 同构（本 2x 恰好整除，公式统一留作非整除安全）
# ---------------------------------------------------------------------------
def scale_ref(px, w, h, n, d, fb=8):
    ow, oh = w * n // d, h * n // d
    step_x = ((w << fb) + ow // 2) // ow
    step_y = ((h << fb) + oh // 2) // oh
    m = (1 << fb) - 1
    out = []
    sy_a = 0
    for dy in range(oh):
        sy = sy_a >> fb
        v = sy_a & m
        sy1 = min(sy + 1, h - 1)
        sy_a += step_y
        sx_a = 0
        for dx in range(ow):
            sx = sx_a >> fb
            u = sx_a & m
            sx1 = min(sx + 1, w - 1)
            p00 = px[sy * w + sx];     p10 = px[sy * w + sx1]
            p01 = px[sy1 * w + sx];    p11 = px[sy1 * w + sx1]
            uu, vv = u / (1 << fb), v / (1 << fb)
            def hup(val):
                return int(math.floor(val + 0.5))
            r = min(255, hup((1 - uu) * (1 - vv) * ch(p00, 16) + uu * (1 - vv) * ch(p10, 16)
                             + (1 - uu) * vv * ch(p01, 16) + uu * vv * ch(p11, 16)))
            g = min(255, hup((1 - uu) * (1 - vv) * ch(p00, 8) + uu * (1 - vv) * ch(p10, 8)
                             + (1 - uu) * vv * ch(p01, 8) + uu * vv * ch(p11, 8)))
            b = min(255, hup((1 - uu) * (1 - vv) * ch(p00, 0) + uu * (1 - vv) * ch(p10, 0)
                             + (1 - uu) * vv * ch(p01, 0) + uu * vv * ch(p11, 0)))
            out.append((r << 16) | (g << 8) | b)
            sx_a += step_x
    return out


# ---------------------------------------------------------------------------
# YUV→RGB（BT.601 逆变换，显示用）
# ---------------------------------------------------------------------------
def yuv_to_rgb(p):
    y, cb, cr = ch(p, 16), ch(p, 8), ch(p, 0)
    r = y + 1.402 * (cr - 128)
    g = y - 0.344 * (cb - 128) - 0.714 * (cr - 128)
    b = y + 1.773 * (cb - 128)
    return (max(0, min(255, round(r))) << 16) | (max(0, min(255, round(g))) << 8) | max(0, min(255, round(b)))


def to_img(px, w, h):
    img = Image.new('RGB', (w, h))
    img.putdata([(ch(p, 16), ch(p, 8), ch(p, 0)) for p in px])
    return img


def main():
    ORDER = 1 if '--swap' in sys.argv else 0      # 1 = 中值→高斯（实验顺序）
    PAD   = 1 if '--pad' in sys.argv else 0       # 1 = pad 版链（全尺寸，不收缩）
    mix   = load_hex('noise_mix.hex')
    g_out = load_coe('gaussian_out.coe')
    m_out = load_coe('median_out.coe')
    c_out = load_coe('csc_out.coe')
    f_out = load_coe('chain_out.coe')
    if PAD:
        SZ = W * H   # 11536（pad 链两级全尺寸）
        assert len(g_out) == SZ and len(m_out) == SZ and len(c_out) == SZ and len(f_out) == (2*W)*(2*H)
        g_ref = gauss_ref(mix, W, H, pad=True)
        m_ref = median_ref(g_out, W, H, pad=True)     # 中值输入 = 高斯输出（全尺寸）
        c_ref = csc_ref(m_out)
        f_ref = scale_ref(c_out, W, H, 2, 1)
    elif ORDER == 0:
        assert len(g_out) == GW * GH and len(m_out) == MW * MH and len(c_out) == MW * MH and len(f_out) == OW * OH
        g_ref = gauss_ref(mix, W, H)
        m_ref = median_ref(g_out, GW, GH)
        c_ref = csc_ref(m_out)
        f_ref = scale_ref(c_out, MW, MH, 2, 1)
    else:
        assert len(m_out) == GW * GH and len(g_out) == MW * MH and len(c_out) == MW * MH and len(f_out) == OW * OH
        m_ref = median_ref(mix, W, H)            # 中值先，输入 112×103
        g_ref = gauss_ref(m_out, GW, GH)         # 高斯后，输入 = 中值输出 110×101
        c_ref = csc_ref(g_out)                   # CSC 输入 = 高斯输出 108×99
        f_ref = scale_ref(c_out, MW, MH, 2, 1)

    print('========================================')
    print('【实现精度】RTL vs 浮点参考（衡量硬件是否正确实现算法）')
    for name, got, ref in [('① 高斯', g_out, g_ref),
                           ('② 中值', m_out, m_ref),
                           ('③ CSC ', c_out, c_ref),
                           ('④ 缩放大2', f_out, f_ref)]:
        v = psnr(got, ref)
        print(f'{name}: PSNR = {v:.2f} dB（{len(got)} 像素，阈值 35dB）', 'PASS' if v >= 35 else 'FAIL')

    # ---- 恢复度：每级输出 vs 原图（衡量各级滤波对噪声图像的改善）----
    # 对齐映射（crop 中心位置链式内缩，与 ORDER 无关，按输出尺寸对齐）：
    #   第一级输出（110×101）坐标 (r1,c1) → 原图 (r1+1, c1+1)
    #   第二级输出（108×99）坐标 (r2,c2) → 原图 (r2+2, c2+2)
    orig = load_hex('input.hex')
    orig_first = [orig[(r1 + 1) * W + (c1 + 1)] for r1 in range(GH) for c1 in range(GW)]
    orig_second = [orig[(r2 + 2) * W + (c2 + 2)] for r2 in range(MH) for c2 in range(MW)]
    orig_sc = scale_ref(orig_second, MW, MH, 2, 1)
    mix_first = [mix[(r1 + 1) * W + (c1 + 1)] for r1 in range(GH) for c1 in range(GW)]
    mix_m  = [mix[(r2 + 2) * W + (c2 + 2)] for r2 in range(MH) for c2 in range(MW)]

    print('========================================')
    print('【恢复度】每级输出 vs 原图（衡量滤波/链路对图像的改善）')
    if PAD:
        # pad 链：全尺寸输出与原图直接逐像素比（无 crop 对齐偏移）
        orig_full = load_hex('input.hex')
        orig_sc = scale_ref(orig_full, W, H, 2, 1)
        rows = [
            ('混合噪声图        ',  mix, orig_full),
            ('① 高斯滤波后(pad) ',  g_out, orig_full),
            ('② 中值滤波后(pad) ',  m_out, orig_full),
            ('③ CSC后(转RGB)    ', [yuv_to_rgb(p) for p in c_out], orig_full),
            ('④ 放大2倍后       ', [yuv_to_rgb(p) for p in f_out], orig_sc),
        ]
    elif ORDER == 0:
        rows = [
            ('混合噪声图',      mix_m, orig_second),
            ('① 高斯滤波后',    g_out[:len(orig_first)], orig_first),
            ('② 中值滤波后',    m_out, orig_second),
            ('③ CSC后(转RGB)', [yuv_to_rgb(p) for p in c_out], orig_second),
            ('④ 放大2倍后',    [yuv_to_rgb(p) for p in f_out], orig_sc),
        ]
    else:
        rows = [
            ('混合噪声图',      mix_first, orig_first),
            ('① 中值滤波后(第1级)', m_out, orig_first),
            ('② 高斯滤波后(第2级)', g_out, orig_second),
            ('③ CSC后(转RGB)', [yuv_to_rgb(p) for p in c_out], orig_second),
            ('④ 放大2倍后',    [yuv_to_rgb(p) for p in f_out], orig_sc),
        ]
    for name, got, ref in rows:
        v = psnr(got, ref)
        print(f'{name}: PSNR = {v:.2f} dB（恢复度，越高越接近原图）')
    print('========================================')

    # ---- 显示对比图：原图 | 混合噪声图 | 链路结果（YUV→RGB），均放大 2 倍 ----
    # 按 ORDER/PAD 区分文件名，避免相互覆盖
    png_name = ('chain_compare_pad.png' if PAD else
                ('chain_compare_swap.png' if ORDER == 1 else 'chain_compare.png'))
    dw, dh = (2 * W, 2 * H) if PAD else (OW, OH)   # pad 链输出 224×206
    orig2 = to_img(load_hex('input.hex'), W, H).resize((dw, dh), Image.BILINEAR)
    m2 = to_img(mix, W, H).resize((dw, dh), Image.NEAREST)
    final = to_img([yuv_to_rgb(p) for p in f_out], dw, dh)
    canvas = Image.new('RGB', (dw * 3 + 8 * 4, dh + 40), (24, 24, 30))
    draw = ImageDraw.Draw(canvas)
    chain_tag = 'pad全尺寸' if PAD else ('中值→高斯' if ORDER == 1 else '高斯→中值')
    labels = ['原图（放大2倍）', '混合噪声图 σ=20+p=0.10', f'链路结果：{chain_tag}+CSC+放大2x（YUV→RGB）']
    for i, (im, t) in enumerate(zip([orig2, m2, final], labels)):
        x = 8 + i * (dw + 8)
        canvas.paste(im, (x, 30))
        draw.text((x + 4, 6), t, font=font(16), fill=(255, 255, 255))
    canvas.save(png_name)
    print(f'对比图已保存: {png_name}（原图 | 噪声 | 链路结果[{chain_tag}]，均为 {dw}×{dh}）')


if __name__ == '__main__':
    main()