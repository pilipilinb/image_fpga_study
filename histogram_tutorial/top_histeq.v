//========================================================================
// top_histeq.v —— 直方图均衡顶层（histogram_tutorial 工程，W2 帧级处理）
// 功能：RGB888 像素流输入 → CSC 灰度化（复用 3stage 工程，取 Y 通道）
//       → 直方图均衡（双 BRAM ping-pong，帧延迟 1 帧）→ 输出均衡图 J
//
// 数据流：
//   din[23:0]/din_valid ──► rgb_to_ycbcr_3stage（BT.601，取 o_y_8b）
//                                │ y / o_data_en（4 拍延迟，与数据对齐）
//                                ▼
//                          histeq_core（统计/CDF/清零/映射 四阶段）
//                                │
//                          o_j[7:0] + o_valid（帧 1 起输出，每帧 H×W 拍）
//
// CSC 灰度化：Y = (0.183R + 0.614G + 0.062B) + 16（BT.601 带 offset，
//   系数 ×256 定点：47/157/16，四舍五入截取，范围约 16~235）。
//   均衡会把这 16..235 区间自动拉伸到 0..255（CDF 映射），低对比度图
//   对比度增强效果直观（这正是"直方图均衡"的卖点）。
//
// 帧间要求：din_valid 帧间空白 ≥ 513 拍（core 做 CDF 257 + 清零 256），
//   TB 给 640 拍；真实视频 1080p v-blank ≈ 99000 拍远够。
// 延迟：CSC 4 拍 + core 读取 1 拍 + 输出寄存 1 拍 = 全链路 6 拍；
//   输出相对输入整体延迟 1 帧（帧 N 统计，帧 N+1 的像素用帧 N 的 CDF 映射）。
//========================================================================
`timescale 1ns/1ps

`include "rgb_to_ycbcr_3stage.v"
`include "histeq_core.v"

module top_histeq #(
    parameter IMG_W = 112,     // 图像宽
    parameter IMG_H = 103,     // 图像高
    parameter S     = 14       // 定点化右移位数（K=(255<<S)/N）
)(
    input               clk,
    input               rst_n,       // 低电平复位（异步）
    input  [23:0]       din,         // RGB888 像素（R[23:16] G[15:8] B[7:0]）
    input               din_valid,   // 输入有效（帧间需 ≥513 拍空白）

    output [7:0]        o_j,         // 均衡输出（8bit 灰度，帧 1 起有效）
    output              o_valid      // 输出有效（与 o_j 同拍）
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
    // 直方图均衡核心：双 BRAM ping-pong（统计→CDF→清零→映射四阶段）
    //========================================================================
    wire [7:0] j_out;
    wire       j_valid;

    histeq_core #(
        .IMG_W (IMG_W),
        .IMG_H (IMG_H),
        .S     (S)
    ) u_histeq (
        .clk     (clk),
        .rst_n   (rst_n),
        .y       (y_8b),
        .y_en    (y_data_en),
        .o_j     (j_out),
        .o_valid (j_valid)
    );

    assign o_j     = j_out;
    assign o_valid = j_valid;

endmodule