// ============================================================================
// blc_dpc_top.v —— BLC 与 DPC 顺序可交换性实验顶层（一个参数切顺序）
//
//   in(简流, Bayer RAW10 含黑电平) ─► BLC ─► DPC ─► out(简流, RAW10)
//                                     ↑__ SWAP_BD=1 时两级互换 __↑
//
// 【本模块的目的】回答"BLC 和 DPC 能不能交换、谁在前更好"——服务于 8 级 ISP 排序论证。
//   顺序0（默认，本工程链路顺序）: BLC → DPC
//   顺序1（对照）              : DPC → BLC
//   除这一个参数外，例化/参数/激励/判据全部相同（单一变量）。
//
// 【理论预测（写代码前先推，实验才有意义）】
//   记 BLC 为 B(x) = max(x − OB[phase], 0)（按相位减常数 + 下钳位）
//      DPC 为 D（只用**同相位**邻居做极值包络 + 阈值判定，替换值也取自同相位邻居）
//   ⇒ D 的判据 `P > nb_max+THR` / `P+THR < nb_min` 与替换值 `nb_min/nb_max` 只涉及同相位像素，
//     而"按相位各加同一个常数 c_p"对 min/max/比较**都是等变的**：D(x + c_p) = D(x) + c_p
//   ⇒ B 可写成 B = S_{−OB} ∘ clamp(·,0)（S = 按相位平移），于是
//         B∘D = D∘B  ⟺  clamp(·,0) 与 D 可交换
//   而 `max(·,0)` 只在 **raw < OB** 的像素上才真正起作用（正常构造 raw = clean + OB ≥ OB ⇒ 钳位是空的）
//   ⇒ **预测：只要 RAW 不低于黑电平，两者位级完全可交换；分歧只出现在"低于 OB"的像素上**
//     ⇒ 验证判据：位级差异的**位置集合是否恰好等于**注入的下沉像素集合。
//
// 【延迟账】BLC LAT=1（无行缓存）；DPC 含 5×5 行缓存（≈2·IMG_W+几拍）
//   总延迟 = 1 + D_DPC（两种顺序相同，加法交换律）⇒ 两流可逐拍对齐比较。
// ============================================================================
`timescale 1ns/1ps

`ifndef BLC_DPC_TOP_V_INC
`define BLC_DPC_TOP_V_INC
`include "blc_core.v"
`include "dpc_stage.v"

module blc_dpc_top #(
    parameter DW       = 10,
    parameter IMG_W    = 640,
    parameter IMG_H    = 480,
    parameter N        = 5,        // DPC 窗口边长
    parameter THR      = 128,      // DPC 缺陷判定阈值
    parameter SWAP_BD  = 0,        // ★ 0 = BLC→DPC（本工程）; 1 = DPC→BLC（对照）
    parameter BAYER_PATTERN = 2'b00
)(
    input  wire            clk,
    input  wire            rst_n,
    // 四通道黑电平（R/Gr/Gb/B）
    input  wire [DW-1:0]   ob_00,
    input  wire [DW-1:0]   ob_01,
    input  wire [DW-1:0]   ob_10,
    input  wire [DW-1:0]   ob_11,
    // 入侧简流
    input  wire            in_valid,
    output wire            in_ready,
    input  wire [DW-1:0]   in_data,
    input  wire            in_sof,
    input  wire            in_eol,
    // 出侧简流
    output wire            out_valid,
    input  wire            out_ready,
    output wire [DW-1:0]   out_data,
    output wire            out_sof,
    output wire            out_eol,
    output wire [1:0]      out_phase
);

    wire            first_rdy;

    // ---- 中间节点：b_* 恒为"BLC 级输出"，d_* 恒为"DPC 级输出"（与位置无关，便于阅读）----
    wire            b_v, b_rdy, b_sof, b_eol;
    wire [DW-1:0]   b_d;
    wire [1:0]      b_ph;
    wire            d_v, d_rdy, d_sof, d_eol;
    wire [DW-1:0]   d_d;
    wire [1:0]      d_ph;

    // ---- 送给出口的简流（= 两级里"最后那一级的输出"，随顺序变）----
    wire            g_v, g_rdy, g_sof, g_eol;
    wire [DW-1:0]   g_d;
    wire [1:0]      g_ph;

    generate
    if (SWAP_BD == 0) begin : g_blc_first
        // ---------------- BLC → DPC ----------------
        blc_core #(.DW(DW), .IMG_W(IMG_W), .IMG_H(IMG_H), .BAYER_PATTERN(BAYER_PATTERN)) u_blc (
            .clk(clk), .rst_n(rst_n),
            .in_valid(in_valid), .in_ready(first_rdy), .in_data(in_data),
            .in_sof(in_sof), .in_eol(in_eol),
            .ob_00(ob_00), .ob_01(ob_01), .ob_10(ob_10), .ob_11(ob_11),
            .out_valid(b_v), .out_ready(b_rdy), .out_data(b_d),
            .out_sof(b_sof), .out_eol(b_eol), .out_phase(b_ph)
        );
        dpc_stage #(.DW(DW), .IMG_W(IMG_W), .IMG_H(IMG_H), .N(N), .THR(THR)) u_dpc (
            .clk(clk), .rst_n(rst_n),
            .in_valid(b_v), .in_ready(b_rdy), .in_data(b_d),
            .in_sof(b_sof), .in_eol(b_eol),
            .out_valid(d_v), .out_ready(d_rdy), .out_data(d_d),
            .out_sof(d_sof), .out_eol(d_eol), .out_phase(d_ph)
        );
        assign d_rdy = g_rdy;                       // DPC 是最后一级
        assign g_v = d_v; assign g_d = d_d; assign g_ph = d_ph;
        assign g_sof = d_sof; assign g_eol = d_eol;
    end else begin : g_dpc_first
        // ---------------- DPC → BLC（对照顺序）----------------
        dpc_stage #(.DW(DW), .IMG_W(IMG_W), .IMG_H(IMG_H), .N(N), .THR(THR)) u_dpc (
            .clk(clk), .rst_n(rst_n),
            .in_valid(in_valid), .in_ready(first_rdy), .in_data(in_data),
            .in_sof(in_sof), .in_eol(in_eol),
            .out_valid(d_v), .out_ready(d_rdy), .out_data(d_d),
            .out_sof(d_sof), .out_eol(d_eol), .out_phase(d_ph)
        );
        blc_core #(.DW(DW), .IMG_W(IMG_W), .IMG_H(IMG_H), .BAYER_PATTERN(BAYER_PATTERN)) u_blc (
            .clk(clk), .rst_n(rst_n),
            .in_valid(d_v), .in_ready(d_rdy), .in_data(d_d),
            .in_sof(d_sof), .in_eol(d_eol),
            .ob_00(ob_00), .ob_01(ob_01), .ob_10(ob_10), .ob_11(ob_11),
            .out_valid(b_v), .out_ready(b_rdy), .out_data(b_d),
            .out_sof(b_sof), .out_eol(b_eol), .out_phase(b_ph)
        );
        assign b_rdy = g_rdy;                       // BLC 是最后一级
        assign g_v = b_v; assign g_d = b_d; assign g_ph = b_ph;
        assign g_sof = b_sof; assign g_eol = b_eol;
    end
    endgenerate

    assign out_valid = g_v;
    assign g_rdy     = out_ready;
    assign out_data  = g_d;
    assign out_sof   = g_sof;
    assign out_eol   = g_eol;
    assign out_phase = g_ph;
    assign in_ready  = first_rdy;

endmodule

`endif  // BLC_DPC_TOP_V_INC
