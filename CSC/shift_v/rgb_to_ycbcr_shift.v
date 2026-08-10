//========================================================================
// CSC色彩空间转换 Verilog实现 (移位代替乘法版本)
// 来源: https://blog.csdn.net/wasdwf/article/details/7396695
//
// 设计特点:
//   1. 完全可综合，不用乘法器，用移位实现乘法
//   2. 6级流水线，输出延迟6个时钟
//   3. Y/Cb/Cr三个输出对齐
//
// 转换公式 (BT.601):
//   Y  = (0.299R + 0.587G + 0.114B)
//   Cr = (0.511R - 0.428G - 0.083B) + 128
//   Cb = (-0.172R - 0.339G + 0.511B) + 128
//
// 定点化 (扩大1024倍):
//   Y  = (306*R + 601*G + 117*B) / 1024
//   Cr = (523*R - 438*G - 85*B) / 1024 + 128
//   Cb = (-176*R - 347*G + 523*B) / 1024 + 128
//
// 移位实现乘法示例:
//   306 = 256 + 32 + 16 + 2 = (R<<8) + (R<<5) + (R<<4) + (R<<1)
//   601 = 512 + 64 + 16 + 8 + 1 = (G<<9) + (G<<6) + (G<<4) + (G<<3) + G
//========================================================================
`timescale 1ns/10ps

module rgb_to_ycbcr_shift(
    input           clk,
    input           ngreset,    // 异步复位，低有效
    input   [7:0]   R,
    input   [7:0]   G,
    input   [7:0]   B,
    output  [7:0]   Y,
    output  [7:0]   Cb,
    output  [7:0]   Cr
);

wire [7:0] Y, Cb, Cr;

//========================================================================
// Y = (306*R + 601*G + 117*B) / 1024
// 306 = 256 + 32 + 16 + 2
// 601 = 512 + 64 + 16 + 8 + 1
// 117 = 64 + 32 + 16 + 4 + 1
//========================================================================

// 第一级: 移位
reg [16:0] r_256_32;    // R×(256+32)
reg [12:0] r_16_2;      // R×(16+2)
reg [17:0] g_512_64;    // G×(512+64)
reg [12:0] g_16_8;      // G×(16+8)
reg [7:0]  g_1;         // G×1
reg [14:0] b_64_32;     // B×(64+32)
reg [12:0] b_16_4;      // B×(16+4)
reg [7:0]  b_1;         // B×1

always @(posedge clk or negedge ngreset) begin
    if (!ngreset) begin
        r_256_32  <= 17'h0;
        r_16_2    <= 13'h0;
        g_512_64  <= 18'h0;
        g_16_8    <= 13'h0;
        g_1       <= 8'h0;
        b_64_32   <= 15'h0;
        b_16_4    <= 13'h0;
        b_1       <= 8'h0;
    end else begin
        r_256_32  <= {R, 8'd0} + {R, 5'd0};   // R×256 + R×32
        r_16_2    <= {R, 4'd0} + {R, 1'd0};   // R×16 + R×2
        g_512_64  <= {G, 9'd0} + {G, 6'd0};   // G×512 + G×64
        g_16_8    <= {G, 4'd0} + {G, 3'd0};   // G×16 + G×8
        g_1       <= G;                        // G×1
        b_64_32   <= {B, 6'd0} + {B, 5'd0};   // B×64 + B×32
        b_16_4    <= {B, 4'd0} + {B, 2'd0};   // B×16 + B×4
        b_1       <= B;                        // B×1
    end
end

// 第二级: 组合移位结果
reg [17:0] r_256_32_16_2;     // R×306
reg [17:0] g_512_64_16_8;     // G×(512+64+16+8)
reg [7:0]  g_1_d1;
reg [17:0] b_64_32_16_4;      // B×(64+32+16+4)
reg [7:0]  b_1_d1;

always @(posedge clk or negedge ngreset) begin
    if (!ngreset) begin
        r_256_32_16_2  <= 18'h0;
        g_512_64_16_8  <= 18'h0;
        g_1_d1         <= 8'h0;
        b_64_32_16_4   <= 18'h0;
        b_1_d1         <= 8'h0;
    end else begin
        r_256_32_16_2  <= r_256_32 + r_16_2;        // R×(256+32+16+2) = R×306
        g_512_64_16_8  <= g_512_64 + g_16_8;        // G×(512+64+16+8)
        g_1_d1         <= g_1;                       // 延迟一拍
        b_64_32_16_4   <= b_64_32 + b_16_4;         // B×(64+32+16+4)
        b_1_d1         <= b_1;                       // 延迟一拍
    end
end

// 第三级: 完成各通道乘法
reg [17:0] y_r;
reg [17:0] y_g;
reg [17:0] y_b;

always @(posedge clk or negedge ngreset) begin
    if (!ngreset) begin
        y_r <= 18'h0;
        y_g <= 18'h0;
        y_b <= 18'h0;
    end else begin
        y_r <= r_256_32_16_2;                        // R×306
        y_g <= g_512_64_16_8 + {10'd0, g_1_d1};     // G×(512+64+16+8+1) = G×601
        y_b <= b_64_32_16_4 + {10'd0, b_1_d1};      // B×(64+32+16+4+1) = B×117
    end
end

// 第四级: R+G
reg [17:0] y_rg;
reg [17:0] y_b_d1;

always @(posedge clk or negedge ngreset) begin
    if (!ngreset) begin
        y_rg   <= 18'h0;
        y_b_d1 <= 18'h0;
    end else begin
        y_rg   <= y_r + y_g;
        y_b_d1 <= y_b;
    end
end

// 第五级: (R+G)+B
reg [17:0] y_rgb;

always @(posedge clk or negedge ngreset) begin
    if (!ngreset)
        y_rgb <= 18'h0;
    else
        y_rgb <= y_rg + y_b_d1;
end

// 右移10位(除以1024)
wire [7:0] y_tmp;
assign y_tmp = y_rgb[17:10];

//========================================================================
// Cr = (523*R - 438*G - 85*B) / 1024 + 128
// 523 = 512 + 8 + 2 + 1
// 438 = 256 + 128 + 32 + 16 + 4 + 2
// 85  = 64 + 16 + 4 + 1
//========================================================================

// 第一级: 移位
reg [17:0] r_512_8;       // R×(512+8)
reg [9:0]  r_2_1;         // R×(2+1)
reg [16:0] g_256_128;     // G×(256+128)
reg [13:0] g_32_16;       // G×(32+16)
reg [10:0] g_4_2;         // G×(4+2)
reg [14:0] b_64_16;       // B×(64+16)
reg [10:0] b_4_1;         // B×(4+1)

always @(posedge clk or negedge ngreset) begin
    if (!ngreset) begin
        r_512_8    <= 18'h0;
        r_2_1      <= 10'h0;
        g_256_128  <= 17'h0;
        g_32_16    <= 14'h0;
        g_4_2      <= 11'h0;
        b_64_16    <= 15'h0;
        b_4_1      <= 11'h0;
    end else begin
        r_512_8    <= {R, 9'd0} + {R, 3'd0};   // R×512 + R×8
        r_2_1      <= {R, 1'd0} + R;            // R×2 + R×1
        g_256_128  <= {G, 8'd0} + {G, 7'd0};   // G×256 + G×128
        g_32_16    <= {G, 5'd0} + {G, 4'd0};   // G×32 + G×16
        g_4_2      <= {G, 2'd0} + {G, 1'd0};   // G×4 + G×2
        b_64_16    <= {B, 6'd0} + {B, 4'd0};   // B×64 + B×16
        b_4_1      <= {B, 2'd0} + B;            // B×4 + B×1
    end
end

// 第二级: 组合
reg [17:0] r_523;
reg [17:0] g_438;
reg [10:0] g_4_2_d1;
reg [17:0] b_85;

always @(posedge clk or negedge ngreset) begin
    if (!ngreset) begin
        r_523      <= 18'h0;
        g_438      <= 18'h0;
        g_4_2_d1   <= 11'h0;
        b_85       <= 18'h0;
    end else begin
        r_523      <= r_512_8 + {8'd0, r_2_1};     // R×(512+8+2+1) = R×523
        g_438      <= g_256_128 + g_32_16;          // G×(256+128+32+16)
        g_4_2_d1   <= g_4_2;                         // 延迟
        b_85       <= b_64_16 + b_4_1;              // B×(64+16+4+1) = B×85
    end
end

// 第三级: 完成G乘法
reg [17:0] cr_r;
reg [17:0] cr_gb;

always @(posedge clk or negedge ngreset) begin
    if (!ngreset) begin
        cr_r  <= 18'h0;
        cr_gb <= 18'h0;
    end else begin
        cr_r  <= r_523;                              // R×523
        cr_gb <= g_438 + {7'd0, g_4_2_d1} + b_85;   // G×438 + B×85
    end
end

// 第四级: 比较大小
reg [17:0] cr_rgb;

always @(posedge clk or negedge ngreset) begin
    if (!ngreset)
        cr_rgb <= 18'h0;
    else if (cr_r > cr_gb)
        cr_rgb <= cr_r - cr_gb;    // 正数
    else
        cr_rgb <= cr_gb - cr_r;    // 取绝对值
end

wire [7:0] cr_rgb_d;
assign cr_rgb_d = cr_rgb[17:10];   // 右移10位

// 保存符号信息用于决定加还是减128
reg [17:0] cr_r_d1;
reg [17:0] cr_gb_d1;

always @(posedge clk or negedge ngreset) begin
    if (!ngreset)
        {cr_r_d1, cr_gb_d1} <= 36'h0;
    else
        {cr_r_d1, cr_gb_d1} <= {cr_r, cr_gb};
end

// 第五级: 加减128
reg [7:0] cr_tmp;

always @(posedge clk or negedge ngreset) begin
    if (!ngreset)
        cr_tmp <= 8'd0;
    else if (cr_r_d1 > cr_gb_d1)
        cr_tmp <= 8'd128 + cr_rgb_d;    // 正: 128 + |差值|
    else
        cr_tmp <= 8'd128 - cr_rgb_d;    // 负: 128 - |差值|
end

//========================================================================
// Cb = (-176*R - 347*G + 523*B) / 1024 + 128
// 176 = 128 + 32 + 16
// 347 = 256 + 64 + 16 + 8 + 2 + 1
// 523 = 512 + 8 + 2 + 1
//========================================================================

// 第一级: 移位
reg [15:0] r_128_32;      // R×(128+32)
reg [12:0] r_16;          // R×16
reg [16:0] g_256_64;      // G×(256+64)
reg [9:0]  g_2_1;         // G×(2+1)
reg [17:0] b_512_8;       // B×(512+8)
reg [9:0]  b_2_1;         // B×(2+1)

always @(posedge clk or negedge ngreset) begin
    if (!ngreset) begin
        r_128_32  <= 16'h0;
        r_16      <= 13'h0;
        g_256_64  <= 17'h0;
        g_2_1     <= 10'h0;
        b_512_8   <= 18'h0;
        b_2_1     <= 10'h0;
    end else begin
        r_128_32  <= {R, 7'd0} + {R, 5'd0};   // R×128 + R×32
        r_16      <= {R, 4'd0};                 // R×16
        g_256_64  <= {G, 8'd0} + {G, 6'd0};   // G×256 + G×64
        g_2_1     <= {G, 1'd0} + G;            // G×2 + G×1
        b_512_8   <= {B, 9'd0} + {B, 3'd0};   // B×512 + B×8
        b_2_1     <= {B, 1'd0} + B;            // B×2 + B×1
    end
end

// 第二级: 组合
reg [17:0] r_176;
reg [17:0] g_347;
reg [17:0] b_523;

always @(posedge clk or negedge ngreset) begin
    if (!ngreset) begin
        r_176  <= 18'h0;
        g_347  <= 18'h0;
        b_523  <= 18'h0;
    end else begin
        r_176  <= r_128_32 + {5'd0, r_16};         // R×(128+32+16) = R×176
        g_347  <= g_256_64 + {7'd0, g_2_1};        // G×(256+64+2+1)
        b_523  <= b_512_8 + {8'd0, b_2_1};         // B×(512+8+2+1) = B×523
    end
end

// 第三级
reg [17:0] cb_r;
reg [17:0] cb_g;
reg [17:0] cb_b;

always @(posedge clk or negedge ngreset) begin
    if (!ngreset) begin
        cb_r <= 18'h0;
        cb_g <= 18'h0;
        cb_b <= 18'h0;
    end else begin
        cb_r <= r_176;
        cb_g <= g_347;
        cb_b <= b_523;
    end
end

// 第四级: 正负项分组
reg [17:0] cb_rg;
reg [17:0] cb_b_d1;

always @(posedge clk or negedge ngreset) begin
    if (!ngreset) begin
        cb_rg   <= 18'h0;
        cb_b_d1 <= 18'h0;
    end else begin
        cb_rg   <= cb_r + cb_g;    // 负数项: R×176 + G×347
        cb_b_d1 <= cb_b;            // 正数项: B×523
    end
end

// 第五级: 比较
reg [17:0] cb_rgb;

always @(posedge clk or negedge ngreset) begin
    if (!ngreset)
        cb_rgb <= 18'h0;
    else if (cb_rg > cb_b_d1)
        cb_rgb <= cb_rg - cb_b_d1;
    else
        cb_rgb <= cb_b_d1 - cb_rg;
end

wire [7:0] cb_rgb_d1;
assign cb_rgb_d1 = cb_rgb[17:10];   // 右移10位

// 第六级: 加减128
reg [7:0] cb_tmp;

always @(posedge clk or negedge ngreset) begin
    if (!ngreset)
        cb_tmp <= 8'h0;
    else if (cb_rg > cb_b_d1)
        cb_tmp <= 8'd128 - cb_rgb_d1;    // 负: 128 - |差值|
    else
        cb_tmp <= 8'd128 + cb_rgb_d1;    // 正: 128 + |差值|
end

//========================================================================
// 输出 (额外延迟一拍使Y与其他对齐)
//========================================================================
reg [7:0] y_tmp_d1;

always @(posedge clk or negedge ngreset) begin
    if (!ngreset)
        y_tmp_d1 <= 8'd0;
    else
        y_tmp_d1 <= y_tmp;
end

assign Y  = y_tmp_d1;
assign Cb = cb_tmp;
assign Cr = cr_tmp;

endmodule
