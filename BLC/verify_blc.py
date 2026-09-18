#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_blc.py —— blc_top 的独立二次校验（numpy 重算，不复用 Verilog 记分板逻辑）

输入：TB 落盘的 blc_out.txt（每像素一行：data phase sof eol），像素按输出先后
      排列 = 帧序 × 帧内光栅序。
约定（与 TB 的输入生成规则一致）：
  像素序列  p(n) = (n*131 + 7) mod 1024，n 从 0 连续编号（跨帧不回绕）
  帧结构    IMG_W x IMG_H，帧内第 k 个像素：r = k//W, c = k%W
  相位      phase = (r&1)*2 + (c&1)（{row&1, col&1}）
  偏置      OB = {00:100, 01:64, 10:180, 11:32}（四通道不同值）
  期望输出  exp = max(p - OB[phase], 0)；sof=(k==0)；eol=(c==W-1)

用法：python verify_blc.py [blc_out.txt] [W] [H] [FRAMES]
默认：blc_out.txt 16 12 5
"""
import sys

import numpy as np

OB = {0: 100, 1: 64, 2: 180, 3: 32}   # 与 TB 的 OB00/OB01/OB10/OB11 一致


def main() -> int:
    wins = sys.argv[1] if len(sys.argv) > 1 else "blc_out.txt"
    w = int(sys.argv[2]) if len(sys.argv) > 2 else 16
    h = int(sys.argv[3]) if len(sys.argv) > 3 else 12
    frames = int(sys.argv[4]) if len(sys.argv) > 4 else 5
    total = w * h

    try:
        got = np.loadtxt(wins, dtype=np.int64).reshape(-1, 4)
    except OSError:
        print(f"[FAIL] 打不开 {wins}（先跑一次 vvp 生成）")
        return 1

    n = np.arange(frames * total, dtype=np.int64)      # 跨帧连续编号
    p = (n * 131 + 7) & 1023                            # 像素满量程 0..1023
    k = n % total                                       # 帧内序号
    r, c = k // w, k % w
    ph = (r & 1) * 2 + (c & 1)
    ob = np.vectorize(OB.get)(ph)
    exp_data = np.maximum(p - ob, 0)                    # BLC 核心：饱和减法
    exp_sof = (k == 0).astype(np.int64)
    exp_eol = (c == w - 1).astype(np.int64)

    exp = np.stack([exp_data, ph, exp_sof, exp_eol], axis=1)
    print(f"参数：IMG_W={w} IMG_H={h} FRAMES={frames}  实际行数={got.shape[0]}（期望 {frames*total}）")

    if got.shape[0] != exp.shape[0]:
        print("[FAIL] 像素总数不符")
        return 1
    bad = np.argwhere(got != exp)
    if bad.size:
        print(f"[FAIL] 不符点数 = {len(bad)}，前 10 处：")
        for idx in bad[:10]:
            i, f = int(idx[0]), int(idx[1])
            kk = i % total
            print(f"  像素#{i}（帧{i//total} 中心({kk//w},{kk%w}) 字段{f}）: "
                  f"got {got[i,f]} exp {exp[i,f]}")
        return 1
    print(f"[PASS] verify_blc：{got.shape[0]} 像素 × 4 字段（data/phase/sof/eol）独立复算全部一致（0 误差）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
