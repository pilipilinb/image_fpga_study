//========================================================================
// row_conv_8b.v —— 一维行卷积核 [1,2,1]（可分离高斯阶段一，GaussianFilter 工程）
//
// 功能：横向 3-tap 加权和（**不做归一化**——÷16 留给列阶段一次完成，
//       与直接 3×3 版 (sum+8)>>4 严格同构，保证位级全等）：
//   hsum = p_prev2 + (p_prev1<<1) + p_cur = 左 + 2×中 + 右
//   （横向邻居：左=上一拍、右=下一拍 → 只需 2 个像素延迟寄存器，不需要行缓存）
//
// 位宽：8bit 输入 → hsum 最大 255×4 = 1020 < 2^10 → 10bit 输出
// 流水：级1 组合加权 + 寄存器输出；valid 链 LAT=1
//========================================================================
`timescale 1ns/1ps

module row_conv_8b (
    input               clk,
    input               rst_n,
    input  [7:0]        din,         // 像素流（行优先）
    input               din_valid,
    output reg  [9:0]   hsum,        // 行卷积和（×4 放大，未归一化）
    output              hsum_valid
);

    // 横向窗口：{d2(左), d1(中), din(右)}
    reg [7:0] d1, d2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d1 <= 8'd0;
            d2 <= 8'd0;
            hsum <= 10'd0;
        end else begin
            d1 <= din;
            d2 <= d1;
            // 左 + 2×中 + 右（10bit：1020 < 2^10）
            hsum <= {2'b00, d2} + ({1'b0, d1} << 1) + {2'b00, din};
        end
    end

    reg valid_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)       valid_r <= 1'b0;
        else              valid_r <= din_valid;
    end
    assign hsum_valid = valid_r;

endmodule