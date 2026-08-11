//========================================================================
// bilinear_rgb_top.v —— 双线性插值缩放顶层（bilinear_v3 版）
// 功能：RGB888 输入 → 任意整数倍缩放（放大 N 倍 / 缩小 N 倍）→ RGB888 输出
//
// 数据流：
//   coord_gen（坐标+权重）→ 邻居地址钳位/权重清零标志
//     → 4×image_rom 并联（1 拍并行读齐 2×2 邻域）
//     → 权重延迟 1 拍对齐 ROM 读潜伏 + 钳位方向清零
//     → 3×bilinear_interp_8b（R/G/B 各一，LAT=8 流水）
//     → o_r/o_g/o_b + o_valid
//
// 时序对齐（关键，务必理解）：
//   T 拍：   coord_gen 组合输出 (sx,sy,u,v,valid0)；组合计算 4 个读地址
//            + 钳位标志（clamp_u/clamp_v，T 拍沿寄存）
//   T 拍沿：ROM 读地址锁入（内部 1 拍潜伏）；u/v/valid0/钳位标志寄存 1 拍
//   T+1 拍：ROM 输出 4×24bit；u/v 按越界标志清零后给插值模块（与 ROM 输出同拍）
//   T+1..+8：插值模块 8 级流水（LAT=8）
//   T+9 拍： o_r/o_g/o_b + o_valid 输出
//
// 架构决策：
//   - 整图 ROM 随机读（非行缓存）：缩放需任意源坐标 2×2 邻域，
//     line_buffer_nxn 不支持随机读；行缓存复用留给 W4 卷积
//     （已登记 AGENTS.md 计划修订记录）
//   - 4 份 image_rom 并联换 1 拍读齐 4 邻域，存储 4×（学习小图可接受）
//   - 3 个 8bit 插值模块并联：R/G/B 各自独立、单独可验证（case1 接口）
//
// 复位：counter/流水异步复位（negedge rst_n 进敏感表）；
//       BRAM 读寄存器同步复位（在 image_rom 内部，守 BRAM 铁律）
//
// W4 衔接：本版实现 mode=0（ROM 随机读，坐标由 coord_gen 驱动）；
//   mode=1（din/din_valid 流式 + 内部行缓存）见计划书 W4 衔接决策，
//   届时新增端口与内部 mux，不改本版数据通路
//========================================================================
`timescale 1ns/1ps

`include "coord_gen.v"
`include "bilinear_interp_8b.v"
`include "image_rom.v"

