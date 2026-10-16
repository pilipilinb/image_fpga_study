// ============================================================================
// tb_awb_stat.v —— M6 Step 1 统计级自检 TB
//
// 五场景：A 满速 2 帧 / B 入侧随机 2 帧 / C 汇长拉低 2 帧（反压不重复计数专项）
//         / D 双向随机 2 帧 / E 运行中复位→释放→重收 2 帧
//
// 期望来源：make_awb_data.py 预生成
//   awb_in_small.hex   8 帧 × 16×12（RAW10）
//   awb_stat_exp.hex   8 帧 × 4 相位和（32bit）
//
// 判据：
//   ① 透传恒等断言：out_data/sof/eol/phase/valid ≡ in_*（0 拍直连，每拍检查）
//   ② 封存点比对：每帧 SOF fire 的下一拍，stat_xx / frame_cnt vs 期望
//      （段内帧 0 封存初值 0；帧 f 封存帧 f-1 全量）
//   ③ irq：恰 1 拍宽，且只出现在"帧首 fire 的下一拍"
//   ④ 复位归零：运行中复位期间 stat/fc/irq 全 0；重收后行为与首次一致
//   ⑤ 收发计数一致（10 帧 = 8 正常 + 2 复位重发）
//   落盘：stat_out.txt（出侧像素序列，供 verify_awb.py 独立复算）
//         stat_shadow.txt（封存点序列：fc + 4 个和，供 verify 复算）
// ============================================================================
`timescale 1ns/1ps
`include "awb_stat.v"

