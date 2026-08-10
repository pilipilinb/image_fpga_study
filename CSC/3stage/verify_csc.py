# -*- coding: utf-8 -*-
# CSC定点转换独立校验: 解析iverilog仿真log, 与独立期望计算比对
import re, os
os.chdir(os.path.dirname(os.path.abspath(__file__)))

def csc_round(v):
    if v < 0: v = 0
    r = (v >> 8) + ((v >> 7) & 1)
    return min(r, 255)

def expect(r, g, b):
    y  = csc_round(47*r + 157*g + 16*b + 4096)
    cb = csc_round(112*b + 32768 - 26*r - 86*g)
    cr = csc_round(112*r + 32768 - 102*g - 10*b)
    return y, cb, cr

# 1. 读测试向量
rgb = []
for line in open('rgb_in.txt'):
    line = line.strip()
    if line:
        v = int(line, 2)
        rgb.append(((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff))

# 2. 读仿真log (兼容 UTF-16LE/UTF-8)
raw = open('sim_log.txt', 'rb').read()
if raw.startswith(b'\xff\xfe') or raw.startswith(b'\xfe\xff'):
    log = raw.decode('utf-16', errors='replace')
else:
    log = raw.decode('utf-8', errors='replace')

# 3. 提取 RES| 行并比对
res_lines = [l for l in log.splitlines() if l.startswith('RES|')]
print(f"仿真RES行数: {len(res_lines)}  (前16行对应16组向量)")
ok = True
print(f"{'R':>3} {'G':>3} {'B':>3} | {'Y':>3} {'Cb':>3} {'Cr':>3} | {'expY':>4} {'expCb':>4} {'expCr':>4} | 结果")
for idx, l in enumerate(res_lines[:16]):
    nums = [int(x) for x in re.findall(r'\d+', l)]
    r, g, b, y, cb, cr = nums[0], nums[1], nums[2], nums[3], nums[4], nums[5]
    ey, ecb, ecr = expect(r, g, b)
    match = (y, cb, cr) == (ey, ecb, ecr)
    ok &= match
    print(f"{r:3d} {g:3d} {b:3d} | {y:3d} {cb:3d} {cr:3d} | {ey:4d} {ecb:4d} {ecr:4d} | {'PASS' if match else 'FAIL'}")

# 4. 仿真报告
m = re.search(r'同步对齐校验: [^\n]*', log)
print("\n" + m.group(0) if m else "未找到对齐报告")
m = re.search(r'数据校验: [^\n]*', log)
print(m.group(0) if m else "未找到数据报告")
print(f"独立校验结论: {'全部 PASS' if ok else '存在 FAIL'}")

# 5. 定点化精度: 定点结果 vs 博主公式浮点真值
print("\n=== 定点 vs 浮点(博主公式) 误差 (应<=1) ===")
maxd = [0, 0, 0]
for r, g, b in rgb:
    yf  = 0.183*r + 0.614*g + 0.062*b + 16
    cbf = -0.101*r - 0.338*g + 0.439*b + 128
    crf = 0.439*r - 0.399*g - 0.040*b + 128
    y, cb, cr = expect(r, g, b)
    maxd[0] = max(maxd[0], abs(yf - y))
    maxd[1] = max(maxd[1], abs(cbf - cb))
    maxd[2] = max(maxd[2], abs(crf - cr))
print(f"最大误差: dY={maxd[0]:.2f}  dCb={maxd[1]:.2f}  dCr={maxd[2]:.2f}")

# 6. 与标准BT.601对比 (灰度中性色, 验证亮度/色度增益)
print("\n=== 博主系数 vs 标准BT.601 (灰度 R=G=B=128) ===")
r = g = b = 128
y_blog = 0.183*r + 0.614*g + 0.062*b + 16
y_601  = 0.299*r + 0.587*g + 0.114*b + 16
cb_blog = -0.101*r - 0.338*g + 0.439*b + 128
cb_601  = -0.1687*r - 0.3313*g + 0.5*b + 128
print(f"博主公式: Y={y_blog:.1f}  Cb={cb_blog:.1f}  Cr={0.439*r-0.399*g-0.040*b+128:.1f}")
print(f"标准BT601: Y={y_601:.1f}  Cb={cb_601:.1f}  Cr={0.5*r-0.4187*g-0.0813*b+128:.1f}")
print(f"亮度差异: {y_601 - y_blog:.1f}  (灰阶亮度被压缩, 因为 Y系数和=0.859<1.0)")
