// ============================================================================
// tb_awb_gain.v —— M6 Step 2 增益应用级自检 TB
//
// 场景：A 恒等 2 帧（满速）/ B 帧边界 2 帧（帧中改写口）/
//       C 反压 2 帧（随机 ready）/ D 长拉低 2 帧 / E 运行中复位 -> 重收 1 帧
//
// ★ 帧增益表 TAB（与 make_awb_data.py 同一约定）：
//   帧 f 的期望 = 全部像素（含首像素）按 TAB[f] 应用；
//   TB 在「帧 f 发送过半」时把写口切到 TAB[f+1]（切点必落在帧中部——
//   专门证明"帧内改写口不影响本帧、下个 SOF 起从首像素用新值"）。
//
// 期望来源：make_awb_data.py 预生成
//   awb_in_small.hex    8 帧 × 16×12（RAW10）
//   awb_gain_exp.hex    8 帧逐像素期望输出（按 TAB 应用，含首像素）
//
// 判据：位级比对（rcv 索引，含饱和/极值 case）+ sof/eol + 帧首追踪打印
//       + 复位段恒等恢复（写口回 1.0）+ 反压稳定 + 收发计数一致
// 落盘：gain_out.txt（出侧像素序列，供 verify_awb.py 独立复算）
// ============================================================================
`timescale 1ns/1ps
`include "awb_gain.v"

