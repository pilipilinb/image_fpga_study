// ============================================================================
// Testbench：tb_line_buffer_3x3
// 验证策略：
//   1. 用小图（8x6，像素值 = row*16+col，肉眼可读）灌入 DUT；
//   2. din_valid 带随机气泡，验证非连续像素流下的流水线对齐；
//   3. 自检：matrix_valid 拉高时，用参考图像数组反推期望 3x3 窗口逐点比对；
//   4. 连灌 2 帧，验证帧边界（行/列计数器回卷）后窗口依然正确；
//   5. 生成 VCD 波形文件 tb_line_buffer_3x3.vcd。
// ============================================================================
`timescale 1ns / 1ps
`include "line_buffer_3x3.v"   // ← 必须 include 被测模块，否则仿真器找不到模块定义

module tb_line_buffer_3x3;

    // 小尺寸参数，方便肉眼核对波形
    localparam DW    = 8;
    localparam IMG_W = 8;
    localparam IMG_H = 6;
    localparam AW    = 3;      // 2^3 = 8 >= IMG_W
    localparam FRAME_NUM = 2;  // 连灌 2 帧测帧边界回卷

    // ------------------------------------------------------------------------
    // 块1：DUT 接口信号与例化
    // ------------------------------------------------------------------------
    reg           clk;
    reg           rst_n;
    reg           din_valid;
    reg  [DW-1:0] din;
    wire          matrix_valid;
    wire [DW-1:0] w11, w12, w13;
    wire [DW-1:0] w21, w22, w23;
    wire [DW-1:0] w31, w32, w33;

    line_buffer_3x3 #(
        .DW    (DW),
        .IMG_W (IMG_W),
        .IMG_H (IMG_H),
        .AW    (AW)
    ) u_dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .din_valid    (din_valid),
        .din          (din),
        .matrix_valid (matrix_valid),
        .w11(w11), .w12(w12), .w13(w13),
        .w21(w21), .w22(w22), .w23(w23),
        .w31(w31), .w32(w32), .w33(w33)
    );

    // ------------------------------------------------------------------------
    // 块2：时钟 —— 100MHz（周期 10ns）
    // ------------------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ------------------------------------------------------------------------
    // 块3：参考图像 —— 像素值 = row*16 + col（十六进制下高位是行、低位是列）
    // 两帧内容相同即可，自检只关心坐标映射
    // ------------------------------------------------------------------------
    reg [DW-1:0] img [0:IMG_H-1][0:IMG_W-1];
    integer r, c;
    initial begin
        for (r = 0; r < IMG_H; r = r + 1)
            for (c = 0; c < IMG_W; c = c + 1)
                img[r][c] = r * 16 + c;
    end

    // ------------------------------------------------------------------------
    // 块4：激励 —— 复位后逐像素灌入，din_valid 随机插气泡（约 30% 空拍）
    // 所有输入在时钟下降沿方向的 @(posedge clk) 后用非阻塞更新，避免竞争
    // ------------------------------------------------------------------------
    integer f, i;
    initial begin
        rst_n     = 1'b0;
        din_valid = 1'b0;
        din       = {DW{1'b0}};
        repeat (5) @(posedge clk);
        rst_n = 1'b1;              // 释放低电平复位
        @(posedge clk);

        for (f = 0; f < FRAME_NUM; f = f + 1) begin
            for (i = 0; i < IMG_W * IMG_H; i = i + 1) begin
                // 随机气泡：模拟真实视频流中 valid 不连续
                // 注意 {$random} 强转无符号，否则有符号取模负数也 <3，气泡率会变 ~60%
                while ({$random} % 10 < 3) begin
                    din_valid <= 1'b0;
                    @(posedge clk);
                end
                din_valid <= 1'b1;
                din       <= img[i / IMG_W][i % IMG_W];
                @(posedge clk);
            end
        end
        din_valid <= 1'b0;

        // 等流水线排空后统计结果
        repeat (10) @(posedge clk);
        if (err_cnt == 0 && win_cnt == exp_win_total)
            $display("[PASS] windows checked = %0d, errors = 0", win_cnt);
        else
            $display("[FAIL] windows checked = %0d (expect %0d), errors = %0d",
                      win_cnt, exp_win_total, err_cnt);
        $finish;
    end

    // ------------------------------------------------------------------------
    // 块5：自检记分板
    // 窗口按光栅顺序出现：中心像素坐标 (wr, wc)，wr∈[2,H-1]、wc∈[2,W-1]
    // （w33 是窗口右下角 = 当前像素，因此 w22 中心 = (wr-1, wc-1)）
    // 期望窗口：w11=img[wr-2][wc-2] ... w33=img[wr][wc]
    // ------------------------------------------------------------------------
    localparam integer exp_win_total = FRAME_NUM * (IMG_H - 2) * (IMG_W - 2);
    integer win_cnt, err_cnt;
    integer wr, wc;                // 当前期望窗口右下角坐标
    integer k;

    initial begin
        win_cnt = 0;
        err_cnt = 0;
    end

    task check_pix;                // 单像素比对子程序
        input [DW-1:0] got;
        input [DW-1:0] exp;
        input [8*3-1:0] name;
        begin
            if (got !== exp) begin
                err_cnt = err_cnt + 1;
                $display("[ERR] t=%0t win#%0d %s: got %02h, expect %02h",
                         $time, win_cnt, name, got, exp);
            end
        end
    endtask

    always @(posedge clk) begin
        if (matrix_valid) begin
            // 由窗口序号反推右下角坐标（每帧 (H-2)*(W-2) 个窗口）
            k  = win_cnt % ((IMG_H - 2) * (IMG_W - 2));
            wr = k / (IMG_W - 2) + 2;
            wc = k % (IMG_W - 2) + 2;
            check_pix(w11, img[wr-2][wc-2], "w11");
            check_pix(w12, img[wr-2][wc-1], "w12");
            check_pix(w13, img[wr-2][wc  ], "w13");
            check_pix(w21, img[wr-1][wc-2], "w21");
            check_pix(w22, img[wr-1][wc-1], "w22");
            check_pix(w23, img[wr-1][wc  ], "w23");
            check_pix(w31, img[wr  ][wc-2], "w31");
            check_pix(w32, img[wr  ][wc-1], "w32");
            check_pix(w33, img[wr  ][wc  ], "w33");
            win_cnt = win_cnt + 1;
        end
    end

    // ------------------------------------------------------------------------
    // 块6：VCD 波形输出 + 超时保护
    // ------------------------------------------------------------------------
    initial begin
        $dumpfile("tb_line_buffer_3x3.vcd");
        $dumpvars(0, tb_line_buffer_3x3);
        #50000;                    // 兜底超时，防止仿真挂死
        $display("[FAIL] simulation timeout!");
        $finish;
    end

endmodule
