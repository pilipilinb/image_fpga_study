// ============================================================================
// awb_top.v —— M6 AWB 级封装（统计旁挂 + 增益应用，替换 M5.3 的 awb_stub）
//
// 【组合】DPC ─► [awb_stat（0 拍透传、旁挂统计）] ─► [awb_gain（1 拍）] ─► Demosaic
//   对外接口 = awb_stub 的接口（Bayer 简流 + 4 个 gain 写口）
//   + 统计快照组（stat_00..11 / frame_cnt / irq）。
//   数据通路延迟：stat 0 拍 + gain 1 拍 = **仍是 1 拍**（与 stub 一致）
//   ⇒ 替换前后整链总延迟不变、端到端 golden 不用重算（M5.3 的预留承诺）。
//
// 【软核闭环接口语义（与 tb_awb_loop / Step 5 软核 C 一致）】
//   · 写口 gain_00..11（inactive）：随时可写；硬件在**每帧首像素拍**采样生效；
//   · 读口 stat_00..11 + frame_cnt（快照组）：fc≥2 起有效，
//     fc=m 的 stat 对应"第 m-1 帧"的统计；irq 每帧边界 1 拍脉冲。
// ============================================================================
`timescale 1ns/1ps
`ifndef AWB_TOP_V_INC
`define AWB_TOP_V_INC
`include "awb_stat.v"
`include "awb_gain.v"

module awb_top #(
    parameter DW = 10,       // 像素位宽（Bayer RAW10）
    parameter GW = 10,       // 增益位宽
    parameter GF = 8         // 增益小数位：1.0 = 2^GF = 256（Q2.8）
)(
    input  wire          clk,
    input  wire          rst_n,
    // ---- 写口（inactive：仿真=TB/顶层端口；上板=AXI-Lite 从机寄存器）----
    input  wire [GW-1:0] gain_00, gain_01, gain_10, gain_11,
    // ---- 入侧简流（DPC 出，Bayer RAW10；in_phase 与数据同拍）----
    input  wire          in_valid,
    output wire          in_ready,
    input  wire [DW-1:0] in_data,
    input  wire          in_sof,
    input  wire          in_eol,
    input  wire [1:0]    in_phase,
    // ---- 出侧简流（Demosaic 入，Bayer RAW10）----
    output wire          out_valid,
    input  wire          out_ready,
    output wire [DW-1:0] out_data,
    output wire          out_sof,
    output wire          out_eol,
    // ---- 统计快照组（软核读；fc≥2 起有效，stat 对应帧 fc-1）----
    output wire [31:0]   stat_00,
    output wire [31:0]   stat_01,
    output wire [31:0]   stat_10,
    output wire [31:0]   stat_11,
    output wire [31:0]   frame_cnt,
    output wire          irq
);

    // stat → gain 内部连线（0 拍透传：数据/相位/valid 直通）
    wire          st_v, st_rdy, st_sof, st_eol;
    wire [DW-1:0] st_d;
    wire [1:0]    st_ph;

    awb_stat #(.DW(DW)) u_stat (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data),
        .in_sof(in_sof), .in_eol(in_eol), .in_phase(in_phase),
        .out_valid(st_v), .out_ready(st_rdy), .out_data(st_d),
        .out_sof(st_sof), .out_eol(st_eol), .out_phase(st_ph),
        .stat_00(stat_00), .stat_01(stat_01), .stat_10(stat_10), .stat_11(stat_11),
        .frame_cnt(frame_cnt), .irq(irq)
    );

    awb_gain #(.DW(DW), .GW(GW), .GF(GF)) u_gain (
        .clk(clk), .rst_n(rst_n),
        .gain_00(gain_00), .gain_01(gain_01), .gain_10(gain_10), .gain_11(gain_11),
        .in_valid(st_v), .in_ready(st_rdy), .in_data(st_d),
        .in_sof(st_sof), .in_eol(st_eol), .in_phase(st_ph),
        .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data),
        .out_sof(out_sof), .out_eol(out_eol)
    );

endmodule

`endif  // AWB_TOP_V_INC