module tb_awb_gain;

    localparam IMG_W = 16, IMG_H = 12, DW = 10;
    localparam TOTAL = IMG_W * IMG_H;        // 192
    localparam FRAMES = 8;
    localparam SEG2 = 2*TOTAL;               // 复位段重发 2 帧

    reg  aclk = 0, aresetn = 0;
    always #5 aclk = ~aclk;

    // ---------------- DUT ----------------
    reg  [DW-1:0] in_data;
    reg           in_sof, in_eol;
    reg  [1:0]    in_phase;
    wire          in_valid;                  // 源模型 assign
    wire          in_ready;
    reg  [9:0]    wr_00 = 256, wr_01 = 256, wr_10 = 256, wr_11 = 256;  // 写口
    wire          out_valid, out_sof, out_eol;
    wire          out_ready;                 // 汇模型 assign
    wire [DW-1:0] out_data;

    awb_gain #(.DW(DW), .GW(10), .GF(8)) dut (
        .clk(aclk), .rst_n(aresetn),
        .gain_00(wr_00), .gain_01(wr_01), .gain_10(wr_10), .gain_11(wr_11),
        .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data),
        .in_sof(in_sof), .in_eol(in_eol), .in_phase(in_phase),
        .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data),
        .out_sof(out_sof), .out_eol(out_eol)
    );

    // ---------------- 数据加载 ----------------
    reg [DW-1:0] src [0:FRAMES*TOTAL-1];
    reg [DW-1:0] exp [0:FRAMES*TOTAL-1];
    initial begin
        $readmemh("awb_in_small.hex", src);
        $readmemh("awb_gain_exp.hex", exp);
    end

    // ---------------- 帧增益表（与 make_awb_data.py 的 TAB 一致）----------------
    reg [9:0] tab [0:31];
    initial begin
        tab[0] = 256; tab[1] = 256; tab[2] = 256; tab[3] = 256;          // f0
        tab[4] = 384; tab[5] = 320; tab[6] = 300; tab[7] = 512;          // f1
        tab[8] = 128; tab[9] = 1023; tab[10] = 200; tab[11] = 1;         // f2
        tab[12] = 256; tab[13] = 256; tab[14] = 256; tab[15] = 256;      // f3
        tab[16] = 512; tab[17] = 512; tab[18] = 384; tab[19] = 256;      // f4
        tab[20] = 256; tab[21] = 256; tab[22] = 256; tab[23] = 256;      // f5
        tab[24] = 1023; tab[25] = 1023; tab[26] = 1023; tab[27] = 1023;  // f6
        tab[28] = 256; tab[29] = 256; tab[30] = 256; tab[31] = 256;      // f7
    end

    // ---------------- 源模型（含相位）----------------
    integer imode = 0, ngen = 0, snd_limit = 2*TOTAL;
    reg     ph_r, ph_c;                      // 行/列奇偶（1bit 定宽，拼接用）
    reg     src_vld = 0, start = 0;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) src_vld <= 1'b0;
        else begin
            if (!src_vld) begin
                if (start && ngen < snd_limit &&
                    (imode == 0 || (({$random} % 1000) < 700))) begin
                    ph_r     = (ngen / IMG_W) & 1;
                    ph_c     = (ngen % IMG_W) & 1;
                    in_data  <= src[ngen];
                    in_sof   <= (ngen % TOTAL == 0);
                    in_eol   <= ((ngen % IMG_W) == IMG_W - 1);
                    in_phase <= {ph_r, ph_c};
                    src_vld  <= 1'b1;
                    ngen     <= ngen + 1;
                end
            end else if (in_ready) begin
                if (ngen < snd_limit) begin
                    ph_r     = (ngen / IMG_W) & 1;
                    ph_c     = (ngen % IMG_W) & 1;
                    in_data  <= src[ngen];
                    in_sof   <= (ngen % TOTAL == 0);
                    in_eol   <= ((ngen % IMG_W) == IMG_W - 1);
                    in_phase <= {ph_r, ph_c};
                    ngen     <= ngen + 1;
                end else src_vld <= 1'b0;    // 到限额真正撤 valid（排空语义）
            end
        end
    end
    assign in_valid = src_vld;

    // ---------------- 汇模型 ----------------
    integer omode = 0, drop_cnt = 0;
    reg     rdy_r = 0;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin rdy_r <= 0; drop_cnt <= 0; end
        else if (omode == 0) rdy_r <= 1'b1;
        else if (omode == 1) rdy_r <= (({$random} % 1000) < 500);
        else begin
            if (drop_cnt > 0) begin drop_cnt <= drop_cnt - 1; rdy_r <= 0; end
            else if (({$random} % 1000) < 20) begin
                drop_cnt <= 40 + ({$random} % 200); rdy_r <= 0;
            end
            else rdy_r <= 1'b1;
        end
    end
    assign out_ready = rdy_r;

    // ---------------- 记分板 ----------------
    integer snd_cnt = 0, rcv_cnt = 0, err_cnt = 0;
    integer kk;
    reg [DW-1:0] od_q;
    reg     ov_q = 0, orq_q = 0;
    integer fd, nf_print = 0;
    reg [DW-1:0] cmp_exp;
    integer idx;

    always @(posedge aclk) begin
        #1;
        if (aresetn && start && in_valid && in_ready) begin
            snd_cnt = snd_cnt + 1;
        end
        // ---- 写口切换：帧 f 发送过半 → 下一帧的 TAB（snd_cnt 命中帧中部）----
        if (aresetn && (snd_cnt % TOTAL) == TOTAL/2 &&
            snd_cnt < (FRAMES-1)*TOTAL) begin
            kk = snd_cnt / TOTAL + 1;
            wr_00 <= tab[kk*4];
            wr_01 <= tab[kk*4+1];
            wr_10 <= tab[kk*4+2];
            wr_11 <= tab[kk*4+3];
        end
        // ---- 位级比对 ----
        if (out_valid && out_ready && start) begin
            idx = (rcv_cnt < FRAMES*TOTAL) ? rcv_cnt : (rcv_cnt - FRAMES*TOTAL);
            cmp_exp = (rcv_cnt < FRAMES*TOTAL) ? exp[idx] : src[idx];  // 复位段=恒等
            $fwrite(fd, "%03X\n", out_data);
            if (out_data !== cmp_exp) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8)
                    $display("MISMATCH @%0t #%0d: got=%03X exp=%03X",
                             $time, idx, out_data, cmp_exp);
            end
            if (out_sof !== (idx % TOTAL == 0)) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8) $display("SOF-MISMATCH @%0t #%0d", $time, idx);
            end
            if (out_eol !== ((idx % IMG_W) == IMG_W - 1)) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8) $display("EOL-MISMATCH @%0t #%0d", $time, idx);
            end
            // ---- 帧首追踪打印（人工可读：帧首用了哪组增益）----
            if ((idx % TOTAL) == 0 && nf_print < 12) begin
                $display("FRAME %0d SOF: wr=(%0d,%0d,%0d,%0d) out=%03X exp=%03X",
                         idx / TOTAL, wr_00, wr_01, wr_10, wr_11, out_data, cmp_exp);
                nf_print = nf_print + 1;
            end
            rcv_cnt = rcv_cnt + 1;
        end
        // ---- 反压期输出稳定断言（★ 用上一拍的 ready）----
        if (ov_q && !orq_q && out_valid && (out_data !== od_q)) begin
            err_cnt = err_cnt + 1;
            if (err_cnt <= 8) $display("STABLE-VIOLATION @%0t: %03X -> %03X",
                                       $time, od_q, out_data);
        end
        ov_q  = out_valid;
        orq_q = out_ready;
        od_q  = out_data;
    end

    // ---------------- 场景流程 ----------------
    initial begin
        fd = $fopen("gain_out.txt", "w");     // ★ 单句柄在同一 initial 打开
