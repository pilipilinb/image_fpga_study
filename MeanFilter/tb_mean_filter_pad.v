//========================================================================
// tb_mean_filter_pad.v —— pad 版均值滤波自检 TB（MeanFilter 工程）
// 与 tb_mean_filter.v（crop 版）的差异：
//   1. 激励符合 pad 版时序要求：h-blank ≥1 拍、v-blank ≥ IMG_W+8 拍
//   2. 期望窗口数 = IMG_H×IMG_W（全尺寸，边缘 replicate）
//   3. 参考模型：窗口中心全尺寸光栅序，越界像素按 replicate 钳位
// 验证内容同 crop 版：定点参考全等 + 浮点误差统计 + 气泡/blanking 鲁棒
// 配置：-DNOISE 跑噪声图 noise.hex，默认 input.hex
//========================================================================
`timescale 1ns/1ps
`include "top_mean_filter_pad.v"

module tb_mean_filter_pad;

    localparam IMG_W = 112;
    localparam IMG_H = 103;
    localparam IN_TOTAL = IMG_W * IMG_H;
    localparam EXP_CNT  = IMG_W * IMG_H;      // pad 版全尺寸输出
`ifdef NOISE
    localparam INIT_FILE = "noise.hex";
`else
    localparam INIT_FILE = "input.hex";