module bilinear_rgb_top #(
    parameter IN_WIDTH   = 112,     // 输入图像宽
    parameter IN_HEIGHT  = 103,     // 输入图像高
    parameter SCALE_N    = 2,       // 缩放倍数（分子）：放大 N 倍 = N/1
    parameter SCALE_D    = 1,       // 缩放倍数（分母）：缩小 N 倍 = 1/N
    parameter FRAC_BITS  = 8,       // 定点小数位（冻结 8，与插值模块位宽绑定）
    parameter INIT_FILE  = "input.hex"  // $readmemh 初始化文件
)(
    input                   clk,
    input                   rst_n,       // 低电平复位（异步）
    input                   start,       // 帧启动（透传 coord_gen）
    input                   pixel_en,    // 逐拍推进（每输出像素一拍）
    output [7:0]            o_r,         // 放大后 R
    output [7:0]            o_g,         // 放大后 G
    output [7:0]            o_b,         // 放大后 B
    output                  o_valid,     // 输出有效（与 o_r/o_g/o_b 同拍）
    output                  o_done       // 帧末（透传 coord_gen.done）
);

    localparam FB        = FRAC_BITS;
    localparam OUT_WIDTH  = IN_WIDTH  * SCALE_N / SCALE_D;   // 缩放后宽（整数除法截断）
    localparam OUT_HEIGHT = IN_HEIGHT * SCALE_N / SCALE_D;   // 缩放后高
    localparam XW = $clog2(IN_WIDTH)  + 1;   // 源 x 位宽（与 coord_gen 一致）
    localparam YW = $clog2(IN_HEIGHT) + 1;   // 源 y 位宽
    localparam ADDR_W = $clog2(IN_WIDTH * IN_HEIGHT);   // ROM 地址位宽

    //========================================================================
    // coord_gen：源坐标 + 权重（T 拍组合直通）
    //========================================================================
    wire [XW-1:0]        sx, sy;
    wire [FB-1:0]        u_frac, v_frac;
    wire                 valid0, done;

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
        .pixel_en   (pixel_en),
        .src_x_int  (sx),
        .src_y_int  (sy),
        .u_frac     (u_frac),
        .v_frac     (v_frac),
        .valid_out  (valid0),
        .done       (done)
    );

    //========================================================================
    // 邻居地址（T 拍组合）：先钳位再算地址，防越界读
    //   像素语义：p00 P(sy,sx) 左上 | p10 P(sy,sx+1) 右上
    //             p01 P(sy+1,sx) 左下 | p11 P(sy+1,sx+1) 右下
    //钳位其实就是饱和保护 也就是越界保护
    // 钳位到 [0, IN-1]：sx/sy 可能累加溢出到 IN（末像素），+1 也可能越界
    wire [XW-1:0] sx00 = (sx    > IN_WIDTH-1)  ? IN_WIDTH-1  : sx;
    wire [XW-1:0] sx10 = (sx+1'b1 > IN_WIDTH-1)? IN_WIDTH-1  : sx + 1'b1;
    wire [YW-1:0] sy00 = (sy    > IN_HEIGHT-1) ? IN_HEIGHT-1 : sy;
    wire [YW-1:0] sy01 = (sy+1'b1 > IN_HEIGHT-1)? IN_HEIGHT-1 : sy + 1'b1;

    // 越界标记：sx/sy 到达边界时置 1，用于把对应方向的权重清零
    // 不清零其实也对（边界上两个邻居是同一个像素，差值自然为 0），清零是显式防错
    wire clamp_u = (sx   >= IN_WIDTH-1);   // x 方向越界（含 sx 溢出到 IN_W）
    wire clamp_v = (sy   >= IN_HEIGHT-1);

    // 地址防截断：sy 先扩展到 ADDR_W 位再乘（避免乘积高位被截）
    wire [ADDR_W-1:0] sy00e = {{(ADDR_W-YW){1'b0}}, sy00};
    wire [ADDR_W-1:0] sy01e = {{(ADDR_W-YW){1'b0}}, sy01};
    wire [ADDR_W-1:0] sx00e = {{(ADDR_W-XW){1'b0}}, sx00};
    wire [ADDR_W-1:0] sx10e = {{(ADDR_W-XW){1'b0}}, sx10};

//sy × IN_WIDTH 是跳过前面的行，+ sx 是本行内的偏移，这4个就代表四个邻居的地址
    wire [ADDR_W-1:0] addr00 = sy00e * IN_WIDTH + sx00e;   // P(sy,   sx)
    wire [ADDR_W-1:0] addr10 = sy00e * IN_WIDTH + sx10e;   // P(sy,   sx+1)
    wire [ADDR_W-1:0] addr01 = sy01e * IN_WIDTH + sx00e;   // P(sy+1, sx)
    wire [ADDR_W-1:0] addr11 = sy01e * IN_WIDTH + sx10e;   // P(sy+1, sx+1)

    //========================================================================
    // 对齐寄存（T 拍沿）：u/v/valid/钳位标志延迟 1 拍，与 ROM 读潜伏对齐
    //========================================================================
    reg [FB-1:0] u_d1, v_d1;
    reg          valid_d1;
    reg          clamp_u_d1, clamp_v_d1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            u_d1       <= {FB{1'b0}};
            v_d1       <= {FB{1'b0}};
            valid_d1   <= 1'b0;
            clamp_u_d1 <= 1'b0;
            clamp_v_d1 <= 1'b0;
        end else begin
            u_d1       <= u_frac;
            v_d1       <= v_frac;
            valid_d1   <= valid0;
            clamp_u_d1 <= clamp_u;
            clamp_v_d1 <= clamp_v;
        end
    end

    // 给插值模块的权重：越界方向清零（比坐标晚 1 拍，和 ROM 输出对齐）
    wire [FB-1:0] u_core = clamp_u_d1 ? {FB{1'b0}} : u_d1;
    wire [FB-1:0] v_core = clamp_v_d1 ? {FB{1'b0}} : v_d1;

    //========================================================================
    // 4×image_rom 并联：1 拍并行读齐 2×2 邻域（共享同一 INIT_FILE）
    //========================================================================
    wire [23:0] dout00, dout10, dout01, dout11;

    image_rom #(
        .IN_WIDTH  (IN_WIDTH),
        .IN_HEIGHT (IN_HEIGHT),
        .INIT_FILE (INIT_FILE)
    ) u_rom00 (.clk(clk), .rst_n(rst_n), .addr(addr00), .dout(dout00));

    image_rom #(
        .IN_WIDTH  (IN_WIDTH),
        .IN_HEIGHT (IN_HEIGHT),
        .INIT_FILE (INIT_FILE)
    ) u_rom10 (.clk(clk), .rst_n(rst_n), .addr(addr10), .dout(dout10));

    image_rom #(
        .IN_WIDTH  (IN_WIDTH),
        .IN_HEIGHT (IN_HEIGHT),
        .INIT_FILE (INIT_FILE)
    ) u_rom01 (.clk(clk), .rst_n(rst_n), .addr(addr01), .dout(dout01));

    image_rom #(
        .IN_WIDTH  (IN_WIDTH),
        .IN_HEIGHT (IN_HEIGHT),
        .INIT_FILE (INIT_FILE)
    ) u_rom11 (.clk(clk), .rst_n(rst_n), .addr(addr11), .dout(dout11));

    //========================================================================
    // 三个插值模块：R/G/B 各一个，权重和 valid 共用
    //   ROM 输出 24bit：R=bit[23:16], G=bit[15:8], B=bit[7:0]
    //   三个模块延迟相同、valid 相同，输出必然同拍（随便取一个 valid 作输出有效）
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
        .valid_in  (valid_d1),
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
        .valid_in  (valid_d1),
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
        .valid_in  (valid_d1),
        .pix_out   (b_out),
        .valid_out (v_b)
    );

    //========================================================================
    // 输出
    //========================================================================
    assign o_r     = r_out;
    assign o_g     = g_out;
    assign o_b     = b_out;
    assign o_valid = v_r;   // v_r/v_g/v_b 同拍（同 LAT 同 valid_in），取任一
    assign o_done  = done;

endmodule