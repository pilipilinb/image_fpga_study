//========================================================================
// top_median_filter_pad.v —— 中值滤波顶层（pad 版行缓存，链路 crop 收缩修复用）
// 与 top_median_filter.v 的唯一区别：行缓存换成 line_buffer_3x3_pad.v，
// 输出全尺寸 IMG_H×IMG_W（边缘 replicate 复制填充），不再 crop 少一圈。
// 输入要求：必须带 blanking（h-blank≥1 拍/行末、v-blank≥IMG_W+8 拍/帧末）
// 数据流与核复用：窗口 w11..w33 → 3×median_3x3_8b（R/G/B），同 crop 版
// (本副本的 include 已移除：底层文件由 top_chain.v 统一声明)
//========================================================================
`timescale 1ns/1ps

module top_median_filter_pad #(
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
    output                  o_valid      // 输出有效（与 o_r/o_g/o_b 同拍；全尺寸 H×W）
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
    // 3×median_3x3_8b：R/G/B 各一核（逐通道独立取中，映射同 crop 版）
    //========================================================================
    wire [7:0] r_out, g_out, b_out;
    wire       v_r, v_g, v_b;

    median_3x3_8b u_med_r (
        .clk      (clk), .rst_n(rst_n),
        .p00(w11[23:16]), .p01(w12[23:16]), .p02(w13[23:16]),
        .p10(w21[23:16]), .p11(w22[23:16]), .p12(w23[23:16]),
        .p20(w31[23:16]), .p21(w32[23:16]), .p22(w33[23:16]),
        .valid_in (matrix_valid),
        .dout     (r_out), .valid_out(v_r)
    );

    median_3x3_8b u_med_g (
        .clk      (clk), .rst_n(rst_n),
        .p00(w11[15:8]), .p01(w12[15:8]), .p02(w13[15:8]),
        .p10(w21[15:8]), .p11(w22[15:8]), .p12(w23[15:8]),
        .p20(w31[15:8]), .p21(w32[15:8]), .p22(w33[15:8]),
        .valid_in (matrix_valid),
        .dout     (g_out), .valid_out(v_g)
    );

    median_3x3_8b u_med_b (
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