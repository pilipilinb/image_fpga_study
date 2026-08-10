#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# make_tb_input.py —— COE → $readmemh 兼容 hex 桥接 + 合成测试图生成（bilinear_v3）
#
# 用途：
#   1. 默认模式：把 MATLAB matlab_img_coe_output.m 生成的 input.coe
#      转换为 $readmemh 可读的 input.hex（剥离两行 header、去行尾逗号）
#   2. --synthetic WxH：生成合成梯度图（像素值 = row*16+col，R/G/B 用不同分量），
#      直接输出 input.hex + input.coe，供 Step 8 小图端到端验证（无需真实图片）
#
# 字节序：每行一个 24bit 十六进制数，R=bit[23:16] G=bit[15:8] B=bit[7:0]
# 尺寸校验：COE 像素数必须 == W×H，否则报错退出
#   （尺寸不匹配时 $readmemh 只填充部分地址、其余为 0/x，仿真不报错，
#     必须靠这里的事前校验拦截）
#
# 依赖：仅 Python 标准库（与 verify_csc.py 同级，无第三方依赖）
# 用法：
#   python make_tb_input.py --coe input.coe --width 112 --height 103
#   python make_tb_input.py --synthetic 4x3 --out input.hex
import argparse
import sys


def parse_coe(path):
    """读 COE：跳过 header 行，去行尾逗号，返回像素 hex 列表
    header 行为 memory_initialization_*（不含冒号，不能用 ':' 判断），
    因此改为：像素行必须是纯十六进制字符（0-9A-Fa-f）"""
    pixels = []
    with open(path, 'r') as f:
        for line in f:
            line = line.strip().rstrip(',')
            if not line:
                continue
            if not all(c in '0123456789abcdefABCDEF' for c in line):
                continue   # header 行（memory_initialization_*）
            pixels.append(line)
    return pixels


def write_hex(pixels, out_path):
    """写 $readmemh 兼容 hex：每行一个 24bit 数"""
    with open(out_path, 'w') as f:
        for p in pixels:
            f.write(p + '\n')
    print(f"OK: {len(pixels)} 像素 -> {out_path}")


def gen_synthetic(w, h):
    """合成梯度图：v = row*16+col，R/G/B 用不同分量以便肉眼区分三通道"""
    pixels = []
    for r in range(h):
        for c in range(w):
            v = (r * 16 + c) & 0xFF
            r_ = v
            g_ = (v * 3) & 0xFF
            b_ = (255 - v) & 0xFF
            pixels.append(f"{r_:02X}{g_:02X}{b_:02X}")
    return pixels


def main():
    ap = argparse.ArgumentParser(description='COE -> hex 桥接 / 合成测试图生成')
    ap.add_argument('--coe', default='input.coe', help='输入 COE 文件（MATLAB 生成，默认 input.coe）')
    ap.add_argument('--out', default='input.hex', help='输出 hex 文件（默认 input.hex）')
    ap.add_argument('--width', type=int, default=112, help='图像宽（校验用，默认 112）')
    ap.add_argument('--height', type=int, default=103, help='图像高（校验用，默认 103）')
    ap.add_argument('--synthetic', metavar='WxH', help='生成合成梯度图（如 4x3），跳过 COE 读取')
    args = ap.parse_args()

    if args.synthetic:
        try:
            w, h = (int(x) for x in args.synthetic.lower().split('x'))
        except ValueError:
            sys.exit(f"错误: --synthetic 格式应为 WxH（如 4x3），收到: {args.synthetic}")
        pixels = gen_synthetic(w, h)
        # 同时写一份标准 COE（供 MATLAB/Python 读回对比显示）
        with open(args.coe, 'w') as f:
            f.write('memory_initialization_radix=16;\n')
            f.write('memory_initialization_vector=\n')
            for p in pixels:
                f.write(p + ',\n')
        print(f"合成图 {w}x{h} -> {args.coe}")
    else:
        pixels = parse_coe(args.coe)
        expect = args.width * args.height
        if len(pixels) != expect:
            sys.exit(
                f"错误: {args.coe} 含 {len(pixels)} 像素，期望 {expect}（{args.width}x{args.height}）\n"
                f"提示: 尺寸不匹配时 ROM 会读到 0/x 却不报错，务必先修正确认")
        print(f"{args.coe}: {len(pixels)} 像素，尺寸校验通过")

    write_hex(pixels, args.out)


if __name__ == '__main__':
    main()