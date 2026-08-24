//========================================================================
// top_gaussian_sep.v —— 高斯滤波可分离版顶层（GaussianFilter 工程）
//
// 可分离性：二维高斯核 = [1,2,1]ᵀ×[1,2,1] → 两次一维卷积：
//   行卷积（横向 3-tap，2 拍延迟实现，无行缓存）→ 列卷积（纵向 3-tap，2 行行缓存）
// 与直接 3×3 版的数学恒等（逐像素系数完全一致）：
//   行和 = 左+2中+右（×4 放大，不归一化）→ 列和 = 上+2中+下 → (列和+8)>>4
//   展开后每个像素的系数 = 行系数×列系数 = 与直接版 sum 完全同构 → 位级全等！
//
// 数据流：
//   din ──► 3×row_conv_8b（R/G/B 各一，2 拍延迟横向和，输出 10bit hsum）
//       ──► line_buffer_3x3（DW=10，存 hsum，输出三行同列 w11/w21/w31）
//       ──► 3×col_conv_8b（纵向和 + 唯一一次 (sum+8)>>4 + 饱和）
//       ──► o_r/o_g/o_b + o_valid
//
// 行缓存对比：可分离版与直接版**同为 2 行**（纵向 3-tap 需要上/中/下三行，
//   两行在过去——省缓存是误解，分离省的是运算 9→6 与组合逻辑）
//========================================================================
// (include 已移至使用方统一声明，约定同 top_gaussian_filter.v 与链路工程)
`timescale 1ns/1ps

module top_gaussian_sep #(
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
    // 阶段1：行卷积（R/G/B 各一，横向 [1,2,1]，输出 10bit hsum）
    //========================================================================
    wire [9:0] h_r, h_g, h_b;
    wire       h_v;
    row_conv_8b u_row_r (
        .clk(clk), .rst_n(rst_n),
        .din(din[23:16]), .din_valid(din_valid),
        .hsum(h_r), .hsum_valid(h_v)
    );
    row_conv_8b u_row_g (
        .clk(clk), .rst_n(rst_n),
        .din(din[15:8]), .din_valid(din_valid),
        .hsum(h_g), .hsum_valid(h_v)
    );
    row_conv_8b u_row_b (
        .clk(clk), .rst_n(rst_n),
        .din(din[7:0]), .din_valid(din_valid),
        .hsum(h_b), .hsum_valid(h_v)
    );

    //========================================================================
    // 阶段2：行缓存（DW=30 打包三路 hsum：{h_r, h_g, h_b}，每路 10bit，
    //         BRAM 容量比直接版 24bit 打包更紧；窗口三行同列 = w11(上)/w21(中)/w31(下)）
    //========================================================================
    wire        matrix_valid;
    wire [29:0] w11, w12, w13;
    wire [29:0] w21, w22, w23;
    wire [29:0] w31, w32, w33;

    line_buffer_3x3 #(
        .DW     (30),
        .IMG_W  (IMG_W),
        .IMG_H  (IMG_H),
        .AW     (AW)
    ) u_lb (
        .clk         (clk),
        .rst_n       (rst_n),
        .din_valid   (h_v),
        .din         ({h_r, h_g, h_b}),   // 30bit 打包（10bit×3）
        .matrix_valid(matrix_valid),
        .w11(w11), .w12(w12), .w13(w13),
        .w21(w21), .w22(w22), .w23(w23),
        .w31(w31), .w32(w32), .w33(w33)
    );

    //========================================================================
    // 阶段3：列卷积 + 归一化（R/G/B 各一；up=w11, mid=w21, down=w31，按通道切片）
    //========================================================================
    wire [7:0] r_o, g_o, b_o;
    wire       v_r, v_g, v_b;
    col_conv_8b u_col_r (
        .clk(clk), .rst_n(rst_n),
        .up(w11[29:20]), .mid(w21[29:20]), .down(w31[29:20]), .valid_in(matrix_valid),
        .dout(r_o), .valid_out(v_r)
    );
    col_conv_8b u_col_g (
        .clk(clk), .rst_n(rst_n),
        .up(w11[19:10]), .mid(w21[19:10]), .down(w31[19:10]), .valid_in(matrix_valid),
        .dout(g_o), .valid_out(v_g)
    );
    col_conv_8b u_col_b (
        .clk(clk), .rst_n(rst_n),
        .up(w11[9:0]), .mid(w21[9:0]), .down(w31[9:0]), .valid_in(matrix_valid),
        .dout(b_o), .valid_out(v_b)
    );

    assign o_r     = r_o;
    assign o_g     = g_o;
    assign o_b     = b_o;
    assign o_valid = v_r;

endmodule