module tb_awb_stat;

    localparam IMG_W = 16, IMG_H = 12, DW = 10;
    localparam TOTAL = IMG_W * IMG_H;        // 192
    localparam FRAMES = 8;

    reg  aclk = 0, aresetn = 0;
    always #5 aclk = ~aclk;

    // ---------------- DUT ----------------
    reg  [DW-1:0] in_data;
    reg           in_sof, in_eol;
    reg  [1:0]    in_phase;
    wire          in_valid;                  // 源模型 assign
    wire          in_ready;
    wire          out_valid, out_sof, out_eol;
    wire [1:0]    out_phase;
    wire          out_ready;                 // 汇模型 assign
    wire [DW-1:0] out_data;
    wire [31:0]   stat_00, stat_01, stat_10, stat_11, frame_cnt;
    wire          irq;

    awb_stat #(.DW(DW)) dut (
        .clk(aclk), .rst_n(aresetn),
        .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data),
        .in_sof(in_sof), .in_eol(in_eol), .in_phase(in_phase),
        .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data),
        .out_sof(out_sof), .out_eol(out_eol), .out_phase(out_phase),
        .stat_00(stat_00), .stat_01(stat_01), .stat_10(stat_10), .stat_11(stat_11),
        .frame_cnt(frame_cnt), .irq(irq)
    );

    // ---------------- 数据加载 ----------------
    reg [DW-1:0] src [0:FRAMES*TOTAL-1];
    reg [31:0]   exp_sum [0:FRAMES*4-1];
    initial begin
        $readmemh("awb_in_small.hex", src);
        $readmemh("awb_stat_exp.hex", exp_sum);
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
    integer snd_cnt = 0, rcv_cnt = 0, err_cnt = 0, snd_idx, seg_base = 0;
    integer cur_fr = 0, cur_fr_q = 0;
    reg     first_pulse = 0, first_pulse_q = 0, irq_q = 0;
    reg [DW-1:0] od_q;
    reg     ov_q = 0, orq_q = 0;
    integer fd_out, fd_sh;
    reg [31:0] expv;
    integer b4;                              // 期望表基索引（防 cur_fr_q=0 时负索引）

    always @(posedge aclk) begin
        #1;
        // ---- 帧首 fire 检测（发送侧；段内帧号 = 封存依据）----
        first_pulse = 1'b0;
        if (aresetn && start && in_valid && in_ready) begin
            snd_idx = snd_cnt;
            snd_cnt = snd_cnt + 1;
            if (((snd_idx - seg_base) % TOTAL) == 0) begin
                first_pulse = 1'b1;
                cur_fr = (snd_idx - seg_base) / TOTAL;
            end
        end
        // ---- 封存点比对（上一拍 SOF fire ⇒ 本拍 shadow/fc 已更新）----
        if (first_pulse_q) begin
            b4 = (cur_fr_q == 0) ? 0 : (cur_fr_q - 1) * 4;
            expv = (cur_fr_q == 0) ? 32'd0 : exp_sum[b4];
            if (stat_00 !== expv) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8) $display("STAT-MISMATCH @%0t fr=%0d p00: got=%08X exp=%08X",
                                           $time, cur_fr_q, stat_00, expv);
            end
            expv = (cur_fr_q == 0) ? 32'd0 : exp_sum[b4+1];
            if (stat_01 !== expv) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8) $display("STAT-MISMATCH @%0t fr=%0d p01: got=%08X exp=%08X",
                                           $time, cur_fr_q, stat_01, expv);
            end
            expv = (cur_fr_q == 0) ? 32'd0 : exp_sum[b4+2];
            if (stat_10 !== expv) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8) $display("STAT-MISMATCH @%0t fr=%0d p10: got=%08X exp=%08X",
                                           $time, cur_fr_q, stat_10, expv);
            end
            expv = (cur_fr_q == 0) ? 32'd0 : exp_sum[b4+3];
            if (stat_11 !== expv) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8) $display("STAT-MISMATCH @%0t fr=%0d p11: got=%08X exp=%08X",
                                           $time, cur_fr_q, stat_11, expv);
            end
            if (frame_cnt !== (cur_fr_q + 1)) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8) $display("FC-MISMATCH @%0t fr=%0d: got=%0d exp=%0d",
                                           $time, cur_fr_q, frame_cnt, cur_fr_q + 1);
            end
            $display("SEAL fr=%0d fc=%0d stat=(%08X,%08X,%08X,%08X)",
                     cur_fr_q, frame_cnt, stat_00, stat_01, stat_10, stat_11);
            $fwrite(fd_sh, "%0d %08X %08X %08X %08X\n",
                    frame_cnt, stat_00, stat_01, stat_10, stat_11);
        end
        // ---- irq：恰 1 拍宽，只在帧首 fire 的下一拍 ----
        if (irq === 1'b1) begin
            if (!first_pulse_q) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8) $display("IRQ-POS-VIOLATION @%0t", $time);
            end
            if (irq_q === 1'b1) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8) $display("IRQ-WIDTH-VIOLATION @%0t", $time);
            end
        end
        irq_q        = irq;
        first_pulse_q = first_pulse;
        cur_fr_q     = cur_fr;

        // ---- 透传恒等断言（0 拍直连）----
        if ((out_data !== in_data) || (out_sof !== in_sof) || (out_eol !== in_eol) ||
            (out_phase !== in_phase) || (out_valid !== in_valid)) begin
            err_cnt = err_cnt + 1;
            if (err_cnt <= 8) $display("THRU-VIOLATION @%0t", $time);
        end

        // ---- 出侧 fire 计数 + 落盘 ----
        if (out_valid && out_ready) begin
            rcv_cnt = rcv_cnt + 1;
            $fwrite(fd_out, "%03X\n", out_data);
        end

        // ---- 复位保持期：stat/fc/irq 必须全 0 ----
        if (!aresetn) begin
            if (stat_00 !== 32'd0 || stat_01 !== 32'd0 || stat_10 !== 32'd0 ||
                stat_11 !== 32'd0 || frame_cnt !== 32'd0 || irq !== 1'b0) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8) $display("RST-NOT-ZERO @%0t", $time);
            end
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
        // ★ 两个 $fopen 放同一个 initial（M4-3 教训：分开 fopen 后一个句柄写入会丢）
        fd_out = $fopen("stat_out.txt", "w");
        fd_sh  = $fopen("stat_shadow.txt", "w");
`ifndef NOVCD
        $dumpfile("tb_awb_stat.vcd");
        $dumpvars(0, tb_awb_stat);
`endif
        aresetn = 0;
        repeat (10) @(posedge aclk);
        aresetn = 1;
        repeat (5) @(posedge aclk);

        $display("=== 场景A：满速 2 帧 ===");
        imode = 0; omode = 0; ngen = 0; snd_limit = 2*TOTAL; start = 1;
        while (rcv_cnt < 2*TOTAL) @(posedge aclk);

        $display("=== 场景B：入侧随机 70%% 2 帧 ===");
        imode = 1; snd_limit = 4*TOTAL;
        while (rcv_cnt < 4*TOTAL) @(posedge aclk);

        $display("=== 场景C：汇长拉低 2 帧（反压不重复计数专项）===");
        imode = 0; omode = 2; snd_limit = 6*TOTAL;
        while (rcv_cnt < 6*TOTAL) @(posedge aclk);

        $display("=== 场景D：双向随机 2 帧 ===");
        imode = 1; omode = 1; snd_limit = 8*TOTAL;
        while (rcv_cnt < 8*TOTAL) @(posedge aclk);

        $display("=== 场景E：运行中复位 -> 释放 -> 重收 2 帧 ===");
        start = 0;
        while (out_valid === 1'b1) @(posedge aclk);
        repeat (8) @(posedge aclk);
        aresetn = 0;
        repeat (10) @(posedge aclk);          // 复位保持期：记分板逐拍查归零
        aresetn = 1;
        repeat (5) @(posedge aclk);
        seg_base = snd_cnt;                   // 段内帧号从这里重新起算
        ngen = 0; imode = 0; omode = 0; snd_limit = 2*TOTAL; start = 1;
        while (rcv_cnt < 10*TOTAL) @(posedge aclk);
        start = 0;

        repeat (20) @(posedge aclk);
        $fclose(fd_out);
        $fclose(fd_sh);
        $display("========================================");
        if (snd_cnt != 10*TOTAL || rcv_cnt != 10*TOTAL) err_cnt = err_cnt + 1;
        $display("入侧 fire %0d 出侧收 %0d —— 反压丢数检查：%s",
                 snd_cnt, rcv_cnt, (err_cnt == 0) ? "一致" : "不一致[ERR]");
        if (err_cnt == 0)
            $display("[PASS] awb_stat：透传恒等 + 封存比对 + irq + 复位归零 全通过");
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