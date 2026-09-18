//========================================================================
// tb_blc_img.v —— BLC 图像实验 TB（真实图链路：blc_in.hex → RTL → output.coe）
//
// 与 tb_blc_top.v（协议/场景 TB）分工：这里只做"真实图过一遍数据通路"——
//   连续流、无反压，输入 $readmemh 读 make_blc_data.py 生成的 blc_in.hex
//   （带每通道黑电平的 RAW10 Bayer 帧），输出写 output.coe（每像素 3 位 hex）。
// 位级校验 / PSNR / 对比图全部在 verify_blc_img.py（独立第二判据）。
//========================================================================
`timescale 1ns/1ps
`include "blc_top.v"

module tb_blc_img;

    localparam DW    = 10;
    localparam IMG_W = 112;
    localparam IMG_H = 103;
    localparam TOTAL = IMG_W * IMG_H;

    reg aclk = 0, aresetn = 0;
    always #5 aclk = ~aclk;

    reg [DW-1:0] img [0:TOTAL-1];
    integer fd, i;

    reg [11:0] s_pix;
    reg        s_vld, s_lst, s_usr;
    wire       out_valid, out_sof, out_eol;
    wire [1:0] out_phase;
    wire [DW-1:0] out_data;
    reg        out_ready = 1'b1;

    blc_top #(.DW(DW), .ENTRY_FIFO_EN(0)) dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata({2'b00, s_pix}), .s_axis_tvalid(s_vld), .s_axis_tready(s_rdy),
        .s_axis_tlast(s_lst), .s_axis_tuser(s_usr),
        .ob_00(10'd100), .ob_01(10'd64), .ob_10(10'd180), .ob_11(10'd32),   // = make_blc_data.py 的真实 OB
        .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data),
        .out_sof(out_sof), .out_eol(out_eol), .out_phase(out_phase)
    );

    initial begin
        $readmemh("blc_in.hex", img);
        fd = $fopen("output.coe", "w");
    end

    // 连续流发送（帧首 sof / 每行末 eol）
    integer idx = 0;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            s_vld <= 1'b0; idx = 0;
        end
        else if (idx < TOTAL) begin
            s_pix <= {2'b00, img[idx]};
            s_usr <= (idx == 0);
            s_lst <= ((idx % IMG_W) == IMG_W - 1);
            s_vld <= 1'b1;
            idx   = idx + 1;
        end
        else begin
            s_vld <= 1'b0;
        end
    end

    // 收侧计数 + 落盘
    integer rcv = 0;
    always @(posedge aclk) begin
        #1;
        if (out_valid && out_ready) begin
            $fwrite(fd, "%03X\n", out_data);
            rcv = rcv + 1;
            if (rcv == TOTAL) begin
                $fclose(fd);
                $display("[PASS] tb_blc_img：发送 %0d 像素，接收 %0d 像素，已写 output.coe", TOTAL, rcv);
                $finish;
            end
        end
    end

    initial begin
        $dumpfile("tb_blc_img.vcd");
        $dumpvars(0, tb_blc_img);
        aresetn = 0;
        repeat (10) @(posedge aclk);
        aresetn = 1;
    end

    // 超时兜底
    initial begin
        #5_000_000;
        $display("[FAIL] tb_blc_img timeout rcv=%0d/%0d", rcv, TOTAL);
        $finish;
    end

endmodule
