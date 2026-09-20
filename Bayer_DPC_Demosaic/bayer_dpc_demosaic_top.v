// ============================================================================
// bayer_dpc_demosaic_top.v —— M3 串联顶层：DPC → Demosaic（Bayer 域，RAW10）
//
// 数据流：
//   BLC 出（Bayer RAW10 简流）─► dpc_stage（5×5 包络检测坏点校正）─► demosaic_stage
//   （5×5 双线性/MHC 去马赛克）─► RGB 简流 {r,g,b} 3*DW
//
// 两级各自内含 line_buffer_fifo_nxn(N=5)——行缓存是"每级一份"而不是共享：
//   DPC 和 Demosaic 的窗口中心错开 K*(W+1) 个有效拍，共享一份行缓存需要额外的
//   窗口重放机制，得不偿失；BRAM 代价 = 2×(N-1) 个深度 W 的 FIFO（可换官方 IP）。
// 全链反压：出侧 out_ready → demosaic_stage 冻结 → dpc_stage 冻结 → in_ready=0
//   （各级都是"寄存器保持"结构，反压可无限期）。
// ============================================================================
`timescale 1ns/1ps

`ifndef BAYER_DPC_DEMOSAIC_TOP_V_INC
`define BAYER_DPC_DEMOSAIC_TOP_V_INC
`include "dpc_stage.v"
`include "demosaic_stage.v"

module bayer_dpc_demosaic_top #(
    parameter DW           = 10,     // 入侧像素位宽（Bayer RAW10）
    parameter OW           = 8,      // 出侧通道位宽（RGB888 契约：out_data[23:0]）
    parameter IMG_W        = 640,
    parameter IMG_H        = 480,
    parameter N            = 5,
    parameter THR          = 128,   // DPC 阈值（RAW10）
    parameter DEMOSAIC_SEL = 0      // 0=双线性 1=MHC
)(
    input  wire          clk,
    input  wire          rst_n,
    // ---- 入侧简流（BLC 出，Bayer RAW10）----
    input  wire          in_valid,
    output wire          in_ready,
    input  wire [DW-1:0] in_data,
    input  wire          in_sof,
    input  wire          in_eol,
    // ---- 出侧简流（RGB888，{r,g,b} 打包 3*OW=24bit）----
    output wire          out_valid,
    input  wire          out_ready,
    output wire [3*OW-1:0] out_data,
    output wire          out_sof,
    output wire          out_eol,
    output wire [1:0]    out_phase
);

    // DPC → Demosaic 之间的 Bayer 简流
    wire        c_valid, c_sof, c_eol;
    wire [DW-1:0] c_data;
    wire        c_ready;
    wire [1:0]  c_phase;

    dpc_stage #(
        .DW(DW), .IMG_W(IMG_W), .IMG_H(IMG_H), .N(N), .THR(THR)
    ) u_dpc (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data),
        .in_sof(in_sof), .in_eol(in_eol),
        .out_valid(c_valid), .out_ready(c_ready), .out_data(c_data),
        .out_sof(c_sof), .out_eol(c_eol), .out_phase(c_phase)
    );

    demosaic_stage #(
        .DW(DW), .OW(OW), .IMG_W(IMG_W), .IMG_H(IMG_H), .N(N), .DEMOSAIC_SEL(DEMOSAIC_SEL)
    ) u_dm (
        .clk(clk), .rst_n(rst_n),
        .in_valid(c_valid), .in_ready(c_ready), .in_data(c_data),
        .in_sof(c_sof), .in_eol(c_eol),
        .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data),
        .out_sof(out_sof), .out_eol(out_eol), .out_phase(out_phase)
    );

endmodule

`endif  // BAYER_DPC_DEMOSAIC_TOP_V_INC
