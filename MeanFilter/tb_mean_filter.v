//========================================================================
// tb_mean_filter.v —— 3×3 均值滤波自检 TB（MeanFilter 工程）
// 验证内容：
//   1. 全帧逐窗口比对：与 RTL 同款定点参考 (sum×57+256)>>9 严格全等
//   2. 近似精度统计：浮点均值 vs 输出，报告最大误差（预期 ≤1 LSB）
//   3. 窗口数核对：输出恰 (IMG_H-2)×(IMG_W-2) 个（crop 边界）
//   4. 行内随机气泡：验证窗口/valid 链对输入气泡鲁棒
// 激励规范（守工程实践）：negedge 置位、先设置后等待、超时兜底、VCD
// 配置：iverilog 加 -DSMALL 跑 4×3 合成小图（三通道不同分量防接错），
//       默认跑真图 input.hex（112×103 RGB888）
//========================================================================
`timescale 1ns/1ps
`include "top_mean_filter.v"

module tb_mean_filter;

`ifdef SMALL
    localparam IMG_W = 4;
    localparam IMG_H = 3;
`else
    localparam IMG_W = 112;
    localparam IMG_H = 103;
`endif
    localparam IN_TOTAL = IMG_W * IMG_H;
    localparam EXP_CNT  = (IMG_H - 2) * (IMG_W - 2);   // crop 后的期望窗口数
`ifdef SMALL
    localparam INIT_FILE = "input_4x3.hex";
`elsif NOISE
    localparam INIT_FILE = "noise.hex";     // 高斯噪声图（noise_add.py 生成）
`elsif SALT
    localparam INIT_FILE = "salt_pepper.hex"; // 椒盐噪声图（与中值滤波同份，椒盐去噪三对照）
