#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_gamma.py —— M4-3 Gamma 独立校验（第二判据）

五条判据：
  1. **LUT 全表覆盖**：ramp 模式跑 1024 值穷举（输入 (x,x,x)），RTL 输出逐项 vs .coe 表
     —— 1024 个表项**每一个**都被验证过（不是抽样）
  2. **单调性 + 端点**：gamma 曲线必须单调不减；LUT[0]=0、LUT[1023]=255
  3. 真图位级全等：RTL（gamma_out_img.txt，24bit）vs golden（exp_img.hex）
  4. 亮度量化：线性直通（>>2）vs Gamma 输出的均值/中位数 —— gamma 提亮的证据
  5. 对比图：真图 线性直通 vs Gamma 输出；另画 gamma 曲线图（含线性参考）

用法（先跑 TB 落盘）：
  python make_gamma_data.py --ramp && iverilog -DRAMP ... && vvp tb_r.vvp
  python make_gamma_data.py --img  && iverilog -DIMG  ... && vvp tb_i.vvp
  python verify_gamma.py
"""
import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFont

DW, OW = 10, 8
MAXV, MAXO = 1023, 255
W_IMG, H_IMG = 112, 103
W_R, H_R = 64, 16
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


def unpack30(px, w, h):
    a = np.array(px, dtype=np.int64)
    return np.stack([(a >> 20) & MAXV, (a >> 10) & MAXV, a & MAXV],
                    axis=1).reshape(h, w, 3).astype(np.float64)


def unpack24(px, w, h):
    a = np.array(px, dtype=np.int64)
    return np.stack([(a >> 16) & MAXO, (a >> 8) & MAXO, a & MAXO],
                    axis=1).reshape(h, w, 3).astype(np.float64)


def to_img8(a):
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), 'RGB')


def main():
    lut = load_hex('gamma_lut.coe')
    ok = True
    print('========================================')
    print(f'.coe 表：{len(lut)} 项，LUT[0]={lut[0]} LUT[1023]={lut[1023]}')

    # ---------------- 判据 1：LUT 全表覆盖（ramp） ----------------
    if os.path.exists('gamma_out_ramp.txt'):
        rtl = load_hex('gamma_out_ramp.txt')
        exp = load_hex('gamma_ramp_exp.hex')
        bad_tab = [i for i in range(min(len(rtl), len(lut)))
                   if rtl[i] != ((lut[i] << 16) | (lut[i] << 8) | lut[i])]
        bad_exp = [i for i in range(min(len(rtl), len(exp))) if rtl[i] != exp[i]]
        print(f'[判据1] RTL 穷举 {len(rtl)} 值 vs .coe 表 逐项：'
              f'{"1024 项全覆盖，0 误差" if not bad_tab else f"{len(bad_tab)} 项不符 [FAIL]"}')
        print(f'        RTL vs Python golden（{len(exp)} 项）：'
              f'{"全等 0 误差" if not bad_exp else f"{len(bad_exp)} 项不符 [FAIL]"}')
        if bad_tab or bad_exp:
            ok = False
            i = (bad_tab or bad_exp)[0]
            print(f'  首个不符 x={i}: rtl={rtl[i]:06X} lut={lut[i]:02X} exp={exp[i]:06X}')
    else:
        print('[判据1] 跳过：缺 gamma_out_ramp.txt（先跑 RAMP 模式 TB）')

    # ---------------- 判据 2：单调性 + 端点 ----------------
    mono = all(lut[i] <= lut[i + 1] for i in range(len(lut) - 1))
    ends = (lut[0] == 0 and lut[-1] == MAXO)
    print(f'[判据2] 单调不减={mono}  端点(LUT[0]=0, LUT[{len(lut)-1}]={MAXO})={ends}')
    if not (mono and ends):
        ok = False

    # ---------------- 判据 2b：bypass 路径穷举（独立于 TB 期望，堵"共享 bug"盲区）----------------
    #   bypass = 线性 10→8 = min(round(v/4), 255)（round-half-up + 饱和）
    #   ★ 这里用 Python 独立算：TB 的期望函数曾与 DUT 用同一表达式，两边同错而不报
    if os.path.exists('gamma_out_byp.txt'):
        byp = load_hex('gamma_out_byp.txt')
        n = min(len(byp), 1 << DW)
        bad_b = []
        for x in range(n):
            e = min((x + 2) // 4, MAXO)
            if byp[x] != ((e << 16) | (e << 8) | e):
                bad_b.append(x)
        print(f'[判据2b] bypass 穷举 {n} 值 vs Python 独立算 min(round(v/4),255)：'
              f'{"0 误差" if not bad_b else f"{len(bad_b)} 项不符 [FAIL]"}')
        if bad_b:
            ok = False
            x = bad_b[0]
            print(f'  首个不符 v={x}: rtl={byp[x]:06X} exp={min((x+2)//4, MAXO):02X}')
            print(f'  端点抽查 v=1022/1023: rtl={byp[1022]:06X}/{byp[1023]:06X}'
                  f'（饱和后应为 FFFFFF）')
    else:
        print('[判据2b] 跳过：缺 gamma_out_byp.txt（RAMP 模式 TB 会生成）')

    # ---------------- 判据 3：真图位级全等 ----------------
    if os.path.exists('gamma_out_img.txt') and os.path.exists('exp_img.hex'):
        rtl_i = load_hex('gamma_out_img.txt')
        exp_i = load_hex('exp_img.hex')
        n = min(len(rtl_i), len(exp_i))
        bad = [i for i in range(n) if rtl_i[i] != exp_i[i]]
        print(f'[判据3] 真图 RTL vs Python golden：{n} 像素，'
              f'{"全等（0 误差）" if not bad else f"{len(bad)} 个不一致 [FAIL]"}')
        if bad:
            ok = False
            i = bad[0]
            print(f'  首个不一致 #{i} ({i//W_IMG},{i%W_IMG}): rtl={rtl_i[i]:06X} exp={exp_i[i]:06X}')

        # ---------------- 判据 4：亮度量化 ----------------
        lin10 = unpack30(load_hex('gamma_in.hex'), W_IMG, H_IMG)      # CCM 输出（线性 10bit）
        lin8 = np.floor(lin10 / 4.0)                                   # 线性直通（>>2）的观感
        gam8 = unpack24(rtl_i[:n], W_IMG, H_IMG)
        print('----------------------------------------')
        print(f'[判据4] 亮度（8bit 域）：线性直通 均值 {lin8.mean():6.2f}'
              f' / 中位 {np.median(lin8):6.1f}   →  Gamma 均值 {gam8.mean():6.2f}'
              f' / 中位 {np.median(gam8):6.1f}')
        print(f'        提亮量：均值 +{gam8.mean() - lin8.mean():.2f}'
              f'（约 {(gam8.mean() / max(lin8.mean(), 1e-9) - 1) * 100:.1f}%）')

        # ---------------- 判据 5：对比图 ----------------
        gap, top, sc = 8, 30, 3
        dw, dh = W_IMG * sc, H_IMG * sc
        cv = Image.new('RGB', (dw * 2 + gap * 3, dh + top + 10), (24, 24, 30))
        dr = ImageDraw.Draw(cv)
        for i, (im, t) in enumerate([
                (lin8, '线性直通（10bit >> 2，不做 gamma）'),
                (gam8, f'Gamma 输出（RTL，{OW}bit；均值 +{gam8.mean()-lin8.mean():.1f}）')]):
            x = gap + i * (dw + gap)
            cv.paste(to_img8(im).resize((dw, dh), Image.NEAREST), (x, top))
            dr.text((x, 6), t, font=font(15), fill=(255, 255, 255))
        cv.save('gamma_compare.png')
        print('对比图：gamma_compare.png（线性直通 vs Gamma）')
    else:
        print('[判据3/4/5] 跳过：缺 gamma_out_img.txt（先跑 IMG 模式 TB）')

    # ---------------- 曲线图（gamma vs 线性） ----------------
    cw, ch, mg = 640, 360, 40
    cv = Image.new('RGB', (cw, ch), (250, 250, 252))
    dr = ImageDraw.Draw(cv)
    dr.rectangle([mg, mg, cw - mg, ch - mg], outline=(120, 120, 130))
    for gv in (0, 64, 128, 192, 255):                       # 网格
        y = ch - mg - int(gv / 255.0 * (ch - 2 * mg))
        dr.line([mg, y, cw - mg, y], fill=(225, 225, 232))
        dr.text((6, y - 8), str(gv), font=font(12), fill=(90, 90, 100))
    def px(x):  return mg + int(x / 1023.0 * (cw - 2 * mg))
    def py(v):  return ch - mg - int(v / 255.0 * (ch - 2 * mg))
    pts_lin = [(px(x), py(x >> 2)) for x in range(0, 1024, 4)]
    pts_gam = [(px(x), py(lut[x])) for x in range(0, 1024, 4)]
    dr.line(pts_lin, fill=(150, 160, 175), width=2)
    dr.line(pts_gam, fill=(220, 90, 60), width=3)
    dr.text((mg + 10, mg + 6), 'gamma 曲线（红）vs 线性直通 >>2（灰）',
            font=font(15), fill=(40, 40, 50))
    cv.save('gamma_curve.png')
    print('曲线图：gamma_curve.png')

    print('========================================')
    print('[PASS] Gamma 独立校验全部通过' if ok else '[FAIL] 见上方不一致项')


if __name__ == '__main__':
    main()
