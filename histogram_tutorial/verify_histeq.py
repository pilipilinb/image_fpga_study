#========================================================================
# verify_histeq.py —— 直方图均衡 RTL 输出独立验证（与 RTL 逐位全等的整数重算）
# 验证内容：
#   1. 读取 RTL 第一帧输出 output.coe，与 numpy 独立重算全等比对
#      （CSC 灰度 → 直方图 → CDF → J=(cdf*K)>>S 饱和）
#   2. 统计：全等错误数（期望 0）、PSNR
#   3. 直方图平坦度量化：输入/输出直方图的 max/avg bin 比值、非零 bin 数
#   4. 生成对比图 histeq_compare.png：原图灰度 vs 均衡后 + 两图直方图 bar
# 灰度化：与 DUT 内置 CSC（rgb_to_ycbcr_3stage）同系数同源：
#   Y=(47R+157G+16B+4096)>>8 + 四舍五入（res[7] 进位）
# 运行：在 histogram_tutorial/ 目录下 python verify_histeq.py
#========================================================================

import numpy as np

W, H = 112, 103
S = 14
N = W * H
K = (255 << S) // N          # 与 RTL localparam 同公式（常数除法截断）


def load_hex(path):
    """读 RGB888 hex → (H*W, 3) uint8"""
    with open(path) as f:
        vals = [int(line.strip(), 16) for line in f if line.strip()]
    arr = np.array(vals, dtype=np.uint32)
    return np.stack([(arr >> 16) & 0xFF, (arr >> 8) & 0xFF, arr & 0xFF], axis=1)


def load_coe(path):
    """读 Xilinx COE 的 8bit 16 进制向量 → (H*W,) uint8"""
    vals = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('memory_'):
                continue
            vals.append(int(line.rstrip(','), 16))
    return np.array(vals, dtype=np.uint8)


def csc_y(px):
    """CSC Y 通道灰度化，与 DUT 内 rgb_to_ycbcr_3stage 逐位同源：
    res = 47R + 157G + 16B + 4096；Y = (res>>8) + ((res>>7)&1)（四舍五入）"""
    r = px[:, 0].astype(np.int64)
    g = px[:, 1].astype(np.int64)
    b = px[:, 2].astype(np.int64)
    res = 47 * r + 157 * g + 16 * b + 4096
    return ((res >> 8) + ((res >> 7) & 1)).astype(np.int64)


def histeq_ref(y):
    """独立整数重算：直方图 → CDF → J = (cdf*K)>>S 饱和（与 RTL 同构）"""
    hist = np.bincount(y, minlength=256).astype(np.int64)
    cdf = np.cumsum(hist)
    j = (cdf[y] * K) >> S
    return np.minimum(j, 255).astype(np.uint8), hist, cdf


def psnr(a, b):
    mse = np.mean((a.astype(np.float64) - b.astype(np.float64)) ** 2)
    if mse == 0:
        return float('inf')
    return 10 * np.log10(255.0 ** 2 / mse)


def flatness(hist):
    """直方图平坦度：非零 bin 数 + max/avg 比值（越低越均匀）"""
    nonzero = int(np.count_nonzero(hist))
    avg = hist.sum() / 256
    mx = hist.max()
    return nonzero, mx / avg if avg > 0 else 0


