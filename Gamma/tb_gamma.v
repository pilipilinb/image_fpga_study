//========================================================================
// tb_gamma.v —— M4-3 Gamma 自检 TB（协议四场景 + bypass 帧间/帧内切换 + RAMP/IMG）
//
// 期望由 make_gamma_data.py 预生成（Python 位级同构）：
//   -DIMG  → gamma_in.hex(30bit)      / exp_img.hex(24bit)
//   -DRAMP → gamma_ramp_in.hex        / gamma_ramp_exp.hex   （1024 值穷举，LUT 全表覆盖）
//   否则   → gamma_small_in.hex       / gamma_small_exp.hex  （5 帧）
//
// ★ 本模块接口"换位宽"：输入 30bit、输出 24bit。bypass 期望不是输入原样，
//   而是"线性 10→8"（bypass 只关曲线、不关位宽缩减）——TB 用 lin8p() 现算期望。
//
// 场景：A 满速 2 帧 / B 汇随机 50% / C 长拉低 / D 双向随机
//       E bypass 帧间切换 ×3 / F 帧中间热切换
// 判据：逐拍位级比对（路径由当拍 bypass 选）+ sof/eol + 反压稳定性 + 收发计数一致
//========================================================================
`timescale 1ns/1ps
`include "gamma_stage.v"

`ifdef IMG
`define SINGLE_FRAME
`endif
`ifdef RAMP
`define SINGLE_FRAME
`endif

module tb_gamma;

`ifdef IMG
    localparam IMG_W = 112, IMG_H = 103;
`elsif RAMP
    localparam IMG_W = 64,  IMG_H = 16;      // 1024 像素 = LUT 全表
`else
    localparam IMG_W = 16,  IMG_H = 12;
`endif
    localparam DW     = 10;
    localparam OW     = 8;
    localparam CW_IN  = 3*DW;                // 30bit
    localparam CW_OUT = 3*OW;                // 24bit
    localparam TOTAL  = IMG_W * IMG_H;
`ifdef SINGLE_FRAME
    localparam NFRAME = 1;
`else
    localparam NFRAME = 5;
`endif

    reg  aclk = 0, aresetn = 0;
    always #5 aclk = ~aclk;

    // ---------------- DUT ----------------
    reg  [CW_IN-1:0]  in_data;
    reg               in_sof, in_eol, bypass = 1'b0;
    wire              in_valid;              // 源模型 assign
    wire              in_ready;
    wire              out_valid, out_sof, out_eol;
    wire              out_ready;             // 汇模型 assign
    wire [CW_OUT-1:0] out_data;

    gamma_stage #(.DW(DW), .OW(OW)) dut (
        .clk(aclk), .rst_n(aresetn),
        .bypass(bypass),
        .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data),
        .in_sof(in_sof), .in_eol(in_eol),
        .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data),
        .out_sof(out_sof), .out_eol(out_eol)
    );

    // ---------------- 数据加载 ----------------
    reg [CW_IN-1:0]  src [0:NFRAME*TOTAL-1];
    reg [CW_OUT-1:0] exp [0:NFRAME*TOTAL-1];
    integer gi;
    initial begin
`ifdef IMG
        $readmemh("gamma_in.hex", src);
        $readmemh("exp_img.hex", exp);
`elsif RAMP
        $readmemh("gamma_ramp_in.hex", src);
        $readmemh("gamma_ramp_exp.hex", exp);
`else
        $readmemh("gamma_small_in.hex", src);
        $readmemh("gamma_small_exp.hex", exp);
`endif
        for (gi = 0; gi < NFRAME*TOTAL; gi = gi + 1) begin
            if (src[gi] === {CW_IN{1'bx}})  src[gi] = {CW_IN{1'b0}};
            if ( exp[gi] === {CW_OUT{1'bx}}) exp[gi] = {CW_OUT{1'b0}};
        end
    end

    // ---------------- bypass 期望：线性 10→8（与 DUT 的 lin8 同规则：round + 饱和）----------------
    //   注意：移位量用无宽度常量时，拼接操作数会被判"宽度不定"（iverilog 报错）
    //   → 先算进定宽 reg，再拼接；并且**必须饱和到 255**（否则 v=1022/1023 会回绕成 0）
    function [CW_OUT-1:0] lin8p;
        input [CW_IN-1:0] p;
        reg [DW-1:0] v0, v1, v2;
        reg [DW:0]   t0, t1, t2;
        reg [OW-1:0] r0, r1, r2;
        begin
            v0 = p[3*DW-1 -: DW];
            v1 = p[2*DW-1 -: DW];
            v2 = p[   DW-1:   0];
            t0 = (v0 + 2) >> 2;
            t1 = (v1 + 2) >> 2;
            t2 = (v2 + 2) >> 2;
            r0 = (t0 > {OW{1'b1}}) ? {OW{1'b1}} : t0[OW-1:0];
            r1 = (t1 > {OW{1'b1}}) ? {OW{1'b1}} : t1[OW-1:0];
            r2 = (t2 > {OW{1'b1}}) ? {OW{1'b1}} : t2[OW-1:0];
            lin8p = { r0, r1, r2 };
        end
    endfunction

    // ---------------- 源模型 ----------------
    integer imode = 0;              // 0=连续 1=随机70%
    integer ngen = 0;
    integer snd_limit = 960;        // 段内发送限额
    reg     src_vld = 0;
    reg     start = 0;              // 发送门控（防清零竞态）

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
    reg     e_mode = 0;
    integer dbg_n = 0;
    reg [CW_OUT-1:0] cmp_exp, out_data_q;
    reg              ov_q = 0, rdy_q = 0;
    integer fd, fb, bw_n = 0;
    initial begin
`ifdef IMG
        fd = $fopen("gamma_out_img.txt", "w");
