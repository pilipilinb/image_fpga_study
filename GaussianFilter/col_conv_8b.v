//========================================================================
// col_conv_8b.v —— 一维列卷积核 [1,2,1] + 归一化（可分离高斯阶段二）
//
// 功能：纵向 3-tap（up/mid/down = 上/中/下行同列的 hsum）+ **唯一一次 ÷16**：
//   col = up + (mid<<1) + down        （hsum 已 ×4 放大，三项和 = 4×1020 = 4080 → 12bit）
//   dout = (col + 8) >> 4              （与直接 3×3 版 (sum+8)>>4 严格同构）
// 输入是行卷积输出 hsum（10bit ×4 放大），故位级上与直接版逐像素同构
// 流水：组合加权 + 寄存器输出；valid 链 LAT=1
//========================================================================
`timescale 1ns/1ps

module col_conv_8b (
    input               clk,
    input               rst_n,
    input  [9:0]        up,          // 上行同列 hsum（行缓存输出）
    input  [9:0]        mid,         // 本行同列 hsum（1 拍延迟 / 行缓存）
    input  [9:0]        down,        // 下行同列 hsum（当前拍）
    input               valid_in,
    output reg  [7:0]   dout,        // 高斯滤波结果（8bit）
    output              valid_out
);

    // 加权和：上 + 2×中 + 下（12bit，4080 < 2^12）
    wire [11:0] col = ({2'b00, up} + ({1'b0, mid} << 1) + {2'b00, down});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            dout <= 8'd0;
        else begin
            // (col+8)>>4：4080>>4=255 恰好满值，饱和为防御保留
            if (col + 12'd8 > 12'd4080)
                dout <= 8'd255;
            else
                dout <= (col + 12'd8) >> 4;
        end
    end

    reg valid_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)       valid_r <= 1'b0;
        else              valid_r <= valid_in;
    end
    assign valid_out = valid_r;

endmodule