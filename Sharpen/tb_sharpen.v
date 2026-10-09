//========================================================================
// tb_sharpen.v —— M5.1 锐化自检 TB（协议四场景 + bypass 三段 + IMG）
//
// 期望由 make_sharpen_data.py 预生成（Python 位级同构）：
//   -DIMG → sharpen_in.hex（Gamma 出 RGB888）/ exp_img.hex（锐化出）
//   -DK64 → src_small.hex / exp_small_k64.hex（kg=64，验证 k 端口）
//   否则  → src_small.hex / exp_small.hex（kg=128，5 帧）
//   -DHARD → 硬切对照实验（**不比对 golden**）：主路跑到帧中间、不排空不停源直接切 bypass，
//            量 out_sof 间隔（= 帧长）—— 稳态恒 192，硬切那一帧变 171（少 21 = 主路延迟）
//
// 场景（small 模式 5 帧）：A 满速 2 帧 / B 汇随机 50% / C 长拉低 / D 双向随机 / E bypass
// IMG 模式：单帧连续流，只做期望比对
//
// 判据：逐拍位级比对（路径由当拍 bypass 选）+ sof/eol + 反压稳定性（用上一拍 ready）
//       + 收发计数一致
//========================================================================
`timescale 1ns/1ps
`include "sharpen_stage.v"

module tb_sharpen;

`ifdef IMG
    localparam IMG_W = 112, IMG_H = 103;
`else
    localparam IMG_W = 16,  IMG_H = 12;
`endif
    localparam DW    = 8;
    localparam CW    = 3*DW;            // 打包位宽 24bit
    localparam TOTAL = IMG_W * IMG_H;
`ifdef IMG
    localparam NFRAME = 1;
`else
    localparam NFRAME = 5;
`endif
// ---- 锐化强度：k = kg / 256 ----
`ifdef K64
    localparam [9:0] KG = 10'd64;
`else
    localparam [9:0] KG = 10'd128;
`endif

    reg  aclk = 0, aresetn = 0;
    always #5 aclk = ~aclk;

    // ---------------- DUT ----------------
    reg  [CW-1:0] in_data;
    reg           in_sof, in_eol, bypass = 1'b0;
    reg  [9:0]    kg = KG;
    wire          in_valid;              // 源模型 assign
    wire          in_ready;
    wire          out_valid, out_sof, out_eol;
    wire          out_ready;             // 汇模型 assign
    wire [CW-1:0] out_data;

    sharpen_stage #(.DW(DW), .IMG_W(IMG_W), .IMG_H(IMG_H), .N(3),
                    .KW(10), .K_FRAC(8)) dut (
        .clk(aclk), .rst_n(aresetn),
        .bypass(bypass), .k_gain(kg),
        .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data),
        .in_sof(in_sof), .in_eol(in_eol),
        .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data),
        .out_sof(out_sof), .out_eol(out_eol)
    );

    // ---------------- 数据加载 ----------------
    reg [CW-1:0] src [0:NFRAME*TOTAL-1];
    reg [CW-1:0] exp [0:NFRAME*TOTAL-1];
    integer gi;
    initial begin
`ifdef IMG
        $readmemh("sharpen_in.hex", src);
        $readmemh("exp_img.hex", exp);
`elsif K64
        $readmemh("src_small.hex", src);
        $readmemh("exp_small_k64.hex", exp);
`else
        $readmemh("src_small.hex", src);
        $readmemh("exp_small.hex", exp);
