#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_blc_dpc_data.py —— BLC / DPC 顺序可交换性实验：输入 + 真值 + 两套顺序 golden

两种模式：
  python make_blc_dpc_data.py           # small：协议 TB（16×12 × 5 帧，伪随机 Bayer RAW10 含 OB）
  python make_blc_dpc_data.py --img     # img：真图（复用 M3 管线的 Bayer RAW10 + OB + 传感级缺陷）

★ 实验的核心（与降噪/CCM 那套同模板，但靶子与指标不同）：
  输入 = **含黑电平的 sensor RAW**（`raw = min(clean + OB[phase], 1023)`）+ 两类刻意注入的像素：
    ① **传感级缺陷** N_DEFECT 个（亮点 1023 / 死点 0，各半）—— 用来检验"缺陷检测是否受顺序影响"
    ② **低于黑电平的暗像素** N_BELOW 个（`raw = OB − D_OFF`）—— 理论预测它们才是唯一的分歧来源
  两种顺序：
    顺序0（本工程）: out = DPC( BLC(raw) )
    顺序1（对照）  : out = BLC( DPC(raw) )

  理论预测（见 README/实现计划）：DPC 只用**同相位**邻居 ⇒ 判据/替换对"按相位加常数"**等变**，
  而 BLC 恰好就是"按相位减常数 + 下钳位" ⇒ 两者可交换 ⟺ `max(·,0)` 与 DPC 可交换。
  下钳位只在 `raw < OB` 时起作用 ⇒ **分歧集合应当恰好等于注入的"低于 OB"像素集合**。

生成物（small）: bd_in_small.hex / exp_order0_small.hex / exp_order1_small.hex
生成物（img）  : bd_in_img.hex / exp_order0_img.hex / exp_order1_img.hex
                 truth_blc_img.hex（只做 BLC 的参照，用于反推"哪些像素被 DPC 改过"）
                 clean_bayer_img.hex（无 OB、无缺陷的原始光强真值，仅作参考）
