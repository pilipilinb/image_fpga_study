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



parameter Y_R_stone = 10'd47;
parameter Y_G_stone = 10'd157;
parameter Y_B_stone = 10'd16;
parameter Y_shift = 18'd4096;


parameter Cb_R_stone = 10'd26;
parameter Cb_G_stone = 10'd87;
parameter Cb_B_stone = 10'd112;
parameter Cb_shift = 18'd32768;


parameter Cr_R_stone = 10'd112;
parameter Cr_G_stone = 10'd102;
parameter Cr_B_stone = 10'd10;
parameter Cr_shift = 18'd32768;




reg [17:0] Y_R_stage1 ;
reg [17:0] Y_G_stage1 ;
reg [17:0] Y_B_stage1 ;

reg [17:0] Cb_R_stage1 ;
reg [17:0] Cb_G_stage1 ;
reg [17:0] Cb_B_stage1 ;

reg [17:0] Cr_R_stage1 ;
reg [17:0] Cr_G_stage1 ;
reg [17:0] Cr_B_stage1 ;


//第一级： 系数相乘

always @(posedge clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            Y_R_stage1 <= 18'd0;
            Y_G_stage1 <= 18'd0;
            Y_B_stage1 <= 18'd0;
            Cb_R_stage1 <= 18'd0;
            Cb_G_stage1 <= 18'd0;
            Cb_B_stage1 <= 18'd0;
            Cr_R_stage1 <= 18'd0;
            Cr_G_stage1 <= 18'd0;
            Cr_B_stage1 <= 18'd0;
        end
        else
            begin
         Y_R_stage1 <=  i_r_8b * Y_R_stone;
         Y_G_stage1 <=  i_g_8b * Y_G_stone;
         Y_B_stage1 <=  i_b_8b * Y_B_stone;

         Cb_R_stage1 <=  i_r_8b * Cb_R_stone;
         Cb_G_stage1 <=  i_g_8b * Cb_G_stone;
         Cb_B_stage1 <=  i_b_8b * Cb_B_stone;

         Cr_R_stage1 <=  i_r_8b * Cr_R_stone;
         Cr_G_stage1 <=  i_g_8b * Cr_G_stone;
         Cr_B_stage1 <=  i_b_8b * Cr_B_stone;
            end  
end



//第二级： 两两相加 正数正数相加，负数负数相加

reg [17:0] Y_stage2_and1 ;
reg [17:0] Y_stage2_and2 ;

reg [17:0] Cb_stage2_and1 ;
reg [17:0] Cb_stage2_and2 ;

reg [17:0] Cr_stage2_and1 ;
reg [17:0] Cr_stage2_and2 ;


always @(posedge clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            Y_stage2_and1 <= 18'd0;
            Y_stage2_and2 <= 18'd0;
            Cb_stage2_and1 <= 18'd0;
            Cb_stage2_and2 <= 18'd0;
            Cr_stage2_and1 <= 18'd0;
            Cr_stage2_and2 <= 18'd0;
        end
        else
            begin
         Y_stage2_and1 <= Y_R_stage1 + Y_G_stage1  ;
         Y_stage2_and2 <= Y_B_stage1 + Y_shift  ;

        Cb_stage2_and1 <=  Cb_R_stage1 + Cb_G_stage1 ;
        Cb_stage2_and2 <=  Cb_B_stage1 + Cb_shift ;

        Cr_stage2_and1 <=  Cr_G_stage1 + Cr_B_stage1 ;
        Cr_stage2_and2 <=  Cr_R_stage1 + Cr_shift;
            end  
end



// 第三级，正负判断后 得到最终值

reg [17:0] Y_stage3 ;
reg [17:0] Cb_stage3 ;
reg [17:0] Cr_stage3 ;

wire Cb_check;
wire Cr_check;
// 1表示最终结果为负数
assign Cb_check = (Cb_stage2_and1 >= Cb_stage2_and2)? 1:0;
assign Cr_check = (Cr_stage2_and1 >= Cr_stage2_and2)? 1:0;

always @(posedge clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            Y_stage3 <= 18'd0;
            Cb_stage3 <= 18'd0;
            Cr_stage3 <= 18'd0;
        end
        else
            begin
        Y_stage3 <= Y_stage2_and1 + Y_stage2_and2;
        Cb_stage3<= Cb_check ? 18'd0 : (Cb_stage2_and2 - Cb_stage2_and1);
        Cr_stage3<= Cr_check ? 18'd0 : (Cr_stage2_and2 - Cr_stage2_and1);
            end  
end


//第四级   截断+四舍五入
reg [9:0] Y_stage4 ;
reg [9:0] Cb_stage4 ;
reg [9:0] Cr_stage4 ;


always @(posedge clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            Y_stage4 <= 10'd0;
            Cb_stage4 <= 10'd0;
            Cr_stage4 <= 10'd0;
        end
        else
            begin
        Y_stage4<= Y_stage3[17:8] + { 9'd0,Y_stage3[7] };
        Cb_stage4<=Cb_stage3[17:8] + {9'd0,Cb_stage3[7]};
        Cr_stage4<=Cr_stage3[17:8] + {9'd0,Cr_stage3[7]};
            end  
end



//最后一级 组合逻辑，用于饱和保护


assign o_y_8b  = (Y_stage4[9:8]!=2'b0)?8'hff:Y_stage4[7:0];
assign o_cb_8b = (Cb_stage4[9:8]!=2'b0)?8'hff:Cb_stage4[7:0];
assign o_cr_8b = (Cr_stage4[9:8]!=2'b0)?8'hff:Cr_stage4[7:0];



//功能信号 打四拍
reg        i_h_sync_delay_1, i_v_sync_delay_1, i_data_en_delay_1;
reg        i_h_sync_delay_2, i_v_sync_delay_2, i_data_en_delay_2;
reg        i_h_sync_delay_3, i_v_sync_delay_3, i_data_en_delay_3;
reg        i_h_sync_delay_4, i_v_sync_delay_4, i_data_en_delay_4;

always @(posedge clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
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