`endif
        for (gi = 0; gi < NFRAME*TOTAL; gi = gi + 1) begin
            if (src[gi] === {CW{1'bx}}) src[gi] = {CW{1'b0}};
            if ( exp[gi] === {CW{1'bx}})  exp[gi] = {CW{1'b0}};
        end
    end

    // ---------------- 源模型 ----------------
    integer imode = 0;              // 0=连续 1=随机70%
    integer ngen = 0;
    integer snd_limit = 960;        // 发送限额：ngen 达到即停（E 场景按段推进）
    reg     src_vld = 0;
    reg     start = 0;              // 发送门控：场景完成计数清零后才开闸（防清零竞态）

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) src_vld <= 1'b0;
        else begin
            if (!src_vld) begin
                if (start && ngen < snd_limit &&
                    (imode == 0 || (({$random} % 1000) < 700))) begin
                    in_data <= src[ngen];
                    in_sof  <= (ngen % TOTAL == 0);
                    in_eol  <= ((ngen % IMG_W) == IMG_W - 1);
                    src_vld <= 1'b1;
                    ngen    <= ngen + 1;
                end
            end else if (in_ready) begin
                if (ngen < snd_limit) begin
                    in_data <= src[ngen];
                    in_sof  <= (ngen % TOTAL == 0);
                    in_eol  <= ((ngen % IMG_W) == IMG_W - 1);
                    ngen    <= ngen + 1;
                end else src_vld <= 1'b0;   // 到限额真正撤 valid（排空语义）
            end
        end
    end
    assign in_valid = src_vld;

    // ---------------- 汇模型 ----------------
    integer omode = 0;
    reg  rdy_r = 0;
    integer drop_cnt = 0;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin rdy_r <= 0; drop_cnt <= 0; end
        else if (omode == 0) rdy_r <= 1'b1;
        else if (omode == 1) rdy_r <= (({$random} % 1000) < 500);
        else begin
            if (drop_cnt > 0) begin drop_cnt <= drop_cnt - 1; rdy_r <= 0; end
            else if (({$random} % 1000) < 20) begin drop_cnt <= 40 + ({$random} % 200); rdy_r <= 0; end
            else rdy_r <= 1'b1;
        end
    end
    assign out_ready = rdy_r;

    // ---------------- 期望比对 + 记分板 ----------------
    integer snd_cnt = 0, rcv_cnt = 0, err_cnt = 0;
    integer sidx = 0;
    reg     e_mode = 0;                    // E 段标志（期望改用段内索引 sidx）
    integer dbg_n = 0;
    reg [CW-1:0] cmp_exp, out_data_q;
    reg          ov_q = 0, rdy_q = 0;
    integer fd;
`ifdef HARD
    initial fd = $fopen("sharpen_hard.txt", "w");   // 硬切实验单独落盘，不覆盖 IMG 模式的比对数据
`else
    initial fd = $fopen("sharpen_out.txt", "w");
`endif
    always @(posedge aclk) begin
        #1;
        if (aresetn && start && in_valid && in_ready) begin
            snd_cnt = snd_cnt + 1;
            if (dbg_n < 8) begin
                $display("DBG-SND t=%0t n=%0d data=%06X sof=%b eol=%b",
                         $time, snd_cnt-1, in_data, in_sof, in_eol);
                dbg_n = dbg_n + 1;
            end
        end
        if (out_valid && out_ready && start) begin
`ifndef HARD
            cmp_exp = e_mode ? (bypass ? src[sidx] : exp[sidx]) : exp[rcv_cnt];
            if (!bypass && !e_mode) $fwrite(fd, "%06X\n", out_data);
            if (out_data !== cmp_exp) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8)
                    $display("MISMATCH @%0t #%0d (bp=%b): got=%06X exp=%06X",
                             $time, e_mode ? sidx : rcv_cnt, bypass, out_data, cmp_exp);
            end
            if (out_sof !== ((e_mode ? sidx : rcv_cnt) % TOTAL == 0)) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8) $display("SOF-MISMATCH @%0t #%0d", $time, e_mode ? sidx : rcv_cnt);
            end
            if (out_eol !== ((((e_mode ? sidx : rcv_cnt) + 1) % IMG_W) == 0)) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8) $display("EOL-MISMATCH @%0t #%0d", $time, e_mode ? sidx : rcv_cnt);
            end
`else
            // ---- ★ 硬切实验：不比对 golden，只量"相邻两个 out_sof 之间隔了多少拍" ----
            //   稳态下这个间隔恒 = TOTAL（帧长）；硬切那一帧必然 ≠ TOTAL。
            out_fire = out_fire + 1;
            if (out_sof) begin
                if (sof_n > 0) begin            // 第 0 个 SOF 只作基准，不报间隔
                    gap = out_fire - last_sof;
                    if (gap < min_gap) min_gap = gap;
                    if (gap == TOTAL)
                        $display("HARD-SOF #%0d @out_fire=%0d  间隔=%0d  (正常帧长)", sof_n, out_fire, gap);
                    else begin
                        $display("HARD-SOF #%0d @out_fire=%0d  间隔=%0d  <<< 异常帧长！正常应 %0d（少 %0d 个像素；主路延迟 LAT_MAIN=%0d）",
                                 sof_n, out_fire, gap, TOTAL, TOTAL - gap, LAT_MAIN);
                        bad_gap_n = bad_gap_n + 1;
                    end
                end else
                    $display("HARD-SOF #0  @out_fire=%0d  (基准)", out_fire);
                last_sof = out_fire;
                sof_n    = sof_n + 1;
            end