`elsif RAMP
        fd = $fopen("gamma_out_ramp.txt", "w");
`else
        fd = $fopen("gamma_out.txt", "w");
`endif
        fb = $fopen("gamma_out_byp.txt", "w");   // bypass 路径输出（供 verify 穷举核对）
    end
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
            // 路径由当拍 bypass 决定：旁路=线性10→8；处理=查表
            cmp_exp = bypass ? lin8p(src[e_mode ? sidx : rcv_cnt])
                             : exp[e_mode ? sidx : rcv_cnt];
            if (!bypass) $fwrite(fd, "%06X\n", out_data);   // 处理路径输出落盘
            else begin
                $fwrite(fb, "%06X\n", out_data);            // bypass 路径输出落盘
                bw_n = bw_n + 1;
            end
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

    // ---------------- 场景流程 ----------------
    initial begin
`ifndef NOVCD
        $dumpfile("tb_gamma.vcd");
        $dumpvars(0, tb_gamma);
`endif
        aresetn = 0;
        repeat (10) @(posedge aclk);
        aresetn = 1;
        repeat (5) @(posedge aclk);

`ifdef SINGLE_FRAME
        $display("=== 单帧模式（IMG/RAMP）：连续流 1 帧 ===");
        imode = 0; omode = 0; bypass = 0;
        snd_limit = TOTAL; start = 1;
        while (rcv_cnt < TOTAL) @(posedge aclk);
        start = 0;
`ifdef RAMP
        // 附加：bypass 穷举（同为 1024 值，走"线性 10→8"路径）→ 落盘供 verify 独立核对
        $display("=== RAMP 附加：bypass 穷举 1024 值（线性 10→8）===");
        e_mode = 1; ngen = 0; sidx = 0; bypass = 1;
        start = 1;
        while (sidx < TOTAL) @(posedge aclk);
        start = 0;
`endif
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

        $display("=== 场景E：bypass 帧间切换 3 段（不排空/不停源）===");
        e_mode = 1; omode = 0; imode = 0;
        ngen = 0; sidx = 0; bypass = 1; snd_limit = TOTAL;
        while (sidx < TOTAL) @(posedge aclk);          // E1 旁路帧（线性10→8）
        ngen = 0; sidx = 0; bypass = 0;                // ★ 直接切
        while (sidx < TOTAL) @(posedge aclk);          // E2 查表帧
        ngen = 0; sidx = 0; bypass = 1;
        while (sidx < TOTAL) @(posedge aclk);          // E3 旁路帧

        $display("=== 场景F：帧中间热切换（等延迟旁路）===");
        ngen = 0; sidx = 0; bypass = 0; snd_limit = TOTAL;
        repeat (TOTAL/2) @(posedge aclk);
        bypass = 1;                                    // ★ 帧中间切
        while (sidx < TOTAL) @(posedge aclk);
        start = 0;
`endif

        repeat (20) @(posedge aclk);
        $fclose(fd);
        $fclose(fb);
        $display("========================================");
`ifdef SINGLE_FRAME
  `ifdef RAMP
        if (snd_cnt != 2*TOTAL || rcv_cnt != 2*TOTAL) err_cnt = err_cnt + 1;   // 查表 + bypass 各一轮
  `else
        if (snd_cnt != TOTAL || rcv_cnt != TOTAL) err_cnt = err_cnt + 1;
  `endif
`else
        // A~D 5 帧 + E 3 段 + F 1 段 = 9 段
        if (snd_cnt != 9*TOTAL || rcv_cnt != 9*TOTAL) err_cnt = err_cnt + 1;
`endif
        $display("入侧 fire %0d 出侧收 %0d —— 反压丢数检查：%s",
                 snd_cnt, rcv_cnt, (err_cnt == 0) ? "pass" : "FAIL");
        $display("bypass 路径落盘 %0d 行（fd=%0d fb=%0d）", bw_n, fd, fb);
        if (err_cnt == 0)
            $display("[PASS] gamma：期望比对全等（0 误差）+ 反压稳定 + bypass 帧间/帧内切换一致");
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
