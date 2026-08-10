#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# verify_scale.py —— 双线性缩放 PSNR 校验 + 对比图渲染（bilinear_v3，计划 Step 7）
#
# 输入：
#   input.hex（原图，与 $readmemh 进 ROM 的比特严格同源——不读 jpg，
#             避免 MATLAB/PIL 的 JPEG 解码差异污染 PSNR）
#   output.coe（RTL 仿真输出，TB 直接 $fwrite 生成）
#
# PSNR 参考：独立浮点双线性，与 RTL 同坐标系（src = dst × IN/OUT）、
#   同钳位语义（越界方向权重清零），但与 TB 内定点参考不同源，
#   避免同源 bug 互相掩盖。
#
# 渲染：PIL 拼图（原图 | 放大图）→ verify_scale_compare.png；
#   PIL 缺失时降级（只打印提示，不阻塞 PASS/FAIL 关键路径）。
#
# 用法：
#   python verify_scale.py --in-hex input.hex --out-coe output.coe \
#       --in-w 112 --in-h 103 --scale 2
#   （所有打印同时写入 --log 指定的日志文件，默认 verify_scale.log）
import argparse
import math
import sys


def load_hex(path):
    """读 input.hex：每行一个 24bit hex（R 最高字节），返回像素 int 列表"""
    px = []
    with open(path, 'r') as f:
        for line in f:
            line = line.strip()
            if line:
                px.append(int(line, 16))
    return px


def load_coe(path):
    """读 output.coe：跳过 header（memory_initialization_*），去行尾逗号"""
    px = []
    with open(path, 'r') as f:
        for line in f:
            line = line.strip().rstrip(',')
            if not line:
                continue
            if not all(c in '0123456789abcdefABCDEF' for c in line):
                continue   # header 行
            px.append(int(line, 16))
    return px


def ref_bilinear(img, w, h, dx, dy, out_w, out_h, chan, step_x, step_y, fb):
    """独立浮点参考（与 RTL 同坐标系=定点累加舍入，插值用浮点）
    坐标：sx_a = dx*STEP_X（与 coord_gen 累加一致，含 STEP 四舍五入），
          sx = sx_a>>FB，u = 小数部分/2^FB
    钳位：越界方向权重清零（与 RTL clamp_u/clamp_v 一致）
    chan: 0=R 1=G 2=B"""
    sx_a = dx * step_x
    sy_a = dy * step_y
    sx = sx_a >> fb
    sy = sy_a >> fb
    u = (sx_a & ((1 << fb) - 1)) / float(1 << fb)
    v = (sy_a & ((1 << fb) - 1)) / float(1 << fb)
    # 钳位（复制边缘）
    sx_c  = min(sx, w - 1)
    sx1   = min(sx + 1, w - 1)
    sy_c  = min(sy, h - 1)
    sy1   = min(sy + 1, h - 1)
    # 越界方向权重清零（与 RTL clamp_u/clamp_v 语义一致）
    if sx >= w - 1: u = 0.0
    if sy >= h - 1: v = 0.0
    sh = 16 - 8 * chan   # R=16 G=8 B=0
    p00 = (img[sy_c * w + sx_c]  >> sh) & 0xFF
    p01 = (img[sy_c * w + sx1]   >> sh) & 0xFF
    p10 = (img[sy1 * w + sx_c]   >> sh) & 0xFF
    p11 = (img[sy1 * w + sx1]    >> sh) & 0xFF
    return ((1-u)*(1-v)*p00 + u*(1-v)*p01 + (1-u)*v*p10 + u*v*p11)


def render_compare(in_px, out_px, in_w, in_h, out_w, out_h, path):
    """PIL 拼图：原图 | 放大图。PIL 缺失降级不阻塞。"""
    try:
        from PIL import Image
    except ImportError:
        print("提示: 未安装 Pillow（pip install pillow），跳过对比图渲染")
        return
    img_in = Image.new('RGB', (in_w, in_h))
    img_in.putdata([((p >> 16) & 0xFF, (p >> 8) & 0xFF, p & 0xFF) for p in in_px])
    img_out = Image.new('RGB', (out_w, out_h))
    img_out.putdata([((p >> 16) & 0xFF, (p >> 8) & 0xFF, p & 0xFF) for p in out_px])
    canvas = Image.new('RGB', (in_w + out_w, max(in_h, out_h)), (0, 0, 0))
    canvas.paste(img_in, (0, 0))
    canvas.paste(img_out, (in_w, 0))
    canvas.save(path)
    print(f"对比图已保存: {path}（左=原图 {in_w}x{in_h} | 右=放大 {out_w}x{out_h}）")


