//========================================================================
// tb_ccm.v —— M4-2 CCM 自检 TB（协议四场景 + bypass 帧间/帧内切换 + IMG）
//
// 期望由 make_ccm_data.py 预生成（Python 位级同构）：
//   -DIMG → ccm_in.hex / exp_img.hex
//   否则  → src_small.hex / exp_small.hex（5 帧）
//
// 场景：
//   A 满速 2 帧 / B 汇随机 50% / C 汇长拉低 / D 双向随机   （bypass=0 处理路径）
//   E bypass 帧间切换 ×3 段（不排空、不停源 —— 等延迟旁路的能力）
//   F **帧中间热切换**（降噪做不到，CCM 等延迟旁路可以）
//
// 判据：逐拍位级比对（期望路径由"当拍 bypass 值"选 src/exp）+ sof/eol 位置 +
//       反压期输出稳定性 + 收发计数一致（0 误差才算 PASS）
//========================================================================
`timescale 1ns/1ps
`include "ccm_stage.v"

// 单帧模式（IMG=真图 / CHART=24 色卡拼接图）共用一套流程
`ifdef IMG
`define SINGLE_FRAME
`endif
`ifdef CHART
`define SINGLE_FRAME
`endif

module tb_ccm;

`ifdef IMG
    localparam IMG_W = 112, IMG_H = 103;
`elsif CHART
    localparam IMG_W = 96,  IMG_H = 64;      // 6 块宽 × 4 块高，每块 16×16
`else
    localparam IMG_W = 16,  IMG_H = 12;
`endif
    localparam DW    = 10;
    localparam CW    = 3*DW;
    localparam TOTAL = IMG_W * IMG_H;
`ifdef SINGLE_FRAME
    localparam NFRAME = 1;
`else
    localparam NFRAME = 5;
`endif

    reg  aclk = 0, aresetn = 0;
    always #5 aclk = ~aclk;

    // ---------------- DUT ----------------
    reg  [CW-1:0] in_data;
    reg           in_sof, in_eol, bypass = 1'b0;
    wire          in_valid;               // 源模型 assign
    wire          in_ready;
    wire          out_valid, out_sof, out_eol;
    wire          out_ready;              // 汇模型 assign
    wire [CW-1:0] out_data;

    ccm_stage #(.DW(DW), .FRAC(12)) dut (
        .clk(aclk), .rst_n(aresetn),
        .bypass(bypass),
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
        $readmemh("ccm_in.hex", src);
        $readmemh("exp_img.hex", exp);
`elsif CHART
        $readmemh("chart_in.hex", src);
        $readmemh("chart_exp_tile.hex", exp);
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
    integer snd_limit = 960;        // 段内发送限额（每段推到即撤 valid）
    reg     src_vld = 0;
    reg     start = 0;              // 发送门控（场景计数清零后才开闸，防清零竞态）

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
                end else src_vld <= 1'b0;   // 到限额真正撤 valid
            end
        end
    end
    assign in_valid = src_vld;

    // ---------------- 汇模型 ----------------
    integer omode = 0;              // 0=常收 1=随机50% 2=长拉低
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
    //   索引：A~D 用全局 rcv_cnt（5 帧连续）；E/F 段用段内 sidx（每段重放第 0 帧）
    //   路径：用**当拍 bypass 值**选 src（旁路）或 exp（处理）——等延迟旁路使这成立
    integer snd_cnt = 0, rcv_cnt = 0, err_cnt = 0;
    integer sidx = 0;
    reg     e_mode = 0;
    integer dbg_n = 0;
    reg [CW-1:0] cmp_exp, out_data_q;
    reg          ov_q = 0, rdy_q = 0;
    integer fd;
`ifdef IMG
    initial fd = $fopen("ccm_out_img.txt", "w");
`elsif CHART
    initial fd = $fopen("ccm_out_chart.txt", "w");