"""
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.normpath(os.path.join(_HERE, '..'))
sys.path.append(os.path.join(_ROOT, 'Bayer_DPC_Demosaic'))

from make_dpc_demosaic_data import (W_IMG, H_IMG, MAXV, OB, THR,           # noqa: E402
                                    load_hex, phase_of, dpc_ref)

DW       = 10
N_DEFECT = 60          # 传感级缺陷个数（与 M3 的数据生成保持一致，便于横向对比）
N_BELOW  = 40          # "低于黑电平"的暗像素个数（理论预测的唯一分歧来源）
D_OFF    = 30          # 下沉量：raw = OB − D_OFF（模拟黑电平以下的暗噪声/死点）
SEED     = 20260918
W_S, H_S, FRAMES = 16, 12, 5


def save_hex(vals, path, width):
    with open(path, 'w') as f:
        for v in vals:
            f.write(f'{v & ((1 << width) - 1):0{(width + 3) // 4}X}\n')


def blc(raw, w, h, ob=OB):
    """BLC 位级同构：out = max(v − OB[phase], 0)（下钳位是唯一的非线性来源）"""
    return [max(v - ob[phase_of(i // w, i % w)], 0) for i, v in enumerate(raw)]


def inject(raw, w, h, ph_list, seed, n_def, n_below):
    """在 **传感级 RAW** 上注入缺陷（1023/0）与"低于 OB"的暗像素；返回 (新图, 缺陷位置, 下沉位置)"""
    import random
    rnd = random.Random(seed)
    out = list(raw)
    pos = []
    # ① 传感级缺陷：亮点 / 死点 各半，只注内部区（避开边界，与 M3 一致）
    while len(pos) < n_def:
        r = rnd.randrange(2, h - 2)
        c = rnd.randrange(2, w - 2)
        if any(p[0] == r and p[1] == c for p in pos):
            continue
        v = MAXV if len(pos) % 2 == 0 else 0
        out[r * w + c] = v
        pos.append((r, c))
    # ② 低于黑电平的暗像素：raw = OB − D_OFF（正常构造是 clean + OB，永不 < OB）
    below = []
    while len(below) < n_below:
        r = rnd.randrange(2, h - 2)
        c = rnd.randrange(2, w - 2)
        if any(p[0] == r and p[1] == c for p in pos + below):
            continue
        p = phase_of(r, c)
        out[r * w + c] = OB[p] - D_OFF if OB[p] >= D_OFF else 0
        below.append((r, c, p))
    return out, pos, below


def main():
    mode = 'img' if '--img' in sys.argv else 'small'

    if mode == 'small':
        import random
        rnd = random.Random(SEED + 3)
        frames, e0, e1 = [], [], []
        for fi in range(FRAMES):
            base = []
            for r in range(H_S):
                for c in range(W_S):
                    # 按相位的平滑底图（不同相位不同亮度）+ 小抖动，再叠加 OB
                    p = phase_of(r, c)
                    v = min(max(200 + p * 120 + r * 8 + c * 6 + fi * 20
                                + round(rnd.gauss(0, 6)), 0), MAXV)
                    base.append(min(v + OB[p], MAXV))
            raw, pos, below = inject(base, W_S, H_S, None, SEED + fi, 6, 4)
            frames += raw
            e0 += dpc_ref(blc(raw, W_S, H_S), W_S, H_S, THR)
            e1 += blc(dpc_ref(raw, W_S, H_S, THR), W_S, H_S)
        save_hex(frames, 'bd_in_small.hex', DW)
        save_hex(e0, 'exp_order0_small.hex', DW)
        save_hex(e1, 'exp_order1_small.hex', DW)
        print(f'OK small：bd_in_small.hex（{FRAMES} 帧 × {W_S*H_S}，RAW10 含 OB + 缺陷 + 下沉像素）')
        return

    # ---------------- img：复用 M3 管线的 Bayer 构造方式 ----------------
    rgb = load_hex(os.path.join(_ROOT, 'Demosaic', 'input.hex'))
    assert len(rgb) == W_IMG * H_IMG, f'input.hex 像素数 {len(rgb)} != {W_IMG*H_IMG}'
    # 与 make_dpc_demosaic_data / make_sharpen_data 逐字同款：Bayer 采样 → 10bit 光强
    clean = []
    for r in range(H_IMG):
        for c in range(W_IMG):
            p = rgb[r * W_IMG + c]
            v = ((p >> 16) & 0xFF) if (r % 2 == 0 and c % 2 == 0) else \
                ((p & 0xFF) if (r % 2 == 1 and c % 2 == 1) else ((p >> 8) & 0xFF))
            clean.append(min(v << 1, MAXV))
    raw_norm = [min(v + OB[phase_of(i // W_IMG, i % W_IMG)], MAXV) for i, v in enumerate(clean)]
    raw, dpos, bpos = inject(raw_norm, W_IMG, H_IMG, None, SEED, N_DEFECT, N_BELOW)

    save_hex(raw, 'bd_in_img.hex', DW)
    save_hex(blc(raw, W_IMG, H_IMG), 'truth_blc_img.hex', DW)          # 只做 BLC（反推"被改像素"的参照）
    save_hex(clean, 'clean_bayer_img.hex', DW)                         # 无 OB 无缺陷的原始光强（仅供对照）
    save_hex(dpc_ref(blc(raw, W_IMG, H_IMG), W_IMG, H_IMG, THR), 'exp_order0_img.hex', DW)
    save_hex(blc(dpc_ref(raw, W_IMG, H_IMG, THR), W_IMG, H_IMG), 'exp_order1_img.hex', DW)

    print(f'OK img：bd_in_img.hex（{W_IMG}×{H_IMG}，RAW10 含 OB）'
          f' + 传感级缺陷 {len(dpos)} 个 + 低于 OB 的像素 {len(bpos)} 个')
    print(f'        exp_order0_img.hex（顺序0 BLC→DPC）/ exp_order1_img.hex（顺序1 DPC→BLC）'
          f' + truth_blc_img.hex（只做 BLC 的参照）')
    with open('below_pos.txt', 'w') as f:                              # 下沉像素位置（verify 要用来验"重合"）
        f.write('\n'.join(f'{r} {c} {p}' for r, c, p in bpos))
    with open('defect_pos.txt', 'w') as f:
        f.write('\n'.join(f'{r} {c}' for r, c in dpos))
    print('下一步：iverilog+vvp 跑 tb_blc_dpc.v（两顺序各自位级比对）→ verify_blc_dpc.py')


if __name__ == '__main__':
    main()
