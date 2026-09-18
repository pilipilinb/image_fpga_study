//========================================================================
// tb_dpc.v —— 坏点校正自检 TB（DPC 工程）
//
// 跑三帧，逐像素和"TB 自己算的参考值"比对（0 误差才算过）：
//   帧0：带坏点的 Bayer（bayer_defect.hex）→ 输出写 output.coe（给 Python 比对）
//   帧1：干净的 Bayer（bayer.hex）        → 输出写 output_clean.coe（量误伤率用）
//   帧2：纯色 0x80                        → 应该原样通过（邻居全相同，谈不上坏点）
//
// 参考模型（与 RTL 同公式，但写法独立）：
//   按中心 (R,C) 的奇偶决定"同色"条件 → 在 5×5 里挑同色邻居取 min/max →
//   P > mx+thr 抄 mx；P+thr < mn 抄 mn；否则原样
//========================================================================
`timescale 1ns/1ps
`include "line_buffer_nxn.v"
`include "dpc_envelope.v"
`include "top_dpc.v"

module tb_dpc;

    localparam IMG_W = 112;
    localparam IMG_H = 103;
    localparam IN_TOTAL = IMG_W * IMG_H;
    localparam OW = IMG_W - 4;                // 108
    localparam OH = IMG_H - 4;                // 99
    localparam WIN_PER_FRAME = OW * OH;       // 10692
    localparam FRAMES = 3;
    localparam EXP_CNT = WIN_PER_FRAME * FRAMES;
    localparam THR = 32;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg [7:0] din = 8'd0;
    reg din_valid = 1'b0;
    wire [7:0] o_dout;
    wire o_valid;

    top_dpc #(
        .IMG_W(IMG_W), .IMG_H(IMG_H), .AW($clog2(IMG_W)+1), .RW($clog2(IMG_H)+1),
        .PH_D(5), .THR(THR)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .din(din), .din_valid(din_valid),
        .o_dout(o_dout), .o_valid(o_valid)
    );

    always #5 clk = ~clk;

    //---- 输入数据：帧0=带坏点，帧1=干净，帧2=纯色 ----
    reg [7:0] img_defect [0:IN_TOTAL-1];
    reg [7:0] img_clean  [0:IN_TOTAL-1];
    initial begin
        $readmemh("bayer_defect.hex", img_defect);
        $readmemh("bayer.hex", img_clean);
    end

    function [7:0] frame_pix;
        input integer fr;
        input integer idx;
        begin
            if      (fr == 0) frame_pix = img_defect[idx];
            else if (fr == 1) frame_pix = img_clean[idx];
            else              frame_pix = 8'h80;
        end
    endfunction

    //---- TB 参考模型（包络检测，按相位挑同色邻居）----
    function [7:0] ref_dpc;
        input integer fr;
        input integer R, C;
        reg [7:0] w00,w01,w02,w03,w04, w10,w11,w12,w13,w14;
        reg [7:0] w20,w21,w22,w23,w24, w30,w31,w32,w33,w34, w40,w41,w42,w43,w44;
        reg [7:0] mn, mx, v;
        integer i, j;
        begin
            w00 = frame_pix(fr, (R-2)*IMG_W + (C-2)); w01 = frame_pix(fr, (R-2)*IMG_W + (C-1));
            w02 = frame_pix(fr, (R-2)*IMG_W +  C   ); w03 = frame_pix(fr, (R-2)*IMG_W + (C+1));
            w04 = frame_pix(fr, (R-2)*IMG_W + (C+2));
            w10 = frame_pix(fr, (R-1)*IMG_W + (C-2)); w11 = frame_pix(fr, (R-1)*IMG_W + (C-1));
            w12 = frame_pix(fr, (R-1)*IMG_W +  C   ); w13 = frame_pix(fr, (R-1)*IMG_W + (C+1));
            w14 = frame_pix(fr, (R-1)*IMG_W + (C+2));
            w20 = frame_pix(fr,  R   *IMG_W + (C-2)); w21 = frame_pix(fr,  R   *IMG_W + (C-1));
            w22 = frame_pix(fr,  R   *IMG_W +  C   ); w23 = frame_pix(fr,  R   *IMG_W + (C+1));
            w24 = frame_pix(fr,  R   *IMG_W + (C+2));
            w30 = frame_pix(fr, (R+1)*IMG_W + (C-2)); w31 = frame_pix(fr, (R+1)*IMG_W + (C-1));
            w32 = frame_pix(fr, (R+1)*IMG_W +  C   ); w33 = frame_pix(fr, (R+1)*IMG_W + (C+1));
            w34 = frame_pix(fr, (R+1)*IMG_W + (C+2));
            w40 = frame_pix(fr, (R+2)*IMG_W + (C-2)); w41 = frame_pix(fr, (R+2)*IMG_W + (C-1));
            w42 = frame_pix(fr, (R+2)*IMG_W +  C   ); w43 = frame_pix(fr, (R+2)*IMG_W + (C+1));
            w44 = frame_pix(fr, (R+2)*IMG_W + (C+2));

            mn = 8'hFF; mx = 8'h00;
            // 逐点判断"这个邻居和中心同色吗"（用绝对坐标奇偶；G 相位 Gr/Gb 都算绿）
            for (i = 0; i < 5; i = i + 1) begin
                for (j = 0; j < 5; j = j + 1) begin
                    if (!(i == 2 && j == 2)) begin
                        if ((i == 0 || i == 4) || (j == 0 || j == 4) || 1) begin
                            // 取该点在窗口里的值
                            case (i*5 + j)
                                0: v = w00;  1: v = w01;  2: v = w02;  3: v = w03;  4: v = w04;
                                5: v = w10;  6: v = w11;  7: v = w12;  8: v = w13;  9: v = w14;
                                10: v = w20; 11: v = w21; 12: v = w22; 13: v = w23; 14: v = w24;
                                15: v = w30; 16: v = w31; 17: v = w32; 18: v = w33; 19: v = w34;
                                20: v = w40; 21: v = w41; 22: v = w42; 23: v = w43;
                                default: v = w44;
                            endcase
                            // 同色判定：绝对相位 = 中心相位 XOR 相对位置奇偶 →
                            //   R/B 相位（绝对同奇偶）→ i,j 都偶
                            //   G 相位（绝对异奇偶）  → i,j 同奇偶（都偶 + 都奇）
                            if ((R % 2 == 0 && C % 2 == 0) || (R % 2 == 1 && C % 2 == 1)) begin
                                if ((i % 2 == 0) && (j % 2 == 0)) begin
                                    if (v < mn) mn = v;
                                    if (v > mx) mx = v;
                                end
                            end else begin      // G 相位（Gr/Gb 合并）
                                if ((i % 2) == (j % 2)) begin
                                    if (v < mn) mn = v;
                                    if (v > mx) mx = v;
                                end
                            end
                        end
                    end
                end
            end
            // 判定替换（与核同规则；用加法避开负数）
            if (w22 > mx + THR)        ref_dpc = mx;
            else if (w22 + THR < mn)   ref_dpc = mn;
            else                       ref_dpc = w22;
        end
    endfunction

    //---- 记分板 ----
    integer out_cnt = 0, err_cnt = 0;
    integer k, fr, R, C;
    reg [7:0] exp_pix;

    always @(posedge clk) begin
        #1;
        if (o_valid) begin
            if (out_cnt < EXP_CNT) begin
                k  = out_cnt % WIN_PER_FRAME;
                fr = out_cnt / WIN_PER_FRAME;
                R = k / OW + 2;
                C = k % OW + 2;
                exp_pix = ref_dpc(fr, R, C);
                if (o_dout !== exp_pix) begin
                    err_cnt = err_cnt + 1;
                    if (err_cnt <= 10)
                        $display("MISMATCH @%0t f%0d win#%0d 中心(%0d,%0d): got %02X expect %02X",
                                 $time, fr, out_cnt, R, C, o_dout, exp_pix);
                end
            end else begin
                err_cnt = err_cnt + 1;
                $display("FALSE o_valid @%0t", $time);
            end
            out_cnt = out_cnt + 1;
        end
    end

    //---- 输出 COE：帧0 → output.coe，帧1 → output_clean.coe（独立计数）----
    integer fd0, fd1, w0 = 0, w1 = 0;
    initial begin
        fd0 = $fopen("output.coe", "w");
        fd1 = $fopen("output_clean.coe", "w");
        $fwrite(fd0, "memory_initialization_radix=16;\nmemory_initialization_vector=\n");
        $fwrite(fd1, "memory_initialization_radix=16;\nmemory_initialization_vector=\n");
    end
    always @(posedge clk) begin
        #1;
        if (o_valid && w0 < WIN_PER_FRAME) begin
            $fwrite(fd0, "%02X,\n", o_dout);
            w0 <= w0 + 1;
        end
        if (o_valid && out_cnt >= WIN_PER_FRAME && w1 < WIN_PER_FRAME) begin
            $fwrite(fd1, "%02X,\n", o_dout);
            w1 <= w1 + 1;
        end
    end

    //---- 激励：三帧连续喂，带随机气泡 ----
    integer frame_i, r, c;
    initial begin
        $dumpfile("tb_dpc.vcd");
        $dumpvars(0, tb_dpc);

        #25 rst_n = 1;
        @(negedge clk);

        for (frame_i = 0; frame_i < FRAMES; frame_i = frame_i + 1) begin
            for (r = 0; r < IMG_H; r = r + 1) begin
                for (c = 0; c < IMG_W; c = c + 1) begin
                    if ({$random} % 7 == 0) begin
                        din_valid = 1'b0;
                        @(negedge clk);
                    end
                    din       = frame_pix(frame_i, r * IMG_W + c);
                    din_valid = 1'b1;
                    @(negedge clk);
                end
                din_valid = 1'b0;
                repeat (1 + {$random} % 3) @(negedge clk);
            end
        end
        din_valid = 1'b0;
        while (out_cnt < EXP_CNT) @(negedge clk);
        #40;

        $display("========================================");
        $display("输出像素: %0d / 期望 %0d（三帧）", out_cnt, EXP_CNT);
        if (err_cnt == 0 && out_cnt == EXP_CNT)
            $display("[PASS] DPC OK: 坏点图+干净图+纯色 三帧共 %0d 像素全对（0 误差）", EXP_CNT);
        else
            $display("[FAIL] err=%0d out=%0d/%0d", err_cnt, out_cnt, EXP_CNT);
        $fclose(fd0); $fclose(fd1);
        $finish;
    end

    //---- 超时兜底 ----
    initial begin
        #(IN_TOTAL * 80 * FRAMES + 1000000);
        $display("[FAIL] simulation timeout out=%0d err=%0d", out_cnt, err_cnt);
        $finish;
    end

endmodule