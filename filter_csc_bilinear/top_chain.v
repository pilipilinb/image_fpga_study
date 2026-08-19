//========================================================================
// top_chain.v —— 滤波+CSC+缩放 串链路顶层（filter_csc_bilinear，W4 收尾）
//
// 链路（流式级联，颜色空间变换贯穿）：
//   din(RGB888 112×103) ──► 高斯滤波（去高斯噪声）──► 中值滤波（去椒盐）
//     ──► CSC(RGB→YCbCr，i_h/i_v_sync 接 0 仅透传) ──► 打包 24bit={Y,Cb,Cr}
//     ──► axis_fifo(速率匹配：缩放放大时读侧慢、in_ready 反压被 FIFO 吸收)
//     ──► 双线性放大 2 倍（Y/Cb/Cr 独立插值，数学等价于 RGB 插值）
//     ──► o_dout(YUV 24bit) + o_valid + o_done
//
// 尺寸链（PAD=0 crop 版 / PAD=1 pad 版）：
//   crop：112×103 → 110×101 → 108×99 → ×2 = 216×198（两级各 -2 边缘）
//   pad ：112×103 全尺寸两级 → 112×103 → ×2 = 224×206（边缘 replicate，不收缩）
//   pad 版级联的关键：line_buffer_3x3_pad 输出是连续流（无行末/帧末空拍），
//   下一级 pad 需要 blanking 才能插 rflush/bflush → 级间插 frame_sync_adapter
//   （行末补 h-blank≥1、帧末补 v-blank≥W+8 的 blanking 重生成器）
//
// 参数：ORDER 两级滤波顺序（0=高斯→中值 / 1=中值→高斯）
//       PAD   行缓存类型（0=crop 版 / 1=pad 版全尺寸）
//----------------------------------------------------------------------------
`timescale 1ns/1ps

`include "line_buffer_3x3.v"
`include "gaussian_3x3_8b.v"
`include "median_3x3_8b.v"
`include "rgb_to_ycbcr_3stage.v"
`include "coord_gen.v"
`include "bilinear_interp_8b.v"
`include "line_cache2.v"
`include "axis_fifo.v"
`include "line_buffer_3x3_pad.v"
`include "frame_sync_adapter.v"
`include "top_gaussian_filter.v"
`include "top_median_filter.v"
`include "top_gaussian_filter_pad.v"
`include "top_median_filter_pad.v"
`include "bilinear_lb_top.v"

