//========================================================================
// top_sobel.v —— 3×3 Sobel 边缘检测顶层（sobel 工程）
// 功能：RGB888 像素流输入 → CSC 灰度化（复用 3stage 工程，取 Y 通道）
//       → 3×3 Sobel → 双输出幅值/边缘图
//       行缓存复用 line_buffer_3x3_pad（replicate padding，H×W 全尺寸窗口）
//
// 数据流：
//   din[23:0]/din_valid ──► rgb_to_ycbcr_3stage（BT.601，取 o_y_8b）
//                                │ o_y_8b / o_data_en（4 拍延迟，与数据对齐）
//                                ▼
//                          line_buffer_3x3_pad（DW=8，pad 版）
//                                │ w11..w33（每像素一个窗口，w22 为中心）
//                                ▼
//                          sobel_3x3_8b（Gx/Gy 差分 → AMBM 幅值 → 饱和/阈值）
//                                │
//                          o_mag[7:0] / o_edge[7:0] + o_valid（H×W 个窗口）
//
// 灰度化：CSC 的 Y = (0.183R + 0.614G + 0.062B) + 16（BT.601 带 offset，
//   系数 ×256 定点：47/157/16，四舍五入截取，范围约 16~235）。
//   亮度 Y 即灰度——Sobel 在 Y 上做差分卷积（梯度 = 差值，+16 偏移相互抵消）。
//   Cb/Cr 两路输出悬空不用（本模块只需灰度）。
//
// 延迟：CSC 4 拍 + 行缓存 4 拍 + 核 3 拍 = 全链路 11 拍（TB 按 valid 计数
//   不对齐；CSC 的 o_data_en 与 i_data_en 同长延迟，blanking 间隔整体后移）
//
// 与 crop 版行缓存的区别（pad 版特性，TB 必须遵守）：
//   1. 输出 H×W 全尺寸窗口（非 (H-2)×(W-2)），四条边按 replicate 复制
//   2. 输入流要求 blanking：行末 din_valid 拉低 ≥1 拍（h-blank，rflush 插拍），
//      帧末拉低 ≥ IMG_W+8 拍（v-blank，bflush 整行回放）——连续流无法做右/下边 padding
//========================================================================
`timescale 1ns/1ps

`include "rgb_to_ycbcr_3stage.v"
`include "line_buffer_3x3_pad.v"
`include "sobel_3x3_8b.v"

module top_sobel #(
    parameter IMG_W = 112,     // 图像宽
    parameter IMG_H = 103,     // 图像高
    parameter AW    = 10       // 列地址位宽（2^AW >= IMG_W）
)(
    input               clk,
    input               rst_n,       // 低电平复位（异步）
    input  [23:0]       din,         // RGB888 像素（R[23:16] G[15:8] B[7:0]）
    input               din_valid,   // 输入有效（行间/帧间需 blanking）
    input  [7:0]        thresh,      // 二值化阈值（可配）

    output [7:0]        o_mag,       // 梯度幅值（AMBM，>>2 + 饱和）
    output [7:0]        o_edge,      // 边缘二值图（0/255）
    output              o_valid      // 输出有效（与 o_mag/o_edge 同拍）
);

    //========================================================================
    // CSC 灰度化：RGB888 → Y（4 拍流水，输出 o_data_en 与 o_y_8b 同拍对齐）
    //   h_sync/v_sync 本工程不用，接 0（模块内只是延迟链，不影响数据）
    //========================================================================
    wire [7:0]  y_8b;
    wire        y_data_en;

    rgb_to_ycbcr_3stage u_csc (
        .clk      (clk),
        .i_rst_n  (rst_n),
        .i_r_8b   (din[23:16]),
        .i_g_8b   (din[15:8]),
        .i_b_8b   (din[7:0]),
        .i_h_sync (1'b0),
        .i_v_sync (1'b0),
        .i_data_en(din_valid),
        .o_y_8b   (y_8b),
        .o_cb_8b  (),
        .o_cr_8b  (),
        .o_h_sync (),
        .o_v_sync (),
        .o_data_en(y_data_en)
    );

    //========================================================================
    // 行缓存：流式收灰度像素，输出 3×3 窗口（pad 版，每像素一窗口）
    //========================================================================
    wire        matrix_valid;
    wire [7:0]  w11, w12, w13;
    wire [7:0]  w21, w22, w23;
    wire [7:0]  w31, w32, w33;

    line_buffer_3x3_pad #(
        .DW     (8),
        .IMG_W  (IMG_W),
        .IMG_H  (IMG_H),
        .AW     (AW)
    ) u_lb (
        .clk         (clk),
        .rst_n       (rst_n),
        .din_valid   (y_data_en),
        .din         (y_8b),
        .matrix_valid(matrix_valid),
        .w11(w11), .w12(w12), .w13(w13),
        .w21(w21), .w22(w22), .w23(w23),
        .w31(w31), .w32(w32), .w33(w33)
    );

    //========================================================================
    // Sobel 核：窗口坐标映射 p00=w11（左上）… p22=w33（右下），w22 为中心
    //========================================================================
    wire [7:0] mag_out, edge_out;
    wire       v_out;

    sobel_3x3_8b u_sobel (
        .clk      (clk), .rst_n(rst_n),
        .p00(w11), .p01(w12), .p02(w13),
        .p10(w21), .p11(w22), .p12(w23),
        .p20(w31), .p21(w32), .p22(w33),
        .valid_in (matrix_valid),
        .thresh   (thresh),
        .o_mag    (mag_out), .o_edge(edge_out), .valid_out(v_out)
    );

    assign o_mag   = mag_out;
    assign o_edge  = edge_out;
    assign o_valid = v_out;

endmodule