//========================================================================
// tb_chain.v —— 滤波+CSC+缩放 串链路自检 TB（filter_csc_bilinear，W4 收尾）
// 验证内容：
//   1. 链路级联完整性：各级输出像素数（高斯 110×101 / 中值 108×99 /
//      CSC 108×99 / 缩放 216×198）逐级核对，无丢拍
//   2. 输出 4 份中间结果 COE：gaussian_out / median_out / csc_out /
//      chain_out —— 供 verify_chain.py 逐级浮点参考 PSNR 定位
//   3. 输入随机气泡 + FIFO 反压压力（链路全程在跑，像素数不丢即通过）
// 激励规范（守工程实践）：negedge 置位、先设置后等待、超时兜底、VCD
//========================================================================
`timescale 1ns/1ps
`include "top_chain.v"

module tb_chain;

    localparam IN_W = 112;
    localparam IN_H = 103;
    localparam IN_TOTAL = IN_W * IN_H;        // 11536

    `ifdef SWAP
        localparam ORDER = 1;   // 滤波顺序实验：中值→高斯
    `else
        localparam ORDER = 0;   // 默认：高斯→中值
    `endif
    `ifdef PAD
        localparam PAD = 1;     // pad 版行缓存：全尺寸链（两级不收缩）
    `else
        localparam PAD = 0;     // crop 版：两级各 -2 边缘
    `endif
    // 尺寸（随 PAD/ORDER 互换）：
    //   crop：高斯(IN-2)^2 先出、中值(IN-4)^2 后出（或反序）
    //   pad ：两级均全尺寸 IN^2
    localparam G_CNT = (PAD == 0) ? ((ORDER == 0) ? (IN_W-2)*(IN_H-2) : (IN_W-4)*(IN_H-4))
                                  : IN_TOTAL;
    localparam M_CNT = (PAD == 0) ? ((ORDER == 0) ? (IN_W-4)*(IN_H-4) : (IN_W-2)*(IN_H-2))
                                  : IN_TOTAL;
    localparam C_CNT = (PAD == 0) ? ((ORDER == 0) ? M_CNT : G_CNT) : IN_TOTAL;
    localparam OUT_W = (PAD == 0) ? (IN_W-4) * 2 : IN_W * 2;
    localparam OUT_H = (PAD == 0) ? (IN_H-4) * 2 : IN_H * 2;
    localparam OUT_CNT = OUT_W * OUT_H;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg frame_start = 1'b0;
    reg [23:0] din = 24'd0;
    reg din_valid = 1'b0;

    wire [23:0] m_gau_dout, m_med_dout, m_csc_dout;
    wire        m_gau_valid, m_med_valid, m_csc_valid;
    wire [23:0] o_dout;
    wire        o_valid, o_done;

    top_chain #(.ORDER(ORDER), .PAD(PAD)) dut (
        .clk(clk), .rst_n(rst_n), .frame_start(frame_start),
        .din(din), .din_valid(din_valid),
        .m_gau_valid(m_gau_valid), .m_gau_dout(m_gau_dout),
        .m_med_valid(m_med_valid), .m_med_dout(m_med_dout),
        .m_csc_valid(m_csc_valid), .m_csc_dout(m_csc_dout),
        .o_dout(o_dout), .o_valid(o_valid), .o_done(o_done)
    );

    always #5 clk = ~clk;

    //---- 输入图像（混合噪声图，112×103）----
    reg [23:0] img [0:IN_TOTAL-1];
    initial $readmemh("noise_mix.hex", img);

    //---- 记分板：四级计数 + 错误标志 ----
    integer gau_cnt = 0, med_cnt = 0, csc_cnt = 0, out_cnt = 0;
    integer err_cnt = 0;
    reg done_seen = 1'b0;
    always @(posedge clk) begin
        #1;
        if (o_done) done_seen <= 1'b1;
        if (m_gau_valid) begin
            if (gau_cnt >= G_CNT) begin err_cnt = err_cnt + 1; $display("FALSE gau_valid @%0t", $time); end
            gau_cnt = gau_cnt + 1;
        end
        if (m_med_valid) begin
            if (med_cnt >= M_CNT) begin err_cnt = err_cnt + 1; $display("FALSE med_valid @%0t", $time); end
            med_cnt = med_cnt + 1;
        end
        if (m_csc_valid) begin
            if (csc_cnt >= C_CNT) begin err_cnt = err_cnt + 1; $display("FALSE csc_valid @%0t", $time); end
            csc_cnt = csc_cnt + 1;
        end
        if (o_valid) begin
            if (out_cnt >= OUT_CNT) begin err_cnt = err_cnt + 1; $display("FALSE o_valid @%0t", $time); end
            out_cnt = out_cnt + 1;
        end
    end

    //---- 4 份 COE 输出（独立写计数）----
    integer f_gau, f_med, f_csc, f_out;
    integer w_gau = 0, w_med = 0, w_csc = 0, w_out = 0;
    initial begin
        f_gau = $fopen("gaussian_out.coe", "w");
        f_med = $fopen("median_out.coe", "w");
        f_csc = $fopen("csc_out.coe", "w");
        f_out = $fopen("chain_out.coe", "w");
        $fwrite(f_gau, "memory_initialization_radix=16;\nmemory_initialization_vector=\n");
        $fwrite(f_med, "memory_initialization_radix=16;\nmemory_initialization_vector=\n");
        $fwrite(f_csc, "memory_initialization_radix=16;\nmemory_initialization_vector=\n");
        $fwrite(f_out, "memory_initialization_radix=16;\nmemory_initialization_vector=\n");
    end
    always @(posedge clk) begin
        #1;
        if (m_gau_valid && w_gau < G_CNT) begin $fwrite(f_gau, "%06X,\n", m_gau_dout); w_gau <= w_gau + 1; end
        if (m_med_valid && w_med < M_CNT) begin $fwrite(f_med, "%06X,\n", m_med_dout); w_med <= w_med + 1; end
        if (m_csc_valid && w_csc < C_CNT) begin $fwrite(f_csc, "%06X,\n", m_csc_dout); w_csc <= w_csc + 1; end
        if (o_valid && w_out < OUT_CNT) begin $fwrite(f_out, "%06X,\n", o_dout); w_out <= w_out + 1; end
    end

    //---- 激励：frame_start 1 拍 → 逐像素喂混合噪声图（随机气泡）+ 行末延时 ----
    integer r, c;
    initial begin
        $dumpfile("tb_chain.vcd");
        $dumpvars(0, tb_chain);

        #25 rst_n = 1;
        @(negedge clk);
        frame_start = 1'b1;
        @(negedge clk);
        frame_start = 1'b0;

        for (r = 0; r < IN_H; r = r + 1) begin
            for (c = 0; c < IN_W; c = c + 1) begin
                if ({$random} % 7 == 0) begin
                    din_valid = 1'b0;
                    @(negedge clk);
                end
                din       = img[r*IN_W + c];
                din_valid = 1'b1;
                @(negedge clk);
            end
            din_valid = 1'b0;
            repeat (1 + {$random} % 3) @(negedge clk);
        end
        din_valid = 1'b0;

        // 等缩放帧结束（o_done 由 coord_gen 在输出完成后拉出，含排空）
        while (!o_done) @(negedge clk);
        // 尾拍对齐
        repeat (20) @(negedge clk);

        $display("========================================");
        $display("各级像素数: 高斯=%0d/%0d 中值=%0d/%0d CSC=%0d/%0d 输出=%0d/%0d",
                 gau_cnt, G_CNT, med_cnt, M_CNT, csc_cnt, C_CNT, out_cnt, OUT_CNT);
        if (err_cnt == 0 && gau_cnt == G_CNT && med_cnt == M_CNT &&
            csc_cnt == C_CNT && out_cnt == OUT_CNT && done_seen)
            $display("[PASS] chain OK: 四级级联像素数全部匹配（%0dx%0d → %0dx%0d 放大%0d 倍）",
                     IN_W, IN_H, OUT_W, OUT_H, 2);
        else
            $display("[FAIL] err=%0d 各级=%0d/%0d/%0d/%0d done_seen=%0d", err_cnt, gau_cnt, med_cnt, csc_cnt, out_cnt, done_seen);
        $fclose(f_gau); $fclose(f_med); $fclose(f_csc); $fclose(f_out);
        $finish;
    end

    //---- 超时兜底（含停滞点调试打印）----
    integer fifo_rd = 0, cache_wr = 0;
    always @(posedge clk) begin
        if (dut.u_fifo.rd_en) fifo_rd = fifo_rd + 1;
        if (dut.u_scaler.din_valid && dut.u_scaler.in_ready) cache_wr = cache_wr + 1;
    end
    initial begin
        #(1200000);   // 缩短预算快速定位停滞
        $display("[FAIL] simulation timeout");
        $display("DEBUG 计数 gau=%0d med=%0d csc=%0d out=%0d", gau_cnt, med_cnt, csc_cnt, out_cnt);
        $display("DEBUG 主FIFO count=%0d rd=%0d cache写=%0d", dut.u_fifo.count, fifo_rd, cache_wr);
        $display("DEBUG coord.sy=%0d done=%0d cache.w=%0d rd_ready=%0d",
                 dut.u_scaler.u_coord.src_y_int, dut.u_scaler.u_coord.done,
                 dut.u_scaler.u_cache.w, dut.u_scaler.u_cache.rd_ready);
        $display("DEBUG 适配器A cnt=%0d nonempty=%0d state=%0d col=%0d row=%0d",
                 dut.g_pad.g_pad_g_first.u_adap0.cnt,
                 dut.g_pad.g_pad_g_first.u_adap0.fifo_nowempty,
                 dut.g_pad.g_pad_g_first.u_adap0.state,
                 dut.g_pad.g_pad_g_first.u_adap0.col_cnt,
                 dut.g_pad.g_pad_g_first.u_adap0.row_cnt);
        $finish;
    end

endmodule