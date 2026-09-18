//========================================================================
// tb_demosaic.v —— 去马赛克自检 TB（Demosaic 工程，W3）
//
// 验证什么：
//   1. 真图帧：喂 bayer.hex（112×103 的 RGGB 原始数据），把每个输出像素
//      和 TB 里自己算的"参考值"逐位比对（0 误差才算过）
//   2. 纯色帧：喂一张全 0x80 的图 —— 平坦区域去马赛克后应该还是 0x80
//      （邻居都相同，平均还是它自己）—— 这是最简单的"解析解"检查
//   3. 计数：两帧各应输出 108×99 = 10692 个像素
//   4. 顺带写 output.coe，给 verify_demosaic.py 和 Python 参考做二次比对
//
// 参考模型怎么算（和 RTL 用同一套公式，但写法独立，相当于"另一个人再算一遍"）：
//   输出第 k 个像素对应窗口中心在原图的 (R, C)（R,C 从 2 开始）
//   取中心周围 3×3（双线性只需 3×3）的 Bayer 值，按 (R,C) 奇偶选公式
//========================================================================
`timescale 1ns/1ps
`include "line_buffer_nxn.v"
`include "demosaic_bilinear.v"
`include "demosaic_mhc.v"
`include "top_demosaic.v"

module tb_demosaic;

    localparam IMG_W = 112;
    localparam IMG_H = 103;
    localparam IN_TOTAL = IMG_W * IMG_H;      // 11536
    localparam OW = IMG_W - 4;                // 108
    localparam OH = IMG_H - 4;                // 99
    localparam WIN_PER_FRAME = OW * OH;       // 10692
    localparam EXP_CNT = WIN_PER_FRAME * 2;   // 两帧（真图 + 纯色）

    // 相位延迟级数：用编译宏扫（找与窗口对齐的值）
`ifdef PH3
    localparam PH_D = 3;
`elsif PH4
    localparam PH_D = 4;
`elsif PH6
    localparam PH_D = 6;
`elsif PH7
    localparam PH_D = 7;
`else
    localparam PH_D = 5;
`endif

    // 算法选择：-DMHC 用 MHC 版（带细节校正），否则双线性
`ifdef MHC
    localparam USE_MHC = 1;
    localparam COE_FILE = "output_mhc.coe";
