#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_isp_chain.py —— M5.3 八级整链：独立第二判据 + 逐级插桩 + 端到端 PSNR + 对比图

① **独立复算（不复用 TB 期望/生成器落盘）**：自己读 chain_in_*，用 Python 位级同构参考
   重算整链**逐级**输出，与 RTL 落盘逐位比对：
     img  : s1..s7（TB 逐级落盘）+ s8（末端 isp_out_img.txt）
     small: 末端 isp_out_small.txt（6 帧）
   ⇒ 任一级不一致即可定位到具体级。
② **逐级插桩**：逐级 PSNR 表（相对"理想输入同链输出"），一眼看出每级把噪声/坏点压掉多少。
③ **端到端 PSNR**：末端 RGB888 vs 理想靶子；并给出"DPC/降噪全关""仅降噪关"两条基线对照。
④ 出对比图 isp_chain_compare.png（输入 Bayer / 理想 Bayer / Demosaic 出 / 末端出 / 理想末端 / 放大差异）。

运行前提：先跑 make_chain_data.py（含 --img）与两种模式的 TB。
"""
import math
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.normpath(os.path.join(_HERE, '..'))
sys.path.append(_HERE)
sys.path.append(os.path.join(_ROOT, 'Bayer_DPC_Demosaic'))

from make_chain_data import (chain_ref, gen_range_lut, gen_inv_rom, quant_coef,  # noqa: E402
                             gen_lut, W_IMG, H_IMG, MAXV, W_S, H_S, FRAMES, OB, KG_DEF, KF)
from PIL import Image, ImageDraw, ImageFont                                  # noqa: E402

FONTS = [r'C:\Windows\Fonts\msyh.ttc', r'C:\Windows\Fonts\simhei.ttf',
         r'C:\Windows\Fonts\simsun.ttc']


def font(size):
    for fp in FONTS:
        try:
            return ImageFont.truetype(fp, size)
        except Exception:
            pass
    return ImageFont.load_default()


def load_hex(path):
    return [int(l.strip(), 16) for l in open(path) if l.strip()]


def load_txt(path):
    return [int(t, 16) for t in open(path).read().split()]


def psnr_ch(a, b, mask, shifts, peak):
    mse, n = 0, 0
    for x, y in zip(a, b):
        for sh in shifts:
            mse += (((x >> sh) & mask) - ((y >> sh) & mask)) ** 2
            n += 1
    return float('inf') if mse == 0 else 10 * math.log10(peak * peak * n / mse)


def bayer_gray(pix, w, h, scale=3):
    buf = bytes([min(v >> 2, 255) for v in pix])
    return Image.frombytes('L', (w, h), buf).resize(
        (w * scale, h * scale), Image.NEAREST).convert('RGB')


def rgb_img(pix, w, h, is24, scale=3):
    """30bit({r,g,b}各10bit) 或 24bit(RGB888) 打包 → PIL RGB"""
    if is24:
        data = [((p >> 16) & 255, (p >> 8) & 255, p & 255) for p in pix]
    else:
        data = [((p >> 20) & MAXV, (p >> 10) & MAXV, p & MAXV) for p in pix]
    im = Image.new('RGB', (w, h))
    im.putdata(data)
    return im.resize((w * scale, h * scale), Image.NEAREST)


def main():
    lut, inv, mint, glut = gen_range_lut(), gen_inv_rom(), quant_coef(), gen_lut()
    ok = True

    # =============== 一、img 模式：逐级独立复算 + 定位 ===============
    noisy = load_hex('chain_in_img.hex')
    raw_ideal = load_hex('ideal_in_img.hex')
    assert len(noisy) == W_IMG * H_IMG, f'chain_in_img {len(noisy)} != {W_IMG*H_IMG}'

    exp = chain_ref(noisy, W_IMG, H_IMG, lut, inv, mint, glut)        # 含噪声+坏点
    idl = chain_ref(raw_ideal, W_IMG, H_IMG, lut, inv, mint, glut)    # 理想靶子

    rtl = {}
    for k in range(1, 8):
        # TB 在 IMG 模式连发 4 帧（锚定 stall），逐级落盘含 4 帧 → 只取第 1 帧比对
        rtl['s%d' % k] = load_txt('isp_s%d_img.txt' % k)[:W_IMG*H_IMG]
    rtl['s8'] = load_txt('isp_out_img.txt')[:W_IMG*H_IMG]

    print('=' * 70)
    print('[1] 逐级独立复算（Python 参考 vs RTL 落盘；下方 "级 N" 即链里第 N 级）')
    STAGE_NAME = {1: 'BLC', 2: 'DPC', 3: 'AWB(占位)', 4: 'Demosaic',
                  5: '降噪', 6: 'CCM', 7: 'Gamma', 8: '锐化'}
    for k in range(1, 9):
        n = len(rtl['s%d' % k])
        if n != W_IMG * H_IMG:
            print(f'    级{k} {STAGE_NAME[k]:10s}: 落盘像素 {n} != {W_IMG*H_IMG} ✗')
            ok = False
            continue
        mm = sum(1 for a, b in zip(rtl['s%d' % k], exp['s%d' % k]) if a != b)
        ok &= (mm == 0)
        print(f'    级{k} {STAGE_NAME[k]:10s}: 位级 0 误差? {mm == 0}'
              f'（{W_IMG*H_IMG - mm}/{W_IMG*H_IMG}）')

    # =============== 二、small 模式：末端独立复算 ===============
    print('=' * 70)
    print('[2] small 模式末端独立复算（6 帧）')
    s_in = load_hex('chain_in_small.hex')
    rtl_s = load_txt('isp_out_small.txt')
    exp_s = []
    for fi in range(FRAMES):
        fr = s_in[fi*W_S*H_S:(fi+1)*W_S*H_S]
        exp_s += chain_ref(fr, W_S, H_S, lut, inv, mint, glut)['s8']
    if len(rtl_s) != len(exp_s):
        print(f'    落盘 {len(rtl_s)} != 期望 {len(exp_s)} ✗')
        ok = False
    else:
        mm = sum(1 for a, b in zip(rtl_s, exp_s) if a != b)
        ok &= (mm == 0)
        print(f'    末端位级 0 误差? {mm == 0}（{len(exp_s) - mm}/{len(exp_s)}）')

    # =============== 三、逐级插桩（PSNR vs 理想同链输出）===============
    print('=' * 70)
    print('[3] 逐级插桩：每级输出 vs「理想输入的同级输出」（越高越好；Bayer 级 10bit / RGB 级 10bit / 末端 8bit）')
    SPEC = {1: (MAXV, [0]), 2: (MAXV, [0]), 3: (MAXV, [0]),
            4: (MAXV, [20, 10, 0]), 5: (MAXV, [20, 10, 0]), 6: (MAXV, [20, 10, 0]),
            7: (255, [16, 8, 0]), 8: (255, [16, 8, 0])}
    for k in range(1, 9):
        peak, shifts = SPEC[k]
        mask = 255 if peak == 255 else MAXV
        v = psnr_ch(exp['s%d' % k], idl['s%d' % k], mask, shifts, peak)
        print(f'    级{k} {STAGE_NAME[k]:10s}: {v:6.2f} dB')

    # =============== 四、端到端 + 基线对照 ===============
    print('=' * 70)
    print('[4] 端到端（末端 RGB888 vs 理想靶子，8bit 口径）+ 基线对照')
    base_d = chain_ref(noisy, W_IMG, H_IMG, lut, inv, mint, glut, bp_denoise=True)
    base_n = chain_ref(noisy, W_IMG, H_IMG, lut, inv, mint, glut, skip_dpc_denoise=True)
    e2e = psnr_ch(exp['s8'], idl['s8'], 255, [16, 8, 0], 255)
    bd = psnr_ch(base_d['s8'], idl['s8'], 255, [16, 8, 0], 255)
    bn = psnr_ch(base_n['s8'], idl['s8'], 255, [16, 8, 0], 255)
    print(f'    DPC/降噪全关（最差）   : {bn:6.2f} dB')
    print(f'    仅降噪关（DPC 开）     : {bd:6.2f} dB')
    print(f'    ★ 整链（DPC+降噪全开）: {e2e:6.2f} dB')

    # =============== 五、对比图 ===============
    scale, bw = 3, 28
    tw, th = W_IMG * scale, H_IMG * scale + bw
    canvas = Image.new('RGB', (tw * 3, th * 2), (255, 255, 255))
    dr = ImageDraw.Draw(canvas)
    f = font(13)
    dmax = max(abs(exp['s8'][i] - idl['s8'][i]) for i in range(len(exp['s8'])))
    diff = []
    for i, p in enumerate(exp['s8']):
        q = idl['s8'][i]
        dv = sum(abs(((p >> sh) & 255) - ((q >> sh) & 255)) for sh in (16, 8, 0)) // 3
        diff.append(min(dv * (255 // max(dmax // 3, 1)), 255))
    panels = [
        ('输入 Bayer（OB+噪声+坏点）', bayer_gray(noisy, W_IMG, H_IMG, scale)),
        ('理想 Bayer（无噪声无坏点）', bayer_gray(raw_ideal, W_IMG, H_IMG, scale)),
        (f'Demosaic 出（级4）PSNR {psnr_ch(exp["s4"], idl["s4"], MAXV, [20,10,0], MAXV):.1f}dB',
         rgb_img(exp['s4'], W_IMG, H_IMG, False, scale)),
        ('末端出（整链）', rgb_img(exp['s8'], W_IMG, H_IMG, True, scale)),
        ('理想末端（靶子）', rgb_img(idl['s8'], W_IMG, H_IMG, True, scale)),
        (f'|末端−理想| ×{255 // max(dmax // 3, 1)}', rgb_img([(d << 16) | (d << 8) | d for d in diff],
                                                             W_IMG, H_IMG, True, scale)),
    ]
    for i, (title, im) in enumerate(panels):
        x, y = (i % 3) * tw, (i // 3) * th
        dr.rectangle([x, y, x + tw - 1, y + bw - 1], fill=(240, 240, 240))
        dr.text((x + 5, y + 7), title, fill=(0, 0, 0), font=f)
        canvas.paste(im, (x, y + bw))
    canvas.save('isp_chain_compare.png')

    print('=' * 70)
    print(f'对比图已出：isp_chain_compare.png（输入/理想 Bayer · Demosaic 出 · 末端/理想 · 差异）')
    print('[PASS] 整链独立复算逐级 0 误差（TB 位级 0 误差）' if ok else '[FAIL] 独立复算不一致')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
