#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_awb.py —— M6 Step1/Step2 独立第二判据（不依赖 TB 内建记分板）

判据（全部从 awb_in_small.hex 重算，独立于 TB/make 脚本的实现）：
  ① 统计透传：stat_out.txt（RTL 出侧落盘 1920 行）vs 输入序列复算
     （输入序列 = 8 帧 + 复位段重发 2 帧，由 TB 场景约定）
  ② 统计封存：stat_shadow.txt（10 个封存点）vs 复算
     （fr=0 封存初值 0；fr=f 封存帧 f-1 全量；复位段从 fr=0 重来）
  ③ 交叉核对：awb_stat_exp.hex（make 产物）vs 复算的 8 帧四相位和
  ④ 增益位级：gain_out.txt（1920 行）vs 按帧增益表 TAB 复算
     （帧 f = 全部像素按 TAB[f]（含首像素）；复位段写口=256 ⇒ 恒等）

用法（需先跑两个 TB）：
  vvp tb_stat.vvp && vvp tb_gain.vvp     # 或经看门狗
  python verify_awb.py
"""
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))

IMG_W, IMG_H, DW = 16, 12, 10
TOTAL = IMG_W * IMG_H
FRAMES = 8
GF, ONE, G_MIN, G_MAX, MAXV = 8, 256, 128, 1023, 1023

# ★ 帧增益表（与 tb_awb_gain / make_awb_data.py 的场景约定一致）
TAB = [
    (256, 256, 256, 256),
    (384, 320, 300, 512),
    (128, 1023, 200, 1),
    (256, 256, 256, 256),
    (512, 512, 384, 256),
    (256, 256, 256, 256),
    (1023, 1023, 1023, 1023),
    (256, 256, 256, 256),
]


def load_hex(path):
    with open(path) as f:
        return [int(l.strip(), 16) for l in f if l.strip()]


def phase_of(row, col):
    return ((row & 1) << 1) | (col & 1)


def apply_gain(px, g):
    v = (px * g + (1 << (GF - 1))) >> GF
    return v if v <= MAXV else MAXV


def frame_sums(frm, w):
    s = [0, 0, 0, 0]
    for i, v in enumerate(frm):
        s[phase_of(i // w, i % w)] += v
    return s


def cmp_list(name, got, exp):
    n = min(len(got), len(exp))
    bad = [i for i in range(n) if got[i] != exp[i]]
    ok = (len(got) == len(exp)) and not bad
    print(f'[{"OK " if ok else "FAIL"}] {name}：{len(got)} 行 vs 期望 {len(exp)} 行'
          f'{"，0 误差" if ok else f"，{len(bad)} 处不一致"}')
    if bad:
        i = bad[0]
        print(f'   首个差异 #{i}: got={got[i]} exp={exp[i]}')
    return ok


def main():
    for f in ('awb_in_small.hex', 'stat_out.txt', 'stat_shadow.txt',
              'gain_out.txt', 'awb_stat_exp.hex'):
        if not os.path.exists(os.path.join(_HERE, f)):
            raise SystemExit(f'缺少 {f}——请先跑 make_awb_data.py 与两个 TB')

    src = load_hex(os.path.join(_HERE, 'awb_in_small.hex'))
    assert len(src) == FRAMES * TOTAL, f'awb_in_small.hex 行数 {len(src)}'

    ok = True
    print('========================================')
    print('AWB Step1/2 独立第二判据（全部从输入 hex 重算）')

    # ---------------- ① 统计透传 ----------------
    st = load_hex(os.path.join(_HERE, 'stat_out.txt'))
    seq = src + src[:2 * TOTAL]           # 8 帧 + 复位段重发 2 帧
    ok &= cmp_list('统计透传 stat_out.txt', st, seq)

    # ---------------- ② 统计封存 ----------------
    lines = [l.split() for l in open(os.path.join(_HERE, 'stat_shadow.txt')) if l.strip()]
    got_sh = [(int(l[0]), [int(x, 16) for x in l[1:5]]) for l in lines]
    exp_sh = []
    for fr in range(FRAMES):              # 正常段
        exp_sh.append((fr + 1, [0, 0, 0, 0] if fr == 0
                       else frame_sums(src[(fr - 1) * TOTAL:fr * TOTAL], IMG_W)))
    for fr in range(2):                   # 复位段（重发帧 0/1）
        exp_sh.append((fr + 1, [0, 0, 0, 0] if fr == 0
                       else frame_sums(src[0:TOTAL], IMG_W)))
    sh_ok = len(got_sh) == len(exp_sh)
    bad_n = 0
    for i in range(min(len(got_sh), len(exp_sh))):
        if got_sh[i][0] != exp_sh[i][0] or got_sh[i][1] != exp_sh[i][1]:
            bad_n += 1
            if bad_n <= 4:
                print(f'   SEAL #{i}: got fc={got_sh[i][0]} {got_sh[i][1]}'
                      f' exp fc={exp_sh[i][0]} {exp_sh[i][1]}')
    ok &= sh_ok and bad_n == 0
    print(f'[{"OK " if (sh_ok and bad_n == 0) else "FAIL"}] 统计封存 stat_shadow.txt：'
          f'{len(got_sh)} 个封存点 vs 期望 {len(exp_sh)}'
          f'{"，0 误差" if (sh_ok and bad_n == 0) else f"，{bad_n} 处不一致"}')

    # ---------------- ③ 交叉核对 make 的统计 golden ----------------
    exp_sum = load_hex(os.path.join(_HERE, 'awb_stat_exp.hex'))
    rec = [v for fr in range(FRAMES)
           for v in frame_sums(src[fr * TOTAL:(fr + 1) * TOTAL], IMG_W)]
    ok &= cmp_list('交叉核对 awb_stat_exp.hex（make vs 复算）', rec, exp_sum)

    # ---------------- ④ 增益位级 ----------------
    go = load_hex(os.path.join(_HERE, 'gain_out.txt'))
    exp_g = []
    for i, v in enumerate(src):
        fr, j = divmod(i, TOTAL)
        exp_g.append(apply_gain(v, TAB[fr][phase_of(j // IMG_W, j % IMG_W)]))
    for i in range(2 * TOTAL):            # 复位段：写口 256 ⇒ 恒等
        exp_g.append(apply_gain(src[i], ONE))
    ok &= cmp_list('增益位级 gain_out.txt', go, exp_g)

    # ---------------- 手算样例（人工可查）----------------
    print('---- 手算样例（帧 1/帧 2 首像素，可人工核对）----')
    for fr in (1, 2):
        v = src[fr * TOTAL]
        g = TAB[fr][0]
        print(f'  帧 {fr} 首像素 in={v:03X}（R 相位），TAB[{fr}][R]={g}：'
              f'({v}*{g}+128)>>8 = {(v * g + 128) >> 8}（期望输出 {exp_g[fr * TOTAL]:03X}）')
    print('  帧 6 饱和校验：in=%03X, g=1023 → 复算输出 %03X（期望饱和 3FF）'
          % (src[6 * TOTAL], exp_g[6 * TOTAL]))

    print('========================================')
    print('[PASS] AWB Step1/2 独立校验全部通过' if ok else '[FAIL] 见上方不一致项')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()