`ifndef NOVCD
        $dumpfile("tb_awb_gain.vcd");
        $dumpvars(0, tb_awb_gain);
`endif
        aresetn = 0;
        repeat (10) @(posedge aclk);
        aresetn = 1;
        repeat (5) @(posedge aclk);

        $display("=== 场景A：恒等 2 帧（满速，写口=256）===");
        imode = 0; omode = 0; ngen = 0; snd_limit = 2*TOTAL; start = 1;
        while (rcv_cnt < 2*TOTAL) @(posedge aclk);

        $display("=== 场景B：帧边界 2 帧（帧中改写口，下帧起含首像素生效）===");
        snd_limit = 4*TOTAL;
        while (rcv_cnt < 4*TOTAL) @(posedge aclk);

        $display("=== 场景C：反压 2 帧（随机 ready）===");
        omode = 1; snd_limit = 6*TOTAL;
        while (rcv_cnt < 6*TOTAL) @(posedge aclk);

        $display("=== 场景D：长拉低 2 帧 ===");
        omode = 2; snd_limit = 8*TOTAL;
        while (rcv_cnt < 8*TOTAL) @(posedge aclk);

        $display("=== 场景E：运行中复位 -> 释放 -> 重收 2 帧（写口回 1.0）===");
        start = 0;
        while (out_valid === 1'b1) @(posedge aclk);
        repeat (8) @(posedge aclk);
        aresetn = 0;
        repeat (10) @(posedge aclk);
        aresetn = 1;                          // 复位释放：写口被复位回 256
        repeat (5) @(posedge aclk);
        ngen = 0; imode = 0; omode = 0; snd_limit = SEG2; start = 1;
        while (rcv_cnt < 8*TOTAL + SEG2) @(posedge aclk);
        start = 0;

        repeat (20) @(posedge aclk);
        $fclose(fd);
        $display("========================================");
        if (snd_cnt != 8*TOTAL + SEG2 || rcv_cnt != 8*TOTAL + SEG2) err_cnt = err_cnt + 1;
        $display("入侧 fire %0d 出侧收 %0d —— 反压丢数检查：%s",
                 snd_cnt, rcv_cnt, (err_cnt == 0) ? "一致" : "不一致[ERR]");
        if (err_cnt == 0)
            $display("[PASS] awb_gain：位级比对 + 帧边界（含首像素）+ 复位恒等 全通过");
        else
            $display("[FAIL] err=%0d", err_cnt);
        $finish;
    end

    // ---------------- 超时兜底 ----------------
    initial begin
        #(12 * TOTAL * 2000 + 5000000);
        $display("[FAIL] timeout snd=%0d rcv=%0d err=%0d", snd_cnt, rcv_cnt, err_cnt);
        $finish;
    end

endmodule