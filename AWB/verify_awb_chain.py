#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_awb_chain.py —— AWB 真增益整链实验：独立第二判据 + PSNR + 对比图（住在 AWB/ 下）

① **独立复算**（不复用 TB 期望落盘）：从 awb_chain_in_img.hex（偏色 RAW 第 1 帧）自己重算
   —— DPC 出统计 → 收敛增益 → expa/expb —— 与 TB 落盘 awb_chain_out.txt（4 帧）逐位比对：
     帧 0/1 = expa（增益 1.0）· 帧 2/3 = expb（收敛增益）⇒ 0 误差。
② **PSNR**（RTL 实际输出 vs 理想靶子=未偏色整链输出）：
     无 AWB（帧 0） vs AWB 收敛（帧 2）——量化"闭环把色偏修掉多少"。
③ **通道均值**：R/G/B 平均（收敛后应回到靶子水平）——"色偏消除"的直接证据。
④ 对比图 awb_chain_compare.png（6 格，沿用 M5.3 版式；输出在 AWB/ 本目录）。

运行前提（均在 AWB/ 下）：
  python make_awb_chain_data.py && vvp tb_awb_chain.vvp && python verify_awb_chain.py
"""
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.append(os.path.join(_HERE, '..', 'FpgaIspChain'))

from make_chain_data import (chain_ref, gen_range_lut, gen_inv_rom, quant_coef,  # noqa: E402
                             gen_lut, psnr8, blc, dpc_ref, phase_of, load_hex,
                             W_IMG, H_IMG, MAXV, THR)
from PIL import Image, ImageDraw, ImageFont                                  # noqa: E402

FONTS = [r'C:\Windows\Fonts\msyh.ttc', r'C:\Windows\Fonts\simhei.ttf',
         r'C:\Windows\Fonts\simsun.ttc']
TOTAL = W_IMG * H_IMG
CNT = TOTAL // 4


def font(size):
    for fp in FONTS:
        try:
            return ImageFont.truetype(fp, size)
        except Exception:
            pass
    return ImageFont.load_default()


def load_txt(path):
    return [int(t, 16) for t in open(path).read().split()]


def bayer_gray(pix, w, h, scale=3):
    buf = bytes([min(v >> 2, 255) for v in pix])
    return Image.frombytes('L', (w, h), buf).resize(
        (w * scale, h * scale), Image.NEAREST).convert('RGB')


def rgb_img(pix, w, h, is24, scale=3):
    if is24:
        data = [((p >> 16) & 255, (p >> 8) & 255, p & 255) for p in pix]
    else:
        data = [((p >> 20) & MAXV, (p >> 10) & MAXV, p & MAXV) for p in pix]
    im = Image.new('RGB', (w, h))
    im.putdata(data)
    return im.resize((w * scale, h * scale), Image.NEAREST)


def ch_means(pix, is24):
    n = len(pix)
    if is24:
        return [sum((p >> sh) & 255 for p in pix) / n for sh in (16, 8, 0)]
    return [sum((p >> sh) & MAXV for p in pix) / n for sh in (20, 10, 0)]


def main():
    for f in ('awb_chain_in_img.hex', 'awb_chain_out.txt',
              os.path.join('..', 'FpgaIspChain', 'chain_in_img.hex')):
        if not os.path.exists(f):
            raise SystemExit(f'缺少 {f}——请先跑 make_awb_chain_data.py 与 tb_awb_chain')

    lut, inv, mint, glut = gen_range_lut(), gen_inv_rom(), quant_coef(), gen_lut()
    ok = True

    # =============== 一、独立复算 ===============
    tin_all = load_hex('awb_chain_in_img.hex')
    assert len(tin_all) == 4 * TOTAL, f'awb_chain_in_img.hex 行数 {len(tin_all)}'
    tin = tin_all[:TOTAL]                                  # 4 帧重复，独立按第 1 帧重算
    rtl = load_txt('awb_chain_out.txt')
    assert len(rtl) == 4 * TOTAL, f'awb_chain_out.txt 行数 {len(rtl)}'

    # 软核同构：DPC 出统计 → 收敛增益（cnt 用 W·H/4 均匀口径）
    s2t = dpc_ref(blc(tin, W_IMG, H_IMG), W_IMG, H_IMG, THR)
    sums = [0, 0, 0, 0]
    for i, v in enumerate(s2t):
        sums[phase_of(i // W_IMG, i % W_IMG)] += v
    m = [s // CNT for s in sums]
    mg = (m[1] + m[2]) >> 1
    g = [min(max((mg << 8) // max(mi, 1), 128), 1023) for mi in m]
    print('=' * 70)
    print(f'[独立重算] 收敛增益 g = {g}（Q2.8，软核同构公式）')
    if os.path.exists('awb_chain_gain.txt'):
        print('           awb_chain_gain.txt：' +
              open('awb_chain_gain.txt').readline().strip())

    expa = chain_ref(tin, W_IMG, H_IMG, lut, inv, mint, glut)['s8']
    expb = chain_ref(tin, W_IMG, H_IMG, lut, inv, mint, glut,
                     awb_gains=tuple(g))['s8']
    print('[1] 独立复算 vs RTL 落盘（4 帧；帧0/1=增益1.0，帧2/3=收敛增益）')
    for fi in range(4):
        ref = expa if fi < 2 else expb
        seg = rtl[fi * TOTAL:(fi + 1) * TOTAL]
        mm = sum(1 for a, b in zip(seg, ref) if a != b)
        ok &= (mm == 0)
        tag = '增益 1.0' if fi < 2 else '收敛增益'
        print(f'    帧{fi}（{tag:6s}）: 位级 0 误差? {mm == 0}（{TOTAL - mm}/{TOTAL}）')

    # =============== 二、PSNR（RTL 实拍 vs 理想靶子）===============
    noisy = load_hex(os.path.join('..', 'FpgaIspChain', 'chain_in_img.hex'))  # 未偏色（同噪声/坏点）
    ideal = chain_ref(noisy, W_IMG, H_IMG, lut, inv, mint, glut)['s8']
    pb = psnr8(rtl[0:TOTAL], ideal)                        # 无 AWB（帧 0）
    pc = psnr8(rtl[2 * TOTAL:3 * TOTAL], ideal)            # AWB 收敛（帧 2）
    print('=' * 70)
    print('[2] 端到端 PSNR（末端 RGB888 vs 理想靶子=未偏色整链输出，8bit 口径）')
    print(f'    无 AWB（帧0，增益 1.0） : {pb:6.2f} dB')
    print(f'    ★ AWB 收敛（帧2）      : {pc:6.2f} dB    （提升 {pc - pb:+.2f} dB）')
    ok &= (pc > pb)

    # =============== 三、通道均值（色偏消除的直接证据）===============
    print('=' * 70)
    print('[3] 通道均值（8bit 域）：色偏应被拉回靶子水平')
    mb = ch_means(rtl[0:TOTAL], True)
    mc = ch_means(rtl[2 * TOTAL:3 * TOTAL], True)
    mi = ch_means(ideal, True)
    print(f'    无 AWB : R {mb[0]:6.2f}  G {mb[1]:6.2f}  B {mb[2]:6.2f}')
    print(f'    收敛   : R {mc[0]:6.2f}  G {mc[1]:6.2f}  B {mc[2]:6.2f}')
    print(f'    理想   : R {mi[0]:6.2f}  G {mi[1]:6.2f}  B {mi[2]:6.2f}')

    # =============== 四、对比图（6 格，沿用 M5.3 版式）===============
    conv = rtl[2 * TOTAL:3 * TOTAL]
    scale, bw = 3, 28
    tw, th = W_IMG * scale, H_IMG * scale + bw
    canvas = Image.new('RGB', (tw * 3, th * 2), (255, 255, 255))
    dr = ImageDraw.Draw(canvas)
    f = font(13)
    dmax = max(abs(conv[i] - ideal[i]) for i in range(TOTAL))
    diff = []
    for i, p in enumerate(conv):
        q = ideal[i]
        dv = sum(abs(((p >> sh) & 255) - ((q >> sh) & 255)) for sh in (16, 8, 0)) // 3
        diff.append(min(dv * (255 // max(dmax // 3, 1)), 255))
    panels = [
        ('偏色 Bayer 输入（R×0.65 / B×1.35）', bayer_gray(tin, W_IMG, H_IMG, scale)),
        ('未偏色 Bayer（靶子输入）', bayer_gray(noisy, W_IMG, H_IMG, scale)),
        (f'无 AWB 末端出（帧0） PSNR {pb:.1f}dB', rgb_img(rtl[0:TOTAL], W_IMG, H_IMG, True, scale)),
        (f'AWB 收敛末端出（帧2） PSNR {pc:.1f}dB', rgb_img(conv, W_IMG, H_IMG, True, scale)),
        ('理想末端（靶子）', rgb_img(ideal, W_IMG, H_IMG, True, scale)),
        (f'|收敛−理想| ×{255 // max(dmax // 3, 1)}',
         rgb_img([(d << 16) | (d << 8) | d for d in diff], W_IMG, H_IMG, True, scale)),
    ]
    for i, (title, im) in enumerate(panels):
        x, y = (i % 3) * tw, (i // 3) * th
        dr.rectangle([x, y, x + tw - 1, y + bw - 1], fill=(240, 240, 240))
        dr.text((x + 5, y + 7), title, fill=(0, 0, 0), font=f)
        canvas.paste(im, (x, y + bw))
    canvas.save('awb_chain_compare.png')

    print('=' * 70)
    print('对比图已出：awb_chain_compare.png（AWB/ 本目录；偏色/未偏色 Bayer · 无 AWB/收敛/理想末端 · 差异）')
    print('[PASS] AWB 整链闭环独立复算 4 帧 0 误差 + 收敛 PSNR 提升' if ok
          else '[FAIL] 见上方不一致项')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())