#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_axis_out_data.py —— M5.1 出端适配器（AXIS 输出）测试数据

生成 ao_src.hex：NFRAME 帧 × (H×W) 个 24bit RGB888 像素（确定性伪随机），
供 tb_axis_out_adapter.v 的源模型读取；verify_axis_out.py 用同一份数据独立核对
"RTL 输出序列 == 源序列"。

尺寸/帧数：
  W_S, H_S = 16, 12      # 每帧 192 像素（对应 HSIZE=16, VSIZE=12）
  NFRAME   = 4           # 4 帧（验证"每帧首拍 tuser"多次出现）

用法：python make_axis_out_data.py
"""
W_S, H_S, NFRAME = 16, 12, 4


def main():
    with open('ao_src.hex', 'w') as f:
        for n in range(NFRAME * W_S * H_S):
            r = (n * 131 + 7) & 0xFF
            g = (n * 57 + 11) & 0xFF
            b = (n * 211 + 29) & 0xFF
            f.write(f'{(r << 16) | (g << 8) | b:06X}\n')
    print(f'OK ao_src.hex：{NFRAME} 帧 × {W_S}×{H_S} = {NFRAME*W_S*H_S} 个 24bit 像素'
          f'（HSIZE={W_S}, VSIZE={H_S}）')


if __name__ == '__main__':
    main()