`else
    localparam USE_MHC = 0;
    localparam COE_FILE = "output.coe";
`endif

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg [7:0] din = 8'd0;
    reg din_valid = 1'b0;
    wire [7:0] o_r, o_g, o_b;
    wire o_valid;

    top_demosaic #(
        .IMG_W(IMG_W), .IMG_H(IMG_H), .AW($clog2(IMG_W)+1), .RW($clog2(IMG_H)+1),
        .PH_D(PH_D), .MHC(USE_MHC)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .din(din), .din_valid(din_valid),
        .o_r(o_r), .o_g(o_g), .o_b(o_b), .o_valid(o_valid)
    );

    always #5 clk = ~clk;

    //---- 输入数据：帧0 = 真图（bayer.hex），帧1 = 纯色 0x80 ----
    reg [7:0] img  [0:IN_TOTAL-1];
    integer si;
    initial begin
        $readmemh("bayer.hex", img);
    end

    function [7:0] frame_pix;                 // 按帧取输入值
        input integer fr;
        input integer idx;
        begin
            frame_pix = (fr == 0) ? img[idx] : 8'h80;
        end
    endfunction

    //---- TB 参考模型：按中心相位把 RGB 算出来（与 RTL 同一套公式）----
    //   输入 fr / 中心坐标 (R,C)；输出 24bit {R,G,B}
    function [23:0] ref_demosaic;
        input integer fr;
        input integer R, C;
        integer g1, g2, g3, g4;    // 十字 4 个（上下左右）
        integer d1, d2, d3, d4;    // 对角 4 个
        reg [7:0] rr, gg, bb;      // 先各自截成 8bit 再拼接
        begin
            g1 = frame_pix(fr, (R-1)*IMG_W + C);
            g2 = frame_pix(fr, (R+1)*IMG_W + C);
            g3 = frame_pix(fr, R*IMG_W + (C-1));
            g4 = frame_pix(fr, R*IMG_W + (C+1));
            d1 = frame_pix(fr, (R-1)*IMG_W + (C-1));
            d2 = frame_pix(fr, (R-1)*IMG_W + (C+1));
            d3 = frame_pix(fr, (R+1)*IMG_W + (C-1));
            d4 = frame_pix(fr, (R+1)*IMG_W + (C+1));
            // 注意：integer 表达式在拼接里是 32bit，必须先截成 8bit，
            //       否则 {a,b,c} 变成 72bit 赋给 24bit 只剩低 24 位（本 TB 踩过的坑）
            if (R % 2 == 0 && C % 2 == 0) begin          // 中心 R
                rr = frame_pix(fr, R*IMG_W + C);         // 直通
                gg = (g1+g2+g3+g4) >> 2;                 // 十字 4 个 G 平均
                bb = (d1+d2+d3+d4) >> 2;                 // 对角 4 个 B 平均
            end else if (R % 2 == 1 && C % 2 == 1) begin // 中心 B
                bb = frame_pix(fr, R*IMG_W + C);
                gg = (g1+g2+g3+g4) >> 2;
                rr = (d1+d2+d3+d4) >> 2;
            end else if (R % 2 == 0 && C % 2 == 1) begin // 中心 Gr（左右 R、上下 B）
                gg = frame_pix(fr, R*IMG_W + C);
                rr = (g3+g4) >> 1;
                bb = (g1+g2) >> 1;
            end else begin                               // 中心 Gb（左右 B、上下 R）
                gg = frame_pix(fr, R*IMG_W + C);
                bb = (g3+g4) >> 1;
                rr = (g1+g2) >> 1;
            end
            ref_demosaic = {rr, gg, bb};
        end
    endfunction

    //---- TB 参考模型（MHC 版）：带细节校正——均值 + (中心 − 远端) 的高通项 ----
    //   先写个小函数：out = sat( (pos_a+pos_b−neg) >> sh )，负数钐0、超255钐255
    function [7:0] mhc8v;
        input [12:0] pos_a, pos_b, neg;
        input [3:0]  sh;
        reg   [12:0] diff;
        begin
            diff = pos_a + pos_b;
            if (diff > neg) begin
                diff = (diff - neg) >> sh;
                mhc8v = (diff > 13'd255) ? 8'd255 : diff[7:0];
            end else mhc8v = 8'd0;
        end
    endfunction

    //   窗口 25 点：取中心 (R,C) 周围 5×5（越界不会发生，因为输出只在内部）
    function [23:0] ref_mhc;
        input integer fr;
        input integer R, C;
        reg [7:0] w00,w01,w02,w03,w04, w10,w11,w12,w13,w14;
        reg [7:0] w20,w21,w22,w23,w24, w30,w31,w32,w33,w34, w40,w41,w42,w43,w44;
        reg [12:0] cross4, diag4, far4, side2, updn2, side2f, updn2f;
        reg [7:0] rr, gg, bb;
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

            cross4 = w12 + w32 + w21 + w23;    // 十字 4 个
            diag4  = w11 + w13 + w31 + w33;    // 对角 4 个
            side2  = w21 + w23;                // 左右
            updn2  = w12 + w32;                // 上下
            side2f = w20 + w24;                // 左右远端
            updn2f = w02 + w42;                // 上下远端
            far4   = side2f + updn2f;          // 远端十字 4 个

            if (R % 2 == 0 && C % 2 == 0) begin          // 中心 R
                rr = w22;
                gg = mhc8v({w22, 2'b00}, {1'b0, cross4, 1'b0}, far4, 4'd3);
                bb = mhc8v({w22, 2'b00}, {1'b0, diag4,  1'b0}, far4, 4'd3);
            end else if (R % 2 == 1 && C % 2 == 1) begin // 中心 B
                bb = w22;
                gg = mhc8v({w22, 2'b00}, {1'b0, cross4, 1'b0}, far4, 4'd3);
                rr = mhc8v({w22, 2'b00}, {1'b0, diag4,  1'b0}, far4, 4'd3);
            end else if (R % 2 == 0 && C % 2 == 1) begin // 中心 Gr
                gg = w22;
                rr = mhc8v({w22, 1'b0}, {1'b0, side2, 1'b0}, side2f, 4'd2);
                bb = mhc8v({w22, 1'b0}, {1'b0, updn2, 1'b0}, updn2f, 4'd2);
            end else begin                               // 中心 Gb
                gg = w22;
                bb = mhc8v({w22, 1'b0}, {1'b0, side2, 1'b0}, side2f, 4'd2);
                rr = mhc8v({w22, 1'b0}, {1'b0, updn2, 1'b0}, updn2f, 4'd2);
            end
            ref_mhc = {rr, gg, bb};
        end
    endfunction

    //---- 记分板 ----
    integer out_cnt = 0, err_cnt = 0;
    integer k, fr, R, C;
    reg [23:0] exp_pix;

    always @(posedge clk) begin
        #1;
        if (o_valid) begin
            if (out_cnt < EXP_CNT) begin
                k  = out_cnt % WIN_PER_FRAME;
                fr = out_cnt / WIN_PER_FRAME;
                R = k / OW + 2;                // 窗口中心在原图的坐标
                C = k % OW + 2;
                exp_pix = USE_MHC ? ref_mhc(fr, R, C) : ref_demosaic(fr, R, C);
                if ({o_r, o_g, o_b} !== exp_pix) begin
                    err_cnt = err_cnt + 1;
                    if (err_cnt <= 10)
                        $display("MISMATCH @%0t f%0d win#%0d 中心(%0d,%0d): got %02X%02X%02X expect %02X%02X%02X",
                                 $time, fr, out_cnt, R, C, o_r, o_g, o_b,
                                 exp_pix[23:16], exp_pix[15:8], exp_pix[7:0]);
                end
                // 纯色帧：三通道都应等于 0x80（平坦区解析解）
                if (fr == 1 && !(o_r == 8'h80 && o_g == 8'h80 && o_b == 8'h80)) begin
                    err_cnt = err_cnt + 1;
                    if (err_cnt <= 10)
                        $display("SOLID FAIL @%0t win#%0d: %02X%02X%02X (期望 808080)",
                                 $time, out_cnt, o_r, o_g, o_b);
                end
            end else begin
                err_cnt = err_cnt + 1;
                $display("FALSE o_valid @%0t", $time);
            end
            out_cnt = out_cnt + 1;
        end
    end

    //---- 输出 COE（只写第一帧，供 verify_demosaic.py 比对）----
    integer fd, w_cnt = 0;
    initial begin
        fd = $fopen(COE_FILE, "w");
        $fwrite(fd, "memory_initialization_radix=16;\nmemory_initialization_vector=\n");
    end
    always @(posedge clk) begin
        #1;
        if (o_valid && w_cnt < WIN_PER_FRAME) begin
            $fwrite(fd, "%02X%02X%02X,\n", o_r, o_g, o_b);
            w_cnt <= w_cnt + 1;
        end
    end

    //---- 激励：两帧（真图 → 纯色），带随机气泡 ----
    integer frame_i, r, c;
    initial begin
        $dumpfile("tb_demosaic.vcd");
        $dumpvars(0, tb_demosaic);

        #25 rst_n = 1;
        @(negedge clk);

        for (frame_i = 0; frame_i < 2; frame_i = frame_i + 1) begin
            for (r = 0; r < IMG_H; r = r + 1) begin
                for (c = 0; c < IMG_W; c = c + 1) begin
                    if ({$random} % 7 == 0) begin       // 随机气泡（验证有空洞也不错位）
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
        $display("输出像素: %0d / 期望 %0d（两帧）", out_cnt, EXP_CNT);
        if (err_cnt == 0 && out_cnt == EXP_CNT)
            $display("[PASS] demosaic OK: 真图+纯色两帧共 %0d 像素全对（0 误差）", EXP_CNT);
        else
            $display("[FAIL] err=%0d out=%0d/%0d", err_cnt, out_cnt, EXP_CNT);
        $fclose(fd);
        $finish;
    end

    //---- 超时兜底 ----
    initial begin
        #(IN_TOTAL * 80 + 1000000);
        $display("[FAIL] simulation timeout out=%0d err=%0d", out_cnt, err_cnt);
        $finish;
    end

endmodule