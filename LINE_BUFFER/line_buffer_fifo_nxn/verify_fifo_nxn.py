#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_fifo_nxn.py —— line_buffer_fifo_nxn 的独立二次校验（与 Verilog TB 记分板互相独立）

思路：完全不复用 TB 的比对逻辑，只用两样东西
  1) TB 落盘的"实际输出窗口"文件 fifo_wins.txt（每行一个窗口，N*N 个十进制字段）
  2) 本脚本自己按"输入图像生成规则 + replicate padding 定义"重算期望窗口（numpy 向量化）

输入图像生成规则（与 TB 一致）：img[p] = p mod 2^DW，p=0..W*H-1，行主序。
窗口定义：中心 (r,c) 的 N×N 窗口，第 (i,j) 格 = img[clamp(r+i-K, 0, H-1)][clamp(c+j-K, 0, W-1)]，
         K=(N-1)/2。窗口按"帧内光栅序 + 帧间顺序"排列 —— TB 正是按接收先后落盘的。

用法：
  python verify_fifo_nxn.py [wins文件] [IMG_W] [IMG_H] [N] [DW] [FRAMES]
  默认：fifo_wins.txt 16 12 3 10 7
"""
import sys

import numpy as np


def main() -> int:
    wins_file = sys.argv[1] if len(sys.argv) > 1 else "fifo_wins.txt"
    img_w = int(sys.argv[2]) if len(sys.argv) > 2 else 16
    img_h = int(sys.argv[3]) if len(sys.argv) > 3 else 12
    n = int(sys.argv[4]) if len(sys.argv) > 4 else 3
    dw = int(sys.argv[5]) if len(sys.argv) > 5 else 10
    frames = int(sys.argv[6]) if len(sys.argv) > 6 else 7

    k = (n - 1) // 2
    total_win = img_w * img_h

    # ---- 输入图像（与 TB 的 img[p] = p[DW-1:0] 一致） ----
    img = (np.arange(total_win, dtype=np.int64) & ((1 << dw) - 1)).reshape(img_h, img_w)

    # ---- 期望窗口：用索引矩阵做 replicate padding（一次性算全图，再按光栅序排开） ----
    rr = np.arange(img_h)[:, None]           # (H,1)
    cc = np.arange(img_w)[None, :]           # (1,W)
    di = np.arange(n) - k                    # 窗口内行偏移
    dj = np.arange(n) - k                    # 窗口内列偏移

    # 期望张量 exp[r, c, i, j] = img[clamp(r+i-K), clamp(c+j-K)]
    sr = np.clip(rr[:, :, None, None] + di[None, None, :, None], 0, img_h - 1)  # (H,W,N,1)
    sc = np.clip(cc[:, :, None, None] + dj[None, None, None, :], 0, img_w - 1)  # (H,W,1,N)
    exp = img[sr, sc]                                                            # (H,W,N,N)
    # 按 beat/窗口顺序（行主序）拉平成 (H*W, N*N)
    exp_flat = exp.reshape(total_win, n * n)
    exp_all = np.tile(exp_flat, (frames, 1))

    # ---- 读取实际输出 ----
    try:
        got = np.loadtxt(wins_file, dtype=np.int64)
    except OSError:
        print(f"[FAIL] 打不开 {wins_file}（先在 TB 目录跑一次仿真生成）")
        return 1
    got = np.atleast_2d(got)
    print(f"参数：IMG_W={img_w} IMG_H={img_h} N={n} DW={dw} FRAMES={frames}")
    print(f"实际窗口数 = {got.shape[0]}（期望 {frames * total_win}）"
          f"，每窗口字段数 = {got.shape[1]}（期望 {n * n}）")

    err = 0
    if got.shape[1] != n * n:
        print("[FAIL] 字段数不符")
        err += 1
    m = min(got.shape[0], exp_all.shape[0])
    if got.shape[0] != exp_all.shape[0]:
        print("[FAIL] 窗口总数不符")
        err += 1

    bad = np.argwhere(got[:m] != exp_all[:m])
    if bad.size:
        err += len(bad)
        print(f"[FAIL] 不符点数 = {len(bad)}，前 10 处：")
        for idx in bad[:10]:
            w, f = int(idx[0]), int(idx[1])
            fr, rem = divmod(w, total_win)
            r, c = divmod(rem, img_w)
            print(f"  窗口#{w}（帧{fr} 中心({r},{c}) 格({f // n},{f % n})): "
                  f"got {got[w, f]} exp {exp_all[w, f]}")

    if err == 0:
        print(f"[PASS] verify_fifo_nxn：{m} 个窗口 × {n * n} 点独立复算全部一致（0 误差）")
        return 0
    print(f"[FAIL] 独立复核不符点数 = {err}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
