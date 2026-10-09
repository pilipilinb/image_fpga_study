# ---- 表内容离线生成（Python / MATLAB，综合前算好写进 .coe）----
for x in 0 .. 255:
    LUT[x] = round( 255 * (x / 255) ^ (1 / 2.2) )

# ---- 运行时：一次查表搞定 ----
function gamma_apply(in):
    return LUT[in]               # in 就是地址，1 拍出结果

# ⚠️ 如果内部是 10/12bit、输出 8bit，地址位宽变宽，LUT 会按 2 的幂膨胀：
#    8bit 地址 → 256 × 8  = 2048 bit   → 半个 BRAM18
#   10bit 地址 → 1024 × 8 = 8192 bit   → 半个 BRAM18
#   12bit 地址 → 4096 × 8 = 32768 bit  → 2 个 BRAM18
#    所以 Gamma 常和"位深压缩"一起做：12bit 进、8bit 出，一张表把两件事都办了
