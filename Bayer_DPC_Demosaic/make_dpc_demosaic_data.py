#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_dpc_demosaic_data.py —— M3（DPC→Demosaic）数据与期望生成 + PSNR + 对比图

两种模式：
  python make_dpc_demosaic_data.py           # small：协议 TB 用（16×12×5 帧，伪随机像素，无坏点）
  python make_dpc_demosaic_data.py --img     # img：图像链用（真图 112×103，BLC 后 + 注 60 坏点）

生成物：
  small 模式：exp_rgb_small_bilinear.hex / exp_rgb_small_mhc.hex（期望 RGB，{r,g,b} 各 10bit 拼 30bit hex）
  img   模式：blc_dpc_in.hex（RTL 链输入：BLC 后 Bayer RAW10 + 坏点）
              exp_rgb_img_bilinear.hex / exp_rgb_img_mhc.hex
              dpc_demosaic_compare.png + PSNR 统计

与 RTL 的公式同构约定（逐位一致的关键，两边注释必须一字不差）：
  * 窗口：5×5，中心 = 当前像素；越界用 replicate padding（clamp）——line_buffer_fifo_nxn
    的 pad 语义（与旧 DPC/Demosaic 工程的 crop 版不同：本链边缘也输出）
  * DPC：THR=128（RAW10）。同色邻居（窗口内相对位置 (i,j)，i/j∈0..4，(i,j)≠(2,2)）：
      中心相位 (r&1,c&1)；同色 ⇔ (i&1,j&1) == 中心奇偶的绝对一致：
      R/B 中心 → (i 偶,j 偶) 8 个；G 中心 → (i,j 同奇偶) 12 个
      P > mx+thr → 抄 mx；P+thr < mn → 抄 mn；否则原样
  * Demosaic 双线性：R/B 中心 G=十字4均值>>2、B/R=对角4均值>>2；Gr/Gb 中心
      R/B = 左右/上下 2 均值>>1（RGGB：Gr 左右是 R 上下是 B；Gb 相反）。>> 截断不舍入
  * Demosaic MHC：R/B 中心 G/B=(4·P+2·十字−远端十字)>>3；Gr/Gb R/B=(2·P+2·近端2−远端2)>>2
      正负分开：差为负钳 0，超 1023 钳 1023
