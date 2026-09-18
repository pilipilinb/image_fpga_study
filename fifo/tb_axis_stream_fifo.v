//========================================================================
// tb_axis_stream_fifo.v —— 手写 AXIS Data FIFO 自检 TB
//
// 四个阶段（记分板 0 误差 + 协议断言零违例才算过）：
//   A. 背靠背满速：源连续 valid、汇连续 ready，500 字（含 10+ 帧帧语义流）
//   B. 双侧随机：源 valid 随机 70%、汇 ready 随机 50%（含拉低跨多拍），1000 字
//   C. 边界：空读（空时 tvalid 必须为 0）→ 读停写满（容量判据 = DEPTH+1，
//      FWFT 输出级固有 +1）→ 全读出 0 误差 → 再空读检查
//   D. 运行中复位：写 10 字读停 → aresetn 脉冲 → 旧字丢弃（复位后 tvalid=0）
//      → 记分板重置 → 重新满速收发 200 字
//
// 帧语义（ISP 流）：全程构造 8×6 小帧流——tuser=帧首（第 0 字）、tlast=行末
//   （每 8 字一个），记分板对 data/tlast/tuser 三元组逐拍对位比对。
//
// AXIS 协议断言（always 检查实现，计入 err）：
//   1) s 侧：tvalid=1 且未 ready → 下一拍 tvalid 仍为 1 且 tdata/tlast/tuser 稳定
//   2) m 侧：同上
//   3) 复位期间 m_axis_tvalid=0
//
// 源模型（规范 master）：空闲时按模式载入新字；字未被消费则原样保持——
//   这本身就是断言 1) 的合规源头（TB 激励自己先不能违例）。
//========================================================================
`timescale 1ns/1ps
`include "axis_stream_fifo.v"

