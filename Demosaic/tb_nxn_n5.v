//========================================================================
// tb_nxn_n5.v —— line_buffer_nxn 的 N=5 回归 + 窗口延迟 L 测量（Demosaic 工程）
//
// 为什么单独做这个 TB：
//   模板自带 TB 只验过 N=3/N=4；去马赛克要用 N=5（5×5 窗口），必须先确认
//   模板在 N=5 下窗口内容正确，否则上层算法调试会被误导。
//
// 做法：喂"递增序列"（第 k 个像素的值 = k），让窗口内容有可预测的规律：
//   窗口右下角 = 当前像素值 v；位置 (i,j)（i=0 最上行）的值 = v - (4-i)*IMG_W - (4-j)
//   从第 5 行第 5 列起 25 个位置都有效，严格逐点比对。
// 顺带测出"窗口延迟 L"（din_valid 到 matrix_valid 的拍数），供顶层相位打拍用。
//========================================================================
`timescale 1ns/1ps
`include "line_buffer_nxn.v"

module tb_nxn_n5;

    localparam DW  = 8;
    localparam IMG_W = 16;      // 小图即可（窗口规律与尺寸无关）
    localparam IMG_H = 8;
    localparam N   = 5;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg [DW-1:0] din = 8'd0;
    reg din_valid = 1'b0;

    wire             matrix_valid;
    wire [N*N*DW-1:0] win_flat;

    line_buffer_nxn #(
        .DW(DW), .IMG_W(IMG_W), .IMG_H(IMG_H), .N(N)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .din_valid(din_valid), .din(din),
        .matrix_valid(matrix_valid), .win_flat(win_flat)
    );

    always #5 clk = ~clk;

    //---- 窗口切片（实测语义修正）：W[i][j] = win_flat[(i*N + j)*DW +: DW]
//   i=0 最上行、j=0 最左列；行列号越大越“新”，win_flat[24] = 右下角 = 当前像素
//   注意：line_buffer_nxn 源码注释写“行0列0=左下角”，本 TB 用递增序列实测证明
//   实际是“行0列0=左上角”——源码注释有误，此处以实测为准
//----
    function [DW-1:0] W;
        input integer i, j;
        begin
            W = win_flat[(i*N + j)*DW +: DW];
        end
    endfunction

    //---- 记分板 ----
    integer in_cnt = 0;          // 已喂有效像素数
    integer out_cnt = 0, err_cnt = 0;
    integer L_meas = -1;         // 测出的窗口延迟
    integer r, c;
    integer exp_val;

    always @(posedge clk) begin
        #1;
        if (matrix_valid) begin
            out_cnt = out_cnt + 1;
            // 首次有效：测延迟 L —— 右下角值 = 该窗口对应像素序号
            if (L_meas < 0)
                L_meas = (in_cnt - 1) - W(4, 4);
            // 从"第 5 行第 5 列"起窗口 25 点应全部有效，逐点严格比对
            if ((out_cnt % (IMG_W - N + 1)) >= 1 || out_cnt > (IMG_W - N + 1) * (N - 1)) begin
                for (r = 0; r < N; r = r + 1) begin
                    for (c = 0; c < N; c = c + 1) begin
                        exp_val = W(4, 4) - (4 - r) * IMG_W - (4 - c);
                        if (exp_val >= 0 && W(r, c) !== exp_val[DW-1:0]) begin
                            err_cnt = err_cnt + 1;
                            if (err_cnt <= 5)
                                $display("MISMATCH @%0t out#%0d W[%0d][%0d]=%0d expect %0d (右下角=%0d)",
                                         $time, out_cnt, r, c, W(r, c), exp_val, W(4, 4));
                        end
                    end
                end
            end
        end
    end

    //---- 激励：连续喂递增序列（第 k 个像素值 = k）----
    integer k;
    initial begin
        $dumpfile("tb_nxn_n5.vcd");
        $dumpvars(0, tb_nxn_n5);

        #25 rst_n = 1;
        @(negedge clk);

        for (k = 0; k < IMG_W * IMG_H; k = k + 1) begin
            din       = k[DW-1:0];
            din_valid = 1'b1;
            in_cnt    = k + 1;
            @(negedge clk);
        end
        din_valid = 1'b0;
        repeat (20) @(negedge clk);

        // 期望窗口数 = (IMG_H-N+1)*(IMG_W-N+1)
        $display("========================================");
        $display("N=5 回归: 输出窗口=%0d 期望=%0d，测得窗口延迟 L=%0d 拍",
                 out_cnt, (IMG_H-N+1)*(IMG_W-N+1), L_meas);
        if (err_cnt == 0 && out_cnt == (IMG_H-N+1)*(IMG_W-N+1))
            $display("[PASS] line_buffer_nxn N=5 窗口内容全对（L=%0d）", L_meas);
        else
            $display("[FAIL] err=%0d 窗口=%0d/%0d", err_cnt, out_cnt, (IMG_H-N+1)*(IMG_W-N+1));
        $finish;
    end

    //---- 超时兜底 ----
    initial begin
        #(IMG_W * IMG_H * 30 + 100000);
        $display("[FAIL] simulation timeout 窗口=%0d err=%0d", out_cnt, err_cnt);
        $finish;
    end

endmodule