"""
import math
import random
import sys

from PIL import Image, ImageDraw, ImageFont

W_IMG, H_IMG = 112, 103          # 真图尺寸（img 模式）
W_SMALL, H_SMALL = 16, 12        # 协议 TB 尺寸
FRAMES = 5
THR = 128                        # DPC 阈值（RAW10）
N_DEFECT = 60
SEED = 20260918
MAXV = 1023
OB = {0: 100, 1: 64, 2: 180, 3: 32}   # 黑电平（与 BLC 实验一致）

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


def save_exp_hex(px, path):
    """期望 RGB888：{r,g,b} 各 8bit 拼 24bit hex（与 RTL out_data[23:0] 打包一致）"""
    with open(path, 'w') as f:
        for p in px:
            f.write(f'{p:06X}\n')


def to_rgb888(p):
    """10bit 打包 {r,g,b} → RGB888 打包（出口 >>2 截断，与 RTL OW=8 折算位级同构）"""
    r, g, b = (p >> 20) & MAXV, (p >> 10) & MAXV, p & MAXV
    return ((r >> 2) << 16) | ((g >> 2) << 8) | (b >> 2)


def ch(px, k):
    return (px >> k) & 0xFF


def phase_of(r, c):
    return (r & 1) * 2 + (c & 1)


# ---------------------------------------------------------------------------
# DPC 包络检测（DW=10，窗口 clamp replicate）
# ---------------------------------------------------------------------------
def dpc_ref(bayer, w, h, thr=THR):
    out = list(bayer)
    for R in range(h):
        for C in range(w):
            P = bayer[R * w + C]
            ph = phase_of(R, C)
            nb = []
            for i in range(5):
                for j in range(5):
                    if i == 2 and j == 2:
                        continue
                    if ph in (0, 3):                       # R 或 B 中心：同色 = (i,j) 都偶
                        if i % 2 == 0 and j % 2 == 0:
                            nb.append(bayer[min(max(R + i - 2, 0), h - 1) * w + min(max(C + j - 2, 0), w - 1)])
                    else:                                  # G 中心：同色 = (i,j) 同奇偶（12 个）
                        if (i % 2) == (j % 2):
                            nb.append(bayer[min(max(R + i - 2, 0), h - 1) * w + min(max(C + j - 2, 0), w - 1)])
            mn, mx = min(nb), max(nb)
            if P > mx + thr:
                out[R * w + C] = mx
            elif P + thr < mn:
                out[R * w + C] = mn
    return out


# ---------------------------------------------------------------------------
# Demosaic（DW=10，窗口 clamp replicate）
# ---------------------------------------------------------------------------
def demosaic_bilinear_ref(bayer, w, h):
    out = []
    for R in range(h):
        for C in range(w):
            def v(i, j):
                return bayer[min(max(R + i - 2, 0), h - 1) * w + min(max(C + j - 2, 0), w - 1)]
            ctr, ph = v(2, 2), phase_of(R, C)
            cross4 = (v(1, 2) + v(3, 2) + v(2, 1) + v(2, 3)) >> 2
            diag4 = (v(1, 1) + v(1, 3) + v(3, 1) + v(3, 3)) >> 2
            side2 = (v(2, 1) + v(2, 3)) >> 1
            updn2 = (v(1, 2) + v(3, 2)) >> 1
            if ph == 0:
                r_o, g_o, b_o = ctr, cross4, diag4
            elif ph == 3:
                b_o, g_o, r_o = ctr, cross4, diag4
            elif ph == 1:
                g_o, r_o, b_o = ctr, side2, updn2
            else:
                g_o, b_o, r_o = ctr, side2, updn2
            out.append((r_o << 20) | (g_o << 10) | b_o)
    return out


def demosaic_mhc_ref(bayer, w, h):
    def sat(x):
        return 0 if x < 0 else (MAXV if x > MAXV else x)
    out = []
    for R in range(h):
        for C in range(w):
            def v(i, j):
                return bayer[min(max(R + i - 2, 0), h - 1) * w + min(max(C + j - 2, 0), w - 1)]
            ctr, ph = v(2, 2), phase_of(R, C)
            cross4 = v(1, 2) + v(3, 2) + v(2, 1) + v(2, 3)
            diag4 = v(1, 1) + v(1, 3) + v(3, 1) + v(3, 3)
            side2 = v(2, 1) + v(2, 3)
            updn2 = v(1, 2) + v(3, 2)
            side2_far = v(2, 0) + v(2, 4)
            updn2_far = v(0, 2) + v(4, 2)
            far4 = side2_far + updn2_far
            if ph in (0, 3):
                g_o = sat((4 * ctr + 2 * cross4 - far4) >> 3)
                x_o = sat((4 * ctr + 2 * diag4 - far4) >> 3)
                r_o, b_o = (ctr, x_o) if ph == 0 else (x_o, ctr)
            else:
                g_o = ctr
                r_o = sat((2 * ctr + 2 * side2 - side2_far) >> 2)
                b_o = sat((2 * ctr + 2 * updn2 - updn2_far) >> 2)
                if ph == 2:                              # Gb：左右是 B、上下是 R
                    r_o, b_o = b_o, r_o
            out.append((r_o << 20) | (g_o << 10) | b_o)
    return out


def psnr(a, b, nch=1):
    """a/b：nch=1 → 裸 10bit 值列表（Bayer，MAX=1023）；nch=3 → RGB888 8bit 打包（MAX=255）"""
    maxv = MAXV if nch == 1 else 255
    sh0 = 0 if nch == 1 else 16          # nch=1 裸值在 bit0 起；nch=3 打包 r 在 bit16 起
    step = 10 if nch == 1 else 8
    mse, n = 0, len(a) * nch
    for x, y in zip(a, b):
        for k in range(nch):
            sh = sh0 - step * k
            mse += (((x >> sh) & maxv) - ((y >> sh) & maxv)) ** 2
    return 10 * math.log10(maxv * maxv * n / mse) if mse > 0 else float('inf')


def gray_img_bayer(px, w, h):
    img = Image.new('L', (w, h))
    img.putdata([v >> 2 for v in px])
    return img


def rgb_img(px, w, h):
    """输入 RGB888 打包（8bit 各通道），直接取字节"""
    img = Image.new('RGB', (w, h))
    img.putdata([((p >> 16) & 0xFF, (p >> 8) & 0xFF, p & 0xFF) for p in px])
    return img


def gen_small_frame_input():
    """协议 TB 的输入像素流（与 tb 源模型一致）：(n*131+7)&1023，跨帧连续"""
    return [((i * 131 + 7) & 1023) for i in range(FRAMES * W_SMALL * H_SMALL)]


def main():
    mode = 'img' if '--img' in sys.argv else 'small'

    if mode == 'small':
        w, h, frames = W_SMALL, H_SMALL, FRAMES
        bayer = gen_small_frame_input()               # 无黑电平无坏点（协议场景）
        # 行缓存在帧间排空（M1 已验证）→ 每帧独立处理（clamp replicate），与 RTL 一致
        # 出口折 RGB888（10bit 打包 → to_rgb888），与 RTL OW=8 位级同构
        exp_bl, exp_mhc = [], []
        for f_i in range(frames):
            fr = bayer[f_i * w * h:(f_i + 1) * w * h]
            exp_bl += [to_rgb888(p) for p in demosaic_bilinear_ref(fr, w, h)]
            exp_mhc += [to_rgb888(p) for p in demosaic_mhc_ref(fr, w, h)]
        save_exp_hex(exp_bl, 'exp_rgb_small_bilinear.hex')
        save_exp_hex(exp_mhc, 'exp_rgb_small_mhc.hex')
        print(f'OK small: 期望 {frames} 帧 × {w * h} 像素（RGB888）→ exp_rgb_small_bilinear/mhc.hex')
        return

    # ---------------- img 模式：真图 + BLC + 坏点 ----------------
    rgb = load_hex('../Demosaic/input.hex')
    assert len(rgb) == W_IMG * H_IMG, f'input.hex 像素数 {len(rgb)} != {W_IMG*H_IMG}'
    # Bayer RAW10（8bit<<1，与 BLC 实验同款：低增益暗场景，留 OB headroom）
    ideal = []
    for r in range(H_IMG):
        for c in range(W_IMG):
            p = rgb[r * W_IMG + c]
            v = ch(p, 16) if (r % 2 == 0 and c % 2 == 0) else (ch(p, 0) if (r % 2 == 1 and c % 2 == 1) else ch(p, 8))
            ideal.append(min(v << 1, MAXV))
    # 加黑电平 → BLC（Python，与已验证 RTL 位级同构）→ "BLC 后"（RTL 链的输入基准）
    with_ob = [min(v + OB[phase_of(i // W_IMG, i % W_IMG)], MAXV) for i, v in enumerate(ideal)]
    after_blc = [max(v - OB[phase_of(i // W_IMG, i % W_IMG)], 0) for i, v in enumerate(with_ob)]

    # 注入坏点（亮点/死点各半，seed 固定；只注内部区域便于统计）
    rnd = random.Random(SEED)
    defect = list(after_blc)
    pos = []
    while len(pos) < N_DEFECT:
        r = rnd.randrange(2, H_IMG - 2)
        c = rnd.randrange(2, W_IMG - 2)
        if any(p[0] == r and p[1] == c for p in pos):
            continue
        v = MAXV if len(pos) % 2 == 0 else 0
        defect[r * W_IMG + c] = v
        pos.append((r, c, v))

    with open('blc_dpc_in.hex', 'w') as f:
        for v in defect:
            f.write(f'{v:03X}\n')

    # Python 参考链（核内 10bit 精度计算，出口折 RGB888）
    dpc_out = dpc_ref(defect, W_IMG, H_IMG)
    exp_bl = [to_rgb888(p) for p in demosaic_bilinear_ref(dpc_out, W_IMG, H_IMG)]
    exp_mhc = [to_rgb888(p) for p in demosaic_mhc_ref(dpc_out, W_IMG, H_IMG)]
    no_dpc = [to_rgb888(p) for p in demosaic_bilinear_ref(defect, W_IMG, H_IMG)]      # 无 DPC 对照
    clean_dm = [to_rgb888(p) for p in demosaic_bilinear_ref(after_blc, W_IMG, H_IMG)] # 干净基准
    save_exp_hex(exp_bl, 'exp_rgb_img_bilinear.hex')
    save_exp_hex(exp_mhc, 'exp_rgb_img_mhc.hex')

    # PSNR：Bayer 域 10bit（MAX=1023）；RGB 域 RGB888 8bit（MAX=255）
    print('========================================')
    print(f'注入 {N_DEFECT} 个坏点（亮点/死点各半，seed={SEED}），THR={THR}（RAW10），出口 RGB888')
    print(f'[Bayer 域] 坏点图 vs 干净(BLC后) : {psnr(defect, after_blc):7.2f} dB')
    print(f'[Bayer 域] DPC 后   vs 干净      : {psnr(dpc_out, after_blc):7.2f} dB')
    print(f'[RGB888]   坏点直接Demosaic      : {psnr(no_dpc, clean_dm, 3):7.2f} dB（无 DPC）')
    print(f'[RGB888]   DPC+Demosaic(bilinear): {psnr(exp_bl, clean_dm, 3):7.2f} dB')
    print(f'[RGB888]   DPC+Demosaic(MHC)     : {psnr(exp_mhc, clean_dm, 3):7.2f} dB')
    print('========================================')

    # 对比图：上排 Bayer 灰度（干净/坏点/DPC 后），下排 RGB（干净 DM / 坏点无 DPC / RTL 链 bilinear）
    gap, top = 8, 30
    dw, dh = W_IMG * 2, H_IMG * 2
    canvas = Image.new('RGB', (dw * 3 + gap * 4, (dh + top + 26) * 2), (24, 24, 30))
    draw = ImageDraw.Draw(canvas)
    up = [(gray_img_bayer(after_blc, W_IMG, H_IMG), '干净 Bayer（BLC 后）'),
          (gray_img_bayer(defect, W_IMG, H_IMG), f'注入 {N_DEFECT} 坏点'),
          (gray_img_bayer(dpc_out, W_IMG, H_IMG), 'DPC 校正后')]
    dn = [(rgb_img(clean_dm, W_IMG, H_IMG), '干净直接 Demosaic（基准）'),
          (rgb_img(no_dpc, W_IMG, H_IMG), f'坏点直接 Demosaic（无 DPC）{psnr(no_dpc, clean_dm, 3):.2f}dB'),
          (rgb_img(exp_bl, W_IMG, H_IMG), f'DPC+Demosaic（RTL 同公式）{psnr(exp_bl, clean_dm, 3):.2f}dB')]
    for row, items in enumerate([up, dn]):
        for i, (im, t) in enumerate(items):
            x = gap + i * (dw + gap)
            y = row * (dh + top + 26) + top
            canvas.paste(im.resize((dw, dh), Image.BILINEAR), (x, y))
            draw.text((x, y - 22), t, font=font(15), fill=(255, 255, 255))
    canvas.save('dpc_demosaic_compare.png')
    print('对比图已保存: dpc_demosaic_compare.png')
    print('下一步：iverilog+vvp 跑 tb（-DIMG -DMHC 可选），RTL 输出与 exp 逐位比对')


if __name__ == '__main__':
    main()
