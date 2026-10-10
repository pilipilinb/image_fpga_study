# ============================================================================
# synth_ooc_timing.tcl —— M5.1 时序预检（锐化 / 降噪 / CCM 三级 OOC 综合 + 时序报告）
#
# 用法（在 synth_rpt/ 下跑，所有中间产物都落那里）：
#   mkdir synth_rpt
#   cd synth_rpt
#   vivado -mode batch -source ../synth_ooc_timing.tcl -log synth_ooc_timing.log
#
# 【为什么顶层取 "xxx_stage" 而不是 "xxx_core"】★ 本脚本最关键的一点
#   锐化/降噪的关键路径起点在**行缓存的 win_reg** —— 行缓存的 sel_row/sel_col 判断
#   与 9:1 pad mux 是**组合逻辑**，和核内的加法树/乘法器叠在**同一个时钟周期**里。
#   只综合 xxx_core 会把前面这半条路径漏掉，报告会"虚好"。stage 才是"整层"的真实边界。
#
# 【约束口径】synth_design **之后**才 create_clock ⇒ 综合是**非时序驱动**（default 指令），
#   报告给的是"中等努力 + 估计布线延迟"下的结果。它足够回答"这一层在目标频率下要不要拆
#   流水"；若结论是"勉强过"，再考虑时序驱动综合 / 上实现（P&R）。
#
# 【$readmemh 的处理】denoise_core / ccm_core 用相对文件名 $readmemh 读 .coe，
#   故每个顶层在 synth_design 前先 cd 到自己的模块目录（脚本内 cd，绝对路径已先算好）。
# ============================================================================

# 器件替身说明：用户给的 xcvu19p-fhgb2104-2i 在 Vivado 2021.2 里不存在
#   （本机 VU19P 只装到 fsva3824 / fsvb3824，且只有 -1-e / -2-e）。
#   同 die、同速度等级 -2 ⇒ 封装差异只影响 I/O，不影响纯 fabric 的 OOC 时序结论。
set part   "xcvu19p-fsva3824-2-e"
set tclk   6.667                       ;# ns，对应 150 MHz
set root   [file normalize [file dirname [info script]]]
set rptdir [file join $root synth_rpt]
file mkdir $rptdir

set fifo_dir [file join $root fifo]
set lb_dir   [file join $root line_buffer line_buffer_fifo_nxn]

set incs [list $root $fifo_dir $lb_dir \
               [file join $root Sharpen] \
               [file join $root BilateralFilter] \
               [file join $root CCM] \
               [file join $root Gamma] \
               [file join $root BLC] \
               [file join $root Bayer_DPC_Demosaic] \
               [file join $root AxisOut]]

# 显式列文件，避免 glob 把 tb_*.v（含 $dumpfile/$readmemh）读进综合
set srcs [list \
    [file join $root Sharpen sharpen_core.v] \
    [file join $root Sharpen sharpen_stage.v] \
    [file join $root BilateralFilter denoise_bilateral_core.v] \
    [file join $root BilateralFilter denoise_stage.v] \
    [file join $root CCM ccm_core.v] \
    [file join $root CCM ccm_stage.v] \
    [file join $root Gamma gamma_core.v] \
    [file join $root Gamma gamma_stage.v] \
    [file join $root BLC blc_core.v] \
    [file join $root BLC blc_axis_adapter.v] \
    [file join $root Bayer_DPC_Demosaic dpc_envelope_dw.v] \
    [file join $root Bayer_DPC_Demosaic dpc_stage.v] \
    [file join $root Bayer_DPC_Demosaic demosaic_bilinear_dw.v] \
    [file join $root Bayer_DPC_Demosaic demosaic_mhc_dw.v] \
    [file join $root Bayer_DPC_Demosaic demosaic_stage.v] \
    [file join $root AxisOut axis_out_adapter.v] \
    [file join $root FpgaIspChain awb_stub.v] \
    [file join $root FpgaIspChain isp_chain_top.v] \
    [file join $fifo_dir axis_stream_fifo.v] \
    [file join $fifo_dir async_fifo.v] \
    [file join $lb_dir line_buffer_fifo_nxn.v] \
    [file join $lb_dir fwft_wrapper.v] ]

set_param general.maxThreads 8

foreach f $srcs {
    puts "READ $f"
    read_verilog $f
}

set tops [list \
    [list sharpen_stage [file join $root Sharpen] clk] \
    [list denoise_stage [file join $root BilateralFilter] clk] \
    [list ccm_stage     [file join $root CCM] clk] \
    [list isp_chain_top [file join $root FpgaIspChain] aclk] ]

foreach item $tops {
    set top [lindex $item 0]
    set wd  [lindex $item 1]
    set clkport [lindex $item 2]

    puts "===== SYNTH OOC: $top   (cwd=$wd) ====="
    cd $wd
    synth_design -top $top -part $part -mode out_of_context \
                 -include_dirs $incs -directive default

    # 关键路径的"级数"是判断要不要拆流水的核心指标
    create_clock -name clk -period $tclk [get_ports $clkport]

    set tp  [get_timing_paths -max_paths 1 -delay_type max]
    set wns "n/a"
    set lvl "n/a"
    if {[llength $tp] > 0} {
        catch { set wns [get_property SLACK $tp] }
        catch { set lvl [get_property LOGIC_LEVELS $tp] }
    }

    set luts  [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
    set ffs   [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]
    set carry [llength [get_cells -hier -filter {REF_NAME =~ CARRY*}]]
    set dsp   [llength [get_cells -hier -filter {REF_NAME =~ DSP48*}]]
    set ramb  [llength [get_cells -hier -filter {REF_NAME =~ RAMB*}]]
    puts "RESULT $top WNS_NS=$wns LOGIC_LEVELS=$lvl LUT=$luts FF=$ffs CARRY=$carry DSP48=$dsp RAMB=$ramb"

    report_timing_summary -file [file join $rptdir "timing_summary_$top.rpt"]
    report_timing -max_paths 15 -sort_by group -file [file join $rptdir "timing_$top.rpt"]
    report_utilization -file [file join $rptdir "util_$top.rpt"]
    close_design
}

puts "ALL_DONE"
