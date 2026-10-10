//========================================================================
// tb_blc_dpc.v —— BLC / DPC 顺序实验自检 TB（两种顺序各编译一次）
//
// 编译（顺序由 SWAP_BD 参数决定；golden 文件随之切换）：
//   顺序0（BLC→DPC）: iverilog -o tb_o0.vvp -DNOVCD        -I . -I ..\BLC -I ..\line_buffer\line_buffer_fifo_nxn -I ..\fifo tb_blc_dpc.v
//   顺序1（DPC→BLC）: iverilog -o tb_o1.vvp -DNOVCD -DSWAP -I . -I ..\BLC -I ..\line_buffer\line_buffer_fifo_nxn -I ..\fifo tb_blc_dpc.v
//   img 模式再加 -DIMG（分别配 -DSWAP）
//
// 期望由 make_blc_dpc_data.py 预生成（Python 位级同构）：
//   bd_in_small.hex(RAW10) / exp_order0_small.hex / exp_order1_small.hex
//   bd_in_img.hex(RAW10)   / exp_order0_img.hex   / exp_order1_img.hex
//
// 场景（small）：A 满速 2 帧 / B 汇随机 50% / C 长拉低 40~240 拍
// 检查项：① 期望逐位比对 ② out_sof/out_eol 位置 ③ **out_phase 与像素坐标一致**（顺序换了也不能丢相位）
//        ④ 反压稳定性（valid 拉高未 ready 时数据保持）
//   ★ DPC 含 5×5 行缓存，每帧有造行期（in_ready=0），"收够 N 帧"必须用 rcv_cnt 判据等待
//========================================================================
`timescale 1ns/1ps
`include "blc_dpc_top.v"

`ifdef IMG
`define SINGLE_FRAME
`endif
`ifdef SWAP
`define ORDER1
`endif

module tb_blc_dpc;

`ifdef IMG
    localparam IMG_W = 112, IMG_H = 103;
`else
    localparam IMG_W = 16,  IMG_H = 12;
`endif
    localparam DW    = 10;
    localparam TOTAL = IMG_W * IMG_H;
    // 四通道黑电平（R/Gr/Gb/B），与 make_blc_dpc_data.py / tb_blc_top.v 一致
    localparam [DW-1:0] OB00 = 100, OB01 = 64, OB10 = 180, OB11 = 32;
`ifdef ORDER1
    localparam SWAP_BD = 1;
`else
    localparam SWAP_BD = 0;
`endif
`ifdef SINGLE_FRAME
    localparam NFRAME = 1;
`else
    localparam NFRAME = 5;
