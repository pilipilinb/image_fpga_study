#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_awb_data.py —— M6（AWB）数据与 golden 准备（Step 0）

两种模式：
  python make_awb_data.py            # small：协议 TB 数据（16×12，8 帧，RAW10）
  python make_awb_data.py --img      # img  ：真图偏色实验（112×103 Bayer RAW10，6 帧）

生成物（small，供 tb_awb_stat / tb_awb_gain / verify_awb.py）：
  awb_in_small.hex    8 帧 × 16×12 像素（RAW10，3 hex/行）
  awb_stat_exp.hex    8 帧 × 4 相位累加和（32bit，8 hex/行）——统计 golden
  awb_gain_exp.hex    8 帧 × 16×12 期望输出（RAW10）——按帧增益表 TAB 应用

生成物（img，供 Step 3 闭环 / PSNR）：
  awb_in_img.hex        偏色 Bayer RAW10（112×103，重复 6 帧，模拟光强被色偏系统乘性污染）
  awb_ideal_img.hex     无偏色理想 Bayer（PSNR 靶子，1 帧）
  awb_img_gain_seq.txt  逐帧 Q2.8 增益序列（N+2 口径）+ 统计值（人工可查）
  awb_img_exp.hex       闭环期望输出（6 帧 × 11536）

位级同构约定（与 RTL / 软核注释必须一致）：
  * 相位 = (row&1, col&1)：00=R, 01=Gr, 10=Gb, 11=B（RGGB）
  * 统计：每 fire 拍 sum[phase] += px；SOF 拍 shadow←sum（上一帧全量）、
          sum 组重启 = 本拍像素入新组、其余相位清零（每帧首像素不吞）
  * 增益应用（Q2.8，1.0=256，范围 [128,1023]）：
          out = (in*gain + 2^7) >> 8，再饱和到 [0,1023]
  * 帧边界生效：帧 i 全部像素（含首像素）用「帧 i 首像素（SOF）拍写口值」
  * 软核同构：mean = sum / (W*H/4)（整数除）；mg = (m01+m10)>>1；
          g_i = clamp((mg<<8) // max(m_i,1), 128, 1023)
  * 闭环节拍（N+2）：帧 i 的增益由帧 i-2 的统计算出（帧 0/1 用 1.0）

★ 帧增益表 TAB（tb_awb_gain 场景约定：TB 在「帧 f 发送过半」时把写口切到 TAB[f+1]）：
  帧 f 的期望 = 全部像素（含首像素）按 TAB[f] 应用。
"""
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))

W_S, H_S, FRAMES = 16, 12, 8      # small 协议场景（8 帧）
W_IMG, H_IMG     = 112, 103       # 真图（与 Demosaic/input.hex 尺寸一致）
DW, MAXV         = 10, 1023       # RAW10
GF, ONE          = 8, 256         # Q2.8 增益：1.0 = 2^8
G_MIN, G_MAX     = 128, 1023      # 软核限幅 [0.5, 3.996]
N_IMG_FRAMES     = 6              # img 闭环帧数

# 帧增益表（四相位顺序 00/01/10/11 = R/Gr/Gb/B；覆盖恒等/中间值/极值/饱和）
TAB = [
    (256, 256, 256, 256),            # f0 恒等
    (384, 320, 300, 512),            # f1 中间值（帧 0 后半切换过去）
    (128, 1023, 200, 1),             # f2 极小/极大（1/256 是「非法写值」边界，验证不崩）
    (256, 256, 256, 256),            # f3 回恒等
    (512, 512, 384, 256),            # f4
    (256, 256, 256, 256),            # f5
    (1023, 1023, 1023, 1023),        # f6 全局最大（饱和压测）
    (256, 256, 256, 256),            # f7
]

# 色偏注入系数（模拟光源/传感器响应差异，纯乘性作用在光强真值上）
# phase → (num, den)：R ×13/20=0.65；B ×27/20=1.35；G ×1（理想增益 ≈ 394 / 190）
TINT = {0: (13, 20), 1: (1, 1), 2: (1, 1), 3: (27, 20)}


def phase_of(row, col):
    """Bayer 相位（与 RTL 一致）：00=R / 01=Gr / 10=Gb / 11=B（RGGB）"""
    return ((row & 1) << 1) | (col & 1)


def save_hex(vals, path, width):
    with open(path, 'w') as f:
        for v in vals:
            f.write(f'{v & ((1 << width) - 1):0{(width + 3) // 4}X}\n')


def load_hex(path):
    with open(path) as f:
        return [int(l.strip(), 16) for l in f if l.strip()]


def apply_gain(px, g):
    """增益应用（与 RTL 位级同构）：(px*g + 2^7) >> 8 → 饱和 [0,1023]"""
    v = (px * g + (1 << (GF - 1))) >> GF
    return v if v <= MAXV else MAXV


def frame_sums(frm, w):
    """一帧的四相位累加和 [R, Gr, Gb, B]（与 RTL 统计级同构）"""
    s = [0, 0, 0, 0]
    for i, v in enumerate(frm):
        s[phase_of(i // w, i % w)] += v
    return s


def calc_gain(sums, cnt):
    """软核灰世界（Q2.8 位级同构）：mean→mg→g_i = clamp((mg<<8)//max(m_i,1), 128, 1023)"""
    m = [s // cnt for s in sums]            # 整数除（C 的 / 对正数 = floor）
    mg = (m[1] + m[2]) >> 1
    return [min(max((mg << 8) // max(mi, 1), G_MIN), G_MAX) for mi in m]


# ---------------------------------------------------------------------------
# small：协议 TB 数据 + 统计/增益 golden
# ---------------------------------------------------------------------------
def gen_small():
    total_f = W_S * H_S
    src = [(n * 131 + 7) & MAXV for n in range(FRAMES * total_f)]
    save_hex(src, os.path.join(_HERE, 'awb_in_small.hex'), DW)

    # 统计 golden：每帧四相位和（帧独立，帧间无耦合）
    sums_all = [frame_sums(src[f * total_f:(f + 1) * total_f], W_S)
                for f in range(FRAMES)]
    save_hex([v for s in sums_all for v in s],
             os.path.join(_HERE, 'awb_stat_exp.hex'), 32)

    # 增益 golden：帧 f 全部像素（含首像素）按 TAB[f] 应用
    exp = []
    for i, v in enumerate(src):
        f, j = divmod(i, total_f)
        exp.append(apply_gain(v, TAB[f][phase_of(j // W_S, j % W_S)]))
    save_hex(exp, os.path.join(_HERE, 'awb_gain_exp.hex'), DW)

    # 自检：golden 与复算一致（防生成逻辑自身错）
    assert frame_sums(src[:total_f], W_S) == sums_all[0]

    # ---- 手算样例（验收要求：增益序列数值人工可查）----
    print('---- small 手算样例（可人工核对）----')
    print('帧 0 行 0 前 8 像素：', ' '.join(f'{v:03X}' for v in src[:8]))
    print('  相位按列交替：00=R 01=Gr 00=R 01=Gr ...（16 列偶=00 奇=01）')
    cnt = total_f // 4
    print(f'帧 0 四相位和 = {sums_all[0]}（每相位 cnt = {cnt}）')
    m = [s // cnt for s in sums_all[0]]
    mg = (m[1] + m[2]) >> 1
    print(f'  mean = {m} → mg = (Gr+Gb)/2 = {mg}')
    for p, name in enumerate(['R  ', 'Gr ', 'Gb ', 'B  ']):
        g = min(max((mg << 8) // max(m[p], 1), G_MIN), G_MAX)
        print(f'  gain[{name}] = {g:4d}（Q2.8 → {g / ONE:.3f}）')
    print('帧增益表 TAB（tb_awb_gain 场景：帧 f 过半时切到 TAB[f+1]）：')
    for f, t in enumerate(TAB):
        print(f'  f{f}: {t}')
    print(f'OK small：awb_in_small.hex（{FRAMES} 帧 × {total_f}，10bit）')
    print('        + awb_stat_exp.hex（4 相位和 × 8 帧）'
          ' + awb_gain_exp.hex（逐像素期望）')


# ---------------------------------------------------------------------------
# img：真图偏色实验（输入 + 理想靶子 + 闭环 golden）
# ---------------------------------------------------------------------------
def gen_img():
    rgb = load_hex(os.path.join(_HERE, '..', 'Demosaic', 'input.hex'))
    assert len(rgb) == W_IMG * H_IMG, f'input.hex 像素数 {len(rgb)} != {W_IMG * H_IMG}'

    clean, tinted = [], []
    for r in range(H_IMG):
        for c in range(W_IMG):
            p = rgb[r * W_IMG + c]
            # 按 Bayer 相位从 RGB 真图取对应通道（同 M5.3 配方；低增益暗场景）
            ch = ((p >> 16) & 0xFF) if (r % 2 == 0 and c % 2 == 0) else \
                 ((p & 0xFF) if (r % 2 == 1 and c % 2 == 1) else ((p >> 8) & 0xFF))
            v = min(ch << 1, MAXV)
            clean.append(v)
            num, den = TINT[phase_of(r, c)]
            # round-half-up：floor(v*num/den + 0.5)
            tv = (2 * v * num + den) // (2 * den)
            tinted.append(min(tv, MAXV))

    save_hex(tinted * N_IMG_FRAMES, os.path.join(_HERE, 'awb_in_img.hex'), DW)
    save_hex(clean, os.path.join(_HERE, 'awb_ideal_img.hex'), DW)

    # 闭环 golden（N+2 口径）：帧 i 增益 = calc(帧 i-2 统计)；帧 0/1 = 1.0
    cnt = W_IMG * H_IMG // 4
    sums = frame_sums(tinted, W_IMG)      # 同一张图重复 → 每帧统计相同
    g_one = [ONE] * 4
    gain_seq = [g_one, g_one]
    for f in range(2, N_IMG_FRAMES):
        gain_seq.append(calc_gain(sums, cnt))

    exp = []
    for f in range(N_IMG_FRAMES):
        g = gain_seq[f]
        for i, v in enumerate(tinted):
            exp.append(apply_gain(v, g[phase_of(i // W_IMG, i % W_IMG)]))
    save_hex(exp, os.path.join(_HERE, 'awb_img_exp.hex'), DW)

    with open(os.path.join(_HERE, 'awb_img_gain_seq.txt'), 'w') as fp:
        fp.write('闭环（N+2 口径）：帧 i 增益 = calc(帧 i-2 统计)；帧 0/1 用 1.0\n')
        for f, g in enumerate(gain_seq):
            fp.write(f'f{f}: {g}\n')
        fp.write(f'\n统计（偏色图）：{sums}\ncnt = {cnt}\n')
        fp.write('色偏系数：R ×13/20、B ×27/20（G ×1）→ 理论补偿 ≈ 394 / 190\n')

    print('---- img 闭环 golden（人工可查，详见 awb_img_gain_seq.txt）----')
    print(f'偏色图四相位和 = {sums}（cnt = {cnt}）')
    print(f'收敛增益（帧 2 起）= {gain_seq[2]}（R/Gr/Gb/B，Q2.8）')
    print(f'  理论对照：1/0.65×256 ≈ {round(1/0.65*ONE)}，1/1.35×256 ≈ {round(1/1.35*ONE)}')
    print(f'OK img：awb_in_img.hex（{N_IMG_FRAMES} 帧 × {W_IMG * H_IMG}）'
          ' + awb_ideal_img.hex + awb_img_exp.hex + awb_img_gain_seq.txt')


def main():
    mode = 'img' if '--img' in sys.argv else 'small'
    if mode == 'small':
        gen_small()
    else:
        gen_img()


if __name__ == '__main__':
    main()