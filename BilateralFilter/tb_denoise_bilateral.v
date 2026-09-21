//========================================================================
// tb_denoise_bilateral.v —— M4 双边降噪自检 TB（协议四场景 + bypass + IMG）
//
// 期望由 make_denoise_data.py 预生成（Python 位级同构）：
//   -DIMG → denoise_in.hex / exp_img.hex
//   否则  → src_small.hex / exp_small.hex（5 帧）
//
// 场景（small 模式 5 帧）：A 满速 2 帧 / B 汇随机 50% / C 长拉低 / D 双向随机 / E bypass
// IMG 模式：单帧连续流，只做期望比对
//========================================================================
`timescale 1ns/1ps
`include "denoise_stage.v"

module tb_denoise_bilateral;

`ifdef IMG
    localparam IMG_W = 112, IMG_H = 103;
`else
    localparam IMG_W = 16,  IMG_H = 12;
`endif
    localparam DW    = 10;
    localparam CW    = 3*DW;            // 打包位宽 30bit
    localparam TOTAL = IMG_W * IMG_H;
`ifdef IMG
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

    denoise_stage #(.DW(DW), .IMG_W(IMG_W), .IMG_H(IMG_H), .N(3)) dut (
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
        $readmemh("denoise_in.hex", src);
        $readmemh("exp_img.hex", exp);
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
    integer snd_limit = 960;        // ★ 发送限额：ngen 达到即停（E 场景按段推进）
    reg     src_vld = 0;
    reg     start = 0;              // ★ 发送门控：场景完成计数清零后才开闸（防清零竞态）

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
                if (ngen < snd_limit && imode != 99) begin
                    in_data <= src[ngen];
                    in_sof  <= (ngen % TOTAL == 0);
                    in_eol  <= ((ngen % IMG_W) == IMG_W - 1);
                    ngen    <= ngen + 1;
                end else src_vld <= 1'b0;   // ★ 到限额真正撤 valid（排空语义）
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
    //   A~D：全局计数 rcv_cnt，期望 exp[rcv_cnt]（5 帧连续）
    //   E  ：段内索引 sidx，每段从 src/exp 的第 0 帧重放 → 期望用段内索引
    //   计数只在 start=1（源在发）时进行：排空期的残留输出不计入、不比对
    integer snd_cnt = 0, rcv_cnt = 0, err_cnt = 0;
    integer sidx = 0;
    reg     e_mode = 0;                    // E 段标志（期望改用 sidx）
    integer dbg_n = 0;
    reg [CW-1:0] cmp_exp;
    integer fd;                            // RTL 输出落盘（供 verify_denoise.py 独立复算）
    initial fd = $fopen("denoise_out.txt", "w");
    always @(posedge aclk) begin
        #1;
        if (aresetn && start && in_valid && in_ready) begin
            snd_cnt = snd_cnt + 1;
            if (dbg_n < 12) begin
                $display("DBG-SND t=%0t n=%0d data=%07X sof=%b eol=%b",
                         $time, snd_cnt-1, in_data, in_sof, in_eol);
                dbg_n = dbg_n + 1;
            end
        end
        if (out_valid && out_ready && start) begin
            cmp_exp = e_mode ? (bypass ? src[sidx] : exp[sidx]) : exp[rcv_cnt];
            if (!bypass && !e_mode) $fwrite(fd, "%08X\n", out_data);   // A~D / IMG 的处理路径输出
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
    end

    // ---------------- 场景流程 ----------------
    initial begin
`ifndef NOVCD
        $dumpfile("tb_denoise_bilateral.vcd");
        $dumpvars(0, tb_denoise_bilateral);
`endif
        aresetn = 0;
        repeat (10) @(posedge aclk);
        aresetn = 1;
        repeat (5) @(posedge aclk);

`ifdef IMG
        $display("=== 场景IMG：连续流 1 帧（10bit 域）===");
        imode = 0; omode = 0; bypass = 0;
        snd_limit = TOTAL; start = 1;
        while (rcv_cnt < TOTAL) @(posedge aclk);
        start = 0;
`else
        $display("=== 场景A：满速 2 帧 ===");
        imode = 0; omode = 0; bypass = 0;
        snd_limit = 2*TOTAL; start = 1;         // ★ 清零完成后再开闸（防清零竞态）
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
        // ★ bypass 与处理路径延迟不等（bypass 延迟线 vs 行缓存 K·W+K+3 拍），
        //   帧中间切换必然错位——必须"源到限额自动撤 valid → 全链排空 → 切 → 再发"
        //   期望用段内索引 sidx（每段重放 src/exp 第 0 帧）
        e_mode = 1;
        start = 0;
        while (out_valid === 1'b1) @(posedge aclk);
        repeat (8) @(posedge aclk);
        ngen = 0; sidx = 0;
        bypass = 1; imode = 0; omode = 0; snd_limit = TOTAL;
        start = 1;
        while (sidx < TOTAL) @(posedge aclk);         // bypass=1 帧（期望=输入本身）
        start = 0;
        while (out_valid === 1'b1) @(posedge aclk);
        repeat (8) @(posedge aclk);
        ngen = 0; sidx = 0;
        bypass = 0; snd_limit = TOTAL;
        start = 1;
        while (sidx < TOTAL) @(posedge aclk);         // bypass=0 帧（核路径回归验证）
        start = 0;
        while (out_valid === 1'b1) @(posedge aclk);
        repeat (8) @(posedge aclk);
        ngen = 0; sidx = 0;
        bypass = 1; snd_limit = TOTAL;
        start = 1;
        while (sidx < TOTAL) @(posedge aclk);         // bypass=1 帧（再切回验证）
`endif

        repeat (20) @(posedge aclk);
        $fclose(fd);
        $display("========================================");
`ifdef IMG
        if (snd_cnt != TOTAL || rcv_cnt != TOTAL) err_cnt = err_cnt + 1;
`else
        // A~D 共 5 帧 + E 三段各 1 帧 = 8 帧（E 每段 snd_limit=192 段内限额）
        if (snd_cnt != 8*TOTAL || rcv_cnt != 8*TOTAL) err_cnt = err_cnt + 1;
`endif
        $display("入侧 fire %0d 出侧收 %0d —— 反压丢数检查：%s",
                 snd_cnt, rcv_cnt,
                 (err_cnt == 0) ? "一致" : "不一致[ERR]");
        if (err_cnt == 0)
            $display("[PASS] denoise_bilateral：期望比对全等（0 误差）+ bypass 一致 + 断言零违例");
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
