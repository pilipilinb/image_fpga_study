#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_axis_out.py —— M5.1 出端适配器独立校验（第二判据）

独立解析 RTL 落盘的 AXIS 输出流 ao_out.txt（每行：tdata tkeep tuser tlast），
逐条核对 S2MM 契约（与 TB 自有记分板互相印证）：

  1. 数据完整性：输出序列 == ao_src.hex（4 个场景各重放 1 遍，逐字比对，零丢零重）
  2. tkeep ≡ 3'b111（每一拍）
  3. 每帧首拍 tuser=1：全局索引 i 满足 (i % TOTAL)==0
  4. 每行末拍 tlast=1：全局索引 i 满足 ((i % W)+1)%W==0
  5. 帧/行计数：帧 = 4 场景 × NFRAME、行 = 帧数 × H（HSIZE/VSIZE 与分辨率一致）

用法（需先跑 tb_ao.vvp）：
  python make_axis_out_data.py && iverilog -o tb_ao.vvp ... && vvp tb_ao.vvp
  python verify_axis_out.py
"""
import os

W, H, NFRAME = 16, 12, 4
TOTAL = W * H
GRAND = NFRAME * TOTAL
NSCEN = 4


def load_hex(path):
    return [int(l.strip(), 16) for l in open(path) if l.strip()]


def main():
    for f in ('ao_out.txt', 'ao_src.hex'):
        if not os.path.exists(f):
            raise SystemExit(f'缺少 {f}——请先跑：python make_axis_out_data.py && vvp tb_ao.vvp')

    src = load_hex('ao_src.hex')
    rec = []
    for l in open('ao_out.txt'):
        p = l.split()
        if len(p) == 4:
            rec.append((int(p[0], 16), int(p[1], 16), int(p[2], 16), int(p[3], 16)))

    ok = True
    print('========================================')
    print(f'输出流 {len(rec)} 拍（期望 {NSCEN*GRAND}），源序列 {len(src)} 字')

    # ---- 判据 1：数据完整性 ----
    n = min(len(rec), NSCEN * GRAND)
    bad_d = [i for i in range(n) if rec[i][0] != src[i % GRAND]]
    print(f'[判据1] tdata 序列 vs 源（场景重放）：'
          f'{"全等（0 误差）" if not bad_d else f"{len(bad_d)} 字不一致 [FAIL]"}')
    if bad_d:
        ok = False
        i = bad_d[0]
        print(f'  首个不一致 #{i}: rtl={rec[i][0]:06X} exp={src[i % GRAND]:06X}')

    # ---- 判据 2：tkeep ≡ 111 ----
    bad_k = [i for i in range(n) if rec[i][1] != 0b111]
    print(f'[判据2] tkeep ≡ 3\'b111：{"全部满足" if not bad_k else f"{len(bad_k)} 拍不符 [FAIL]"}')
    if bad_k:
        ok = False
        print(f'  首个不符 #{bad_k[0]}: {rec[bad_k[0]][1]:03b}')

    # ---- 判据 3/4：tuser 帧首 / tlast 行末 ----
    bad_u = [i for i in range(n) if rec[i][2] != (1 if (i % TOTAL) == 0 else 0)]
    bad_l = [i for i in range(n) if rec[i][3] != (1 if ((i % W) + 1) % W == 0 else 0)]
    print(f'[判据3] tuser=帧首（(i%%%d)==0）：{"全部满足" if not bad_u else f"{len(bad_u)} 拍不符 [FAIL]"}'
          % TOTAL)
    print(f"[判据4] tlast=行末（每 {W} 拍一次）：{'全部满足' if not bad_l else f'{len(bad_l)} 拍不符 [FAIL]'}")
    if bad_u or bad_l:
        ok = False

    # ---- 判据 5：帧/行计数 ----
    frames = sum(1 for r in rec[:n] if r[2])
    rows = sum(1 for r in rec[:n] if r[3])
    ef, er = NSCEN * NFRAME, NSCEN * NFRAME * H
    print(f'[判据5] 帧数 {frames}（期望 {ef}）/ 行数 {rows}（期望 {er}）'
          f'（HSIZE={W}, VSIZE={H}）')
    if frames != ef or rows != er:
        ok = False

    # ---- 预览 ----
    print('----------------------------------------')
    print('流前 3 拍 / 首行末拍预览：')
    for i in list(range(3)) + [W - 1]:
        d, k, u, l = rec[i]
        print(f'  #{i:4d} tdata={d:06X} tkeep={k:03b} tuser={u} tlast={l}')

    print('========================================')
    print('[PASS] AxisOut 独立校验全部通过' if ok else '[FAIL] 见上方不一致项')


if __name__ == '__main__':
    main()
