// ============================================================================
// blc_top —— BLC 第一级完整模块：axis_adapter + blc_core 串联
//
// 入侧 AXIS（CSI-2 RX RAW10，1 pixel/clock）；出侧简流（给链路下一级用）
//   集成时把 ENTRY_FIFO_EN 开为 1 吸收下游行缓存的造行反压，
//   并把 axis_stream_fifo 整体换成 Xilinx AXI4-Stream Data FIFO IP（同名同义直连）。
// ============================================================================
`timescale 1ns/1ps

`ifndef BLC_TOP_V_INC
`define BLC_TOP_V_INC
`include "blc_axis_adapter.v"      // 内部再级联 include axis_stream_fifo.v（-I 指向 fifo 目录）
`include "blc_core.v"

module blc_top #(
    parameter DW            = 10,
    parameter ENTRY_FIFO_EN = 0,
    parameter FIFO_DEPTH    = 512
)(
    input  wire          aclk,
    input  wire          aresetn,
    // ---- AXIS 入 ----
    input  wire [11:0]   s_axis_tdata,
    input  wire          s_axis_tvalid,
    output wire          s_axis_tready,
    input  wire          s_axis_tlast,
    input  wire          s_axis_tuser,
    // ---- 黑电平偏置（寄存器可配）----
    input  wire [DW-1:0] ob_00, ob_01, ob_10, ob_11,
    // ---- 简流出 ----
    output wire          out_valid,
    input  wire          out_ready,
    output wire [DW-1:0] out_data,
    output wire          out_sof, out_eol,
    output wire [1:0]    out_phase
);

    // adapter → core 之间是简流
    wire        c_valid, c_ready;
    wire [DW-1:0] c_data;
    wire        c_sof, c_eol;

    blc_axis_adapter #(
        .DW(DW), .ENTRY_FIFO_EN(ENTRY_FIFO_EN), .FIFO_DEPTH(FIFO_DEPTH)
    ) u_adp (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast), .s_axis_tuser(s_axis_tuser),
        .out_valid(c_valid), .out_ready(c_ready), .out_data(c_data),
        .out_sof(c_sof), .out_eol(c_eol)
    );

    blc_core #(.DW(DW)) u_core (
        .clk(aclk), .rst_n(aresetn),
        .in_valid(c_valid), .in_ready(c_ready), .in_data(c_data),
        .in_sof(c_sof), .in_eol(c_eol),
        .ob_00(ob_00), .ob_01(ob_01), .ob_10(ob_10), .ob_11(ob_11),
        .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data),
        .out_sof(out_sof), .out_eol(out_eol), .out_phase(out_phase)
    );

endmodule

`endif  // BLC_TOP_V_INC
