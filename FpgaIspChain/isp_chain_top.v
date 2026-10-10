// ============================================================================
// isp_chain_top.v —— M5.3 八级 ISP 整链顶层（Bayer RAW10 进 → RGB888 出）
//
//   AXIS(RAW10) ─►[入端适配]─► BLC ─► DPC ─►[AWB 增益占位]─► Demosaic ─►
//        降噪 ─► CCM ─► Gamma ─► 锐化 ─►[出端适配]─► AXIS(RGB888, S2MM)
//
// 【八级 = 计划里的"8 级 ISP 链路"】域划分见 6month 计划开篇：
//   RAW 域（BLC → DPC）→ Bayer 域增益（AWB）→ 线性 RGB 域（Demosaic → 降噪 → CCM）
//   → 感知域（Gamma → 锐化）
//
// 【位宽在链里怎么走】
//   Bayer RAW10 = 10bit；线性 RGB = 30bit {R[29:20],G[19:10],B[9:0]}（保持 10bit，
//   位宽缩减统一推迟到 Gamma 出口）；Gamma 是**全链唯一换位宽的一级** 30bit→24bit；
//   锐化在 RGB888（24bit）域做；出口 AXIS tdata[23:0] + tkeep=3'b111。
//
// 【级间为什么先不加弹性 FIFO（M5.3 的刻意选择）】
//   8 级之间先用**纯组合 ready 穿透**（out_ready → in_ready 逐级上传），
//   先由 TB 量出真实的 stall 模式（哪几级/多长/是否同相），再按数据决定在哪儿插
//   弹性 FIFO、插多深。顺序反了就会"凭感觉加一堆没用的大 FIFO"。
//   两端（入端 ENTRY_FIFO_EN / 出端 OUT_FIFO_DEPTH）本就是弹性缓冲，
//   把"反压通路"的头尾护住。
//
// 【顶层的 AWB 端口按最终形态预留在位】
//   · 增益 gain_00/01/10/11（Q2.8，1.0=256）：占位期全给常数即可；
//   · 统计 stat_00/01/10/11（32bit）：留给 M6 的 AWB 统计（现恒 0）。
//   这样 M6 做完 AWB 不需要再改本顶层接口。
//
// 【反压语义】出端 AXIS.tready → 出端 FIFO → 逐级简流 ready → ... → 入端 FIFO → s_axis_tready
//   每一级内部都是"冻结+保持"结构，反压可无限期（数据不丢、不乱序）。
// ============================================================================
`timescale 1ns/1ps

`ifndef ISP_CHAIN_TOP_V_INC
`define ISP_CHAIN_TOP_V_INC
`include "blc_axis_adapter.v"
`include "blc_core.v"
`include "dpc_stage.v"
`include "awb_stub.v"
`include "demosaic_stage.v"
`include "denoise_stage.v"
`include "ccm_stage.v"
`include "gamma_stage.v"
`include "sharpen_stage.v"
`include "axis_out_adapter.v"

module isp_chain_top #(
    parameter DW    = 10,          // Bayer 域像素位宽（RAW10）
    parameter OW    = 8,           // 出口单通道位宽（RGB888）
    parameter IMG_W = 640,
    parameter IMG_H = 480,
    parameter N_DPC = 5,           // DPC/Demosaic 窗口边长
    parameter N_RGB = 3,           // 降噪/锐化窗口边长
    parameter THR   = 128,         // DPC 缺陷判定阈值（RAW10）
    parameter DEMOSAIC_SEL = 0,    // 0=双线性 1=MHC
    parameter FRAC  = 12,          // CCM 系数小数位（Q5.12）
    parameter KW    = 10,          // 锐化 k_gain 端口位宽
    parameter K_FRAC = 8,          // 锐化 k 小数位：k = k_gain/2^K_FRAC
    parameter AWB_GW = 10,         // AWB 增益位宽
    parameter AWB_GF = 8,          // AWB 增益小数位：1.0 = 2^AWB_GF
    parameter ENTRY_FIFO_EN = 0,   // 入端弹性 FIFO（单级仿真默认关；集成开）
    parameter ENTRY_FIFO_DEPTH = 512,
    parameter OUT_FIFO_DEPTH   = 512,
    parameter BAYER_PATTERN = 2'b00
)(
    input  wire            aclk,
    input  wire            aresetn,
    // ---- AXIS 入（MIPI CSI-2 RX，1 pixel/clock：tdata[11:0]，低 10bit=像素）----
    input  wire [11:0]     s_axis_tdata,
    input  wire            s_axis_tvalid,
    output wire            s_axis_tready,
    input  wire            s_axis_tlast,
    input  wire            s_axis_tuser,
    // ---- 配置：四通道黑电平（R/Gr/Gb/B）----
    input  wire [DW-1:0]   ob_00,
    input  wire [DW-1:0]   ob_01,
    input  wire [DW-1:0]   ob_10,
    input  wire [DW-1:0]   ob_11,
    // ---- 配置：AWB 增益（Q2.8，1.0=256；占位期全 256）----
    input  wire [AWB_GW-1:0] awb_gain_00,
    input  wire [AWB_GW-1:0] awb_gain_01,
    input  wire [AWB_GW-1:0] awb_gain_10,
    input  wire [AWB_GW-1:0] awb_gain_11,
    // ---- 配置：bypass（降噪/CCM/Gamma/锐化 四段有；BLC/DPC/Demosaic/AWB 无）----
    input  wire            bp_denoise,
    input  wire            bp_ccm,
    input  wire            bp_gamma,
    input  wire            bp_sharpen,
    // ---- 配置：锐化强度 ----
    input  wire [KW-1:0]   sharpen_k,
    // ---- AWB 统计（预留：M6 用；现恒 0）----
    output wire [31:0]     awb_stat_00,
    output wire [31:0]     awb_stat_01,
    output wire [31:0]     awb_stat_10,
    output wire [31:0]     awb_stat_11,
    // ---- AXIS 出（VDMA S2MM，RGB888）----
    output wire [3*OW-1:0] m_axis_tdata,
    output wire [3-1:0]    m_axis_tkeep,    // OW=8 ⇒ 3 字节 ⇒ 恒 3'b111
    output wire            m_axis_tvalid,
    input  wire            m_axis_tready,
    output wire            m_axis_tlast,
    output wire            m_axis_tuser
);

    localparam CW = 3*DW;      // 线性 RGB 打包位宽（30bit）
    localparam CO = 3*OW;      // 出口打包位宽（24bit）

    // ======== 入端适配：AXIS(RAW10) → 简流 ========
    wire          s0_v, s0_rdy, s0_sof, s0_eol;
    wire [DW-1:0] s0_d;
    blc_axis_adapter #(
        .DW(DW), .ENTRY_FIFO_EN(ENTRY_FIFO_EN), .FIFO_DEPTH(ENTRY_FIFO_DEPTH)
    ) u_in_adp (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast), .s_axis_tuser(s_axis_tuser),
        .out_valid(s0_v), .out_ready(s0_rdy), .out_data(s0_d),
        .out_sof(s0_sof), .out_eol(s0_eol)
    );

    // ======== 级 1：BLC（黑电平校正，LAT=1）========
    wire          s1_v, s1_rdy, s1_sof, s1_eol;
    wire [DW-1:0] s1_d;
    wire [1:0]    s1_ph;
    blc_core #(.DW(DW), .IMG_W(IMG_W), .IMG_H(IMG_H), .BAYER_PATTERN(BAYER_PATTERN)) u_blc (
        .clk(aclk), .rst_n(aresetn),
        .in_valid(s0_v), .in_ready(s0_rdy), .in_data(s0_d),
        .in_sof(s0_sof), .in_eol(s0_eol),
        .ob_00(ob_00), .ob_01(ob_01), .ob_10(ob_10), .ob_11(ob_11),
        .out_valid(s1_v), .out_ready(s1_rdy), .out_data(s1_d),
        .out_sof(s1_sof), .out_eol(s1_eol), .out_phase(s1_ph)
    );

    // ======== 级 2：DPC（缺陷像素校正，5×5 行缓存）========
    wire          s2_v, s2_rdy, s2_sof, s2_eol;
    wire [DW-1:0] s2_d;
    wire [1:0]    s2_ph;
    dpc_stage #(.DW(DW), .IMG_W(IMG_W), .IMG_H(IMG_H), .N(N_DPC), .THR(THR)) u_dpc (
        .clk(aclk), .rst_n(aresetn),
        .in_valid(s1_v), .in_ready(s1_rdy), .in_data(s1_d),
        .in_sof(s1_sof), .in_eol(s1_eol),
        .out_valid(s2_v), .out_ready(s2_rdy), .out_data(s2_d),
        .out_sof(s2_sof), .out_eol(s2_eol), .out_phase(s2_ph)
    );

    // ======== 级 3：AWB 增益占位（Bayer 域，LAT=1；gain=1.0 时恒等）========
    wire          s3_v, s3_rdy, s3_sof, s3_eol;
    wire [DW-1:0] s3_d;
    awb_stub #(.DW(DW), .GW(AWB_GW), .GF(AWB_GF)) u_awb (
        .clk(aclk), .rst_n(aresetn),
        .gain_00(awb_gain_00), .gain_01(awb_gain_01),
        .gain_10(awb_gain_10), .gain_11(awb_gain_11),
        .in_valid(s2_v), .in_ready(s2_rdy), .in_data(s2_d),
        .in_sof(s2_sof), .in_eol(s2_eol), .in_phase(s2_ph),
        .out_valid(s3_v), .out_ready(s3_rdy), .out_data(s3_d),
        .out_sof(s3_sof), .out_eol(s3_eol)
    );

    // ======== 级 4：Demosaic（去马赛克，5×5 行缓存；线性 RGB 保持 10bit）========
    wire          s4_v, s4_rdy, s4_sof, s4_eol;
    wire [CW-1:0] s4_d;
    wire [1:0]    s4_ph;
    demosaic_stage #(
        .DW(DW), .OW(DW), .IMG_W(IMG_W), .IMG_H(IMG_H), .N(N_DPC), .DEMOSAIC_SEL(DEMOSAIC_SEL)
    ) u_dm (
        .clk(aclk), .rst_n(aresetn),
        .in_valid(s3_v), .in_ready(s3_rdy), .in_data(s3_d),
        .in_sof(s3_sof), .in_eol(s3_eol),
        .out_valid(s4_v), .out_ready(s4_rdy), .out_data(s4_d),
        .out_sof(s4_sof), .out_eol(s4_eol), .out_phase(s4_ph)
    );

    // ======== 级 5：双边降噪（3×3 行缓存，LAT 链 7）========
    wire          s5_v, s5_rdy, s5_sof, s5_eol;
    wire [CW-1:0] s5_d;
    denoise_stage #(.DW(DW), .IMG_W(IMG_W), .IMG_H(IMG_H), .N(N_RGB)) u_dn (
        .clk(aclk), .rst_n(aresetn), .bypass(bp_denoise),
        .in_valid(s4_v), .in_ready(s4_rdy), .in_data(s4_d),
        .in_sof(s4_sof), .in_eol(s4_eol),
        .out_valid(s5_v), .out_ready(s5_rdy), .out_data(s5_d),
        .out_sof(s5_sof), .out_eol(s5_eol)
    );

    // ======== 级 6：CCM（色彩校正矩阵，LAT=2）========
    wire          s6_v, s6_rdy, s6_sof, s6_eol;
    wire [CW-1:0] s6_d;
    ccm_stage #(.DW(DW), .FRAC(FRAC)) u_ccm (
        .clk(aclk), .rst_n(aresetn), .bypass(bp_ccm),
        .in_valid(s5_v), .in_ready(s5_rdy), .in_data(s5_d),
        .in_sof(s5_sof), .in_eol(s5_eol),
        .out_valid(s6_v), .out_ready(s6_rdy), .out_data(s6_d),
        .out_sof(s6_sof), .out_eol(s6_eol)
    );

    // ======== 级 7：Gamma（LAT=1，★ 全链唯一换位宽：30bit → 24bit）========
    wire          s7_v, s7_rdy, s7_sof, s7_eol;
    wire [CO-1:0] s7_d;
    gamma_stage #(.DW(DW), .OW(OW)) u_gam (
        .clk(aclk), .rst_n(aresetn), .bypass(bp_gamma),
        .in_valid(s6_v), .in_ready(s6_rdy), .in_data(s6_d),
        .in_sof(s6_sof), .in_eol(s6_eol),
        .out_valid(s7_v), .out_ready(s7_rdy), .out_data(s7_d),
        .out_sof(s7_sof), .out_eol(s7_eol)
    );

    // ======== 级 8：锐化（USM，3×3 行缓存，LAT 链 3；RGB888 感知域）========
    wire          s8_v, s8_rdy, s8_sof, s8_eol;
    wire [CO-1:0] s8_d;
    sharpen_stage #(
        .DW(OW), .IMG_W(IMG_W), .IMG_H(IMG_H), .N(N_RGB), .KW(KW), .K_FRAC(K_FRAC)
    ) u_shp (
        .clk(aclk), .rst_n(aresetn), .bypass(bp_sharpen), .k_gain(sharpen_k),
        .in_valid(s7_v), .in_ready(s7_rdy), .in_data(s7_d),
        .in_sof(s7_sof), .in_eol(s7_eol),
        .out_valid(s8_v), .out_ready(s8_rdy), .out_data(s8_d),
        .out_sof(s8_sof), .out_eol(s8_eol)
    );

    // ======== 出端适配：简流(RGB888) → AXIS（S2MM 契约）========
    axis_out_adapter #(
        .DW(CO), .DEPTH(OUT_FIFO_DEPTH)
    ) u_out_adp (
        .clk(aclk), .rst_n(aresetn),
        .in_data(s8_d), .in_valid(s8_v), .in_ready(s8_rdy),
        .in_sof(s8_sof), .in_eol(s8_eol),
        .m_axis_tdata(m_axis_tdata), .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast), .m_axis_tuser(m_axis_tuser)
    );

    // ======== AWB 统计占位（M6 接入点；现恒 0，避免综合出未驱动端口）========
    assign awb_stat_00 = 32'd0;
    assign awb_stat_01 = 32'd0;
    assign awb_stat_10 = 32'd0;
    assign awb_stat_11 = 32'd0;

endmodule

`endif  // ISP_CHAIN_TOP_V_INC
