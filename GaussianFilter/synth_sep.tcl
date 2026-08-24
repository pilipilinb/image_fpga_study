# synth_sep.tcl —— 高斯滤波 直接 3×3 vs 可分离版 资源对比（Vivado batch）
# 用法: vivado -mode batch -source synth_sep.tcl
# 报告：LUT / FF / CARRY8 / DSP48（xc7z010-1，OOC 模式）

set part "xc7z010clg400-1"
set root [file normalize [file dirname [info script]]]

# 全部源文件（统一 read，避免 include 顺序问题）
foreach f {line_buffer_3x3.v gaussian_3x3_8b.v row_conv_8b.v col_conv_8b.v top_gaussian_filter.v top_gaussian_sep.v} {
    read_verilog [file join $root $f]
}

foreach name {top_gaussian_filter top_gaussian_sep} {
    puts "===== SYNTH: $name ====="
    synth_design -top $name -part $part -mode out_of_context
    set luts  [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
    set ffs   [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]
    set carry [llength [get_cells -hier -filter {REF_NAME == CARRY8}]]
    set dsp   [llength [get_cells -hier -filter {REF_NAME =~ DSP48*}]]
    puts "RESULT $name LUT=$luts FF=$ffs CARRY8=$carry DSP48=$dsp"
    after 200
    close_design
    after 200
}