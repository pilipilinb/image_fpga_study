#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# make_dpc_data.py —— 生成坏点测试数据 + Python 参考 + 对比图（DPC 工程）
#
# 干什么（三步）：
#   1. 拿一张干净的 Bayer 图（bayer.hex），人为注入坏点：
#      亮点（置 255）和死点（置 0），位置随机但 **seed 固定**（保证可复现）
#      → 写出 bayer_defect.hex（给 RTL 当输入）+ defect_pos.txt（坏点位置清单）
#   2. 用 Python 跑一遍包络检测校正（和 RTL 同一套公式）→ ref_dpc.hex
#      （给 RTL 输出做"逐位全等"比对）
#   3. 统计并打印：坏点图/校正后 vs 干净图的 PSNR、修复率、误伤率；拼对比图
#
# 用法：python make_dpc_data.py
#
# 包络检测（伪代码）：
#   同色邻居的 min/max；P > mx+thr → 抄 mx（亮点）；P < mn-thr → 抄 mn（死点）；否则不动
import math
import random
from PIL import Image, ImageDraw, ImageFont

W, H = 112, 103
MW, MH = W - 4, H - 4        # 输出 108×99（5×5 窗口裁掉四周各 2 圈）
THR = 32                     # 判定阈值（与 RTL 默认一致）
N_DEFECT = 60                # 注入坏点个数（亮点/死点各半）
SEED = 20260916              # 固定随机种子：坏点位置可复现

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


def save_hex8(px, path):
    with open(path, 'w') as f:
        for p in px:
            f.write(f'{p & 0xFF:02X}\n')


def psnr_gray(a, b):
    mse = sum((x - y) ** 2 for x, y in zip(a, b)) / len(a)
    return 10 * math.log10(255 * 255 / mse) if mse > 0 else float('inf')


# ---------------------------------------------------------------------------
# 第 1 步：注入坏点（固定 seed）
# ---------------------------------------------------------------------------
def inject_defects(bayer, w, h, n, seed):
    rnd = random.Random(seed)
    out = list(bayer)
    pos = []                       # [(行, 列, 值)]，值 255=亮点 0=死点
    while len(pos) < n:
        r = rnd.randrange(2, h - 2)   # 只注入到"会输出"的内部区域，便于统计
        c = rnd.randrange(2, w - 2)
        idx = r * w + c
        if any(p[0] == r and p[1] == c for p in pos):
            continue
        v = 255 if len(pos) % 2 == 0 else 0
        out[idx] = v
        pos.append((r, c, v))
    return out, pos


# ---------------------------------------------------------------------------
# 第 2 步：包络检测校正（与 RTL 同一套公式）
#   中心 (R,C)：先按 (R%2, C%2) 决定"同色"条件，再在 5×5 内挑同色邻居取 min/max
#     R 相位 → 取 (偶,偶)；B 相位 → 取 (奇,奇)；G 相位 → 取 (偶,奇)/(奇,偶)（G 合并）
# ---------------------------------------------------------------------------
def dpc_ref(bayer, w, h, thr=THR):
    out = []
    for R in range(2, h - 2):
        for C in range(2, w - 2):
            P = bayer[R * w + C]
            # 中心相位
            if R % 2 == 0 and C % 2 == 0:
                same = lambda r, c: (r % 2 == 0 and c % 2 == 0)     # R
            elif R % 2 == 1 and C % 2 == 1:
                same = lambda r, c: (r % 2 == 1 and c % 2 == 1)     # B
            else:
                same = lambda r, c: ((r % 2) != (c % 2))            # G（Gr/Gb 合并）
            nb = []
            for r in range(R - 2, R + 3):
                for c in range(C - 2, C + 3):
                    if r == R and c == C:
                        continue
                    if same(r, c):
                        nb.append(bayer[r * w + c])
            mn, mx = min(nb), max(nb)
            if P > mx + thr:
                out.append(mx)          # 亮点 → 抄最亮邻居
            elif P + thr < mn:
                out.append(mn)          # 死点 → 抄最暗邻居
            else:
                out.append(P)           # 正常 → 原样
    return out


