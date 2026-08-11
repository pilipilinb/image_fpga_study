//========================================================================
// bilinear_lb_top.v —— 行缓存版双线性缩放顶层（bilinear_v4）
// 功能：流式像素输入（din/din_valid）→ 任意整数倍缩放（放大/缩小）→ RGB888 输出
//       用 3 行环形行缓存替代 v3 的 4 份整图 ROM，存储恒定、支持大图/实时视频流
//
// 数据流：
//   din/din_valid ──► line_cache2（3 行环形，写侧光栅、读侧按源坐标随机读）
//                          │ 4 邻居（组合读）
//   coord_gen ──(sx,sy,u,v,valid0)──► 钳位/权重清零 ──► 3×bilinear_interp_8b
//                          │
//          pixel_en = rd_ready（行就绪才推进输出像素）
//                          ▼
//                    o_r/o_g/o_b + o_valid + o_done
//
// 反压（核心）：
//   in_ready = wr_ready（写侧最多领先读窗口顶行 1 行；放大时写快暂停等读）
//   rd_ready = 行 sy+1 已写完（读侧等写；缩小时读快暂停等写）
//   谁落后谁等待，无死锁（详见 line_cache2.v 注释）
//
// 与 v3 顶层的时序差异：
//   line_cache2 为组合读（0 拍潜伏），u/v/valid0/4 邻居同拍喂核，
//   无需 v3 的"对齐寄存 1 拍"（那是 ROM 同步读潜伏 1 拍造成的）
//
// 复用：coord_gen / bilinear_interp_8b 零改动；钳位/权重清零逻辑与 v3 相同
// 大图升级：line_cache2 换 BRAM 时读变同步（1 拍），此处需补对齐寄存
//========================================================================
`timescale 1ns/1ps

`include "coord_gen.v"
`include "bilinear_interp_8b.v"
`include "line_cache2.v"

