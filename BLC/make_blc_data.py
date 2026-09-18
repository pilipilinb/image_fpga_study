#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# make_blc_data.py —— 生成 BLC 图像实验数据（BLC 工程）
#
# 干什么：
#   1. 复用 Demosaic 的真实彩图 input.hex（112×103 RGB24）→ RGGB Bayer 采样
#      （与 Demosaic/make_bayer.py 同一套采样），8bit 值 <<2 铺满 RAW10 动态范围
#      → blc_ideal.hex（"理想 sensor RAW"：无黑电平）
#   2. 模拟 sensor 黑电平：每通道加性底（R+100 / Gr+64 / Gb+180 / B+32，
#      与 tb_blc_top.v 的 OB 一致），钳到 1023 → blc_in.hex（带黑电平的 RAW10）
#
# 用法：python make_blc_data.py        （默认读 ../Demosaic/input.hex，112×103）
#
# RGGB：(行偶,列偶)=R (行偶,列奇)=Gr (行奇,列偶)=Gb (行奇,列奇)=B
from PIL import Image

W, H = 112, 103
OB = {0: 100, 1: 64, 2: 180, 3: 32}   # 真实黑电平（每通道不同：暗电流通道差异）


def load_hex(path):
    return [int(l.strip(), 16) for l in open(path) if l.strip()]


def ch(px, k):
    return (px >> k) & 0xFF


def main():
    rgb = load_hex('../Demosaic/input.hex')
    if len(rgb) != W * H:
        raise SystemExit(f'错误: input.hex 有 {len(rgb)} 像素，期望 {W}×{H}')

    # 1. RGGB 采样 + 铺 RAW10 低半段
    #    【为什么 <<1 不是 <<2】8bit 值<<2 后均值 811/1023，加 OB 后高光大量被钳到
    #    1023（满阱削顶），BLC 减不回来 → "校准后 vs 理想"PSNR 到不了 ∞，实验失真。
    #    <<1 后最大 510+180=690 < 1023，零钳位——等价于低增益暗场景（BLC 的主场）。
    ideal = []
    for r in range(H):
        for c in range(W):
            p = rgb[r * W + c]
            if r % 2 == 0 and c % 2 == 0:
                v = ch(p, 16)            # R
            elif r % 2 == 1 and c % 2 == 1:
                v = ch(p, 0)             # B
            else:
                v = ch(p, 8)             # G（Gr/Gb 同绿）
            ideal.append(min(v << 1, 1023))
    with open('blc_ideal.hex', 'w') as f:
        for v in ideal:
            f.write(f'{v:03X}\n')

    # 2. 加每通道黑电平（模拟 sensor 输出；加性底 + 满量程钳位）
    with_ob = []
    for i, v in enumerate(ideal):
        r, c = divmod(i, W)
        ob = OB[(r & 1) * 2 + (c & 1)]
        with_ob.append(min(v + ob, 1023))
    with open('blc_in.hex', 'w') as f:
        for v in with_ob:
            f.write(f'{v:03X}\n')

    import statistics
    print(f'OK: input.hex -> blc_ideal.hex（理想 RAW10，均值 {statistics.mean(ideal):.1f}）')
    print(f'OK:            -> blc_in.hex   （加黑电平 OB={OB}，均值 {statistics.mean(with_ob):.1f}）')
    print('下一步：vvp 跑 tb_blc_img.v 生成 output.coe，再跑 verify_blc_img.py')


if __name__ == '__main__':
    main()
