//========================================================================
// tb_median_filter.v —— 3×3 中值滤波自检 TB（MedianFilter 工程）
// 验证内容：
//   1. 全帧逐窗口比对：参考模型 = 计数法（统计每个候选的 ≤ 个数，取第 5 小）
//      ——与 RTL 的排序网络完全不同源的独立实现（中值为精确运算，全等即正确）
//   2. 中值不变性：第二帧喂全 0x808080 纯色图，输出必须恒 0x80
//   3. 窗口数核对：两帧各 (IMG_H-2)×(IMG_W-2)；行内随机气泡验证鲁棒
// 激励规范（守工程实践）：negedge 置位、先设置后等待、超时兜底、VCD
// 配置：-DSMALL 4×3 小图；-DNOISE 高斯噪声图；-DSALT 椒盐噪声图
//       第一帧结果写 output.coe（供去噪对比）
//========================================================================
`timescale 1ns/1ps
`include "top_median_filter.v"

module tb_median_filter;

`ifdef SMALL
    localparam IMG_W = 4;
    localparam IMG_H = 3;
`else
    localparam IMG_W = 112;
    localparam IMG_H = 103;
`endif
    localparam IN_TOTAL = IMG_W * IMG_H;
    localparam WIN_PER_FRAME = (IMG_H - 2) * (IMG_W - 2);
    localparam EXP_CNT  = WIN_PER_FRAME * 2;      // 两帧（真实/纯色）
`ifdef SMALL
    localparam INIT_FILE = "input_4x3.hex";
`elsif NOISE
    localparam INIT_FILE = "noise.hex";
`elsif SALT
    localparam INIT_FILE = "salt_pepper.hex";
