# 临时校验脚本（verify_grid.py）：验证 compare_grid 的 6 个 PSNR 与已知值一致
import compare_grid as cg

orig = cg.load_hex('input.hex')
center = [orig[(r - 1) * cg.W + (c - 1)] for r in range(2, cg.H) for c in range(2, cg.W)]
files = [
    ('../MeanFilter/output_salt_mean.coe', 'mean-salt', 20.53),
    ('../MeanFilter/output.coe', 'mean-gauss', 22.14),
    ('../GaussianFilter/output_salt_gaussian.coe', 'gau-salt', 20.44),
    ('../GaussianFilter/output.coe', 'gau-gauss', 22.50),
    ('output_salt_median.coe', 'med-salt', 26.18),
    ('output.coe', 'med-gauss', 22.01),
]
ok = True
for f, name, expect in files:
    v = cg.psnr(cg.load_coe(f), center)
    match = abs(v - expect) < 0.05
    ok = ok and match
    print(f'{name}: {v:.2f} dB expect {expect} -> {"OK" if match else "MISMATCH"}')
print('ALL OK' if ok else 'SOME MISMATCH')