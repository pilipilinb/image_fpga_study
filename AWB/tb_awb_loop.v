// ============================================================================
// tb_awb_loop.v —— M6 Step 3 闭环联调 TB（行为模型软核 + "统计 N → 生效 N+2"）
//
// 数据（Step 0 预生成）：
//   awb_in_img.hex   偏色图 6 帧 × 112×103（RAW10）
//   awb_img_exp.hex  Python 闭环 golden（帧 0/1 用 1.0；帧 2..5 用 conv 增益）
//
// 行为模型软核（= Step 5 软核 C 的 Verilog 替身，位级同构）：
//   轮询 frame_cnt → fc≥2 时读 stat 快照 → 整数除法算增益 → 写写口；
//   硬件在帧首拍采样写口 ⇒ 帧 i 的增益 = 由帧 i-2 的统计算出（N+2 口径）。
//
// Pass 1（正常闭环）：逐像素比对 awb_img_exp.hex（含各帧首像素）。
// Pass 2（容错演练）：复位重跑，软核响应**人为推迟 1 帧**（跳过第一次有效响应）
//   ⇒ 期望 = 帧 0..2 用 1.0（输出=输入本身）；帧 3..5 用 conv 增益（=exp 同值）——
//   验证"生效滑到 N+3、系统不崩、其后恢复正常"；并开随机反压（omode=1）。
//
// 判据：位级 0 误差 + sof/eol + 反压稳定 + 收发计数一致
// 落盘：loop_out.txt（Pass1）/ loop_out_delay.txt（Pass2）——供 verify_awb.py 独立复算
// ============================================================================
`timescale 1ns/1ps
`include "awb_top.v"