`endif

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg [23:0] din = 24'd0;
    reg din_valid = 1'b0;
    wire [7:0] o_r, o_g, o_b;
    wire o_valid;

    top_mean_filter_pad #(
        .IMG_W(IMG_W), .IMG_H(IMG_H), .AW($clog2(IMG_W)+1)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .din(din), .din_valid(din_valid),
        .o_r(o_r), .o_g(o_g), .o_b(o_b), .o_valid(o_valid)
    );

    always #5 clk = ~clk;

    //---- 输入图像 ----
    reg [23:0] img [0:IN_TOTAL-1];
    initial $readmemh(INIT_FILE, img);

    //---- 参考模型：同款定点均值 ----
    function integer ref_mean;
        input integer a, b, c, d, e, f, g, h, i2;
        integer sum, v;
        begin
            sum = a + b + c + d + e + f + g + h + i2;
            v = (sum * 57 + 256) >> 9;
            ref_mean = (v > 255) ? 255 : v;
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

    //---- pad 语义取像素：坐标越界钳位（replicate 复制边缘）----
    function integer get_pix;
        input integer rr, cc;
        input integer chan;
        integer r2, c2;
        begin
            r2 = (rr < 0) ? 0 : (rr > IMG_H-1) ? IMG_H-1 : rr;
            c2 = (cc < 0) ? 0 : (cc > IMG_W-1) ? IMG_W-1 : cc;
            get_pix = pix_ch(img[r2*IMG_W + c2], chan);
        end
    endfunction

    //---- 记分板 ----
    integer out_cnt = 0, err_cnt = 0;
    integer wr, wc;                    // 窗口中心（全尺寸光栅序）
    real    max_err = 0.0;
    real    sum_f;
    integer row, col;

    always @(posedge clk) begin
        #1;
        if (o_valid) begin
            if (out_cnt < EXP_CNT) begin
                wr = out_cnt / IMG_W;
                wc = out_cnt % IMG_W;
                // 窗口 9 像素 = 中心 ±1（越界钳位），对应 p00..p22（顶左..底右）
                if (o_r !== ref_mean(
                        get_pix(wr-1, wc-1, 0), get_pix(wr-1, wc, 0), get_pix(wr-1, wc+1, 0),
                        get_pix(wr,   wc-1, 0), get_pix(wr,   wc, 0), get_pix(wr,   wc+1, 0),
                        get_pix(wr+1, wc-1, 0), get_pix(wr+1, wc, 0), get_pix(wr+1, wc+1, 0))) begin
                    err_cnt = err_cnt + 1;
                    if (err_cnt <= 10)
                        $display("R  MISMATCH @%0t win#%0d(%0d,%0d): got %0d", $time, out_cnt, wr, wc, o_r);
                end
                if (o_g !== ref_mean(
                        get_pix(wr-1, wc-1, 1), get_pix(wr-1, wc, 1), get_pix(wr-1, wc+1, 1),
                        get_pix(wr,   wc-1, 1), get_pix(wr,   wc, 1), get_pix(wr,   wc+1, 1),
                        get_pix(wr+1, wc-1, 1), get_pix(wr+1, wc, 1), get_pix(wr+1, wc+1, 1))) begin
                    err_cnt = err_cnt + 1;
                    if (err_cnt <= 10)
                        $display("G  MISMATCH @%0t win#%0d(%0d,%0d): got %0d", $time, out_cnt, wr, wc, o_g);
                end
                if (o_b !== ref_mean(
                        get_pix(wr-1, wc-1, 2), get_pix(wr-1, wc, 2), get_pix(wr-1, wc+1, 2),
                        get_pix(wr,   wc-1, 2), get_pix(wr,   wc, 2), get_pix(wr,   wc+1, 2),
                        get_pix(wr+1, wc-1, 2), get_pix(wr+1, wc, 2), get_pix(wr+1, wc+1, 2))) begin
                    err_cnt = err_cnt + 1;
                    if (err_cnt <= 10)
                        $display("B  MISMATCH @%0t win#%0d(%0d,%0d): got %0d", $time, out_cnt, wr, wc, o_b);
                end
                // 浮点误差统计（R 通道代表）
                sum_f = 0.0;
                for (row = -1; row <= 1; row = row + 1)
                    for (col = -1; col <= 1; col = col + 1)
                        sum_f = sum_f + get_pix(wr+row, wc+col, 0);
                if (sum_f / 9.0 - o_r > max_err) max_err = sum_f / 9.0 - o_r;
                if (o_r - sum_f / 9.0 > max_err) max_err = o_r - sum_f / 9.0;
            end else begin
                err_cnt = err_cnt + 1;
                $display("FALSE o_valid @%0t (已超 %0d 窗口)", $time, EXP_CNT);
            end
            out_cnt = out_cnt + 1;
        end
    end

    //---- 输出 COE（独立写计数）----
    integer fd;
    integer w_cnt = 0;
    initial begin
        fd = $fopen("output_pad.coe", "w");
        $fwrite(fd, "memory_initialization_radix=16;\n");
        $fwrite(fd, "memory_initialization_vector=\n");
    end
    always @(posedge clk) begin
        #1;
        if (o_valid && w_cnt < EXP_CNT) begin
            $fwrite(fd, "%02X%02X%02X,\n", o_r, o_g, o_b);
            w_cnt <= w_cnt + 1;
        end
    end

    //---- 激励：逐像素喂图 + pad 版时序（h-blank≥1、v-blank≥W+8）----
    integer r, c;
    initial begin
        $dumpfile("tb_mean_filter_pad.vcd");
        $dumpvars(0, tb_mean_filter_pad);

        #25 rst_n = 1;
        @(negedge clk);

        for (r = 0; r < IMG_H; r = r + 1) begin
            for (c = 0; c < IMG_W; c = c + 1) begin
                din       = img[r * IMG_W + c];
                din_valid = 1'b1;
                @(negedge clk);
            end
            // h-blank：行末至少 1 拍（pad 版硬性要求，右边缘 flush 依赖空拍）
            din_valid = 1'b0;
            repeat (1 + {$random} % 3) @(negedge clk);
        end
        // v-blank：帧末至少 IMG_W+8 拍（pad 版下边缘 flush 依赖空拍）
        din_valid = 1'b0;
        repeat (IMG_W + 16) @(negedge clk);

        // 等输出排空（全尺寸 IMG_H×IMG_W）
        while (out_cnt < EXP_CNT) @(negedge clk);
        #40;

        $display("========================================");
        if (err_cnt == 0 && out_cnt == EXP_CNT && max_err <= 1.0)
            $display("[PASS] mean_filter_pad OK: %0d 窗口全对 (OUT=%0dx%0d, INIT=%s)",
                     out_cnt, IMG_W, IMG_H, INIT_FILE);
        else
            $display("[FAIL] errors=%0d out=%0d/%0d INIT=%s", err_cnt, out_cnt, EXP_CNT, INIT_FILE);
        $display("除9近似精度: 浮点均值 vs 定点输出 最大误差 = %0.2f LSB（预期 ≤1）", max_err);
        $fclose(fd);
        $finish;
    end

    //---- 超时兜底 ----
    initial begin
        #(IN_TOTAL * 40 + (IMG_W + 16) * 40 + 1000000);
        $display("[FAIL] simulation timeout");
        $finish;
    end

endmodule