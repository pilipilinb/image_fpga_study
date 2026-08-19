//========================================================================
// CSC色彩空间转换 Verilog实现 (三级流水线版本)
// 来源: https://blog.csdn.net/qq_39507748/article/details/115270948
// 参考: 小梅哥《FPGA系统设计与验证实战指南》
//
// 设计特点:
//   1. 四级流水线(寄存器级): 乘法 -> 加法 -> 求和 -> 输出截取/饱和
//   2. 定点化: 系数扩大256倍，结果右移8位
//   3. 含行场同步信号延迟对齐(4拍, 与数据路径一致)
//   4. 负数处理: 正负分开相加，最后比较
//   5. 异步复位同步释放: i_rst_n低有效异步复位，内部两级同步器
//      同步释放复位沿，避免复位释放亚稳态；复位后所有寄存器
//      清零，同步输出为无效电平(0)
//
// 转换公式 (BT.601, 8-bit):
//   Y  = 0.183*R + 0.614*G + 0.062*B + 16
//   Cb = -0.101*R - 0.338*G + 0.439*B + 128
//   Cr = 0.439*R - 0.399*G - 0.040*B + 128
//   (注意: 此处使用的是带offset的公式，Y有+16偏移)
//========================================================================
`timescale 1ns/1ps

module rgb_to_ycbcr_3stage(
    input           clk,
    input           i_rst_n,    // 异步复位, 低有效 (内部同步释放)
    input   [7:0]   i_r_8b,
    input   [7:0]   i_g_8b,
    input   [7:0]   i_b_8b,

    input           i_h_sync,
    input           i_v_sync,
    input           i_data_en,

    output  [7:0]   o_y_8b,
    output  [7:0]   o_cb_8b,
    output  [7:0]   o_cr_8b,

    output          o_h_sync,
    output          o_v_sync,
    output          o_data_en
);

//========================================================================
// 参数定义: 浮点系数 × 256 得到定点系数
//========================================================================
// Y = 0.183*R + 0.614*G + 0.062*B + 16
parameter para_0183_10b = 10'd47;   // 0.183 × 256 ≈ 47
parameter para_0614_10b = 10'd157;  // 0.614 × 256 ≈ 157
parameter para_0062_10b = 10'd16;   // 0.062 × 256 ≈ 16
parameter para_16_18b   = 18'd4096; // 16  × 256 = 4096

// Cb = -0.101*R - 0.338*G + 0.439*B + 128
parameter para_0101_10b = 10'd26;   // 0.101 × 256 ≈ 26
parameter para_0338_10b = 10'd86;   // 0.338 × 256 ≈ 86
parameter para_0439_10b = 10'd112;  // 0.439 × 256 ≈ 112
parameter para_128_18b  = 18'd32768;// 128 × 256 = 32768

// Cr = 0.439*R - 0.399*G - 0.040*B + 128
parameter para_0399_10b = 10'd102;  // 0.399 × 256 ≈ 102
parameter para_0040_10b = 10'd10;   // 0.040 × 256 ≈ 10

//========================================================================
// 信号定义
//========================================================================
//========================================================================
// 异步复位同步释放: 外部异步复位i_rst_n, 释放沿与clk同步
// 复位: i_rst_n拉低后两级立即清零(异步); 释放: 两级逐拍拉高(同步)
//========================================================================
reg     rst_n_sync_1;
reg     rst_n_sync_2;
wire    rst_n = rst_n_sync_2;   // 同步释放后的复位信号(低有效)

always @(posedge clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        rst_n_sync_1 <= 1'b0;
        rst_n_sync_2 <= 1'b0;
    end else begin
        rst_n_sync_1 <= 1'b1;
        rst_n_sync_2 <= rst_n_sync_1;
    end
end

wire    sign_cb;
wire    sign_cr;

// 第一级流水线: 乘法结果
reg [17:0] mult_r_for_y_18b;
reg [17:0] mult_r_for_cb_18b;
reg [17:0] mult_r_for_cr_18b;
reg [17:0] mult_g_for_y_18b;
reg [17:0] mult_g_for_cb_18b;
reg [17:0] mult_g_for_cr_18b;
reg [17:0] mult_b_for_y_18b;
reg [17:0] mult_b_for_cb_18b;
reg [17:0] mult_b_for_cr_18b;

// 第二级流水线: 加法结果 (正负分开)
reg [17:0] add_y_0_18b;
reg [17:0] add_y_1_18b;
reg [17:0] add_cb_0_18b;
reg [17:0] add_cb_1_18b;
reg [17:0] add_cr_0_18b;
reg [17:0] add_cr_1_18b;

// 第三级流水线: 最终结果
reg [17:0] result_y_18b;
reg [17:0] result_cb_18b;
reg [17:0] result_cr_18b;

// 输出截取 (右移8位 + 四舍五入)
reg [9:0]  y_tmp;
reg [9:0]  cb_tmp;
reg [9:0]  cr_tmp;

// 同步信号延迟链 (4级: 与数据路径的4级寄存器对齐)
reg        i_h_sync_delay_1, i_v_sync_delay_1, i_data_en_delay_1;
reg        i_h_sync_delay_2, i_v_sync_delay_2, i_data_en_delay_2;
reg        i_h_sync_delay_3, i_v_sync_delay_3, i_data_en_delay_3;
reg        i_h_sync_delay_4, i_v_sync_delay_4, i_data_en_delay_4;

//========================================================================
// 第一级流水线: 乘法计算
// 所有乘法在同一时钟周期并行执行
//========================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        mult_r_for_y_18b  <= 18'd0;
        mult_g_for_y_18b  <= 18'd0;
        mult_b_for_y_18b  <= 18'd0;
        mult_r_for_cb_18b <= 18'd0;
        mult_g_for_cb_18b <= 18'd0;
        mult_b_for_cb_18b <= 18'd0;
        mult_r_for_cr_18b <= 18'd0;
        mult_g_for_cr_18b <= 18'd0;
        mult_b_for_cr_18b <= 18'd0;
    end else begin
        // Y通道: R×0.183, G×0.614, B×0.062
        mult_r_for_y_18b  <= i_r_8b * para_0183_10b;
        mult_g_for_y_18b  <= i_g_8b * para_0614_10b;
        mult_b_for_y_18b  <= i_b_8b * para_0062_10b;

        // Cb通道: R×0.101, G×0.338, B×0.439 (注意Cb中R和G是负系数)
        mult_r_for_cb_18b <= i_r_8b * para_0101_10b;
        mult_g_for_cb_18b <= i_g_8b * para_0338_10b;
        mult_b_for_cb_18b <= i_b_8b * para_0439_10b;

        // Cr通道: R×0.439, G×0.399, B×0.040 (注意Cr中G和B是负系数)
        mult_r_for_cr_18b <= i_r_8b * para_0439_10b;
        mult_g_for_cr_18b <= i_g_8b * para_0399_10b;
        mult_b_for_cr_18b <= i_b_8b * para_0040_10b;
    end
end

//========================================================================
// 第二级流水线: 加法计算
// 正数项和负数项分开相加，避免有符号运算
// Y  = (R×0.183 + G×0.614) + (B×0.062 + 16)
// Cb = (B×0.439 + 128) - (R×0.101 + G×0.338)
// Cr = (R×0.439 + 128) - (G×0.399 + B×0.040)
//========================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        add_y_0_18b  <= 18'd0;
        add_y_1_18b  <= 18'd0;
        add_cb_0_18b <= 18'd0;
        add_cb_1_18b <= 18'd0;
        add_cr_0_18b <= 18'd0;
        add_cr_1_18b <= 18'd0;
    end else begin
        // Y: 全部正数，直接加
        add_y_0_18b  <= mult_r_for_y_18b + mult_g_for_y_18b;
        add_y_1_18b  <= mult_b_for_y_18b + para_16_18b;

        // Cb: 正数项(B+128)，负数项(R+G)
        add_cb_0_18b <= mult_b_for_cb_18b + para_128_18b;
        add_cb_1_18b <= mult_r_for_cb_18b + mult_g_for_cb_18b;

        // Cr: 正数项(R+128)，负数项(G+B)
        add_cr_0_18b <= mult_r_for_cr_18b + para_128_18b;
        add_cr_1_18b <= mult_g_for_cr_18b + mult_b_for_cr_18b;
    end
end

//========================================================================
// 第三级流水线: 最终求和
// Y: 正数相加
// Cb/Cr: 比较正负项大小，大减小，符号决定加还是减128
//========================================================================
assign sign_cb = (add_cb_0_18b >= add_cb_1_18b);
assign sign_cr = (add_cr_0_18b >= add_cr_1_18b);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        result_y_18b  <= 18'd0;
        result_cb_18b <= 18'd0;
        result_cr_18b <= 18'd0;
    end else begin
        // Y: 直接相加
        result_y_18b  <= add_y_0_18b + add_y_1_18b;
        // Cb: 若正数项>=负数项，正常；否则取0(负数截断为0)
        result_cb_18b <= sign_cb ? (add_cb_0_18b - add_cb_1_18b) : 18'd0;
        // Cr: 同理
        result_cr_18b <= sign_cr ? (add_cr_0_18b - add_cr_1_18b) : 18'd0;
    end
end

//========================================================================
// 输出截取: 右移8位(除以256) + 四舍五入 + 饱和钳位
//========================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        y_tmp  <= 10'd0;
        cb_tmp <= 10'd0;
        cr_tmp <= 10'd0;
    end else begin
        // 右移8位，最高位加1实现四舍五入
        y_tmp  <= result_y_18b[17:8]  + {9'd0, result_y_18b[7]};
        cb_tmp <= result_cb_18b[17:8] + {9'd0, result_cb_18b[7]};
        cr_tmp <= result_cr_18b[17:8] + {9'd0, result_cr_18b[7]};
    end
end

// 饱和处理: 结果限制在0~255
assign o_y_8b  = (y_tmp[9:8]  == 2'b00) ? y_tmp[7:0]  : 8'hFF;
assign o_cb_8b = (cb_tmp[9:8] == 2'b00) ? cb_tmp[7:0] : 8'hFF;
assign o_cr_8b = (cr_tmp[9:8] == 2'b00) ? cr_tmp[7:0] : 8'hFF;

//========================================================================
// 同步信号延迟对齐 (延迟4个时钟周期，与数据流水线对齐)
//========================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        i_h_sync_delay_1  <= 1'b0;
        i_v_sync_delay_1  <= 1'b0;
        i_data_en_delay_1 <= 1'b0;
        i_h_sync_delay_2  <= 1'b0;
        i_v_sync_delay_2  <= 1'b0;
        i_data_en_delay_2 <= 1'b0;
        i_h_sync_delay_3  <= 1'b0;
        i_v_sync_delay_3  <= 1'b0;
        i_data_en_delay_3 <= 1'b0;
        i_h_sync_delay_4  <= 1'b0;
        i_v_sync_delay_4  <= 1'b0;
        i_data_en_delay_4 <= 1'b0;
    end else begin
        // 第1级延迟
        i_h_sync_delay_1 <= i_h_sync;
        i_v_sync_delay_1 <= i_v_sync;
        i_data_en_delay_1 <= i_data_en;

        // 第2级延迟
        i_h_sync_delay_2 <= i_h_sync_delay_1;
        i_v_sync_delay_2 <= i_v_sync_delay_1;
        i_data_en_delay_2 <= i_data_en_delay_1;

        // 第3级延迟
        i_h_sync_delay_3 <= i_h_sync_delay_2;
        i_v_sync_delay_3 <= i_v_sync_delay_2;
        i_data_en_delay_3 <= i_data_en_delay_2;

        // 第4级延迟
        i_h_sync_delay_4 <= i_h_sync_delay_3;
        i_v_sync_delay_4 <= i_v_sync_delay_3;
        i_data_en_delay_4 <= i_data_en_delay_3;
    end
end

assign o_h_sync  = i_h_sync_delay_4;
assign o_v_sync  = i_v_sync_delay_4;
assign o_data_en = i_data_en_delay_4;

endmodule