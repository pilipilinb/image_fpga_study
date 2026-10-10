//========================================================================
// tb_rgb_chain.v —— M5.2 RGB 三段链自检 TB（降噪 → CCM → Gamma 的两种顺序各跑一遍）
//
// 编译（顺序由 SWAP_DC 参数决定；golden 文件随之切换）：
//   small + 顺序0（降噪→CCM）: iverilog -o tb_o0.vvp -DNOVCD -I . -I ..\line_buffer\line_buffer_fifo_nxn -I ..\fifo tb_rgb_chain.v
//   small + 顺序1（CCM→降噪）: iverilog -o tb_o1.vvp -DNOVCD -DSWAP  -I . -I ..\line_buffer\line_buffer_fifo_nxn -I ..\fifo tb_rgb_chain.v
//   img   + 顺序0/1          : 再加 -DIMG（分别配 -DSWAP）
//
// 期望由 make_chain_data.py 预生成（Python 位级同构）：
//   chain_in_small.hex(30bit) / exp_order0_small.hex(24bit) / exp_order1_small.hex(24bit)
//   chain_in_img.hex  (30bit) / exp_order0_img.hex  (24bit) / exp_order1_img.hex  (24bit)
//
// 场景（small）：A 满速 2 帧 / B 汇随机 50% / C 长拉低 40 拍（都做期望比对）
//   ★ 注意：降噪含行缓存，每帧末有 K·W+K 拍造行期（in_ready=0），
//     所以"收够 2 帧"要靠 rcv_cnt 判据等待，不能按拍数估。
//   ★ 三种场景 bp_* 全为 0：本 TB 的目标是"顺序对比"与"链的接线/反压正确性"；
//     各段 bypass 已在各自模块 TB 中验证（且链只是把端口直连，无额外逻辑）。
//   IMG 模式：单帧真图连续流，只做期望比对。
//========================================================================
`timescale 1ns/1ps
`include "rgb_chain_top.v"

`ifdef IMG
`define SINGLE_FRAME
`endif
`ifdef SWAP
`define ORDER1
`endif

module tb_rgb_chain;

`ifdef IMG
    localparam IMG_W = 112, IMG_H = 103;
`else
    localparam IMG_W = 16,  IMG_H = 12;
`endif
    localparam DW     = 10;
    localparam OW     = 8;
    localparam CW_IN  = 3*DW;                // 30bit
    localparam CW_OUT = 3*OW;                // 24bit
    localparam TOTAL  = IMG_W * IMG_H;
`ifdef ORDER1
    localparam SWAP_DC = 1;
`else
    localparam SWAP_DC = 0;
`endif
`ifdef SINGLE_FRAME
    localparam NFRAME = 1;
`else
    localparam NFRAME = 5;
`endif

    reg  aclk = 0, aresetn = 0;
    always #5 aclk = ~aclk;

    // ---------------- DUT ----------------
    reg  [CW_IN-1:0]  in_data;
    reg               in_sof, in_eol;
    reg               bp_denoise = 1'b0, bp_ccm = 1'b0, bp_gamma = 1'b0;
    wire              in_valid;              // 源模型 assign
    wire              in_ready;
    wire              out_valid, out_sof, out_eol;
    wire              out_ready;             // 汇模型 assign
    wire [CW_OUT-1:0] out_data;

    rgb_chain_top #(
        .DW(DW), .IMG_W(IMG_W), .IMG_H(IMG_H), .SWAP_DC(SWAP_DC)
    ) dut (
        .clk(aclk), .rst_n(aresetn),
        .bp_denoise(bp_denoise), .bp_ccm(bp_ccm), .bp_gamma(bp_gamma),
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
        $readmemh("chain_in_img.hex", src);
    `ifdef ORDER1
        $readmemh("exp_order1_img.hex", exp);
    `else
        $readmemh("exp_order0_img.hex", exp);
    `endif
`else
        $readmemh("chain_in_small.hex", src);
    `ifdef ORDER1
        $readmemh("exp_order1_small.hex", exp);
    `else
        $readmemh("exp_order0_small.hex", exp);
    `endif