module tb_awb_loop;

    localparam W = 112, H = 103, DW = 10;
    localparam TOTAL  = W * H;            // 11536
    localparam NFRAME = 6;
    localparam NPIX   = NFRAME * TOTAL;   // 69216
    localparam CNT    = TOTAL / 4;        // 2884（软核口径：四相位等量假设）

    reg  aclk = 0, aresetn = 0;
    always #5 aclk = ~aclk;

    // ---------------- DUT ----------------
    reg  [DW-1:0] in_data;
    reg           in_sof, in_eol;
    reg  [1:0]    in_phase;
    wire          in_valid;               // 源模型 assign
    wire          in_ready;
    reg  [9:0]    wr_00 = 256, wr_01 = 256, wr_10 = 256, wr_11 = 256;  // 写口
    wire          out_valid, out_sof, out_eol;
    wire          out_ready;              // 汇模型 assign
    wire [DW-1:0] out_data;
    wire [31:0]   st00, st01, st10, st11, fc;
    wire          irq;

    awb_top #(.DW(DW), .GW(10), .GF(8)) dut (
        .clk(aclk), .rst_n(aresetn),
        .gain_00(wr_00), .gain_01(wr_01), .gain_10(wr_10), .gain_11(wr_11),
        .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data),
        .in_sof(in_sof), .in_eol(in_eol), .in_phase(in_phase),
        .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data),
        .out_sof(out_sof), .out_eol(out_eol),
        .stat_00(st00), .stat_01(st01), .stat_10(st10), .stat_11(st11),
        .frame_cnt(fc), .irq(irq)
    );

    // ---------------- 数据加载 ----------------
    reg [DW-1:0] src [0:NPIX-1];
    reg [DW-1:0] exp [0:NPIX-1];
    initial begin
        $readmemh("awb_in_img.hex", src);
        $readmemh("awb_img_exp.hex", exp);
    end

    // ---------------- 行为模型软核（轮询 fc → 读 stat → 算增益 → 写写口）----------------
    integer fc_seen = 0, skip_done = 0, delayed = 0;
    integer m00i, m01i, m10i, m11i, mgi, ti;
    integer g00i, g01i, g10i, g11i;
    always @(posedge aclk) begin
        if (!aresetn) begin
            fc_seen  = 0;
            skip_done = 0;
            wr_00 <= 10'd256; wr_01 <= 10'd256; wr_10 <= 10'd256; wr_11 <= 10'd256;
        end else if (fc != fc_seen) begin
            fc_seen = fc;
            if (fc >= 2) begin
                if (delayed && !skip_done) begin
                    skip_done = 1;                       // ★ 容错演练：推迟 1 帧（跳过本次）
                    $display("SOFT-SKIP fc=%0d（响应推迟 1 帧）", fc);
                end else begin
                    m00i = st00 / CNT;                   // 整数除法（与软核 C / Python 同构）
                    m01i = st01 / CNT;
                    m10i = st10 / CNT;
                    m11i = st11 / CNT;
                    mgi  = (m01i + m10i) >> 1;
                    ti = (mgi << 8) / ((m00i > 0) ? m00i : 1);
                    if (ti < 128) ti = 128; if (ti > 1023) ti = 1023; g00i = ti;
                    ti = (mgi << 8) / ((m01i > 0) ? m01i : 1);
                    if (ti < 128) ti = 128; if (ti > 1023) ti = 1023; g01i = ti;
                    ti = (mgi << 8) / ((m10i > 0) ? m10i : 1);
                    if (ti < 128) ti = 128; if (ti > 1023) ti = 1023; g10i = ti;
                    ti = (mgi << 8) / ((m11i > 0) ? m11i : 1);
                    if (ti < 128) ti = 128; if (ti > 1023) ti = 1023; g11i = ti;
                    wr_00 <= g00i[9:0]; wr_01 <= g01i[9:0];
                    wr_10 <= g10i[9:0]; wr_11 <= g11i[9:0];
                    $display("SOFT-WRITE fc=%0d stat=(%0d,%0d,%0d,%0d) gain=(%0d,%0d,%0d,%0d)",
                             fc, st00, st01, st10, st11, g00i, g01i, g10i, g11i);
                end
            end
        end
    end

    // ---------------- 源模型（含相位）----------------
    integer ngen = 0, snd_limit = NPIX;
    reg     ph_r, ph_c;                   // 行/列奇偶（1bit 定宽，拼接用）
    reg     src_vld = 0, start = 0;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) src_vld <= 1'b0;
        else begin
            if (!src_vld) begin
                if (start && ngen < snd_limit) begin
                    // ★ 相位必须用「帧内局部索引」算：H=103 为奇数 ⇒ 逐帧行奇偶会翻转，
                    //   用全局 ngen 会把奇数帧的相位整体旋转 2（踩过的坑）
                    ph_r     = ((ngen % TOTAL) / W) & 1;
                    ph_c     = (ngen % W) & 1;
                    in_data  <= src[ngen];
                    in_sof   <= (ngen % TOTAL == 0);
                    in_eol   <= ((ngen % W) == W - 1);
                    in_phase <= {ph_r, ph_c};
                    src_vld  <= 1'b1;
                    ngen     <= ngen + 1;
                end
            end else if (in_ready) begin
                if (ngen < snd_limit) begin
                    ph_r     = ((ngen % TOTAL) / W) & 1;
                    ph_c     = (ngen % W) & 1;
                    in_data  <= src[ngen];
                    in_sof   <= (ngen % TOTAL == 0);
                    in_eol   <= ((ngen % W) == W - 1);
                    in_phase <= {ph_r, ph_c};
                    ngen     <= ngen + 1;
                end else src_vld <= 1'b0;    // 到限额真正撤 valid（排空语义）
            end
        end
    end
    assign in_valid = src_vld;

    // ---------------- 汇模型 ----------------
    integer omode = 0;                    // 0=恒 ready 1=随机50%
    reg     rdy_r = 0;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) rdy_r <= 0;
        else if (omode == 0) rdy_r <= 1'b1;
        else rdy_r <= (({$random} % 1000) < 500);
    end
    assign out_ready = rdy_r;

    // ---------------- 记分板 ----------------
    integer snd_cnt = 0, rcv_cnt = 0, err_cnt = 0, pass = 1;
    integer idx, fr_i;
    reg [DW-1:0] cmp_exp, od_q;
    reg     ov_q = 0, orq_q = 0;
    integer fd1, fd2;
    integer okn = 0;

    always @(posedge aclk) begin
        #1;
        if (aresetn && start && in_valid && in_ready) snd_cnt = snd_cnt + 1;

        if (out_valid && out_ready && start) begin
            idx  = rcv_cnt % NPIX;                       // 两遍复用同一 6 帧序列
            fr_i = idx / TOTAL;
            // Pass1：期望 = Python 闭环 golden；Pass2（推迟演练）：帧 0..2 = 输入本身
            cmp_exp = (pass == 2 && fr_i <= 2) ? src[idx] : exp[idx];
            if (pass == 1) $fwrite(fd1, "%03X\n", out_data);
            else           $fwrite(fd2, "%03X\n", out_data);
            if (out_data !== cmp_exp) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8)
                    $display("MISMATCH pass=%0d @%0t #%0d(f%0d): got=%03X exp=%03X",
                             pass, $time, idx, fr_i, out_data, cmp_exp);
            end
            if (out_sof !== (idx % TOTAL == 0)) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8) $display("SOF-MISMATCH @%0t #%0d", $time, idx);
            end
            if (out_eol !== ((idx % W) == W - 1)) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8) $display("EOL-MISMATCH @%0t #%0d", $time, idx);
            end
            if (idx % TOTAL == 0) begin
                $display("OUT-FRAME pass=%0d f%0d done  (已比对 %0d 像素, err=%0d)",
                         pass, fr_i, rcv_cnt + 1, err_cnt);
            end
            rcv_cnt = rcv_cnt + 1;
            okn = okn + 1;
        end

        // 反压期输出稳定断言（★ 用上一拍的 ready）
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
        // ★ 两个 $fopen 放同一个 initial（M4-3 教训）
        fd1 = $fopen("loop_out.txt", "w");
        fd2 = $fopen("loop_out_delay.txt", "w");