def to_img_gray(px, w, h):
    img = Image.new('RGB', (w, h))
    img.putdata([(p, p, p) for p in px])
    return img


def main():
    clean = load_hex8('bayer.hex')
    if len(clean) != W * H:
        raise SystemExit(f'错误: bayer.hex 有 {len(clean)} 像素，期望 {W}×{H}')

    # 1. 注入坏点
    defect, pos = inject_defects(clean, W, H, N_DEFECT, SEED)
    save_hex8(defect, 'bayer_defect.hex')
    with open('defect_pos.txt', 'w') as f:
        for r, c, v in pos:
            f.write(f'{r} {c} {v}\n')
    print(f'OK: bayer.hex → bayer_defect.hex（注入 {N_DEFECT} 个坏点，seed={SEED}，'
          f'亮点/死点各半）→ 位置清单 defect_pos.txt')

    # 2. Python 参考校正
    ref = dpc_ref(defect, W, H, THR)
    save_hex8(ref, 'ref_dpc.hex')
    print(f'OK: 参考校正 → ref_dpc.hex（{MW}×{MH} = {len(ref)} 像素，与 RTL 同公式）')

    # 3. 指标统计（在输出网格上比：中心 (r,c) ↔ 输出 (r-2, c-2)）
    clean_in = [clean[(r + 2) * W + (c + 2)] for r in range(MH) for c in range(MW)]
    defect_in = [defect[(r + 2) * W + (c + 2)] for r in range(MH) for c in range(MW)]
    defect_set = {(r - 2, c - 2) for r, c, v in pos if 2 <= r < H - 2 and 2 <= c < W - 2}
    # 修复率：坏点位置里被改掉的（输出 ≠ 坏点值）；误伤率：非坏点位置被改的
    fixed = sum(1 for (r, c) in defect_set if ref[r * MW + c] != defect_in[r * MW + c])
    hurt = sum(1 for k in range(MW * MH)
               if (k // MW, k % MW) not in defect_set and ref[k] != defect_in[k])

    print('========================================')
    print(f'坏点图   vs 干净图 : PSNR = {psnr_gray(defect_in, clean_in):.2f} dB（坏点伤害）')
    print(f'校正后   vs 干净图 : PSNR = {psnr_gray(ref, clean_in):.2f} dB（恢复度）')
    print(f'修复率：{fixed}/{len(defect_set)} 个坏点被改掉（{fixed*100.0/max(1,len(defect_set)):.1f}%）')
    print(f'误伤率：{hurt}/{MW*MH-len(defect_set)} 个正常像素被改（'
          f'{hurt*100.0/(MW*MH-len(defect_set)):.3f}%，THR={THR} 下的副作用）')
    print('========================================')

    # 4. 对比图：干净 | 带坏点 | 校正后（灰度）
    gap, top = 8, 30
    canvas = Image.new('RGB', (W * 3 + gap * 4, max(H, MH) + top + 10), (24, 24, 30))
    draw = ImageDraw.Draw(canvas)
    labels = ['干净 Bayer（参考）', f'注入 {N_DEFECT} 个坏点（亮点/死点）', 'DPC 校正后']
    imgs = [to_img_gray(clean, W, H), to_img_gray(defect, W, H), to_img_gray(ref, MW, MH)]
    for i, (im, t) in enumerate(zip(imgs, labels)):
        x = gap + i * (W + gap)
        canvas.paste(im, (x, top))
        draw.text((x, 6), t, font=font(15), fill=(255, 255, 255))
    canvas.save('dpc_compare.png')
    print('对比图已保存: dpc_compare.png（干净 | 带坏点 | 校正后）')


if __name__ == '__main__':
    main()