// ============================================================================
// Testbench：tb_line_buffer_nxn —— 参数化行缓存模板自检
// 验证策略：
//   1. 8x6 小图（像素值 = row*16+col），连灌 2 帧，行内随机气泡(~30%)；
//   2. 同一激励同时喂 N=3 和 N=4 两个 DUT 实例，验证参数化正确性；
//   3. 参考模型（crop，无 padding）：窗口右下角 (wr,wc) 按光栅序遍历，
//      win[i][j] 应 = img[wr-(N-1-i)][wc-(N-1-j)]；
//   4. 每帧期望窗口数 = (IMG_H-N+1)*(IMG_W-N+1)；
//   5. 生成 VCD 波形文件 tb_line_buffer_nxn.vcd。
// ============================================================================
`timescale 1ns / 1ps
`include "line_buffer_nxn.v"   // ← 必须 include 被测模块

module tb_line_buffer_nxn;

    localparam DW    = 8;
    localparam IMG_W = 8;
    localparam IMG_H = 6;
    localparam FRAME_NUM = 2;

    // ------------------------------------------------------------------------
    // 块1：两个 DUT 实例 —— N=3 与 N=4，共享同一激励
    // ------------------------------------------------------------------------
    reg           clk, rst_n, din_valid;
    reg  [DW-1:0] din;

    wire          mv3;
    wire [3*3*DW-1:0] win3;
    line_buffer_nxn #(.DW(DW), .IMG_W(IMG_W), .IMG_H(IMG_H), .N(3)) u_n3 (
        .clk(clk), .rst_n(rst_n), .din_valid(din_valid), .din(din),
        .matrix_valid(mv3), .win_flat(win3));

    wire          mv4;
    wire [4*4*DW-1:0] win4;
    line_buffer_nxn #(.DW(DW), .IMG_W(IMG_W), .IMG_H(IMG_H), .N(4)) u_n4 (
        .clk(clk), .rst_n(rst_n), .din_valid(din_valid), .din(din),
        .matrix_valid(mv4), .win_flat(win4));

    // ------------------------------------------------------------------------
    // 块2：时钟 100MHz
    // ------------------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ------------------------------------------------------------------------
    // 块3：参考图像
    // ------------------------------------------------------------------------
    reg [DW-1:0] img [0:IMG_H-1][0:IMG_W-1];
    integer r, c;
    initial
        for (r = 0; r < IMG_H; r = r + 1)
            for (c = 0; c < IMG_W; c = c + 1)
                img[r][c] = r * 16 + c;

    // ------------------------------------------------------------------------
    // 块4：激励 —— 2 帧，行内随机气泡（{$random} 强转无符号，真 30%）
    // ------------------------------------------------------------------------
    integer f, ii;
    initial begin
        rst_n = 1'b0; din_valid = 1'b0; din = {DW{1'b0}};
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        for (f = 0; f < FRAME_NUM; f = f + 1) begin
            for (ii = 0; ii < IMG_W*IMG_H; ii = ii + 1) begin
                while ({$random} % 10 < 3) begin      // 随机气泡
                    din_valid <= 1'b0;
                    @(posedge clk);
                end
                din_valid <= 1'b1;
                din       <= img[ii/IMG_W][ii%IMG_W];
                @(posedge clk);
            end
        end
        din_valid <= 1'b0;
        repeat (20) @(posedge clk);

        if (err3 == 0 && cnt3 == exp3 && err4 == 0 && cnt4 == exp4)
            $display("[PASS] N=3: %0d windows, N=4: %0d windows, errors = 0", cnt3, cnt4);
        else
            $display("[FAIL] N=3: cnt=%0d(exp %0d) err=%0d | N=4: cnt=%0d(exp %0d) err=%0d",
                     cnt3, exp3, err3, cnt4, exp4, err4);
        $finish;
    end

    // ------------------------------------------------------------------------
    // 块5：记分板 N=3 —— 期望 (IMG_H-2)*(IMG_W-2)/帧
    // ------------------------------------------------------------------------
    localparam integer exp3 = FRAME_NUM * (IMG_H-2) * (IMG_W-2);
    integer cnt3, err3, k3, wr3, wc3, i3, j3;
    initial begin cnt3 = 0; err3 = 0; end

    task chk3;
        input [DW-1:0] got; input [DW-1:0] exp_v; input integer ii_; input integer jj_;
        begin
            if (got !== exp_v) begin
                err3 = err3 + 1;
                $display("[ERR3] t=%0t win#%0d (r%0d,c%0d) [%0d,%0d]: got %02h exp %02h",
                         $time, cnt3, wr3, wc3, ii_, jj_, got, exp_v);
            end
        end
    endtask

    always @(posedge clk) begin
        if (mv3) begin
            k3  = cnt3 % ((IMG_H-2)*(IMG_W-2));
            wr3 = k3 / (IMG_W-2) + 2;          // 右下角行
            wc3 = k3 % (IMG_W-2) + 2;          // 右下角列
            for (i3 = 0; i3 <= 2; i3 = i3 + 1)
                for (j3 = 0; j3 <= 2; j3 = j3 + 1)
                    chk3(win3[(i3*3+j3)*DW +: DW], img[wr3-(2-i3)][wc3-(2-j3)], i3, j3);
            cnt3 = cnt3 + 1;
        end
    end

    // ------------------------------------------------------------------------
    // 块6：记分板 N=4 —— 期望 (IMG_H-3)*(IMG_W-3)/帧
    // ------------------------------------------------------------------------
    localparam integer exp4 = FRAME_NUM * (IMG_H-3) * (IMG_W-3);
    integer cnt4, err4, k4, wr4, wc4, i4, j4;
    initial begin cnt4 = 0; err4 = 0; end

    task chk4;
        input [DW-1:0] got; input [DW-1:0] exp_v; input integer ii_; input integer jj_;
        begin
            if (got !== exp_v) begin
                err4 = err4 + 1;
                $display("[ERR4] t=%0t win#%0d (r%0d,c%0d) [%0d,%0d]: got %02h exp %02h",
                         $time, cnt4, wr4, wc4, ii_, jj_, got, exp_v);
            end
        end
    endtask

    always @(posedge clk) begin
        if (mv4) begin
            k4  = cnt4 % ((IMG_H-3)*(IMG_W-3));
            wr4 = k4 / (IMG_W-3) + 3;
            wc4 = k4 % (IMG_W-3) + 3;
            for (i4 = 0; i4 <= 3; i4 = i4 + 1)
                for (j4 = 0; j4 <= 3; j4 = j4 + 1)
                    chk4(win4[(i4*4+j4)*DW +: DW], img[wr4-(3-i4)][wc4-(3-j4)], i4, j4);
            cnt4 = cnt4 + 1;
        end
    end

    // ------------------------------------------------------------------------
    // 块7：VCD 波形输出 + 超时保护
    // ------------------------------------------------------------------------
    initial begin
        $dumpfile("tb_line_buffer_nxn.vcd");
        $dumpvars(0, tb_line_buffer_nxn);
        #60000;
        $display("[FAIL] simulation timeout!");
        $finish;
    end

endmodule
