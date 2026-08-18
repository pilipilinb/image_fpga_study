//========================================================================
// top_mean_filter.v —— 3×3 均值滤波顶层（MeanFilter 工程，W4 第一站）
// 功能：RGB888 像素流输入 → 3×3 均值滤波 → RGB888 输出
//       输入侧复用已验证的 line_buffer_3x3.v（BRAM 行缓存，crop 边界），
//       下游挂 3 个 8bit 均值核（R/G/B 各一）
//
// 数据流：
//   din[23:0]/din_valid ──► line_buffer_3x3（DW=24，输出 3×3 窗口）
//                                │ w11..w33（各 24bit）
//                                ├─ R[23:16] ──► mean_3x3_8b（R 核）
//                                ├─ G[15:8]  ──► mean_3x3_8b（G 核）
//                                └─ B[7:0]   ──► mean_3x3_8b（B 核）
//                                │ 同一 matrix_valid 驱动三核
//                                ▼
//                          o_r / o_g / o_b + o_valid
//
// 边界：crop（行缓存基础版行为），输出 (IMG_H-2)×(IMG_W-2) 个像素，
//       边缘一圈不出窗口（matrix_valid 门控 row>=2 && col>=2）
// 均值算法：见 mean_3x3_8b.v 注释（9 路加法树 + 除 9 定点近似 ×57>>9）
//========================================================================
`timescale 1ns/1ps

`include "line_buffer_3x3.v"
`include "mean_3x3_8b.v"

module top_mean_filter #(
    parameter IMG_W = 112,     // 图像宽
    parameter IMG_H = 103,     // 图像高
    parameter AW    = 10       // 列地址位宽（2^AW >= IMG_W）
)(
    input                   clk,
    input                   rst_n,       // 低电平复位（异步）
    input  [23:0]           din,         // RGB888 像素（R[23:16] G[15:8] B[7:0]）
    input                   din_valid,   // 输入有效
    output [7:0]            o_r,         // 滤波后 R
    output [7:0]            o_g,         // 滤波后 G
    output [7:0]            o_b,         // 滤波后 B
    output                  o_valid      // 输出有效（与 o_r/o_g/o_b 同拍）
);

    //========================================================================
    // 行缓存：流式收像素，输出 3×3 窗口（w11 最老行最左列 … w33 当前像素）
    //========================================================================
    wire        matrix_valid;
    wire [23:0] w11, w12, w13;
    wire [23:0] w21, w22, w23;
    wire [23:0] w31, w32, w33;

    line_buffer_3x3 #(
        .DW     (24),
        .IMG_W  (IMG_W),
        .IMG_H  (IMG_H),
        .AW     (AW)
    ) u_lb (
        .clk         (clk),
        .rst_n       (rst_n),
        .din_valid   (din_valid),
        .din         (din),
        .matrix_valid(matrix_valid),
        .w11(w11), .w12(w12), .w13(w13),
        .w21(w21), .w22(w22), .w23(w23),
        .w31(w31), .w32(w32), .w33(w33)
    );

    //========================================================================
    // 3×mean_3x3_8b：R/G/B 各一核，共用同一窗口与 matrix_valid
    //   三核同 LAT=3 同 valid_in，输出必然同拍（取任一 valid 作 o_valid）
    //   窗口拼接顺序：p00=w11（左上）… p22=w33（右下）
    //========================================================================
    wire [7:0] r_out, g_out, b_out;
    wire       v_r, v_g, v_b;

    mean_3x3_8b u_mean_r (
        .clk      (clk), .rst_n(rst_n),
        .p00(w11[23:16]), .p01(w12[23:16]), .p02(w13[23:16]),
        .p10(w21[23:16]), .p11(w22[23:16]), .p12(w23[23:16]),
        .p20(w31[23:16]), .p21(w32[23:16]), .p22(w33[23:16]),
        .valid_in (matrix_valid),
        .dout     (r_out), .valid_out(v_r)
    );

    mean_3x3_8b u_mean_g (
        .clk      (clk), .rst_n(rst_n),
        .p00(w11[15:8]), .p01(w12[15:8]), .p02(w13[15:8]),
        .p10(w21[15:8]), .p11(w22[15:8]), .p12(w23[15:8]),
        .p20(w31[15:8]), .p21(w32[15:8]), .p22(w33[15:8]),
        .valid_in (matrix_valid),
        .dout     (g_out), .valid_out(v_g)
    );

    mean_3x3_8b u_mean_b (
        .clk      (clk), .rst_n(rst_n),
        .p00(w11[7:0]), .p01(w12[7:0]), .p02(w13[7:0]),
        .p10(w21[7:0]), .p11(w22[7:0]), .p12(w23[7:0]),
        .p20(w31[7:0]), .p21(w32[7:0]), .p22(w33[7:0]),
        .valid_in (matrix_valid),
        .dout     (b_out), .valid_out(v_b)
    );

    //========================================================================
    // 输出
    //========================================================================
    assign o_r     = r_out;
    assign o_g     = g_out;
    assign o_b     = b_out;
    assign o_valid = v_r;   // 三核同 LAT 同 valid_in，取任一

endmodule