module bilinear_lb_top #(
    parameter IN_WIDTH   = 112,     // 输入图像宽
    parameter IN_HEIGHT  = 103,     // 输入图像高
    parameter SCALE_N    = 2,       // 缩放倍数（分子）：放大 N 倍 = N/1
    parameter SCALE_D    = 1,       // 缩放倍数（分母）：缩小 N 倍 = 1/N
    parameter FRAC_BITS  = 8        // 定点小数位（冻结 8，与插值核绑定）
)(
    input                   clk,
    input                   rst_n,       // 低电平复位（异步）
    input                   start,       // 帧启动（透传 coord_gen）
    input  [23:0]           din,         // 流式像素输入（RGB888：R[23:16] G[15:8] B[7:0]）
    input                   din_valid,   // 输入有效
    output                  in_ready,    // 输入反压：拉低时输入应暂停
    output [7:0]            o_r,         // 缩放后 R
    output [7:0]            o_g,         // 缩放后 G
    output [7:0]            o_b,         // 缩放后 B
    output                  o_valid,     // 输出有效（与 o_r/o_g/o_b 同拍）
    output                  o_done       // 帧末（透传 coord_gen.done）
);

    localparam FB         = FRAC_BITS;
    localparam OUT_WIDTH  = IN_WIDTH  * SCALE_N / SCALE_D;   // 缩放后宽（整数除法截断）
    localparam OUT_HEIGHT = IN_HEIGHT * SCALE_N / SCALE_D;   // 缩放后高
    localparam XW = $clog2(IN_WIDTH)  + 1;   // 源 x 位宽（与 coord_gen 一致）
    localparam YW = $clog2(IN_HEIGHT) + 1;   // 源 y 位宽

    //========================================================================
    // coord_gen：源坐标 + 权重（T 拍组合直通）；pixel_en 由行就绪门控
    //========================================================================
    wire [XW-1:0] sx;
    wire [YW-1:0] sy;
    wire [FB-1:0] u, v;
    wire valid0, done;
    wire rd_ready;      // 行就绪（读侧可推进）
    wire wr_ready;      // 写侧就绪（输入反压）

    coord_gen #(
        .IN_WIDTH   (IN_WIDTH),
        .IN_HEIGHT  (IN_HEIGHT),
        .OUT_WIDTH  (OUT_WIDTH),
        .OUT_HEIGHT (OUT_HEIGHT),
        .FRAC_BITS  (FRAC_BITS)
    ) u_coord (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (start),
        .pixel_en   (rd_ready),          // 行未就绪时坐标不推进（暂停输出）
        .src_x_int  (sx),
        .src_y_int  (sy),
        .u_frac     (u),
        .v_frac     (v),
        .valid_out  (valid0),
        .done       (done)
    );

    //========================================================================
    // line_cache2：3 行环形行缓存（写侧流式、读侧按源坐标）
    //========================================================================
    wire [23:0] dout00, dout10, dout01, dout11;

    line_cache2 #(
        .IN_WIDTH  (IN_WIDTH),
        .IN_HEIGHT (IN_HEIGHT)
    ) u_cache (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (din),
        .din_valid  (din_valid),
        .wr_ready   (wr_ready),
        .rd_sy      (sy),
        .rd_sx      (sx),
        .rd_ready   (rd_ready),
        .dout00     (dout00),
        .dout10     (dout10),
        .dout01     (dout01),
        .dout11     (dout11)
    );

    assign in_ready = wr_ready;

    //========================================================================
    // 越界方向权重清零（组合，与 v3 一致；行缓存组合读与 u/v 同拍，无需延迟）
    //========================================================================
    wire clamp_u = (sx >= IN_WIDTH-1);
    wire clamp_v = (sy >= IN_HEIGHT-1);
    wire [FB-1:0] u_core = clamp_u ? {FB{1'b0}} : u;
    wire [FB-1:0] v_core = clamp_v ? {FB{1'b0}} : v;

    //========================================================================
    // 3×bilinear_interp_8b：R/G/B 各一核，共用权重/valid 驱动
    //   dout 24bit：R=bit[23:16], G=bit[15:8], B=bit[7:0]
    //========================================================================
    wire [7:0] r_out, g_out, b_out;
    wire       v_r, v_g, v_b;

    bilinear_interp_8b #(.FRAC_BITS(FRAC_BITS)) u_core_r (
        .clk       (clk),
        .rst_n     (rst_n),
        .u_frac    (u_core),
        .v_frac    (v_core),
        .p00       (dout00[23:16]),
        .p01       (dout10[23:16]),
        .p10       (dout01[23:16]),
        .p11       (dout11[23:16]),
        .valid_in  (valid0),
        .pix_out   (r_out),
        .valid_out (v_r)
    );

    bilinear_interp_8b #(.FRAC_BITS(FRAC_BITS)) u_core_g (
        .clk       (clk),
        .rst_n     (rst_n),
        .u_frac    (u_core),
        .v_frac    (v_core),
        .p00       (dout00[15:8]),
        .p01       (dout10[15:8]),
        .p10       (dout01[15:8]),
        .p11       (dout11[15:8]),
        .valid_in  (valid0),
        .pix_out   (g_out),
        .valid_out (v_g)
    );

    bilinear_interp_8b #(.FRAC_BITS(FRAC_BITS)) u_core_b (
        .clk       (clk),
        .rst_n     (rst_n),
        .u_frac    (u_core),
        .v_frac    (v_core),
        .p00       (dout00[7:0]),
        .p01       (dout10[7:0]),
        .p10       (dout01[7:0]),
        .p11       (dout11[7:0]),
        .valid_in  (valid0),
        .pix_out   (b_out),
        .valid_out (v_b)
    );

    //========================================================================
    // 输出
    //========================================================================
    assign o_r     = r_out;
    assign o_g     = g_out;
    assign o_b     = b_out;
    assign o_valid = v_r;   // 三核同 LAT 同 valid_in，取任一
    assign o_done  = done;

endmodule