`endif
            rcv_cnt = rcv_cnt + 1;
            if (e_mode) sidx = sidx + 1;
        end
        // 反压期输出稳定性断言（★ 用上一拍的 ready）
        if (ov_q && !rdy_q && out_valid && (out_data !== out_data_q)) begin
            err_cnt = err_cnt + 1;
            if (err_cnt <= 8) $display("STABLE-VIOLATION @%0t: %06X -> %06X", $time, out_data_q, out_data);
        end
        ov_q = out_valid;
        rdy_q = out_ready;
        out_data_q = out_data;
    end

`ifdef HARD
    // ---- ★ 硬切实验的测量量（只在 -DHARD 下编译）----
    integer  out_fire = 0, last_sof = 0, sof_n = 0, bad_gap_n = 0, min_gap = 999999;
    integer  gap;
    // 处理路径总延迟：行缓存 K·W+K（N=3 → K=1 → IMG_W+1）+ stage LAT 3 = IMG_W+4
    localparam LAT_MAIN = (IMG_W + 1) + 3;
`endif

    // ---------------- 场景流程 ----------------
    initial begin
`ifndef NOVCD
        $dumpfile("tb_sharpen.vcd");
        $dumpvars(0, tb_sharpen);
`endif
        aresetn = 0;
        repeat (10) @(posedge aclk);
        aresetn = 1;
        repeat (5) @(posedge aclk);

`ifdef IMG
        $display("=== 场景IMG：连续流 1 帧（RGB888）===");
        imode = 0; omode = 0; bypass = 0; kg = KG;
        snd_limit = TOTAL; start = 1;
        while (rcv_cnt < TOTAL) @(posedge aclk);
        start = 0;
