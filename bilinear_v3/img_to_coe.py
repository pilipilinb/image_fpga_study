#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# img_to_coe.py —— 图像 → COE 文件（MATLAB matlab_img_coe_output.m 的 Python 等价实现）
#
# 用途：把任意 jpg/png/bmp 图片转成 Xilinx COE 格式（RGB888，每像素一行），
#       供 make_tb_input.py 转 input.hex 后喂给 RTL 的 $readmemh ROM。
#       无 MATLAB 环境时替代 matlab_img_coe_output.m。
#
# 输出格式与 matlab_img_coe_output.m 完全一致：
#   memory_initialization_radix=16;
#   memory_initialization_vector=
#   <RRGGBB>,
#   ...
# 字节序：每像素 24bit，R=最高字节（bit[23:16]），与 RTL image_rom 约定一致。
#
# 用法：
#   python img_to_coe.py --input feibi.jpg --output input.coe          # 原尺寸输出
#   python img_to_coe.py --input feibi.jpg --output input.coe --resize 112x103
#   （--resize 时额外输出 resized_preview.jpg 预览图，供肉眼检查缩放效果）
#
# 注意：RTL 的 IN_WIDTH/IN_HEIGHT 是写死参数，COE 像素数必须 == IN_W×IN_H。
#   --resize 把图缩放到目标尺寸（与 RTL 参数匹配）；不 resize 时脚本会
#   打印图片尺寸，需把 RTL 参数设成该值。
#
# 依赖：Pillow（pip install pillow）
import argparse
import sys

from PIL import Image


def img_to_coe(src_path, dst_path, resize=None, preview_path=None):
    """读图 → 写 COE，返回 (W, H)；resize 时输出预览 jpg"""
    im = Image.open(src_path).convert('RGB')   # 统一 RGB（jpg 也可能是灰度/索引图）
    if resize:
        w, h = resize
        im = im.resize((w, h), Image.BILINEAR)  # 双线性缩放，与 RTL 语义一致
        if preview_path:
            im.save(preview_path, 'JPEG', quality=95)   # 预览图供肉眼检查
    else:
        w, h = im.size

    px = im.load()
    with open(dst_path, 'w') as f:
        f.write('memory_initialization_radix=16;\n')
        f.write('memory_initialization_vector=\n')
        for y in range(h):
            for x in range(w):
                r, g, b = px[x, y]
                f.write(f'{r:02X}{g:02X}{b:02X},\n')
    return w, h


def main():
    ap = argparse.ArgumentParser(description='图像 -> COE（RGB888，替代 MATLAB 脚本）')
    ap.add_argument('--input', required=True, help='输入图片路径（jpg/png/bmp）')
    ap.add_argument('--output', default='input.coe', help='输出 COE 文件（默认 input.coe）')
    ap.add_argument('--resize', metavar='WxH', help='缩放到目标尺寸（与 RTL 的 IN_WIDTH×IN_HEIGHT 匹配）')
    ap.add_argument('--preview', default='resized_preview.jpg', help='resize 后预览图 jpg（默认 resized_preview.jpg）')
    args = ap.parse_args()

    resize = None
    if args.resize:
        try:
            resize = tuple(int(x) for x in args.resize.lower().split('x'))
        except ValueError:
            sys.exit(f"错误: --resize 格式应为 WxH（如 112x103），收到: {args.resize}")

    w, h = img_to_coe(args.input, args.output, resize, args.preview)
    if resize:
        print(f"预览图已保存: {args.preview}")
    print(f"OK: {args.input} ({'resize→' + f'{resize[0]}x{resize[1]}' if resize else f'原尺寸 {w}x{h}'}) "
          f"-> {args.output}（{w*h} 像素）")
    print(f"RTL 参数提示: IN_WIDTH={w}, IN_HEIGHT={h}")


if __name__ == '__main__':
    main()