module top_chain #(
    parameter IN_W  = 112,       // 输入图像宽
    parameter IN_H  = 103,       // 输入图像高
    parameter SCALE_N = 2,       // 放大倍数（=2）
    parameter SCALE_D = 1,
    parameter FRAC_BITS = 8,     // 缩放定点小数位（与插值核绑定）
    parameter ORDER = 0,         // 滤波顺序：0=高斯→中值，1=中值→高斯
    parameter PAD   = 0          // 行缓存：0=crop 版（两级各 -2），1=pad 版（全尺寸）
)(
    input                clk,
    input                rst_n,
    input                frame_start,   // 帧启动（拉 1 拍，直通缩放 start）
    input  [23:0]        din,           // RGB888 输入
    input                din_valid,

    // ---- 中间级探针（调试/逐级验证用；语义：高斯输出/中值输出/CSC 输出）----
    output               m_gau_valid,
    output [23:0]        m_gau_dout,
    output               m_med_valid,
    output [23:0]        m_med_dout,
    output               m_csc_valid,
    output [23:0]        m_csc_dout,

    // ---- 输出 ----
    output [23:0]        o_dout,        // YUV 放大（{Y,Cb,Cr}）
    output               o_valid,
    output               o_done
);

    // 尺寸参数（随 PAD）：
    //   crop：第一级输入 IN_W，第二级输入 IN_W-2，缩放输入 IN_W-4
    //   pad ：两级与缩放输入均为 IN_W（全尺寸不收缩）
    localparam G_W = IN_W - 2, G_H = IN_H - 2;          // crop 第一级后 110×101
    localparam M_W = G_W - 2, M_H = G_H - 2;            // crop 第二级后 108×99
    localparam SC_W = (PAD == 0) ? M_W : IN_W;          // 缩放输入宽
    localparam SC_H = (PAD == 0) ? M_H : IN_H;          // 缩放输入高

    //========================================================================
    // 级1+2：两级滤波（crop 版 / pad 版两分支，按 PAD 选择）
    //   中间信号（顶层声明，两分支各自驱动；末级 f_* 常量选择）
    //========================================================================
    // crop 分支信号
    wire [7:0] c_g_r, c_g_g, c_g_b;  wire c_g_v;
    wire [7:0] c_m_r, c_m_g, c_m_b;  wire c_m_v;
    // pad 分支信号（高斯级 / 中值级输出，与 ORDER 内的物理两级解耦命名：
    //   pad_g_* = 高斯滤波输出，pad_m_* = 中值滤波输出）
    wire [7:0] p_g_r, p_g_g, p_g_b;  wire p_g_v;
    wire [7:0] p_m_r, p_m_g, p_m_b;  wire p_m_v;

    generate
        if (PAD == 0) begin : g_crop
            if (ORDER == 0) begin : g_crop_g_first
                top_gaussian_filter #(
                    .IMG_W(IN_W), .IMG_H(IN_H), .AW($clog2(IN_W)+1)
                ) u_gau (
                    .clk(clk), .rst_n(rst_n),
                    .din(din), .din_valid(din_valid),
                    .o_r(c_g_r), .o_g(c_g_g), .o_b(c_g_b), .o_valid(c_g_v)
                );
                top_median_filter #(
                    .IMG_W(G_W), .IMG_H(G_H), .AW($clog2(G_W)+1)
                ) u_med (
                    .clk(clk), .rst_n(rst_n),
                    .din({c_g_r, c_g_g, c_g_b}), .din_valid(c_g_v),
                    .o_r(c_m_r), .o_g(c_m_g), .o_b(c_m_b), .o_valid(c_m_v)
                );
            end else begin : g_crop_m_first
                top_median_filter #(
                    .IMG_W(IN_W), .IMG_H(IN_H), .AW($clog2(IN_W)+1)
                ) u_med0 (
                    .clk(clk), .rst_n(rst_n),
                    .din(din), .din_valid(din_valid),
                    .o_r(c_m_r), .o_g(c_m_g), .o_b(c_m_b), .o_valid(c_m_v)
                );
                top_gaussian_filter #(
                    .IMG_W(G_W), .IMG_H(G_H), .AW($clog2(G_W)+1)
                ) u_gau0 (
                    .clk(clk), .rst_n(rst_n),
                    .din({c_m_r, c_m_g, c_m_b}), .din_valid(c_m_v),
                    .o_r(c_g_r), .o_g(c_g_g), .o_b(c_g_b), .o_valid(c_g_v)
                );
            end
        end else begin : g_pad
            // pad 版两级 + 级间 blanking 重生成适配器（全尺寸链，不收缩）
            wire [23:0] pad_l1_adj;  wire pad_l1_av;  // 适配器后（带 blanking）

            if (ORDER == 0) begin : g_pad_g_first
                top_gaussian_filter_pad #(
                    .IMG_W(IN_W), .IMG_H(IN_H), .AW($clog2(IN_W)+1)
                ) u_gp0 (
                    .clk(clk), .rst_n(rst_n),
                    .din(din), .din_valid(din_valid),
                    .o_r(p_g_r), .o_g(p_g_g), .o_b(p_g_b), .o_valid(p_g_v)
                );
                frame_sync_adapter #(
                    .IMG_W(IN_W), .IMG_H(IN_H)
                ) u_adap0 (
                    .clk(clk), .rst_n(rst_n),
                    .din({p_g_r, p_g_g, p_g_b}), .din_valid(p_g_v),
                    .dout(pad_l1_adj), .dout_valid(pad_l1_av)
                );
                top_median_filter_pad #(
                    .IMG_W(IN_W), .IMG_H(IN_H), .AW($clog2(IN_W)+1)
                ) u_mp0 (
                    .clk(clk), .rst_n(rst_n),
                    .din(pad_l1_adj), .din_valid(pad_l1_av),
                    .o_r(p_m_r), .o_g(p_m_g), .o_b(p_m_b), .o_valid(p_m_v)
                );
            end else begin : g_pad_m_first
                top_median_filter_pad #(
                    .IMG_W(IN_W), .IMG_H(IN_H), .AW($clog2(IN_W)+1)
                ) u_mp1 (
                    .clk(clk), .rst_n(rst_n),
                    .din(din), .din_valid(din_valid),
                    .o_r(p_m_r), .o_g(p_m_g), .o_b(p_m_b), .o_valid(p_m_v)
                );
                frame_sync_adapter #(
                    .IMG_W(IN_W), .IMG_H(IN_H)
                ) u_adap1 (
                    .clk(clk), .rst_n(rst_n),
                    .din({p_m_r, p_m_g, p_m_b}), .din_valid(p_m_v),
                    .dout(pad_l1_adj), .dout_valid(pad_l1_av)
                );
                top_gaussian_filter_pad #(
                    .IMG_W(IN_W), .IMG_H(IN_H), .AW($clog2(IN_W)+1)
                ) u_gp1 (
                    .clk(clk), .rst_n(rst_n),
                    .din(pad_l1_adj), .din_valid(pad_l1_av),
                    .o_r(p_g_r), .o_g(p_g_g), .o_b(p_g_b), .o_valid(p_g_v)
                );
            end
        end
    endgenerate

    // 第二级输出选择（CSC 输入）：crop 分支第二级 = ORDER? 高斯:中值
    wire [7:0] f_r, f_g, f_b;  wire f_v;
    assign f_r = (PAD == 0) ? ((ORDER == 0) ? c_m_r : c_g_r)
                            : ((ORDER == 0) ? p_m_r : p_g_r);
    assign f_g = (PAD == 0) ? ((ORDER == 0) ? c_m_g : c_g_g)
                            : ((ORDER == 0) ? p_m_g : p_g_g);
    assign f_b = (PAD == 0) ? ((ORDER == 0) ? c_m_b : c_g_b)
                            : ((ORDER == 0) ? p_m_b : p_g_b);
    assign f_v = (PAD == 0) ? ((ORDER == 0) ? c_m_v : c_g_v)
                            : ((ORDER == 0) ? p_m_v : p_g_v);

    //========================================================================
    // 级3：CSC RGB→YCbCr（i_h_sync/i_v_sync 链路无行场概念，接 0 仅透传）
    //========================================================================
    wire [7:0] y_o, cb_o, cr_o;
    wire       csc_v;
    rgb_to_ycbcr_3stage u_csc (
        .clk      (clk),
        .i_rst_n  (rst_n),
        .i_r_8b   (f_r),
        .i_g_8b   (f_g),
        .i_b_8b   (f_b),
        .i_h_sync (1'b0),
        .i_v_sync (1'b0),
        .i_data_en(f_v),
        .o_y_8b   (y_o),
        .o_cb_8b  (cb_o),
        .o_cr_8b  (cr_o),
        .o_h_sync (),
        .o_v_sync (),
        .o_data_en(csc_v)
    );

    //========================================================================
    // 级4：速率匹配 FIFO（隔离无背压前级与缩放反压）
    //========================================================================
    wire [23:0] fifo_dout;
    wire        fifo_v, fifo_ready;
    axis_fifo #(
        .DATA_W(24), .DEPTH(16384), .AW(14)
    ) u_fifo (
        .clk      (clk),
        .rst_n    (rst_n),
        .s_tvalid (csc_v),
        .s_tdata  ({y_o, cb_o, cr_o}),
        .s_tready (),
        .m_tvalid (fifo_v),
        .m_tdata  (fifo_dout),
        .m_tready (fifo_ready)
    );

    //========================================================================
    // 级5：双线性放大 2 倍（YUV 三通道独立插值，接口与 RGB 完全一致）
    //       输入尺寸随 PAD：crop=108×99 → 216×198；pad=112×103 → 224×206
    //========================================================================
    wire [7:0] o_r8, o_g8, o_b8;
    bilinear_lb_top #(
        .IN_WIDTH (SC_W),
        .IN_HEIGHT(SC_H),
        .SCALE_N  (SCALE_N),
        .SCALE_D  (SCALE_D),
        .FRAC_BITS(FRAC_BITS)
    ) u_scaler (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (frame_start),
        .din      (fifo_dout),
        .din_valid(fifo_v),
        .in_ready (fifo_ready),
        .o_r      (o_r8),
        .o_g      (o_g8),
        .o_b      (o_b8),
        .o_valid  (o_valid),
        .o_done   (o_done)
    );

    assign o_dout = {o_r8, o_g8, o_b8};   // YUV 打包（Y 在高字节）

    //========================================================================
    // 探针输出（语义：高斯滤波输出 / 中值滤波输出；随 PAD/ORDER 选择）
    //========================================================================
    assign m_gau_dout = (PAD == 0) ? {c_g_r, c_g_g, c_g_b} : {p_g_r, p_g_g, p_g_b};
    assign m_gau_valid = (PAD == 0) ? c_g_v : p_g_v;
    assign m_med_dout = (PAD == 0) ? {c_m_r, c_m_g, c_m_b} : {p_m_r, p_m_g, p_m_b};
    assign m_med_valid = (PAD == 0) ? c_m_v : p_m_v;
    assign m_csc_dout = {y_o, cb_o, cr_o};
    assign m_csc_valid = csc_v;

endmodule