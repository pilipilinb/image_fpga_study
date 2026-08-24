#========================================================================
# verify_sobel.py —— Sobel RTL 输出独立验证（与 RTL 逐位全等的整数重算）
# 验证内容：
#   1. 读取 RTL 第一帧幅值输出 output.coe，与 numpy 整数重算全等比对
#      （RGB888 → CSC 灰度(Y) → replicate pad → Gx/Gy → AMBM(α=1,β=0.5)
#      → >>2 → 饱和）
#   2. 统计：全等错误数（期望 0）、逐像素差直方图、PSNR
#   3. 生成对比图 sobel_compare.png（四宫格：原图 RGB / 灰度(CSC Y) /
#      RTL Sobel 幅值 / Python 参考模型幅值，thresh=64 边缘叠加可选）
# 灰度化：与 DUT 内置 CSC（rgb_to_ycbcr_3stage）同系数同源：
#   Y = (0.183R + 0.614G + 0.062B) + 16，系数 ×256 定点(47/157/16) + 4096，
#   右移 8 位 + 四舍五入（res[7] 进位），与 RTL 的 y_tmp 逐位一致
# 运行：在 sobel/ 目录下 python verify_sobel.py
#========================================================================

import numpy as np

W, H = 112, 103


def load_hex(path):
    """读 RGB888 hex（每行 24bit 16 进制文本）→ (H*W, 3) uint8"""
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
    res = 47R + 157G + 16B + 4096（系数 ×256 + 16×256）
    Y = (res >> 8) + ((res >> 7) & 1)（四舍五入，同 RTL y_tmp；
    注意显式写与 RTL 同构，而不是 (res+128)>>8，避免移位语义差异）
    """
    r = px[:, 0].astype(np.int64)
    g = px[:, 1].astype(np.int64)
    b = px[:, 2].astype(np.int64)
    res = 47 * r + 157 * g + 16 * b + 4096
    return ((res >> 8) + ((res >> 7) & 1)).astype(np.int64)


def sobel_ref(px):
    """独立整数重算：H×W 灰度 → replicate pad → Gx/Gy → AMBM → mag>>2（未饱和，0..382）
    与 RTL 的约定逐条对齐：
      - CSC 灰度化（Y 通道，同 DUT 内 rgb_to_ycbcr_3stage 系数）
      - 边界 replicate：越界复制边缘像素（与 pad 行缓存一致）
      - gx = (p02 + 2p12 + p22) − (p00 + 2p10 + p20)（2p 即左移 1 位）
      - abs → max/min（M+m，共 1 次比较）→ mag = M + (m >> 1)（整数右移截断）
      - 返回 mag >> 2（未饱和版本，饱和/阈值在上级比对）
    """
    gy = csc_y(px).reshape(H, W)
    gp = np.pad(gy, 1, mode='edge')                    # replicate padding
    # 以像素 (i,j) 为中心取 3×3，p00=左上 … p22=右下（i-1..i+1 = 行0..行2）
    p00, p01, p02 = gp[0:-2, 0:-2], gp[0:-2, 1:-1], gp[0:-2, 2:]
    p10, p11, p12 = gp[1:-1, 0:-2], gp[1:-1, 1:-1], gp[1:-1, 2:]
    p20, p21, p22 = gp[2:,   0:-2], gp[2:,   1:-1], gp[2:,   2:]
    gx = (p02 + (p12 << 1) + p22) - (p00 + (p10 << 1) + p20)   # ±1020
    gy_ = (p20 + (p21 << 1) + p22) - (p00 + (p01 << 1) + p02)
    ax = np.abs(gx)
    ay = np.abs(gy_)
    M = np.maximum(ax, ay)
    m = np.minimum(ax, ay)
    mag = M + (m >> 1)                                       # AMBM α=1 β=0.5
    return (mag >> 2).flatten()                              # 0..382


def psnr(a, b):
    mse = np.mean((a.astype(np.float64) - b.astype(np.float64)) ** 2)
    if mse == 0:
        return float('inf')
    return 10 * np.log10(255.0 ** 2 / mse)


def main():
    orig = load_hex('input.hex')
    ref_raw = sobel_ref(orig)                     # mag>>2，未饱和（0..382）
    ref_mag = np.minimum(ref_raw, 255).astype(np.uint8)

    rtl = load_coe('output.coe')
    assert rtl.size == H * W, f"output.coe 大小 {rtl.size} != {H*W}"

    diff = rtl.astype(np.int32) - ref_mag.astype(np.int32)
    n_err = int(np.count_nonzero(diff))
    print(f"全等比对：{rtl.size} 像素，不一致 {n_err} 个")
    if n_err:
        idx = np.nonzero(diff)[0]
        print("前 10 个差异 (idx, rtl, ref):",
              [(int(i), int(rtl[i]), int(ref_mag[i])) for i in idx[:10]])
    else:
        print("RTL 输出与独立整数重算完全一致 (0 错误)")
    hist, _ = np.histogram(diff, bins=range(-8, 9))
    print("逐像素差分布 [-8..8]:", dict(zip(range(-8, 8), hist)))
    print(f"PSNR: {psnr(rtl, ref_mag):.2f} dB")

    # 四宫格对比图：原图 RGB / 灰度(CSC Y) / RTL 幅值 / Python 参考幅值
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        rgb_img = orig.reshape(H, W, 3).astype(np.uint8)      # 原图（彩色）
        gray    = csc_y(orig).reshape(H, W)                    # CSC 灰度（TB/DUT 同源）
        mag_img = rtl.reshape(H, W).astype(np.uint8)           # RTL Sobel 幅值
        ref_img = ref_mag.reshape(H, W).astype(np.uint8)       # Python 参考幅值
        edge_img = np.where(mag_img > 64, 255, 0).astype(np.uint8)
        fig, axes = plt.subplots(1, 4, figsize=(20, 5))
        axes[0].imshow(rgb_img)
        axes[0].set_title('1. Original RGB')
        axes[0].axis('off')
        for ax, im, ttl in zip(axes[1:],
                               [gray, mag_img, ref_img],
                               ['2. Grayscale (CSC Y)', '3. Sobel mag (RTL)', '4. Sobel mag (Python ref)']):
            ax.imshow(im, cmap='gray', vmin=0, vmax=255)
            ax.set_title(ttl)
            ax.axis('off')
        # 在 RTL 幅值图上叠加边缘轮廓（thresh=64），一眼看出检测效果
        axes[2].contour(edge_img, levels=[127], colors='red', linewidths=0.4)
        fig.tight_layout()
        fig.savefig('sobel_compare.png', dpi=100)
        print('四宫格对比图已生成 sobel_compare.png')
    except ImportError as e:
        print(f'跳过对比图（缺依赖 {e}）')


if __name__ == '__main__':
    main()