class Tee:
    """stdout 同时输出到终端和日志文件（所有 print 自动落盘）"""
    def __init__(self, path):
        self.f = open(path, 'w', encoding='utf-8')
    def write(self, s):
        sys.stdout.write(s)
        self.f.write(s)
    def flush(self):
        sys.stdout.flush()
        self.f.flush()
    def close(self):
        self.f.close()


def main():
    ap = argparse.ArgumentParser(description='双线性缩放 PSNR 校验 + 对比图')
    ap.add_argument('--in-hex', default='input.hex', help='原图 hex（与 ROM 同源）')
    ap.add_argument('--out-coe', default='output.coe', help='RTL 仿真输出 COE')
    ap.add_argument('--in-w', type=int, default=112, help='输入宽')
    ap.add_argument('--in-h', type=int, default=103, help='输入高')
    ap.add_argument('--scale', type=int, default=2, help='放大整数倍')
    ap.add_argument('--png', default='verify_scale_compare.png', help='对比图输出路径')
    ap.add_argument('--log', default='verify_scale.log', help='日志文件（默认 verify_scale.log）')
    args = ap.parse_args()

    tee = Tee(args.log)     # 之后所有 print 同时写入日志文件

    out_w, out_h = args.in_w * args.scale, args.in_h * args.scale
    out_total = out_w * out_h
    # 与 RTL 一致的定点步进（coord_gen 的 localparam 算法，含四舍五入）
    fb = 8
    step_x = ((args.in_w << fb) + out_w // 2) // out_w
    step_y = ((args.in_h << fb) + out_h // 2) // out_h

    in_px = load_hex(args.in_hex)
    if len(in_px) != args.in_w * args.in_h:
        sys.exit(f"错误: {args.in_hex} 含 {len(in_px)} 像素，期望 {args.in_w}x{args.in_h}={args.in_w*args.in_h}"
                 f"\n提示: 原图尺寸与 --in-w/--in-h 不匹配，RTL 参数需同步")
    out_px = load_coe(args.out_coe)
    if len(out_px) != out_total:
        sys.exit(f"错误: {args.out_coe} 含 {len(out_px)} 像素，期望 {out_w}x{out_h}={out_total}"
                 f"\n提示: 仿真输出尺寸与 --scale 不匹配")

    # 逐像素独立浮点参考 + 误差统计
    mse_sum = 0.0
    max_err = 0
    for dy in range(out_h):
        for dx in range(out_w):
            out = out_px[dy * out_w + dx]
            for ch in range(3):
                got = (out >> (16 - 8 * ch)) & 0xFF
                ref = ref_bilinear(in_px, args.in_w, args.in_h, dx, dy, out_w, out_h, ch,
                                    step_x, step_y, fb)
                err = abs(got - ref)
                mse_sum += err * err
                if err > max_err:
                    max_err = int(err)

    mse = mse_sum / (out_total * 3)
    psnr = 10 * math.log10(255.0 * 255.0 / mse) if mse > 0 else float('inf')

    print("========================================")
    print(f"PSNR: {psnr:.2f} dB（W3 目标 >30dB）  最大误差: {max_err} LSB")
    if mse > 0:
        print(f"MSE: {mse:.3f}")
    if psnr > 30.0 and max_err <= 8:
        print(f"[PASS] 缩放质量达标（{args.in_w}x{args.in_h} -> {out_w}x{out_h}）")
    else:
        print(f"[FAIL] PSNR 或误差不达标，检查 RTL 或参考坐标系")
    print("========================================")

    render_compare(in_px, out_px, args.in_w, args.in_h, out_w, out_h, args.png)


if __name__ == '__main__':
    main()