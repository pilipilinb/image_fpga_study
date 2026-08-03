`timescale 1ns/1ps

`timescale 1ns/1ps

module line_buffer (
        rst_n,
        clk,
        din,
        dout,
        valid_in,
        valid_out
    );

parameter WIDTH = 10;//数据位宽
parameter IMG_WIDTH = 480;//图像宽度

input  rst_n;
input  clk;
input  [WIDTH-1:0] din;
output [WIDTH-1:0] dout;
input  valid_in;//输入数据有效，写使能
output valid_out;//输出给下一级的valid_in，也即上一级开始读的同时下一级就可以开始写入

wire   rd_en;//读使能
reg    [8:0] cnt;//这里的宽度注意要根据IMG_WIDTH的值来设置，需要满足cnt的范围≥图像宽度

always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        cnt <= {9{1'b0}};
    else if(valid_in)
        if(cnt == IMG_WIDTH)
            cnt <= IMG_WIDTH;
        else
            cnt <= cnt +1'b1;
    else
        cnt <= cnt;
end
//一行数据写完之后，该级fifo就可以开始读出，下一级也可以开始写入了
assign rd_en = ((cnt == IMG_WIDTH) && (valid_in)) ? 1'b1:1'b0;
assign valid_out = rd_en;

line_fifo u_line_fifo(
    .clk (clk),
    .rst (!rst_n),
    .din (din),
    .wr_en (valid_in),
    .rd_en (rd_en),
    .dout(dout),

    .empty(),
    .full(),
    .data_count(),    
    .wr_rst_busy(),  
    .rd_rst_busy()
);

/*
  .clk(clk),                  // input wire clk
  .rst(rst),                  // input wire rst
  .din(din),                  // input wire [9 : 0] din
  .wr_en(wr_en),              // input wire wr_en
  .rd_en(rd_en),              // input wire rd_en
  .dout(dout),                // output wire [9 : 0] dout
  .full(full),                // output wire full
  .empty(empty),              // output wire empty
  .data_count(data_count),    // output wire [8 : 0] data_count
  .wr_rst_busy(wr_rst_busy),  // output wire wr_rst_busy
  .rd_rst_busy(rd_rst_busy)  // output wire rd_rst_busy
*/
endmodule




module matrix_3x3 (
    clk,
    rst_n,
    valid_in,//输入数据有效信号
    din,//输入的图像数据，将一帧的数据从左到右，然后从上到下依次输入
    
    dout_r0,//第一行的输出数据
    dout_r1,//第二行的输出数据
    dout_r2,//第三行的输出数据
    dout,//最后一行的输出数据
    mat_flag//当第四行数据到来，前三行数据才开始同时输出，此时该信号拉高
);
parameter WIDTH = 10;//数据位宽
parameter           COL_NUM     =   480    ;
parameter           ROW_NUM     =   272     ;
parameter LINE_NUM = 3;//行缓存的行数

input clk;
input rst_n;
input valid_in;
input [WIDTH-1:0] din;

output[WIDTH-1:0] dout;
output[WIDTH-1:0] dout_r0;
output[WIDTH-1:0] dout_r1;
output[WIDTH-1:0] dout_r2;
output mat_flag;

reg   [WIDTH-1:0] line[2:0];//保存每个line_buffer的输入数据
reg   valid_in_r  [2:0];
wire  valid_out_r [2:0];
wire  [WIDTH-1:0] dout_r[2:0];//保存每个line_buffer的输出数据

assign dout_r0 = dout_r[0];
assign dout_r1 = dout_r[1];
assign dout_r2 = dout_r[2];

assign dout = dout_r[2];

genvar i;
generate
    begin:HDL1
    for (i = 0;i < LINE_NUM;i = i +1)
        begin : buffer_inst
            // line 1
            if(i == 0) begin: MAPO
                always @(*)begin
                    line[i]<=din;
                    valid_in_r[i]<= valid_in;//第一个line_fifo的din和valid_in由顶层直接提供
                end
            end
            // line 2 3 ...
            if(~(i == 0)) begin: MAP1
                always @(*) begin
                	//将上一个line_fifo的输出连接到下一个line_fifo的输入
                    line[i] <= dout_r[i-1];
                    //当上一个line_fifo写入480个数据之后拉高rd_en，表示开始读出数据；
                    //valid_out和rd_en同步，valid_out赋值给下一个line_fifo的
                    //valid_in,表示可以开始写入了
                    valid_in_r[i] <= valid_out_r[i-1];
                end
            end
        line_buffer #(WIDTH,COL_NUM)
            line_buffer_inst(
                .rst_n (rst_n),
                .clk (clk),
                .din (line[i]),
                .dout (dout_r[i]),
                .valid_in(valid_in_r[i]),
                .valid_out (valid_out_r[i])
                );
        end
    end
endgenerate
reg                 [10:0]  col_cnt         ;
reg                 [10:0]  row_cnt         ;

assign      mat_flag        =       row_cnt >= 11'd3 ? valid_in : 1'b0;

always @(posedge clk or negedge rst_n)
    if(rst_n == 1'b0)
        col_cnt             <=          11'd0;
    else if(col_cnt == COL_NUM-1 && valid_in == 1'b1)
        col_cnt             <=          11'd0;
    else if(valid_in == 1'b1)
        col_cnt             <=          col_cnt + 1'b1;
    else
        col_cnt             <=          col_cnt;

always @(posedge clk or negedge rst_n)
    if(rst_n == 1'b0)
        row_cnt             <=          11'd0;
    else if(row_cnt == ROW_NUM-1 && col_cnt == COL_NUM-1 && valid_in == 1'b1)
        row_cnt             <=          11'd0;
    else if(col_cnt == COL_NUM-1 && valid_in == 1'b1) 
        row_cnt             <=          row_cnt + 1'b1;
endmodule
