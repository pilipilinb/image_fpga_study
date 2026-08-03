// ============================================================================
// Testbench：tb_line_buffer_3x3_pad
// 验证策略：
//   1. 8x6 小图（像素值 = row*16+col），连灌 2 帧；
//   2. 激励模拟真实视频时序：行内随机气泡(~30%) + 行间 h-blank(2拍) +
//      帧间 v-blank(IMG_W+16拍)——flush 拍依赖 blanking，必须提供；
//   3. 自检：每帧期望 IMG_H*IMG_W 个窗口（光栅序，中心 (0,0)..(H-1,W-1)），
//      期望值 = img[clamp(cr+dr)][clamp(cc+dc)]，clamp 即 replicate 语义；
//   4. 生成 VCD 波形文件 tb_line_buffer_3x3_pad.vcd。
// ============================================================================
`timescale 1ns / 1ps
`include "line_buffer_3x3_pad.v"   // ← 必须 include 被测模块

module tb_line_buffer_3x3_pad;

    localparam DW    = 8;
    localparam IMG_W = 8;
    localparam IMG_H = 6;
    localparam AW    = 3;
    localparam FRAME_NUM = 2;
    localparam HBLANK = 2;              // 行间空拍（设计要求 >=1）
    localparam VBLANK = IMG_W + 16;     // 帧间空拍（设计要求 >= IMG_W+8）

    // ------------------------------------------------------------------------
    // 块1：DUT 例化
    // ------------------------------------------------------------------------
    reg           clk;
    reg           rst_n;
    reg           din_valid;
    reg  [DW-1:0] din;
    wire          matrix_valid;
    wire [DW-1:0] w11, w12, w13;
    wire [DW-1:0] w21, w22, w23;
    wire [DW-1:0] w31, w32, w33;

    line_buffer_3x3_pad #(
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
    // 块2：时钟 —— 100MHz
    // ------------------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ------------------------------------------------------------------------
    // 块3：参考图像
    // ------------------------------------------------------------------------
    reg [DW-1:0] img [0:IMG_H-1][0:IMG_W-1];
    integer r, c;
    initial begin
        for (r = 0; r < IMG_H; r = r + 1)
            for (c = 0; c < IMG_W; c = c + 1)
                img[r][c] = r * 16 + c;
    end

    // ------------------------------------------------------------------------
    // 块4：激励 —— 行内随机气泡 + 行间 h-blank + 帧间 v-blank
    // ------------------------------------------------------------------------
    integer f, rr, cc;
    initial begin
        rst_n     = 1'b0;
        din_valid = 1'b0;
        din       = {DW{1'b0}};
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        for (f = 0; f < FRAME_NUM; f = f + 1) begin
            for (rr = 0; rr < IMG_H; rr = rr + 1) begin
                for (cc = 0; cc < IMG_W; cc = cc + 1) begin
                    // 行内随机气泡（{$random} 强转无符号，气泡率真 30%）
                    while ({$random} % 10 < 3) begin
                        din_valid <= 1'b0;
                        @(posedge clk);
                    end
                    din_valid <= 1'b1;
                    din       <= img[rr][cc];
                    @(posedge clk);
                end
                // 行间 h-blank：行尾 flush 拍靠这里插入
                din_valid <= 1'b0;
                repeat (HBLANK) @(posedge clk);
            end
            // 帧间 v-blank：帧尾整行 flush 靠这里完成
            repeat (VBLANK) @(posedge clk);
        end

        repeat (20) @(posedge clk);
        if (err_cnt == 0 && win_cnt == exp_win_total)
            $display("[PASS] windows checked = %0d, errors = 0", win_cnt);
        else
            $display("[FAIL] windows checked = %0d (expect %0d), errors = %0d",
                      win_cnt, exp_win_total, err_cnt);
        $finish;
    end

    // ------------------------------------------------------------------------
    // 块5：自检记分板 —— clamp 坐标即 replicate padding 的参考模型
    // 窗口光栅序：中心 (cr,cc)，cr∈[0,H-1]、cc∈[0,W-1]，每帧 H*W 个
    // ------------------------------------------------------------------------
    localparam integer exp_win_total = FRAME_NUM * IMG_H * IMG_W;
    integer win_cnt, err_cnt;
    integer cr, ccol, k;

    initial begin
        win_cnt = 0;
        err_cnt = 0;
    end

    function integer clip;          // clamp 到 [0, vmax]
        input integer v;
        input integer vmax;
        begin
            clip = (v < 0) ? 0 : ((v > vmax) ? vmax : v);
        end
    endfunction

    task check_pix;
        input [DW-1:0] got;
        input [DW-1:0] exp;
        input [8*3-1:0] name;
        begin
            if (got !== exp) begin
                err_cnt = err_cnt + 1;
                $display("[ERR] t=%0t win#%0d (cr=%0d,cc=%0d) %s: got %02h, expect %02h",
                         $time, win_cnt, cr, ccol, name, got, exp);
            end
        end
    endtask

    always @(posedge clk) begin
        if (matrix_valid) begin
            k    = win_cnt % (IMG_H * IMG_W);
            cr   = k / IMG_W;               // 窗口中心行
            ccol = k % IMG_W;               // 窗口中心列
            check_pix(w11, img[clip(cr-1,IMG_H-1)][clip(ccol-1,IMG_W-1)], "w11");
            check_pix(w12, img[clip(cr-1,IMG_H-1)][clip(ccol  ,IMG_W-1)], "w12");
            check_pix(w13, img[clip(cr-1,IMG_H-1)][clip(ccol+1,IMG_W-1)], "w13");
            check_pix(w21, img[clip(cr  ,IMG_H-1)][clip(ccol-1,IMG_W-1)], "w21");
            check_pix(w22, img[clip(cr  ,IMG_H-1)][clip(ccol  ,IMG_W-1)], "w22");
            check_pix(w23, img[clip(cr  ,IMG_H-1)][clip(ccol+1,IMG_W-1)], "w23");
            check_pix(w31, img[clip(cr+1,IMG_H-1)][clip(ccol-1,IMG_W-1)], "w31");
            check_pix(w32, img[clip(cr+1,IMG_H-1)][clip(ccol  ,IMG_W-1)], "w32");
            check_pix(w33, img[clip(cr+1,IMG_H-1)][clip(ccol+1,IMG_W-1)], "w33");
            win_cnt = win_cnt + 1;
        end
    end

    // ------------------------------------------------------------------------
    // 块6：VCD 波形输出 + 超时保护
    // ------------------------------------------------------------------------
    initial begin
        $dumpfile("tb_line_buffer_3x3_pad.vcd");
        $dumpvars(0, tb_line_buffer_3x3_pad);
        #100000;
        $display("[FAIL] simulation timeout!");
        $finish;
    end

endmodule