`else
    initial fd = $fopen("ccm_out.txt", "w");
`endif
    always @(posedge aclk) begin
        #1;
        if (aresetn && start && in_valid && in_ready) begin
            snd_cnt = snd_cnt + 1;
            if (dbg_n < 8) begin
                $display("DBG-SND t=%0t n=%0d data=%07X sof=%b eol=%b",
                         $time, snd_cnt-1, in_data, in_sof, in_eol);
                dbg_n = dbg_n + 1;
            end
        end
        if (out_valid && out_ready && start) begin
            cmp_exp = bypass ? src[e_mode ? sidx : rcv_cnt] : exp[e_mode ? sidx : rcv_cnt];
            if (!bypass) $fwrite(fd, "%08X\n", out_data);   // 处理路径输出落盘（供 verify 复算）
            if (out_data !== cmp_exp) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8)
                    $display("MISMATCH @%0t #%0d (bp=%b): got=%07X exp=%07X",
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
            rcv_cnt = rcv_cnt + 1;
            if (e_mode) sidx = sidx + 1;
        end
        // 反压期输出稳定性断言（简流铁律）：**上一拍** valid=1 且 ready=0（stall）
        // ⇒ 本拍若仍 valid，字段必须原地保持（★ 用上一拍的 ready，不能用当拍的）
        if (ov_q && !rdy_q && out_valid && (out_data !== out_data_q)) begin
            err_cnt = err_cnt + 1;
            if (err_cnt <= 8) $display("STABLE-VIOLATION @%0t: %07X -> %07X", $time, out_data_q, out_data);
        end
        ov_q = out_valid;
        rdy_q = out_ready;
        out_data_q = out_data;
    end

    // ---------------- 场景流程 ----------------
    initial begin
`ifndef NOVCD
        $dumpfile("tb_ccm.vcd");
        $dumpvars(0, tb_ccm);
`endif
        aresetn = 0;
        repeat (10) @(posedge aclk);
        aresetn = 1;
        repeat (5) @(posedge aclk);

`ifdef SINGLE_FRAME
        $display("=== 单帧模式（IMG/CHART）：连续流 1 帧 ===");
        imode = 0; omode = 0; bypass = 0;
        snd_limit = TOTAL; start = 1;
        while (rcv_cnt < TOTAL) @(posedge aclk);
        start = 0;
`else
        $display("=== 场景A：满速 2 帧 ===");
        imode = 0; omode = 0; bypass = 0;
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

        // ---- E/F：bypass 三段 + 帧内热切换（等延迟旁路 ⇒ 无需排空）----
        $display("=== 场景E：bypass 帧间切换 3 段（不排空/不停源）===");
        e_mode = 1; omode = 0; imode = 0;
        ngen = 0; sidx = 0; bypass = 1; snd_limit = TOTAL;
        while (sidx < TOTAL) @(posedge aclk);          // E1 旁路帧
        ngen = 0; sidx = 0; bypass = 0;                // ★ 直接切，不排空
        while (sidx < TOTAL) @(posedge aclk);          // E2 处理帧（核路径回归）
        ngen = 0; sidx = 0; bypass = 1;                // ★ 再切回
        while (sidx < TOTAL) @(posedge aclk);          // E3 旁路帧

        $display("=== 场景F：帧中间热切换（降噪做不到）===");
        ngen = 0; sidx = 0; bypass = 0; snd_limit = TOTAL;
        repeat (TOTAL/2) @(posedge aclk);              // 发到半帧
        bypass = 1;                                    // ★ 帧中间切
        while (sidx < TOTAL) @(posedge aclk);
        start = 0;
`endif

        repeat (20) @(posedge aclk);
        $fclose(fd);
        $display("========================================");
`ifdef SINGLE_FRAME
        if (snd_cnt != TOTAL || rcv_cnt != TOTAL) err_cnt = err_cnt + 1;
`else
        // A~D 5 帧 + E 3 段 + F 1 段 = 9 段
        if (snd_cnt != 9*TOTAL || rcv_cnt != 9*TOTAL) err_cnt = err_cnt + 1;
`endif
        $display("入侧 fire %0d 出侧收 %0d —— 反压丢数检查：%s",
                 snd_cnt, rcv_cnt, (err_cnt == 0) ? "一致" : "不一致[ERR]");
        if (err_cnt == 0)
            $display("[PASS] ccm：期望比对全等（0 误差）+ 反压稳定 + bypass 帧间/帧内切换一致");
        else
            $display("[FAIL] err=%0d", err_cnt);
        $finish;
    end

    // ---------------- 超时兜底 ----------------
    initial begin
        #(NFRAME * TOTAL * 2000 + 5000000);
        $display("[FAIL] timeout snd=%0d rcv=%0d err=%0d", snd_cnt, rcv_cnt, err_cnt);
        $finish;
    end

endmodule