`else
    localparam INIT_FILE = "input.hex";
`endif

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg [23:0] din = 24'd0;
    reg din_valid = 1'b0;
    wire [7:0] o_r, o_g, o_b;
    wire o_valid;

    top_mean_filter #(
        .IMG_W(IMG_W), .IMG_H(IMG_H), .AW($clog2(IMG_W)+1)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .din(din), .din_valid(din_valid),
        .o_r(o_r), .o_g(o_g), .o_b(o_b), .o_valid(o_valid)
    );

    always #5 clk = ~clk;

    //---- 输入图像（$readmemh 加载，24bit RGB888）----
    reg [23:0] img [0:IN_TOTAL-1];
    initial $readmemh(INIT_FILE, img);

    //---- 参考模型：与 RTL 同款定点均值（严格全等）----
    function integer ref_mean;
        input integer a, b, c, d, e, f, g, h, i2;   // 9 个像素
        integer sum, v;
        begin
            sum = a + b + c + d + e + f + g + h + i2;
            v = (sum * 57 + 256) >> 9;              // 除 9 定点近似（同 RTL）
            ref_mean = (v > 255) ? 255 : v;
        end
    endfunction

    //---- 辅助：按通道取 24bit 像素的 8bit 分量 ----
    function integer pix_ch;
        input integer px;
        input integer chan;   // 0=R 1=G 2=B
        begin
            if (chan == 0)      pix_ch = (px >> 16) & 8'hFF;
            else if (chan == 1) pix_ch = (px >>  8) & 8'hFF;
            else                pix_ch = px        & 8'hFF;
        end
    endfunction

    //---- 记分板 ----
    integer out_cnt = 0, err_cnt = 0;
    integer k, wr, wc;
    real    max_err = 0.0;          // 定点输出 vs 浮点均值（除9近似精度）
    real    sum_f;                   // 浮点和（仅 R 通道统计，三通道规律一致）
    integer row, col;

    always @(posedge clk) begin
        #1;
        if (o_valid) begin
            if (out_cnt < EXP_CNT) begin
                // 由窗口序号反推右下角坐标（与 tb_line_buffer_3x3 同法）
                k  = out_cnt;
                wr = k / (IMG_W - 2) + 2;
                wc = k % (IMG_W - 2) + 2;
                // 9 个窗口像素（img 按行存，img[row*IMG_W+col]）
                // 窗口：p00=img[wr-2][wc-2] ... p22=img[wr][wc]
                if (o_r !== ref_mean(
                        pix_ch(img[(wr-2)*IMG_W + wc-2], 0), pix_ch(img[(wr-2)*IMG_W + wc-1], 0), pix_ch(img[(wr-2)*IMG_W + wc], 0),
                        pix_ch(img[(wr-1)*IMG_W + wc-2], 0), pix_ch(img[(wr-1)*IMG_W + wc-1], 0), pix_ch(img[(wr-1)*IMG_W + wc], 0),
                        pix_ch(img[(wr  )*IMG_W + wc-2], 0), pix_ch(img[(wr  )*IMG_W + wc-1], 0), pix_ch(img[(wr  )*IMG_W + wc], 0))) begin
                    err_cnt = err_cnt + 1;
                    if (err_cnt <= 10)
                        $display("R  MISMATCH @%0t win#%0d(%0d,%0d): got %0d", $time, out_cnt, wr, wc, o_r);
                end
                if (o_g !== ref_mean(
                        pix_ch(img[(wr-2)*IMG_W + wc-2], 1), pix_ch(img[(wr-2)*IMG_W + wc-1], 1), pix_ch(img[(wr-2)*IMG_W + wc], 1),
                        pix_ch(img[(wr-1)*IMG_W + wc-2], 1), pix_ch(img[(wr-1)*IMG_W + wc-1], 1), pix_ch(img[(wr-1)*IMG_W + wc], 1),
                        pix_ch(img[(wr  )*IMG_W + wc-2], 1), pix_ch(img[(wr  )*IMG_W + wc-1], 1), pix_ch(img[(wr  )*IMG_W + wc], 1))) begin
                    err_cnt = err_cnt + 1;
                    if (err_cnt <= 10)
                        $display("G  MISMATCH @%0t win#%0d(%0d,%0d): got %0d", $time, out_cnt, wr, wc, o_g);
                end
                if (o_b !== ref_mean(
                        pix_ch(img[(wr-2)*IMG_W + wc-2], 2), pix_ch(img[(wr-2)*IMG_W + wc-1], 2), pix_ch(img[(wr-2)*IMG_W + wc], 2),
                        pix_ch(img[(wr-1)*IMG_W + wc-2], 2), pix_ch(img[(wr-1)*IMG_W + wc-1], 2), pix_ch(img[(wr-1)*IMG_W + wc], 2),
                        pix_ch(img[(wr  )*IMG_W + wc-2], 2), pix_ch(img[(wr  )*IMG_W + wc-1], 2), pix_ch(img[(wr  )*IMG_W + wc], 2))) begin
                    err_cnt = err_cnt + 1;
                    if (err_cnt <= 10)
                        $display("B  MISMATCH @%0t win#%0d(%0d,%0d): got %0d", $time, out_cnt, wr, wc, o_b);
                end
                // 浮点误差统计（×57>>9 近似精度验证，仅统计不判错）
                // 用 R 通道代表：sum_f = 9 像素浮点和，mean_f = 均值，|got - mean_f| 取最大
                sum_f = 0.0;
                for (row = 0; row < 3; row = row + 1)
                    for (col = 0; col < 3; col = col + 1)
                        sum_f = sum_f + pix_ch(img[(wr-2+row)*IMG_W + wc-2+col], 0);
                if (sum_f / 9.0 - o_r > max_err) max_err = sum_f / 9.0 - o_r;
                if (o_r - sum_f / 9.0 > max_err) max_err = o_r - sum_f / 9.0;
            end else begin
                err_cnt = err_cnt + 1;
                $display("FALSE o_valid @%0t (已超 %0d 窗口)", $time, EXP_CNT);
            end
            out_cnt = out_cnt + 1;
        end
    end

    //---- 输出 COE（独立写计数 w_cnt，避免跨 always 竞态丢最后一行）----
    integer fd;
    integer w_cnt = 0;
    initial begin
        fd = $fopen("output.coe", "w");
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

    //---- 激励：逐像素喂图（每行随机气泡 + 行末延时）----
    integer r, c, i;
    initial begin
        $dumpfile("tb_mean_filter.vcd");
        $dumpvars(0, tb_mean_filter);

        #25 rst_n = 1;
        @(negedge clk);

        for (r = 0; r < IMG_H; r = r + 1) begin
            for (c = 0; c < IMG_W; c = c + 1) begin
                // 行内气泡（约 20%）
                if ({$random} % 5 == 0) begin
                    din_valid = 1'b0;
                    @(negedge clk);
                end
                // 先设置后等待（本次无写侧反压，直接一拍一个）
                din       = img[r * IMG_W + c];
                din_valid = 1'b1;
                @(negedge clk);
            end
            // 行末延时（0~3 拍）
            din_valid = 1'b0;
            repeat ({$random} % 4) @(negedge clk);
        end
        din_valid = 1'b0;

        // 等流水排空（行缓存潜伏 + 核 3 级 + 余量）
        while (out_cnt < EXP_CNT) @(negedge clk);
        #40;

        // 汇总（主比对全等 + 窗口数 + 气泡压力 + 除9近似精度）
        $display("========================================");
        if (err_cnt == 0 && out_cnt == EXP_CNT && max_err <= 1.0)
            $display("[PASS] mean_filter OK: %0d 窗口全对 (OUT=%0dx%0d, INIT=%s)",
                     out_cnt, IMG_W-2, IMG_H-2, INIT_FILE);
        else
            $display("[FAIL] errors=%0d out=%0d/%0d INIT=%s", err_cnt, out_cnt, EXP_CNT, INIT_FILE);
        $display("除9近似精度: 浮点均值 vs 定点输出 最大误差 = %0.2f LSB（预期 ≤1）", max_err);
        $fclose(fd);
        $finish;
    end

    //---- 超时兜底 ----
    initial begin
        #(IN_TOTAL * 40 + 1000000);
        $display("[FAIL] simulation timeout");
        $finish;
    end

endmodule