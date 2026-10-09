//========================================================================
// tb_axis_out_adapter.v —— M5.1 出端适配器自检 TB（S2MM 契约逐条核对）
//
// DUT：简流(RGB888) → AXIS(RGB888 → VDMA S2MM)，含弹性 FIFO（DEPTH=16，故意取小
//      以便快速撞满/触发反压）
//
// 契约判据（M5 验收逐条）：
//   ① 每帧首拍 tuser=1，其余 tuser=0
//   ② 每行末拍 tlast=1，其余 tlast=0
//   ③ tkeep ≡ 3'b111（每拍）
//   ④ tdata 序列 == 源序列（数据完整性/顺序，零丢零重）
//   ⑤ 每帧像素数 = W×H（HSIZE/VSIZE 与分辨率一致）
//   ⑥ AXIS 稳定性：tvalid=1 且 tready=0 时 tdata/tkeep/tuser/tlast 保持（用上一拍 ready）
//   ⑦ 复位期 tvalid=0
//
// 场景：A 满速 4 帧 / B 汇随机 50% / C 汇长拉低（撞满反压）/ D 源气泡+汇随机 / E 复位断言
//========================================================================
`timescale 1ns/1ps
`include "axis_out_adapter.v"

module tb_axis_out_adapter;

    localparam DW     = 24;
    localparam KW     = 3;                 // tkeep 位宽
    localparam W      = 16;
    localparam H      = 12;
    localparam NFRAME = 4;
    localparam TOTAL  = W * H;
    localparam GRAND  = NFRAME * TOTAL;    // 每个场景发 NFRAME 帧

    reg  aclk = 0, aresetn = 0;
    always #5 aclk = ~aclk;

    // ---------------- DUT ----------------
    reg  [DW-1:0] in_data;
    reg           in_sof, in_eol;
    wire          in_valid;                // 源模型 assign
    wire          in_ready;
    wire [DW-1:0] m_tdata;
    wire [KW-1:0] m_tkeep;
    wire          m_tvalid, m_tlast, m_tuser;
    wire          m_tready;                // 汇模型 assign

    axis_out_adapter #(.DW(DW), .DEPTH(16)) dut (
        .clk(aclk), .rst_n(aresetn),
        .in_data(in_data), .in_valid(in_valid), .in_ready(in_ready),
        .in_sof(in_sof), .in_eol(in_eol),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep),
        .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready),
        .m_axis_tlast(m_tlast), .m_axis_tuser(m_tuser)
    );

    // ---------------- 数据加载 ----------------
    reg [DW-1:0] src [0:GRAND-1];
    integer gi;
    initial begin
        $readmemh("ao_src.hex", src);
        for (gi = 0; gi < GRAND; gi = gi + 1)
            if (src[gi] === {DW{1'bx}}) src[gi] = {DW{1'b0}};
    end

    // ---------------- 源模型（简流，本场景内局部索引 ngen）----------------
    integer imode = 0;                 // 0=连续 1=随机70%
    integer ngen = 0;
    integer snd_limit = GRAND;
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
                    in_eol  <= ((ngen % W) == W - 1);
                    src_vld <= 1'b1;
                    ngen    <= ngen + 1;
                end
            end else if (in_ready) begin
                if (ngen < snd_limit) begin
                    in_data <= src[ngen];
                    in_sof  <= (ngen % TOTAL == 0);
                    in_eol  <= ((ngen % W) == W - 1);
                    ngen    <= ngen + 1;
                end else src_vld <= 1'b0;
            end
        end
    end
    assign in_valid = src_vld;

    // ---------------- 汇模型（AXIS tready）----------------
    integer omode = 0;                 // 0=满速 1=随机50% 2=长拉低
    reg  rdy_r = 0;
    integer drop_cnt = 0;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin rdy_r <= 0; drop_cnt <= 0; end
        else if (omode == 0) rdy_r <= 1'b1;
        else if (omode == 1) rdy_r <= (({$random} % 1000) < 500);
        else begin
            if (drop_cnt > 0) begin drop_cnt <= drop_cnt - 1; rdy_r <= 0; end
            else if (({$random} % 1000) < 30) begin drop_cnt <= 60 + ({$random} % 300); rdy_r <= 0; end
            else rdy_r <= 1'b1;
        end
    end
    assign m_tready = rdy_r;

    // ---------------- 契约核对 + 记分板 ----------------
    integer rcv_cnt = 0, snd_cnt = 0, err_cnt = 0;
    integer sidx = 0;                  // 场景内索引（期望与契约位置都用它）
    integer frame_cnt = 0, row_cnt = 0;
    integer dbg_n = 0;
    reg [DW-1:0] td_q; reg [KW-1:0] tk_q; reg tu_q, tl_q;
    reg          mv_q = 0, mr_q = 0;
    integer fd;
    initial fd = $fopen("ao_out.txt", "w");
    always @(posedge aclk) begin
        #1;
        if (aresetn && start && in_valid && in_ready) snd_cnt = snd_cnt + 1;

        // ③ tkeep 恒 111（每个 valid 拍）
        if (m_tvalid && (m_tkeep !== {KW{1'b1}})) begin
            err_cnt = err_cnt + 1;
            if (err_cnt <= 8) $display("TKEEP-BAD @%0t: %b", $time, m_tkeep);
        end
        // ⑦ 复位期 tvalid 必须为 0
        if (!aresetn && m_tvalid) begin
            err_cnt = err_cnt + 1;
            if (err_cnt <= 8) $display("RESET-TVALID @%0t", $time);
        end

        // 数据/契约逐拍比对（fire 拍）
        if (m_tvalid && m_tready && start) begin
            if (m_tdata !== src[sidx]) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8) $display("DATA-MISMATCH @%0t #%0d: got=%06X exp=%06X",
                                           $time, sidx, m_tdata, src[sidx]);
            end
            if (m_tuser !== (sidx % TOTAL == 0)) begin       // ① 帧首
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8) $display("TUSER-MISMATCH @%0t #%0d: %b", $time, sidx, m_tuser);
            end
            if (m_tlast !== ((sidx + 1) % W == 0)) begin      // ② 行末
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8) $display("TLAST-MISMATCH @%0t #%0d: %b", $time, sidx, m_tlast);
            end
            if (m_tuser) frame_cnt = frame_cnt + 1;
            if (m_tlast) row_cnt = row_cnt + 1;
            $fwrite(fd, "%06X %01X %01X %01X\n", m_tdata, m_tkeep, m_tuser, m_tlast);
            rcv_cnt = rcv_cnt + 1;
            sidx = sidx + 1;
        end

        // ⑥ 稳定性（上一拍 stalled：tvalid=1 && tready=0 → 本拍载荷必须不变）
        if (mv_q && !mr_q && m_tvalid) begin
            if (m_tdata !== td_q || m_tkeep !== tk_q || m_tuser !== tu_q || m_tlast !== tl_q) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8) $display("STABLE-VIOLATION @%0t: %06X/%b vs %06X/%b",
                                           $time, m_tdata, m_tkeep, td_q, tk_q);
            end
        end
        mv_q = m_tvalid; mr_q = m_tready;
        td_q = m_tdata; tk_q = m_tkeep; tu_q = m_tuser; tl_q = m_tlast;
    end

    // ---------------- 场景流程 ----------------
    integer seg;
    initial begin
`ifndef NOVCD
        $dumpfile("tb_axis_out_adapter.vcd");
        $dumpvars(0, tb_axis_out_adapter);
`endif
        aresetn = 0;
        repeat (10) @(posedge aclk);
        aresetn = 1;
        repeat (5) @(posedge aclk);

        // 四个场景各发 NFRAME 帧，每场景：开闸→等收满→撤源→排空
        for (seg = 0; seg < 4; seg = seg + 1) begin
            case (seg)
                0: begin $display("=== 场景A：满速 双向连续 4 帧 ==="); imode = 0; omode = 0; end
                1: begin $display("=== 场景B：汇随机 50%% 4 帧 ===");    imode = 0; omode = 1; end
                2: begin $display("=== 场景C：汇长拉低（撞满反压）4 帧 ==="); imode = 0; omode = 2; end
                3: begin $display("=== 场景D：源气泡70%% + 汇随机 4 帧 ==="); imode = 1; omode = 1; end
            endcase
            ngen = 0; sidx = 0; snd_limit = GRAND; start = 1;
            while (sidx < GRAND) @(posedge aclk);
            start = 0;
            while (m_tvalid === 1'b1) @(posedge aclk);       // 排空
            repeat (5) @(posedge aclk);
        end

        // 场景E：复位期 tvalid=0 断言
        $display("=== 场景E：复位断言 tvalid=0 ===");
        repeat (5) @(posedge aclk);
        aresetn = 0;
        repeat (10) @(posedge aclk);
        aresetn = 1;
        repeat (5) @(posedge aclk);

        repeat (20) @(posedge aclk);
        $fclose(fd);
        $display("========================================");
        // 每场景 4 帧 × 4 场景 = 16 帧；帧/行计数也应一致
        if (snd_cnt != 4*GRAND || rcv_cnt != 4*GRAND) err_cnt = err_cnt + 1;
        if (frame_cnt != 4*NFRAME) err_cnt = err_cnt + 1;
        if (row_cnt != 4*NFRAME*H) err_cnt = err_cnt + 1;
        $display("入侧 fire %0d 出侧收 %0d（期望各 %0d）· 帧 %0d（期望 %0d）· 行 %0d（期望 %0d）",
                 snd_cnt, rcv_cnt, 4*GRAND, frame_cnt, 4*NFRAME, row_cnt, 4*NFRAME*H);
        if (err_cnt == 0)
            $display("[PASS] axis_out_adapter：S2MM 契约（tuser/tlast/tkeep/HSIZE/VSIZE）全过 + 反压零丢 + 稳定性断言零违例");
        else
            $display("[FAIL] err=%0d", err_cnt);
        $finish;
    end

    // ---------------- 超时兜底 ----------------
    initial begin
        #(4*GRAND*2000 + 5000000);
        $display("[FAIL] timeout snd=%0d rcv=%0d err=%0d", snd_cnt, rcv_cnt, err_cnt);
        $finish;
    end

endmodule
