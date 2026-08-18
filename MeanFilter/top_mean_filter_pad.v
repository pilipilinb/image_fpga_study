//========================================================================
// top_mean_filter_pad.v —— 3×3 均值滤波顶层（pad 版，MeanFilter 工程）
// 与 top_mean_filter.v 的唯一区别：行缓存换成 line_buffer_3x3_pad.v，
// 输出全尺寸 IMG_H×IMG_W（边缘 replicate 复制填充），而不是 crop 少一圈。
//
// 对比结论（为什么 pad 版"会好一点"）：
//   1. 输出完整性：crop 版丢掉边缘一圈（(H-2)×(W-2)）；pad 版 H×W 全尺寸，
//      多级滤波不会逐级缩水，边缘像素也被滤波（replicate 后均值平滑）
//   2. 可对比性：pad 版输出与输入逐像素对应，PSNR 直接比，无需 crop 对齐
//   3. 代价：输入必须带 blanking（h-blank≥1 拍、v-blank≥IMG_W+8 拍），
//      且输出多出边缘一圈的计算量
//
// 数据流：
//   din[23:0]/din_valid ──► line_buffer_3x3_pad（DW=24，全尺寸窗口）
//                                │ w11..w33（各 24bit，w22 为中心）
//                                ├─ R[23:16] ──► mean_3x3_8b（R 核）
//                                ├─ G[15:8]  ──► mean_3x3_8b（G 核）
//                                └─ B[7:0]   ──► mean_3x3_8b（B 核）
//                                │ 同一 matrix_valid 驱动三核
//                                ▼
//                          o_r / o_g / o_b + o_valid（每帧 IMG_H×IMG_W 次）
//
// 注意：均值核的 9 像素求和与位置无关（对称），所以 w 映射与 crop 版完全一致，
//       p00=w11 … p22=w33，无需调整。
//========================================================================
`timescale 1ns/1ps

`include "line_buffer_3x3_pad.v"
`include "mean_3x3_8b.v"

module top_mean_filter_pad #(
    parameter IMG_W = 112,     // 图像宽
    parameter IMG_H = 103,     // 图像高
    parameter AW    = 10       // 列地址位宽（2^AW >= IMG_W）
)(
    input                   clk,
    input                   rst_n,       // 低电平复位（异步）
    input  [23:0]           din,         // RGB888 像素（R[23:16] G[15:8] B[7:0]）
    input                   din_valid,   // 输入有效（行末/帧末需 blanking）
    output [7:0]            o_r,         // 滤波后 R
    output [7:0]            o_g,         // 滤波后 G
    output [7:0]            o_b,         // 滤波后 B
    output                  o_valid      // 输出有效（与 o_r/o_g/o_b 同拍）
);

    //========================================================================
    // 行缓存（pad 版）：输出全尺寸 3×3 窗口（w22 为中心，边缘 replicate）
    //========================================================================
    wire        matrix_valid;
    wire [23:0] w11, w12, w13;
    wire [23:0] w21, w22, w23;
    wire [23:0] w31, w32, w33;

    line_buffer_3x3_pad #(
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
    // 3×mean_3x3_8b：R/G/B 各一核（均值求和与窗口位置无关，映射同 crop 版）
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