`else
    localparam INIT_FILE = "input.hex";
`endif

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg [23:0] din = 24'd0;
    reg din_valid = 1'b0;
    wire [7:0] o_r, o_g, o_b;
    wire o_valid;

    top_median_filter #(
        .IMG_W(IMG_W), .IMG_H(IMG_H), .AW($clog2(IMG_W)+1)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .din(din), .din_valid(din_valid),
        .o_r(o_r), .o_g(o_g), .o_b(o_b), .o_valid(o_valid)
    );

    always #5 clk = ~clk;

    //---- 输入图像：第一帧从文件读（input/noise/salt），第二帧纯色 0x808080 ----
    reg [23:0] img   [0:IN_TOTAL-1];
    reg [23:0] solid [0:IN_TOTAL-1];
    integer si;
    initial begin
        $readmemh(INIT_FILE, img);
        for (si = 0; si < IN_TOTAL; si = si + 1)
            solid[si] = 24'h808080;
    end

    //---- 参考模型：计数法取第 5 小（独立于排序网络的不同源实现）----
    //   中值 = 最小的 v，满足窗口内 ≤v 的像素数 ≥5（升序第 5 个位置）
    function integer ref_median9;
        input integer d0, d1, d2, d3, d4, d5, d6, d7, d8;
        integer i2, v, leq, best;
        begin
            best = 8'hFF;
            for (i2 = 0; i2 < 9; i2 = i2 + 1) begin
                case (i2)
                    0: v = d0;  1: v = d1;  2: v = d2;
                    3: v = d3;  4: v = d4;  5: v = d5;
                    6: v = d6;  7: v = d7;  8: v = d8;
                    default: v = 0;
                endcase
                leq = 0;
                if (d0 <= v) leq = leq + 1;  if (d1 <= v) leq = leq + 1;
                if (d2 <= v) leq = leq + 1;  if (d3 <= v) leq = leq + 1;
                if (d4 <= v) leq = leq + 1;  if (d5 <= v) leq = leq + 1;
                if (d6 <= v) leq = leq + 1;  if (d7 <= v) leq = leq + 1;
                if (d8 <= v) leq = leq + 1;
                if (leq >= 5 && v < best) best = v;
            end
            ref_median9 = best;
        end
    endfunction

    function integer pix_ch;
        input integer px;
        input integer chan;
        begin
            if (chan == 0)      pix_ch = (px >> 16) & 8'hFF;
            else if (chan == 1) pix_ch = (px >>  8) & 8'hFF;
            else                pix_ch = px        & 8'hFF;
        end
    endfunction

    //---- 按帧取像素：帧0=img（真实/噪声图），帧1=solid（纯色）----
    function integer frame_pix;
        input integer fr;
        input integer rr, cc;
        begin
            if (fr == 0) frame_pix = img[rr*IMG_W + cc];
            else         frame_pix = solid[rr*IMG_W + cc];
        end
    endfunction

    //---- 记分板 ----
    integer out_cnt = 0, err_cnt = 0;
    integer k, wr, wc, frame;

    always @(posedge clk) begin
        #1;
        if (o_valid) begin
            if (out_cnt < EXP_CNT) begin
                k     = out_cnt % WIN_PER_FRAME;
                frame = out_cnt / WIN_PER_FRAME;
                wr = k / (IMG_W - 2) + 2;
                wc = k % (IMG_W - 2) + 2;
                // R 通道：9 个窗口像素 → 计数法参考
                if (o_r !== ref_median9(
                        pix_ch(frame_pix(frame, wr-2, wc-2), 0), pix_ch(frame_pix(frame, wr-2, wc-1), 0), pix_ch(frame_pix(frame, wr-2, wc), 0),
                        pix_ch(frame_pix(frame, wr-1, wc-2), 0), pix_ch(frame_pix(frame, wr-1, wc-1), 0), pix_ch(frame_pix(frame, wr-1, wc), 0),
                        pix_ch(frame_pix(frame, wr,   wc-2), 0), pix_ch(frame_pix(frame, wr,   wc-1), 0), pix_ch(frame_pix(frame, wr,   wc), 0))) begin
                    err_cnt = err_cnt + 1;
                    if (err_cnt <= 10)
                        $display("R  MISMATCH @%0t f%0d win#%0d(%0d,%0d): got %0d", $time, frame, out_cnt, wr, wc, o_r);
                end
                if (o_g !== ref_median9(
                        pix_ch(frame_pix(frame, wr-2, wc-2), 1), pix_ch(frame_pix(frame, wr-2, wc-1), 1), pix_ch(frame_pix(frame, wr-2, wc), 1),
                        pix_ch(frame_pix(frame, wr-1, wc-2), 1), pix_ch(frame_pix(frame, wr-1, wc-1), 1), pix_ch(frame_pix(frame, wr-1, wc), 1),
                        pix_ch(frame_pix(frame, wr,   wc-2), 1), pix_ch(frame_pix(frame, wr,   wc-1), 1), pix_ch(frame_pix(frame, wr,   wc), 1))) begin
                    err_cnt = err_cnt + 1;
                    if (err_cnt <= 10)
                        $display("G  MISMATCH @%0t f%0d win#%0d(%0d,%0d): got %0d", $time, frame, out_cnt, wr, wc, o_g);
                end
                if (o_b !== ref_median9(
                        pix_ch(frame_pix(frame, wr-2, wc-2), 2), pix_ch(frame_pix(frame, wr-2, wc-1), 2), pix_ch(frame_pix(frame, wr-2, wc), 2),
                        pix_ch(frame_pix(frame, wr-1, wc-2), 2), pix_ch(frame_pix(frame, wr-1, wc-1), 2), pix_ch(frame_pix(frame, wr-1, wc), 2),
                        pix_ch(frame_pix(frame, wr,   wc-2), 2), pix_ch(frame_pix(frame, wr,   wc-1), 2), pix_ch(frame_pix(frame, wr,   wc), 2))) begin
                    err_cnt = err_cnt + 1;
                    if (err_cnt <= 10)
                        $display("B  MISMATCH @%0t f%0d win#%0d(%0d,%0d): got %0d", $time, frame, out_cnt, wr, wc, o_b);
                end
            end else begin
                err_cnt = err_cnt + 1;
                $display("FALSE o_valid @%0t (已超 %0d 窗口)", $time, EXP_CNT);
            end
            out_cnt = out_cnt + 1;
        end
    end

    //---- 输出 COE：仅第一帧（真实/噪声图）写 output.coe，供去噪对比 ----
    integer fd;
    integer w_cnt = 0;
    initial begin
        fd = $fopen("output.coe", "w");
        $fwrite(fd, "memory_initialization_radix=16;\n");
        $fwrite(fd, "memory_initialization_vector=\n");
    end
    always @(posedge clk) begin
        #1;
        if (o_valid && w_cnt < WIN_PER_FRAME) begin
            $fwrite(fd, "%02X%02X%02X,\n", o_r, o_g, o_b);
            w_cnt <= w_cnt + 1;
        end
    end

    //---- 激励：两帧（真实图 → 纯色），每行随机气泡 + 行末延时 ----
    integer frame_i, r, c;
    initial begin
        $dumpfile("tb_median_filter.vcd");
        $dumpvars(0, tb_median_filter);

        #25 rst_n = 1;
        @(negedge clk);

        for (frame_i = 0; frame_i < 2; frame_i = frame_i + 1) begin
            for (r = 0; r < IMG_H; r = r + 1) begin
                for (c = 0; c < IMG_W; c = c + 1) begin
                    if ({$random} % 5 == 0) begin
                        din_valid = 1'b0;
                        @(negedge clk);
                    end
                    din       = (frame_i == 0) ? img[r*IMG_W + c] : solid[r*IMG_W + c];
                    din_valid = 1'b1;
                    @(negedge clk);
                end
                din_valid = 1'b0;
                repeat (1 + {$random} % 3) @(negedge clk);
            end
        end
        din_valid = 1'b0;
        // 等流水排空
        while (out_cnt < EXP_CNT) @(negedge clk);
        #40;

        $display("========================================");
        if (err_cnt == 0 && out_cnt == EXP_CNT)
            $display("[PASS] median_filter OK: %0d 窗口全对（2 帧，INIT=%s）", out_cnt, INIT_FILE);
        else
            $display("[FAIL] errors=%0d out=%0d/%0d INIT=%s", err_cnt, out_cnt, EXP_CNT, INIT_FILE);
        $fclose(fd);
        $finish;
    end

    //---- 超时兜底 ----
    initial begin
        #(IN_TOTAL * 60 + 1000000);
        $display("[FAIL] simulation timeout");
        $finish;
    end

endmodule