`endif

    reg  aclk = 0, aresetn = 0;
    always #5 aclk = ~aclk;

    // ---------------- DUT ----------------
    reg  [DW-1:0] in_data;
    reg           in_sof, in_eol;
    wire          in_valid;                  // 源模型 assign
    wire          in_ready;
    wire          out_valid, out_sof, out_eol;
    wire          out_ready;                 // 汇模型 assign
    wire [DW-1:0] out_data;
    wire [1:0]    out_phase;

    blc_dpc_top #(
        .DW(DW), .IMG_W(IMG_W), .IMG_H(IMG_H), .N(5), .THR(128), .SWAP_BD(SWAP_BD)
    ) dut (
        .clk(aclk), .rst_n(aresetn),
        .ob_00(OB00), .ob_01(OB01), .ob_10(OB10), .ob_11(OB11),
        .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data),
        .in_sof(in_sof), .in_eol(in_eol),
        .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data),
        .out_sof(out_sof), .out_eol(out_eol), .out_phase(out_phase)
    );

    // ---------------- 数据加载 ----------------
    reg [DW-1:0] src [0:NFRAME*TOTAL-1];
    reg [DW-1:0] exp [0:NFRAME*TOTAL-1];
    integer gi;
    initial begin
`ifdef IMG
        $readmemh("bd_in_img.hex", src);
    `ifdef ORDER1
        $readmemh("exp_order1_img.hex", exp);
    `else
        $readmemh("exp_order0_img.hex", exp);
    `endif
`else
        $readmemh("bd_in_small.hex", src);
    `ifdef ORDER1
        $readmemh("exp_order1_small.hex", exp);
    `else
        $readmemh("exp_order0_small.hex", exp);
    `endif
`endif
        for (gi = 0; gi < NFRAME*TOTAL; gi = gi + 1) begin
            if (src[gi] === {DW{1'bx}}) src[gi] = {DW{1'b0}};
            if (exp[gi] === {DW{1'bx}}) exp[gi] = {DW{1'b0}};
        end
    end

    // ---------------- 源模型 ----------------
    integer imode = 0;              // 0=连续 1=随机70%
    integer ngen = 0;
    integer snd_limit = 960;
    reg     src_vld = 0;
    reg     start = 0;

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
                end else src_vld <= 1'b0;
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
            else if (({$random} % 1000) < 20) begin
                drop_cnt <= 40 + ({$random} % 200); rdy_r <= 0;
            end else rdy_r <= 1'b1;
        end
    end
    assign out_ready = rdy_r;

    // ---------------- 期望比对 + 记分板 ----------------
    integer snd_cnt = 0, rcv_cnt = 0, err_cnt = 0, dbg_n = 0;
    reg [DW-1:0] out_data_q;
    reg          ov_q = 0, rdy_q = 0;
    integer      phase_err = 0;
    integer      r_exp = 0, c_exp = 0;
    reg [1:0]    ph_exp = 2'b00;
    integer fd;
    initial begin
`ifdef IMG
    `ifdef ORDER1
        fd = $fopen("blc_dpc_out_swap_img.txt", "w");
    `else
        fd = $fopen("blc_dpc_out_img.txt", "w");
    `endif
`else
    `ifdef ORDER1
        fd = $fopen("blc_dpc_out_swap_small.txt", "w");
    `else
        fd = $fopen("blc_dpc_out_small.txt", "w");
    `endif
`endif
    end
    always @(posedge aclk) begin
        #1;
        if (aresetn && start && in_valid && in_ready) begin
            snd_cnt = snd_cnt + 1;
            if (dbg_n < 8) begin
                $display("DBG-SND t=%0t n=%0d data=%03X sof=%b eol=%b",
                         $time, snd_cnt-1, in_data, in_sof, in_eol);
                dbg_n = dbg_n + 1;
            end
        end
        if (out_valid && out_ready && start) begin
            $fwrite(fd, "%03X\n", out_data);
            if (out_data !== exp[rcv_cnt]) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8)
                    $display("MISMATCH @%0t #%0d: got=%03X exp=%03X",
                             $time, rcv_cnt, out_data, exp[rcv_cnt]);
            end
            if (out_sof !== (rcv_cnt % TOTAL == 0)) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8) $display("SOF-MISMATCH @%0t #%0d", $time, rcv_cnt);
            end
            if (out_eol !== (((rcv_cnt + 1) % IMG_W) == 0)) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8) $display("EOL-MISMATCH @%0t #%0d", $time, rcv_cnt);
            end
            // ★ 相位检查：输出像素的 Bayer 相位必须 = {(row&1),(col&1)}（顺序换了也不能丢相位）
            r_exp  = rcv_cnt / IMG_W;
            c_exp  = rcv_cnt % IMG_W;
            ph_exp[1] = r_exp[0];
            ph_exp[0] = c_exp[0];
            if (out_phase !== ph_exp) begin
                phase_err = phase_err + 1;
                err_cnt   = err_cnt + 1;
                if (err_cnt <= 8)
                    $display("PHASE-MISMATCH @%0t #%0d: got=%b exp=%b",
                             $time, rcv_cnt, out_phase, ph_exp);
            end
            rcv_cnt = rcv_cnt + 1;
        end
        if (ov_q && !rdy_q && out_valid && (out_data !== out_data_q)) begin
            err_cnt = err_cnt + 1;
            if (err_cnt <= 8) $display("STABILITY-VIOLATION @%0t", $time);
        end
        ov_q = out_valid; rdy_q = out_ready; out_data_q = out_data;
    end

    // ---------------- 场景流程 ----------------
    initial begin
        aresetn = 0;
        repeat (10) @(posedge aclk);
        aresetn = 1;
        repeat (10) @(posedge aclk);

`ifdef IMG
        $display("=== IMG 模式（SWAP_BD=%0d，%0d×%0d 单帧真图）===", SWAP_BD, IMG_W, IMG_H);
        imode = 0; omode = 0; start = 1; snd_limit = TOTAL;
        while (rcv_cnt < TOTAL) @(posedge aclk);
        start = 0;
`else
        $display("=== 场景A：满速 2 帧（SWAP_BD=%0d）===", SWAP_BD);
        imode = 0; omode = 0; start = 1; snd_limit = 2*TOTAL;
        while (rcv_cnt < 2*TOTAL) @(posedge aclk);
        start = 0;
        repeat (50) @(posedge aclk);

        $display("=== 场景B：汇随机 50%%，2 帧 ===");
        imode = 0; omode = 1; start = 1; snd_limit = 4*TOTAL;
        while (rcv_cnt < 4*TOTAL) @(posedge aclk);
        start = 0;
        repeat (50) @(posedge aclk);

        $display("=== 场景C：汇长拉低（40~240 拍），2 帧 ===");
        imode = 0; omode = 2; start = 1; snd_limit = 6*TOTAL;
        while (rcv_cnt < 6*TOTAL) @(posedge aclk);
        start = 0;
`endif

        repeat (60) @(posedge aclk);
        $fclose(fd);
        $display("========================================");
`ifdef IMG
        if (snd_cnt != TOTAL || rcv_cnt != TOTAL) err_cnt = err_cnt + 1;
`else
        if (snd_cnt != 6*TOTAL || rcv_cnt != 6*TOTAL) err_cnt = err_cnt + 1;
`endif
        $display("入侧 fire %0d 出侧收 %0d（SWAP_BD=%0d）相位违例 %0d",
                 snd_cnt, rcv_cnt, SWAP_BD, phase_err);
        if (err_cnt == 0)
            $display("[PASS] blc_dpc（SWAP_BD=%0d）：期望比对全等（0 误差）+ 相位一致 + 反压稳定",
                     SWAP_BD);
        else
            $display("[FAIL] blc_dpc（SWAP_BD=%0d）err=%0d", SWAP_BD, err_cnt);
        $finish;
    end

    // ---------------- 超时兜底 ----------------
    initial begin
        #(NFRAME * TOTAL * 4000 + 20000000);
        $display("[FAIL] timeout snd=%0d rcv=%0d err=%0d", snd_cnt, rcv_cnt, err_cnt);
        $finish;
    end

endmodule