`ifndef NOVCD
        $dumpfile("tb_awb_loop.vcd");
        $dumpvars(0, tb_awb_loop);
`endif
        aresetn = 0;
        repeat (10) @(posedge aclk);
        aresetn = 1;
        repeat (5) @(posedge aclk);

        // ================= Pass 1：正常闭环（满速）=================
        $display("=== Pass1：正常闭环 6 帧（N+2：帧2 起用收敛增益）===");
        pass = 1; delayed = 0; omode = 0;
        ngen = 0; snd_limit = NPIX; start = 1;
        while (rcv_cnt < NPIX) @(posedge aclk);
        start = 0;
        repeat (40) @(posedge aclk);

        // ================= Pass 2：复位重跑 + 软核推迟 1 帧（容错演练）=================
        $display("=== Pass2：复位重跑 + 软核响应推迟 1 帧（生效滑到 N+3）+ 随机反压 ===");
        aresetn = 0;
        repeat (10) @(posedge aclk);          // 复位：软核/写口/DUT 全回 1.0
        aresetn = 1;
        repeat (5) @(posedge aclk);
        pass = 2; delayed = 1; omode = 1;
        ngen = 0; snd_limit = NPIX; start = 1;
        while (rcv_cnt < 2 * NPIX) @(posedge aclk);
        start = 0;
        repeat (40) @(posedge aclk);

        $fclose(fd1);
        $fclose(fd2);
        $display("========================================");
        if (snd_cnt != 2 * NPIX || rcv_cnt != 2 * NPIX) err_cnt = err_cnt + 1;
        $display("入侧 fire %0d 出侧收 %0d（各 2×%0d）—— 反压丢数检查：%s",
                 snd_cnt, rcv_cnt, NPIX, (err_cnt == 0) ? "一致" : "不一致[ERR]");
        if (err_cnt == 0)
            $display("[PASS] awb_loop：N+2 闭环位级全等 + 推迟 1 帧容错（滑到 N+3 不崩）+ 反压稳定");
        else
            $display("[FAIL] err=%0d", err_cnt);
        $finish;
    end

    // ---------------- 超时兜底 ----------------
    initial begin
        #(2 * NPIX * 800 + 20000000);
        $display("[FAIL] timeout snd=%0d rcv=%0d err=%0d", snd_cnt, rcv_cnt, err_cnt);
        $finish;
    end

endmodule