//========================================================================
// image_rom.v —— 推断式 BRAM 只读 ROM（bilinear_v3 版）
// 功能：存储输入 RGB888 图像（24bit/像素），按地址同步读出
//   initial $readmemh(INIT_FILE, mem) 从 input.hex 初始化，
//   等价于 BRAM IP 的 COE 初始化（不绑定厂商 IP，可移植）
//
// 使用方式：顶层例化 4 份（addr00/addr10/addr01/addr11），1 拍并行
//   读齐 2×2 邻域 4 像素；每份独立读端口，共享同一 INIT_FILE 内容。
//   注：4 份 = 4× 存储开销，学习小图（112×103）可接受；真机大图
//   可改真双口 BRAM 或行缓存方案（见计划书已知限制）
//
// 铁律（守 line_buffer_3x3.v 同款）：
//   - BRAM 阵列不可复位（原语无内容复位 pin），不能加复位条件否则推断失败
//   - 读输出寄存器 rd 用同步复位（if(!rst_n) 写在 posedge clk 内，
//     不进敏感表），保证 BRAM 推断
//   - 上电脏数据（x）由下游 valid/坐标门控屏蔽，不用复位清零
//
// 时序：同步读，1 拍潜伏 —— addr 在 T 拍有效，dout = mem[addr] 在 T+1 拍输出
//   顶层用 valid 链对齐这 1 拍（与 coord_gen valid_out 的延迟对齐）
//========================================================================
`timescale 1ns/1ps

module image_rom #(
    parameter IN_WIDTH  = 112,        // 输入图像宽
    parameter IN_HEIGHT = 103,        // 输入图像高
    parameter INIT_FILE = "input.hex",// $readmemh 初始化文件（相对运行目录）
    parameter ADDR_W    = $clog2(IN_WIDTH * IN_HEIGHT)   // 地址位宽
)(
    input                   clk,
    input                   rst_n,       // 低电平复位（同步复位读寄存器）
    input  [ADDR_W-1:0]     addr,        // 读地址
    output [23:0]           dout         // 读数据（R=bit[23:16], G=bit[15:8], B=bit[7:0]）
);

    (* ram_style = "block" *) reg [23:0] mem [0:IN_WIDTH*IN_HEIGHT-1];

    // $readmemh 初始化：每行一个 24bit 十六进制数（input.hex，由
    // make_tb_input.py 从 input.coe 转换而来，R 为最高字节）
    initial begin
        $readmemh(INIT_FILE, mem);
    end

    // 同步读 + 读输出寄存器同步复位（守 BRAM 铁律：不进敏感表）
    reg [23:0] rd;
    always @(posedge clk) begin
        if (!rst_n) rd <= 24'd0;
        else        rd <= mem[addr];
    end

    assign dout = rd;

endmodule