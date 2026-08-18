//========================================================================
// tb_gaussian_filter.v —— 3×3 高斯滤波自检 TB（GaussianFilter 工程）
// 验证内容：
//   1. 全帧逐窗口比对：与 RTL 同款定点参考（对称分组移位 + 舍入)严格全等
//   2. 近似精度统计：浮点基准 = 整数点积/16.0（非浮点核卷积），报告最大误差（≤0.5 LSB）
//   3. 均值不变性：第二帧喂全 0x808080 纯色图，输出必须恒 0x80（核和=16 保证）
//   4. 窗口数核对：两帧各 (IMG_H-2)×(IMG_W-2)，共 2 倍；行内随机气泡验证鲁棒
// 激励规范（守工程实践）：negedge 置位、先设置后等待、超时兜底、VCD
// 配置：iverilog 加 -DSMALL 跑 4×3 合成小图；-DNOISE 第一帧改喂 noise.hex
//       并只把第一帧结果写 output.coe（供噪声去噪对比）
//========================================================================
`timescale 1ns/1ps
`include "top_gaussian_filter.v"

module tb_gaussian_filter;

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

    top_gaussian_filter #(
        .IMG_W(IMG_W), .IMG_H(IMG_H), .AW($clog2(IMG_W)+1)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .din(din), .din_valid(din_valid),
        .o_r(o_r), .o_g(o_g), .o_b(o_b), .o_valid(o_valid)
    );

    always #5 clk = ~clk;

    //---- 输入图像：第一帧从文件读（input/noise），第二帧纯色 0x808080 ----
    reg [23:0] img   [0:IN_TOTAL-1];
    reg [23:0] solid [0:IN_TOTAL-1];
    integer si;
    initial begin
        $readmemh(INIT_FILE, img);
        for (si = 0; si < IN_TOTAL; si = si + 1)
            solid[si] = 24'h808080;
    end

    //---- 参考模型：与 RTL 同款定点高斯（对称分组 + 移位 + (sum+8)>>4）----
    function integer ref_gau;
        input integer a, b, c, d, e, f, g, h, i2;   // 9 像素
        integer ang, e_sum, sum, v;
        begin
            ang   = a + c + g + i2;                  // 4 角（系数 1）
            e_sum = b + d + f + h;                   // 4 边（系数 2）
            sum   = ang + (e_sum << 1) + (e << 2);   // 中心（系数 4），括号显式
            v     = (sum + 8) >> 4;                  // 加 8 舍入后右移 4
            ref_gau = (v > 255) ? 255 : v;
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
    real    max_err = 0.0;
    real    sum_f, golden;
    integer row, col;

    always @(posedge clk) begin
        #1;
        if (o_valid) begin
            if (out_cnt < EXP_CNT) begin
                k     = out_cnt % WIN_PER_FRAME;     // 帧内窗口序号
                frame = out_cnt / WIN_PER_FRAME;     // 0=真实图 1=纯色
                wr = k / (IMG_W - 2) + 2;
                wc = k % (IMG_W - 2) + 2;
                // 9 个窗口像素取数（按帧选数据源，右下角反推坐标）
                if ((o_r !== ref_gau(
                        pix_ch(frame_pix(frame, wr-2, wc-2), 0), pix_ch(frame_pix(frame, wr-2, wc-1), 0), pix_ch(frame_pix(frame, wr-2, wc), 0),
                        pix_ch(frame_pix(frame, wr-1, wc-2), 0), pix_ch(frame_pix(frame, wr-1, wc-1), 0), pix_ch(frame_pix(frame, wr-1, wc), 0),
                        pix_ch(frame_pix(frame, wr,   wc-2), 0), pix_ch(frame_pix(frame, wr,   wc-1), 0), pix_ch(frame_pix(frame, wr,   wc), 0)))) begin
                    err_cnt = err_cnt + 1;
                    if (err_cnt <= 10)
                        $display("R  MISMATCH @%0t f%0d win#%0d(%0d,%0d): got %0d", $time, frame, out_cnt, wr, wc, o_r);
                end
                if ((o_g !== ref_gau(
                        pix_ch(frame_pix(frame, wr-2, wc-2), 1), pix_ch(frame_pix(frame, wr-2, wc-1), 1), pix_ch(frame_pix(frame, wr-2, wc), 1),
                        pix_ch(frame_pix(frame, wr-1, wc-2), 1), pix_ch(frame_pix(frame, wr-1, wc-1), 1), pix_ch(frame_pix(frame, wr-1, wc), 1),
                        pix_ch(frame_pix(frame, wr,   wc-2), 1), pix_ch(frame_pix(frame, wr,   wc-1), 1), pix_ch(frame_pix(frame, wr,   wc), 1)))) begin
                    err_cnt = err_cnt + 1;
                    if (err_cnt <= 10)
                        $display("G  MISMATCH @%0t f%0d win#%0d(%0d,%0d): got %0d", $time, frame, out_cnt, wr, wc, o_g);
                end
                if ((o_b !== ref_gau(
                        pix_ch(frame_pix(frame, wr-2, wc-2), 2), pix_ch(frame_pix(frame, wr-2, wc-1), 2), pix_ch(frame_pix(frame, wr-2, wc), 2),
                        pix_ch(frame_pix(frame, wr-1, wc-2), 2), pix_ch(frame_pix(frame, wr-1, wc-1), 2), pix_ch(frame_pix(frame, wr-1, wc), 2),
                        pix_ch(frame_pix(frame, wr,   wc-2), 2), pix_ch(frame_pix(frame, wr,   wc-1), 2), pix_ch(frame_pix(frame, wr,   wc), 2)))) begin
                    err_cnt = err_cnt + 1;
                    if (err_cnt <= 10)
                        $display("B  MISMATCH @%0t f%0d win#%0d(%0d,%0d): got %0d", $time, frame, out_cnt, wr, wc, o_b);
                end
                // 浮点误差统计（R 通道代表，仅帧0 真实图有意义；
                //   基准 = 加权整数点积/16.0：角×1 + 边×2 + 中心×4，非简单 9 像素和）
                if (frame == 0) begin
                    sum_f = 0.0;
                    // 角（系数 1）
                    sum_f = sum_f + pix_ch(frame_pix(0, wr-2, wc-2), 0) + pix_ch(frame_pix(0, wr-2, wc), 0)
                                 + pix_ch(frame_pix(0, wr,   wc-2), 0) + pix_ch(frame_pix(0, wr,   wc), 0);
                    // 边（系数 2）
                    sum_f = sum_f + 2.0 * (pix_ch(frame_pix(0, wr-2, wc-1), 0) + pix_ch(frame_pix(0, wr-1, wc-2), 0)
                                         + pix_ch(frame_pix(0, wr-1, wc), 0) + pix_ch(frame_pix(0, wr,   wc-1), 0));
                    // 中心（系数 4）
                    sum_f = sum_f + 4.0 * pix_ch(frame_pix(0, wr-1, wc-1), 0);
                    golden = sum_f / 16.0;
                    if (golden - o_r > max_err) max_err = golden - o_r;
                    if (o_r - golden > max_err) max_err = o_r - golden;
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
        $dumpfile("tb_gaussian_filter.vcd");
        $dumpvars(0, tb_gaussian_filter);

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
        if (err_cnt == 0 && out_cnt == EXP_CNT && max_err <= 0.5)
            $display("[PASS] gaussian_filter OK: %0d 窗口全对（2 帧，INIT=%s）", out_cnt, INIT_FILE);
        else
            $display("[FAIL] errors=%0d out=%0d/%0d INIT=%s", err_cnt, out_cnt, EXP_CNT, INIT_FILE);
        $display("浮点误差（整数点积/16.0 基准）: 最大 = %0.3f LSB（预期 ≤0.5）", max_err);
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