module tb_axis_stream_fifo;

    localparam DW     = 8;
    localparam DEPTH  = 16;         // 故意用小深度：阶段C 快速撞满（容量判据 DEPTH+1）
    localparam IMG_W  = 8;          // 帧语义：8×6 小帧
    localparam IMG_H  = 6;
    localparam FRAME  = IMG_W * IMG_H;

    reg  aclk = 0, aresetn = 0;
    always #5 aclk = ~aclk;

    // ---------------- DUT ----------------
    wire [DW-1:0] s_tdata;
    wire          s_tvalid, s_tready, s_tlast, s_tuser;
    wire [DW-1:0] m_tdata;
    wire          m_tvalid, m_tready, m_tlast, m_tuser;

    axis_stream_fifo #(
        .DW(DW), .DEPTH(DEPTH),
        .TLAST_EN(1), .TUSER_EN(1), .TUSER_W(1)
    ) dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
        .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready),
        .m_axis_tlast(m_tlast), .m_axis_tuser(m_tuser)
    );

    // ---------------- 字生成（确定性伪随机：n*131+7，与 256 互素保证 256 字内单射） ----------------
    function [DW-1:0] gen_data(input integer n);
        gen_data = (n * 131 + 7) & 255;
    endfunction
    function gen_tlast(input integer n);
        gen_tlast = (n % IMG_W == IMG_W - 1);
    endfunction
    function gen_tuser(input integer n);
        gen_tuser = (n % FRAME == 0);
    endfunction

    // ---------------- 源模型（AXIS 规范 master） ----------------
    // 【integer 而非 reg】模式值有 0/1/2 三种，1bit reg 会把 2 截断成 0（停摆超时）
    integer    src_mode = 0;        // 0=停 1=连续 2=随机 valid(70%)
    reg        src_valid_r = 0;
    reg [DW-1:0] src_data_r = 0;
    reg        src_tlast_r = 0, src_tuser_r = 0;
    integer    ngen = 0;            // 已载入字数
    integer    snd_target = 0;      // 本阶段要发的总字数（载入上限）
    integer    snd_cnt = 0;         // 已被 fire（真正写入 DUT）的字数

    assign s_tdata  = src_data_r;
    assign s_tvalid = src_valid_r;
    assign s_tlast  = src_tlast_r;
    assign s_tuser  = src_tuser_r;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            src_valid_r <= 1'b0;
        end else begin
            if (!src_valid_r) begin
                // 空闲：按模式决定是否载入新字
                if (ngen < snd_target &&
                    (src_mode == 1 || (src_mode == 2 && (({$random} % 1000) < 700)))) begin
                    src_data_r  <= gen_data(ngen);
                    src_tlast_r <= gen_tlast(ngen);
                    src_tuser_r <= gen_tuser(ngen);
                    src_valid_r <= 1'b1;
                    ngen        <= ngen + 1;
                end
            end else if (s_tready) begin
                // 本拍被消费：继续载入下一字（或按模式收手）
                if (ngen < snd_target && src_mode != 0) begin
                    src_data_r  <= gen_data(ngen);
                    src_tlast_r <= gen_tlast(ngen);
                    src_tuser_r <= gen_tuser(ngen);
                    ngen        <= ngen + 1;
                    // src_valid_r 保持 1（无缝背靠背）
                end else begin
                    src_valid_r <= 1'b0;  // 只有被 ready 之后才允许撤 valid（规范）
                end
            end
            // valid 且未 ready：什么都不做 → 字段保持稳定（规范）
        end
    end

    // ---------------- 汇模型（AXIS slave：只驱动 tready） ----------------
    integer rcv_mode = 0;           // 0=停 1=连续 2=随机 ready(50%)
    reg  rdy_r = 0;
    integer rcv_cnt = 0;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn)          rdy_r <= 1'b0;
        else if (rcv_mode==2)  rdy_r <= (({$random} % 1000) < 500);
        else                   rdy_r <= (rcv_mode == 1);
    end
    assign m_tready = rdy_r;

    // ---------------- 记分板 + 协议断言 ----------------
    reg [DW-1:0] exp_data  [0:65535];
    reg          exp_tlast [0:65535];
    reg          exp_tuser [0:65535];
    integer err_cnt = 0;
    integer max_used = 0;           // 水线峰值（snd_cnt - rcv_cnt）

    // 写侧：s_fire 时记入期望队列
    always @(posedge aclk) begin
        #1;
        if (aresetn && s_tvalid && s_tready) begin
            exp_data[snd_cnt] = s_tdata;
            exp_tlast[snd_cnt] = s_tlast;
            exp_tuser[snd_cnt] = s_tuser;
            snd_cnt = snd_cnt + 1;
        end
        if ((snd_cnt - rcv_cnt) > max_used) max_used = snd_cnt - rcv_cnt;
    end

    // 读侧：m_fire 时三元组逐拍比对
    always @(posedge aclk) begin
        #1;
        if (m_tvalid && m_tready) begin
            if (m_tdata !== exp_data[rcv_cnt] ||
                m_tlast !== exp_tlast[rcv_cnt] ||
                m_tuser !== exp_tuser[rcv_cnt]) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8)
                    $display("MISMATCH @%0t rcv=%0d: got(data=%0d tl=%b tu=%b) exp(data=%0d tl=%b tu=%b)",
                             $time, rcv_cnt, m_tdata, m_tlast, m_tuser,
                             exp_data[rcv_cnt], exp_tlast[rcv_cnt], exp_tuser[rcv_cnt]);
            end
            rcv_cnt = rcv_cnt + 1;
        end
    end

    // 断言1：s 侧 stability（valid 未 ready → 字段保持、valid 不撤）
    reg        pv_sv, pv_sr;
    reg [DW-1:0] pv_sd;
    reg        pv_sl, pv_su;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            pv_sv <= 0; pv_sr <= 0;
        end else begin
            if (pv_sv && !pv_sr) begin
                if (s_tvalid !== 1'b1) begin
                    err_cnt = err_cnt + 1;
                    $display("[ASSERT-ERR] @%0t s 侧 valid 未 ready 时撤销", $time);
                end
                if (s_tdata !== pv_sd || s_tlast !== pv_sl || s_tuser !== pv_su) begin
                    err_cnt = err_cnt + 1;
                    $display("[ASSERT-ERR] @%0t s 侧字段未 ready 时不稳定", $time);
                end
            end
            pv_sv <= s_tvalid; pv_sr <= s_tready;
            pv_sd <= s_tdata;  pv_sl <= s_tlast;  pv_su <= s_tuser;
        end
    end

    // 断言2：m 侧 stability
    reg        pv_mv, pv_mr;
    reg [DW-1:0] pv_md;
    reg        pv_ml, pv_mu;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            pv_mv <= 0; pv_mr <= 0;
        end else begin
            if (pv_mv && !pv_mr && m_tvalid) begin  // 现在还 valid（若已撤但曾被 hold？规范：不许撤）
                if (m_tdata !== pv_md || m_tlast !== pv_ml || m_tuser !== pv_mu) begin
                    err_cnt = err_cnt + 1;
                    $display("[ASSERT-ERR] @%0t m 侧字段未 ready 时不稳定", $time);
                end
            end
            if (pv_mv && !pv_mr && m_tvalid !== 1'b1) begin
                err_cnt = err_cnt + 1;
                $display("[ASSERT-ERR] @%0t m 侧 valid 未 ready 时撤销", $time);
            end
            pv_mv <= m_tvalid; pv_mr <= m_tready;
            pv_md <= m_tdata;  pv_ml <= m_tlast;  pv_mu <= m_tuser;
        end
    end

    // 断言3：复位期间 m_axis_tvalid=0
    always @(posedge aclk) begin
        #1;
        if (!aresetn && m_tvalid) begin
            err_cnt = err_cnt + 1;
            $display("[ASSERT-ERR] @%0t 复位期间 m_axis_tvalid=1", $time);
        end
    end

    // ---------------- 测试流程 ----------------
    integer cap_base, low_cnt;

    initial begin
        $dumpfile("tb_axis_stream_fifo.vcd");
        $dumpvars(0, tb_axis_stream_fifo);

        // 复位
        aresetn = 0;
        repeat (10) @(posedge aclk);
        aresetn = 1;
        repeat (5) @(posedge aclk);

        // ---------- A. 背靠背满速 ----------
        $display("=== 阶段A：满速背靠背 500 字（8x6 帧语义流）===");
        src_mode = 1; rcv_mode = 1; snd_target = 500;
        while (snd_cnt < 500) @(posedge aclk);
        while (rcv_cnt < 500) @(posedge aclk);
        repeat (3) @(posedge aclk);
        $display("  snd=%0d rcv=%0d err=%0d tvalid=%b（期望 0）", snd_cnt, rcv_cnt, err_cnt, m_tvalid);
        if (m_tvalid !== 1'b0) err_cnt = err_cnt + 1;

        // ---------- B. 双侧随机 ----------
        $display("=== 阶段B：源随机70%%/汇随机50%%，1000 字 + 排空 ===");
        src_mode = 2; rcv_mode = 2;
        snd_target = snd_cnt + 1000;
        while (snd_cnt < snd_target) @(posedge aclk);
        src_mode = 0;                        // 源收手（在ready后撤valid，规范）
        while (rcv_cnt < snd_cnt) @(posedge aclk);   // 真正排空（对齐 async_fifo TB 的教训）
        repeat (3) @(posedge aclk);
        $display("  snd=%0d rcv=%0d err=%0d tvalid=%b（期望 0）", snd_cnt, rcv_cnt, err_cnt, m_tvalid);
        if (m_tvalid !== 1'b0) err_cnt = err_cnt + 1;

        // ---------- C. 边界：空读 / 写满 / 读出 ----------
        $display("=== 阶段C：空读 → 读停写满 → 读出 ===");
        // C1 空读：汇 ready=1 但 FIFO 空 → tvalid 必须 0（不得吐假数据）
        rcv_mode = 1;
        repeat (5) @(posedge aclk);
        $display("  空读检查：tready=1 时 tvalid=%b（期望 0）", m_tvalid);
        if (m_tvalid !== 1'b0) err_cnt = err_cnt + 1;
        // C2 写满：读停、源连续。容量 = DEPTH(BRAM) + 1(输出寄存器) = DEPTH+1
        rcv_mode = 0;
        cap_base = snd_cnt;
        snd_target = snd_cnt + DEPTH + 1 + 10;   // 多发 10 个试探溢出（应被 ready=0 挡住）
        src_mode = 1;
        low_cnt = 0;
        while (low_cnt < 5) begin
            @(posedge aclk); #1;
            if (!s_tready) low_cnt = low_cnt + 1; else low_cnt = 0;
        end
        $display("  写满：成功写入 %0d 字（期望 %0d） tready=%b",
                 snd_cnt - cap_base, DEPTH + 1, s_tready);
        if (snd_cnt - cap_base != DEPTH + 1) begin
            err_cnt = err_cnt + 1;
            $display("  [ERR] 容量不是 DEPTH+1");
        end
        if (s_tready !== 1'b0) err_cnt = err_cnt + 1;
        // C3 全读出：0 误差
        rcv_mode = 1;
        src_mode = 0;                        // 源在 ready 后规范撤 valid
        while (rcv_cnt < snd_cnt) @(posedge aclk);
        repeat (3) @(posedge aclk);
        $display("  读出：snd=%0d rcv=%0d err=%0d tvalid=%b（期望 0）", snd_cnt, rcv_cnt, err_cnt, m_tvalid);
        if (m_tvalid !== 1'b0) err_cnt = err_cnt + 1;

        // ---------- D. 运行中复位 ----------
        $display("=== 阶段D：运行中复位（旧字丢弃）===");
        rcv_mode = 0;                        // 读停
        // 【载入上限要用 ngen 基准】源模型载入判据是 ngen < snd_target；阶段C2 里
        //   源已把 ngen 预载到 snd_cnt+10（多试的 10 个字在 valid 上等到 ready 才
        //   被消费，ngen 领先 snd_cnt）。若用 snd_cnt+10 做上限会小于 ngen → 源停摆超时
        snd_target = ngen + 10;
        src_mode = 1;
        while (ngen < snd_target) @(posedge aclk);  // 等源把字全部载入（部分会在
        repeat (10) @(posedge aclk);                //   valid 上等 ready/写满，无所谓，复位全丢）
        src_mode = 0;
        repeat (3) @(posedge aclk);
        aresetn = 0;                         // 异步复位断言（写进 10 字未读 → 应被丢弃）
        repeat (4) @(posedge aclk);
        aresetn = 1;
        repeat (5) @(posedge aclk);          // busy 释放 + 缓冲
        $display("  复位后：tvalid=%b（期望 0，10 个旧字已丢弃）", m_tvalid);
        if (m_tvalid !== 1'b0) err_cnt = err_cnt + 1;
        // 重新满速收发：记分板指针全部归零重记
        snd_cnt = 0; rcv_cnt = 0; ngen = 0;
        snd_target = 200;
        src_mode = 1; rcv_mode = 1;
        while (snd_cnt < 200) @(posedge aclk);
        while (rcv_cnt < 200) @(posedge aclk);
        repeat (3) @(posedge aclk);
        $display("  复位后重收：snd=%0d rcv=%0d err=%0d", snd_cnt, rcv_cnt, err_cnt);

        // ---------- 汇总 ----------
        $display("========================================");
        $display("总发送 %0d 字，总接收 %0d 字，水线峰值 %0d", snd_cnt, rcv_cnt, max_used);
        if (err_cnt == 0)
            $display("[PASS] axis_stream_fifo：四个阶段全部通过（满速/随机/满空/复位）");
        else
            $display("[FAIL] err=%0d", err_cnt);
        $finish;
    end

    // ---------------- 超时兜底 ----------------
    initial begin
        #20_000_000;
        $display("[FAIL] simulation timeout snd=%0d rcv=%0d err=%0d", snd_cnt, rcv_cnt, err_cnt);
        $finish;
    end

endmodule