`elsif HARD
        // ★★ 硬切对照实验：主路跑到帧"中间"，不排空、不停源，直接把 bypass 翻成 1
        //    预期：out_sof 的间隔在切换处突然变短（= TOTAL − 主路延迟），
        //    证明那批像素不是"迟到"而是"被跳过"。
        $display("=== 硬切实验：主路跑 2.5 帧 → 帧中间硬切 bypass=1（不排空、上游不停）===");
        $display("    参考值：TOTAL=%0d（正常帧长）, 主路延迟 LAT_MAIN=%0d", TOTAL, LAT_MAIN);
        imode = 0; omode = 0; bypass = 0; kg = KG;
        // 注意：硬切会让"已发出"与"已收到"的计数永久差出 LAT_MAIN 个像素，
        //   所以收数目标必须留足余量（否则输入已发完、输出永远追不上 → 超时兜底）。
        snd_limit = 5*TOTAL; start = 1;
        while (rcv_cnt < 2*TOTAL + TOTAL/2) @(posedge aclk);
        $display(">>> 硬切点 @out_fire=%0d（当前帧才走了 %0d 拍，远未到帧尾）",
                 rcv_cnt, TOTAL/2);
        bypass = 1;                                   // ★ 硬切：不停源、不等排空
        while (rcv_cnt < 4*TOTAL + TOTAL/2) @(posedge aclk);
        start = 0;
`else
        $display("=== 场景A：满速 2 帧（kg=%0d）===", KG);
        imode = 0; omode = 0; bypass = 0; kg = KG;
        snd_limit = 2*TOTAL; start = 1;
        while (rcv_cnt < 2*TOTAL) @(posedge aclk);

        $display("=== 场景B：汇随机 50%% 1 帧 ===");
        imode = 0; omode = 1; snd_limit = 3*TOTAL;
        while (rcv_cnt < 3*TOTAL) @(posedge aclk);

        $display("=== 场景C：汇长拉低 1 帧 ===");
        imode = 0; omode = 2; snd_limit = 4*TOTAL;
        while (rcv_cnt < 4*TOTAL) @(posedge aclk);

        $display("=== 场景D：双向随机 1 帧 ===");
        imode = 1; omode = 1; snd_limit = 5*TOTAL;
        while (rcv_cnt < 5*TOTAL) @(posedge aclk);

        $display("=== 场景E：bypass（每帧独立：发一段→撤 valid→排空→切 bypass→再发）===");
        // ★ bypass 与处理路径延迟不等（bypass 延迟线 vs 行缓存 K·W+K+1 拍），
        //   帧中间切换必然错位——必须"源到限额自动撤 valid → 全链排空 → 切 → 再发"
        e_mode = 1;
        start = 0;
        while (out_valid === 1'b1) @(posedge aclk);
        repeat (8) @(posedge aclk);
        ngen = 0; sidx = 0;
        bypass = 1; imode = 0; omode = 0; snd_limit = TOTAL; kg = KG;
        start = 1;
        while (sidx < TOTAL) @(posedge aclk);          // bypass=1 帧（期望=输入本身）
        start = 0;
        while (out_valid === 1'b1) @(posedge aclk);
        repeat (8) @(posedge aclk);
        ngen = 0; sidx = 0;
        bypass = 0; snd_limit = TOTAL;
        start = 1;
        while (sidx < TOTAL) @(posedge aclk);          // bypass=0 帧（核路径回归验证）
        start = 0;
        while (out_valid === 1'b1) @(posedge aclk);
        repeat (8) @(posedge aclk);
        ngen = 0; sidx = 0;
        bypass = 1; snd_limit = TOTAL;
        start = 1;
        while (sidx < TOTAL) @(posedge aclk);          // bypass=1 帧（再切回验证）
`endif

        repeat (20) @(posedge aclk);
        $fclose(fd);
        $display("========================================");
`ifdef IMG
        if (snd_cnt != TOTAL || rcv_cnt != TOTAL) err_cnt = err_cnt + 1;
`elsif HARD
        // 硬切实验：不做计数比对（输出按设计"跳过"了主路延迟个像素，属预期现象）
        $display("统计：共 %0d 个 out_sof，其中异常帧长 %0d 个，最小间隔 %0d 拍（正常应 %0d）",
                 sof_n, bad_gap_n, min_gap, TOTAL);
`else
        // A~D 共 5 帧 + E 三段各 1 帧 = 8 帧
        if (snd_cnt != 8*TOTAL || rcv_cnt != 8*TOTAL) err_cnt = err_cnt + 1;
`endif
        $display("入侧 fire %0d 出侧收 %0d —— 反压丢数检查：%s",
                 snd_cnt, rcv_cnt, (err_cnt == 0) ? "一致" : "不一致[ERR]");
`ifdef HARD
        $display("[DONE] 硬切实验完成（本模式不做 golden 比对；看上方 HARD-SOF 序列）");
`else
        if (err_cnt == 0)
            $display("[PASS] sharpen：期望比对全等（0 误差）+ bypass 一致 + 反压稳定");
        else
            $display("[FAIL] err=%0d", err_cnt);
`endif
        $finish;
    end

    // ---------------- 超时兜底 ----------------
    initial begin
        #(NFRAME * TOTAL * 2000 + 5000000);
        $display("[FAIL] timeout snd=%0d rcv=%0d err=%0d", snd_cnt, rcv_cnt, err_cnt);
        $finish;
    end

endmodule