`endif
        for (gi = 0; gi < NFRAME*TOTAL; gi = gi + 1) begin
            if (src[gi] === {CW_IN{1'bx}})  src[gi] = {CW_IN{1'b0}};
            if ( exp[gi] === {CW_OUT{1'bx}}) exp[gi] = {CW_OUT{1'b0}};
        end
    end

    // ---------------- 源模型 ----------------
    integer imode = 0;              // 0=连续 1=随机70% 2=长停顿
    integer ngen = 0;
    integer snd_limit = 960;        // 段内发送限额
    integer sgap = 0;
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
    integer omode = 0;              // 0=恒 ready 1=随机50% 2=长拉低
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
    reg [CW_OUT-1:0] cmp_exp, out_data_q;
    reg              ov_q = 0, rdy_q = 0;
    integer fd;
    initial begin
`ifdef IMG
    `ifdef ORDER1
        fd = $fopen("chain_out_swap_img.txt", "w");
    `else
        fd = $fopen("chain_out_img.txt", "w");
    `endif
`else
    `ifdef ORDER1
        fd = $fopen("chain_out_swap_small.txt", "w");
    `else
        fd = $fopen("chain_out_small.txt", "w");
    `endif
`endif
    end
    always @(posedge aclk) begin
        #1;
        if (aresetn && start && in_valid && in_ready) begin
            snd_cnt = snd_cnt + 1;
            if (dbg_n < 8) begin
                $display("DBG-SND t=%0t n=%0d data=%08X sof=%b eol=%b",
                         $time, snd_cnt-1, in_data, in_sof, in_eol);
                dbg_n = dbg_n + 1;
            end
        end
        if (out_valid && out_ready && start) begin
            cmp_exp = exp[rcv_cnt];
            $fwrite(fd, "%06X\n", out_data);
            if (out_data !== cmp_exp) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8)
                    $display("MISMATCH @%0t #%0d: got=%06X exp=%06X",
                             $time, rcv_cnt, out_data, cmp_exp);
            end
            if (out_sof !== (rcv_cnt % TOTAL == 0)) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8) $display("SOF-MISMATCH @%0t #%0d", $time, rcv_cnt);
            end
            if (out_eol !== (((rcv_cnt + 1) % IMG_W) == 0)) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8) $display("EOL-MISMATCH @%0t #%0d", $time, rcv_cnt);
            end
            rcv_cnt = rcv_cnt + 1;
        end
        // 反压稳定性：valid 拉高且上一拍未 ready 时，数据必须保持
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
        // 单帧真图：连续流
        $display("=== IMG 模式（SWAP_DC=%0d，%0d×%0d 单帧）===", SWAP_DC, IMG_W, IMG_H);
        imode = 0; omode = 0; start = 1; snd_limit = TOTAL;
        while (rcv_cnt < TOTAL) @(posedge aclk);
        start = 0;
`else
        // A：满速 2 帧
        $display("=== 场景A：满速 2 帧（SWAP_DC=%0d）===", SWAP_DC);
        imode = 0; omode = 0; start = 1; snd_limit = 2*TOTAL;
        while (rcv_cnt < 2*TOTAL) @(posedge aclk);
        start = 0;
        repeat (50) @(posedge aclk);

        // B：汇随机 50%，2 帧
        $display("=== 场景B：汇随机 50%%，2 帧 ===");
        imode = 0; omode = 1; start = 1; snd_limit = 4*TOTAL;
        while (rcv_cnt < 4*TOTAL) @(posedge aclk);
        start = 0;
        repeat (50) @(posedge aclk);

        // C：汇长拉低，2 帧
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
        $display("入侧 fire %0d 出侧收 %0d（SWAP_DC=%0d）", snd_cnt, rcv_cnt, SWAP_DC);
        if (err_cnt == 0)
            $display("[PASS] rgb_chain（SWAP_DC=%0d）：期望比对全等（0 误差）+ 反压稳定", SWAP_DC);
        else
            $display("[FAIL] rgb_chain（SWAP_DC=%0d）err=%0d", SWAP_DC, err_cnt);
        $finish;
    end

    // ---------------- 超时兜底 ----------------
    initial begin
        #(NFRAME * TOTAL * 4000 + 20000000);
        $display("[FAIL] timeout snd=%0d rcv=%0d err=%0d", snd_cnt, rcv_cnt, err_cnt);
        $finish;
    end

endmodule
