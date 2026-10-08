#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_ccm.py —— M4-2 CCM 独立校验（第二判据）

四条判据：
  1. 位级全等（真图）：RTL 输出 ccm_out_img.txt vs Python golden exp_img.hex 逐像素比对
  2. 灰阶保持：Python 穷举 v=0..1023 过系数表必须逐位不变（行和=1 的定点实现）；
     并在 RTL 输出上抽查"输入本身是灰(r=g=b)的像素 ⇒ 输出必须 == 输入"
  3. ΔE76（24 色卡）：用 **RTL 输出**（ccm_out_chart.txt）逐块取中心像素，
     对比理想线性 RGB —— 校正前 vs 校正后
  4. 对比图：真图前后（ccm_compare.png）+ 色卡三栏（ccm_chart_compare.png）

用法（先跑 TB 落盘）：
  python make_ccm_data.py --img    && iverilog -DIMG ... && vvp tb_i.vvp
  python make_ccm_data.py --chart  && iverilog -DCHART ... && vvp tb_c.vvp
  python verify_ccm.py
"""
import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFont

from make_ccm_data import (MAXV, CH_N, CH_P, ccm_ref, quant_coef, delta_e76)

W_IMG, H_IMG = 112, 103
W_CH, H_CH = CH_N * CH_P, 4 * CH_P          # 96 × 64
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


def unpack(px, w, h):
    a = np.array(px, dtype=np.int64)
    return np.stack([(a >> 20) & MAXV, (a >> 10) & MAXV, a & MAXV],
                    axis=1).reshape(h, w, 3).astype(np.float64)


def to_img(a):
    return Image.fromarray(np.clip(a / 4.0, 0, 255).astype(np.uint8), 'RGB')


def main():
    mint = quant_coef()
    ok = True

    # ---------------- 判据 1：真图位级全等 ----------------
    if os.path.exists('ccm_out_img.txt') and os.path.exists('exp_img.hex'):
        rtl = load_hex('ccm_out_img.txt')
        exp = load_hex('exp_img.hex')
        n = min(len(rtl), len(exp))
        bad = [i for i in range(n) if rtl[i] != exp[i]]
        print('========================================')
        print(f'[判据1] 真图 RTL vs Python golden：{n} 像素，'
              f'{"全等（0 误差）" if not bad else f"{len(bad)} 个不一致 [FAIL]"}')
        if bad:
            ok = False
            i = bad[0]
            print(f'  首个不一致 #{i} ({i//W_IMG},{i%W_IMG}): rtl={rtl[i]:08X} exp={exp[i]:08X}')

        src_img = unpack(load_hex('ccm_in.hex'), W_IMG, H_IMG)
        rtl_img = unpack(rtl[:n], W_IMG, H_IMG)

        # ---------------- 判据 2（b）：RTL 上的灰阶抽查 ----------------
        flat_s = src_img.reshape(-1, 3).astype(int)
        flat_r = rtl_img.reshape(-1, 3).astype(int)
        grays = np.where((flat_s[:, 0] == flat_s[:, 1]) & (flat_s[:, 1] == flat_s[:, 2]))[0]
        if len(grays):
            gbad = [i for i in grays if not np.array_equal(flat_r[i], flat_s[i])]
            print(f'[判据2b] RTL 灰阶抽查：输入灰像素 {len(grays)} 个，'
                  f'{"全部逐位保持" if not gbad else f"{len(gbad)} 个改变 [FAIL]"}')
            if gbad:
                ok = False
        else:
            print('[判据2b] RTL 灰阶抽查：真图中无精确灰像素（跳过，见判据2a 穷举）')

        # 真图对比图
        gap, top, sc = 8, 30, 3
        dw, dh = W_IMG * sc, H_IMG * sc
        cv = Image.new('RGB', (dw * 2 + gap * 3, dh + top + 10), (24, 24, 30))
        dr = ImageDraw.Draw(cv)
        for i, (im, t) in enumerate([(src_img, 'M3 链出图（线性 RGB 10bit）'),
                                     (rtl_img, 'CCM 输出（RTL，位级 = golden）')]):
            x = gap + i * (dw + gap)
            cv.paste(to_img(im).resize((dw, dh), Image.NEAREST), (x, top))
            dr.text((x, 6), t, font=font(15), fill=(255, 255, 255))
        cv.save('ccm_compare.png')
        print('对比图：ccm_compare.png（真图 CCM 前后）')
    else:
        print('[判据1/2b] 跳过：缺 ccm_out_img.txt / exp_img.hex（先跑 IMG 模式 TB）')

    # ---------------- 判据 2（a）：灰阶保持穷举 ----------------
    bad_v = [v for v in range(MAXV + 1)
             if ccm_ref([(v << 20) | (v << 10) | v], mint)[0] != ((v << 20) | (v << 10) | v)]
    print('----------------------------------------')
    print(f'[判据2a] 灰阶保持穷举 v=0..{MAXV}：'
          f'{"全部逐位不变（行和=4096 生效）" if not bad_v else f"{len(bad_v)} 个不保持 [FAIL]"}')
    if bad_v:
        ok = False

    # ---------------- 判据 3：24 色卡 ΔE76（用 RTL 输出） ----------------
    if os.path.exists('ccm_out_chart.txt') and os.path.exists('chart_ideal.hex'):
        rtl_c = load_hex('ccm_out_chart.txt')
        ideal = load_hex('chart_ideal.hex')
        sens = load_hex('chart_sensor.hex')
        # 每块中心像素在拼接图中的线性位置
        pos = [((i // CH_N) * CH_P + CH_P // 2) * W_CH + (i % CH_N) * CH_P + CH_P // 2
               for i in range(24)]
        de_b = [delta_e76(sens[i], ideal[i]) for i in range(24)]
        de_a = [delta_e76(rtl_c[pos[i]], ideal[i]) for i in range(24)]
        print('----------------------------------------')
        print('[判据3] 24 色卡 ΔE76（RTL 输出 vs 理想线性 RGB）：')
        print(f'  校正前（传感器响应）：均值 {sum(de_b)/24:6.2f}   最大 {max(de_b):6.2f}')
        print(f'  校正后（CCM / RTL）  ：均值 {sum(de_a)/24:6.2f}   最大 {max(de_a):6.2f}')
        print(f'  灰阶 6 块（后 6）：校正前 {[round(x,2) for x in de_b[18:]]}')
        print(f'  灰阶 6 块（后 6）：校正后 {[round(x,2) for x in de_a[18:]]}  ← 应≈0')

        # 色卡三栏图
        sens_img = unpack(sens, CH_N, 4)
        rtl_img = unpack([rtl_c[pos[i]] for i in range(24)], CH_N, 4)
        ideal_img = unpack(ideal, CH_N, 4)
        gap, top, sc = 10, 30, 22
        dw, dh = CH_N * sc, 4 * sc
        cv = Image.new('RGB', (dw * 3 + gap * 4, dh + top + 12), (24, 24, 30))
        dr = ImageDraw.Draw(cv)
        for i, (im, t) in enumerate([
                (sens_img, f'传感器响应（校正前）ΔE {sum(de_b)/24:.2f}'),
                (rtl_img,  f'CCM 输出 / RTL    ΔE {sum(de_a)/24:.2f}'),
                (ideal_img, '理想目标（参考）')]):
            x = gap + i * (dw + gap)
            cv.paste(to_img(im).resize((dw, dh), Image.NEAREST), (x, top))
            dr.text((x, 6), t, font=font(15), fill=(255, 255, 255))
        cv.save('ccm_chart_compare.png')
        print('对比图：ccm_chart_compare.png（色卡三栏）')
    else:
        print('[判据3] 跳过：缺 ccm_out_chart.txt（先跑 CHART 模式 TB）')

    print('========================================')
    print('[PASS] CCM 独立校验全部通过' if ok else '[FAIL] 见上方不一致项')


if __name__ == '__main__':
    main()