def main():
    orig = load_hex('input.hex')
    y = csc_y(orig)
    ref_j, ref_hist, ref_cdf = histeq_ref(y)

    rtl = load_coe('output.coe')
    assert rtl.size == N, f"output.coe 大小 {rtl.size} != {N}"

    diff = rtl.astype(np.int32) - ref_j.astype(np.int32)
    n_err = int(np.count_nonzero(diff))
    print(f"全等比对：{rtl.size} 像素，不一致 {n_err} 个")
    if n_err:
        idx = np.nonzero(diff)[0]
        print("前 10 个差异 (idx, rtl, ref):",
              [(int(i), int(rtl[i]), int(ref_j[i])) for i in idx[:10]])
    else:
        print("RTL 输出与独立整数重算完全一致 (0 错误)")
    print(f"PSNR: {psnr(rtl, ref_j):.2f} dB")

    # 直方图平坦度：输入 vs 输出（注意：input.hex 是正常动态图，均衡收益有限，
    # 量化级别可能减少——这是物理事实，低对比度图的效果见 low_contrast_demo.png）
    out_hist = np.bincount(rtl, minlength=256).astype(np.int64)
    in_nz, in_ratio = flatness(ref_hist)
    out_nz, out_ratio = flatness(out_hist)
    print(f"输入直方图: 非零 bin={in_nz}  max/avg={in_ratio:.2f}")
    print(f"输出直方图: 非零 bin={out_nz}  max/avg={out_ratio:.2f}")

    # 对比图：原图灰度 / 均衡输出 + 两图直方图
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        gray_img = y.reshape(H, W)
        out_img = rtl.reshape(H, W)
        fig, axes = plt.subplots(2, 2, figsize=(12, 9))
        axes[0, 0].imshow(gray_img, cmap='gray', vmin=0, vmax=255)
        axes[0, 0].set_title('Input grayscale (CSC Y)')
        axes[0, 0].axis('off')
        axes[0, 1].imshow(out_img, cmap='gray', vmin=0, vmax=255)
        axes[0, 1].set_title('Histogram-equalized (RTL)')
        axes[0, 1].axis('off')
        axes[1, 0].bar(np.arange(256), ref_hist, width=1)
        axes[1, 0].set_title(f'Input histogram (nonzero={in_nz})')
        axes[1, 1].bar(np.arange(256), out_hist, width=1)
        axes[1, 1].set_title(f'Output histogram (nonzero={out_nz})')
        fig.tight_layout()
        fig.savefig('histeq_compare.png', dpi=100)
        print('对比图已生成 histeq_compare.png')
    except ImportError as e:
        print(f'跳过对比图（缺依赖 {e}）')


def demo_low_contrast():
    """低对比度图均衡效果演示（纯软件：构造压缩灰度图 → 同一算法重算）。
    RTL 等价性已由 output.coe 全等验证保证，这里展示的是算法本身的对比度拉伸能力。"""
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
    except ImportError:
        print('跳过低对比度演示（缺 matplotlib）')
        return

    orig = load_hex('input.hex')
    y = csc_y(orig)
    # 把灰度压缩到 60..140 区间模拟低对比度（雾化/欠曝图），再按原图坐标排布
    y_low = 60 + (y * 80) // 256           # 0..255 → 60..140
    y_low_img = y_low.reshape(H, W)

    j_low, hist_in, _ = histeq_ref(y_low)
    j_img = j_low.reshape(H, W)
    hist_out = np.bincount(j_low, minlength=256).astype(np.int64)

    in_nz, in_ratio = flatness(hist_in)
    out_nz, out_ratio = flatness(hist_out)
    print(f"低对比度演示: 输入 Y∈[{y_low.min()},{y_low.max()}] → 输出 J∈[{j_low.min()},{j_low.max()}]")
    print(f"  非零 bin {in_nz}→{out_nz}，max/avg {in_ratio:.2f}→{out_ratio:.2f}")

    fig, axes = plt.subplots(2, 2, figsize=(12, 9))
    axes[0, 0].imshow(y_low_img, cmap='gray', vmin=0, vmax=255)
    axes[0, 0].set_title(f'Low-contrast input (Y 60..140, nonzero={in_nz})')
    axes[0, 0].axis('off')
    axes[0, 1].imshow(j_img, cmap='gray', vmin=0, vmax=255)
    axes[0, 1].set_title(f'Equalized output (J 0..255, nonzero={out_nz})')
    axes[0, 1].axis('off')
    axes[1, 0].bar(np.arange(256), hist_in, width=1)
    axes[1, 0].set_title(f'Input histogram (max/avg={in_ratio:.1f})')
    axes[1, 1].bar(np.arange(256), hist_out, width=1)
    axes[1, 1].set_title(f'Output histogram (max/avg={out_ratio:.1f})')
    fig.tight_layout()
    fig.savefig('low_contrast_demo.png', dpi=100)
    print('低对比度演示图已生成 low_contrast_demo.png')


if __name__ == '__main__':
    main()
    demo_low_contrast()