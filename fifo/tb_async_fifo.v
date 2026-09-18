//========================================================================
// tb_async_fifo.v —— 纯 Verilog 双时钟 FIFO 自检 TB
//
// 五个阶段（每个阶段都边写边读、逐字比对，0 误差才算过）：
//   A. 同步时钟（10ns/10ns）：连续写 1000 字、连续读 —— 基本功能
//   B. 异步 + 写快读慢（6ns/11ns）：随机气泡 3000 字 —— 会撞 full（写被挡）
//   C. 异步 + 写慢读快（15ns/6ns）：随机气泡 3000 字 —— 会撞 empty（读被挡）
//   D. 写满/读空：读停→连续写→检查 full 与写入数=DEPTH；再全读空 → 检查 empty 与数据
//   E. 运行中复位：rst 脉冲 → 检查 busy 拉高、复位后 empty=1/full=0、重新收发正常
//
// 记分板：写侧把"真正写进去的值"按顺序记进 exp_mem；读侧把"真正读出来的值"
//   与 exp_mem 按顺序比对（标准模式：rd_en 后 1 拍出数，所以比对用延迟 1 拍的标志）。
//========================================================================
`timescale 1ns/1ps
`include "async_fifo.v"

module tb_async_fifo;

    localparam DW    = 10;
    localparam DEPTH = 512;
    localparam AW    = $clog2(DEPTH);

    reg wr_clk = 0, rd_clk = 0;
    reg rst = 1;
    reg [DW-1:0] din = 0;
    reg wr_en = 0, rd_en = 0;
    wire [DW-1:0] dout;
    wire full, empty;
    wire [AW:0] data_count;
    wire wr_rst_busy, rd_rst_busy;

    async_fifo #(.DW(DW), .DEPTH(DEPTH)) dut (
        .wr_clk(wr_clk), .rd_clk(rd_clk), .rst(rst),
        .din(din), .wr_en(wr_en), .rd_en(rd_en), .dout(dout),
        .full(full), .empty(empty), .data_count(data_count),
        .wr_rst_busy(wr_rst_busy), .rd_rst_busy(rd_rst_busy)
    );

    // 时钟周期可变（用变量控制半周期，方便切换同步/异步场景）
    // 【real 而非 reg[31:0]】整数 reg 会把 5.5/7.5 截断，阶段B/C 的时钟周期
    //   就不是注释宣称的 11ns/15ns 了；real 才能保留半个 ns 精度
    real wr_half = 5.0, rd_half = 5.0;
    always #(wr_half) wr_clk = ~wr_clk;
    always #(rd_half) rd_clk = ~rd_clk;

    // ---------------- 激励/气流控制 ----------------
    reg        wr_cont = 1, rd_cont = 1;      // 1 = 尽量连续，0 = 按概率出气泡
    reg        wr_stop = 0, rd_stop = 0;      // 1 = 激励源头强制停（优先级最高）
    // 【为什么需要 stop】测试流程里直接写 wr_en=0/rd_en=0 无效：wr_en/rd_en 由下面的
    //   always 块每拍持续驱动，下一拍就被覆盖回随机值，造成"想让读停但读没停"：
    //   阶段B/C 尾巴漏写（FIFO 排不空）、阶段D 写满计数≠DEPTH、读空检查 empty=0 全错。
    //   正确做法是从激励源头关断：stop=1 时 always 块自己输出 0。
    integer    wr_permil = 500, rd_permil = 500;  // 随机模式下的"写/读概率"（千分比）
    reg [DW-1:0] din_seq = 0;                 // 输入数据：每拍自增（写不写都自增）

    // 【激励不做复位门控】每拍无条件驱动 wr_en/din：若加 if(!rst)，复位期间 wr_en 会
    //   "保持复位前的值 1"，复位释放沿（busy 恰好已清零）可能吃进 1 个计划外写入而
    //   记分板没记 → 数据全错位。去掉门控后激励值完全由 wr_stop/wr_cont 决定，
    //   复位期间多出的激励无害（DUT 写口与记分板都带 wr_rst_busy 门控）。
    always @(posedge wr_clk) begin
        din     <= din_seq;
        din_seq <= din_seq + 1'b1;
        wr_en   <= !wr_stop && (wr_cont ? 1'b1 : (({$random} % 1000) < wr_permil));
    end

    // rd 激励同理不做复位门控（对称处理，防同样的"保持旧值"竞态）
    always @(posedge rd_clk) begin
        rd_en <= !rd_stop && (rd_cont ? 1'b1 : (({$random} % 1000) < rd_permil));
    end

    // ---------------- 记分板 ----------------
    reg [DW-1:0] exp_mem [0:16383];
    integer w_cnt = 0;        // 真正写进 FIFO 的字数（也是 exp_mem 的写指针）
    integer r_cnt = 0;        // 真正读出的字数（也是 exp_mem 的读指针）
    integer err_cnt = 0;
    reg     rd_fire_d = 0;    // 上一拍"真正读走"的标志（对应当前 dout）
    integer max_used = 0;     // 记录 FIFO 里同时存在的最大字数（看水线）

    always @(posedge wr_clk) begin
        #1;
        if (wr_en && !full && !wr_rst_busy) begin
            if (w_cnt < 16384) exp_mem[w_cnt] = din;
            w_cnt = w_cnt + 1;
        end
    end

    always @(posedge rd_clk) begin
        #1;
        // 读侧比对：rd_fire_d 那一拍的数据已经出现在 dout 上
        if (rd_fire_d) begin
            if (dout !== exp_mem[r_cnt]) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8)
                    $display("MISMATCH @%0t r_cnt=%0d: dout=%0X exp=%0X",
                             $time, r_cnt, dout, exp_mem[r_cnt]);
            end
            r_cnt = r_cnt + 1;
        end
        rd_fire_d = (rd_en && !empty);
        if (data_count > max_used) max_used = data_count;
    end

    // ---------------- 测试流程 ----------------
    integer i;
    integer w_mark, r_mark, full_cnt;

    initial begin
        $dumpfile("tb_async_fifo.vcd");
        $dumpvars(0, tb_async_fifo);

        // 复位
        rst = 1;
        repeat (10) @(posedge wr_clk);
        rst = 0;
        while (wr_rst_busy || rd_rst_busy) @(posedge wr_clk);

        // ---------- A. 同步时钟：连续写 1000 字、连续读 ----------
        $display("=== 阶段A：同步时钟（10ns/10ns）连续写读 ===");
        wr_half = 5; rd_half = 5; wr_cont = 1; rd_cont = 1;
        while (w_cnt < 1000) @(posedge wr_clk);
        while (r_cnt < 1000) @(posedge rd_clk);
        $display("  w_cnt=%0d r_cnt=%0d err=%0d full=%b empty=%b count=%0d",
                 w_cnt, r_cnt, err_cnt, full, empty, data_count);

        // ---------- B. 异步，写快读慢 + 随机气泡 ----------
        $display("=== 阶段B：写快读慢（6ns/11ns）+ 随机气泡 ===");
        wr_half = 3; rd_half = 5.5; wr_cont = 0; rd_cont = 0;
        wr_permil = 700; rd_permil = 700;
        w_mark = w_cnt + 3000;
        while (w_cnt < w_mark) @(posedge wr_clk);
        wr_stop = 1;                          // 源头停写
        // 【排空要排到真正空】不能等 r_cnt 到某个定值就收：本阶段写快读慢，收尾时 FIFO
        //   里还压着几个字（读侧滞后）。必须等到 r_cnt==w_cnt（每个已写字都被读走）。
        //   否则阶段D不是从空起步：满判断提前几个写就触发 → 写入增量≠DEPTH 假错。
        while (r_cnt < w_cnt) @(posedge rd_clk);
        $display("  w_cnt=%0d r_cnt=%0d err=%0d count=%0d", w_cnt, r_cnt, err_cnt, data_count);

        // ---------- C. 异步，写慢读快 + 随机气泡 ----------
        $display("=== 阶段C：写慢读快（15ns/6ns）+ 随机气泡 ===");
        wr_half = 7.5; rd_half = 3; wr_cont = 0; rd_cont = 0;
        wr_stop = 0;                          // 解除 B 尾巴的停写
        wr_permil = 700; rd_permil = 700;
        w_mark = w_cnt + 3000;
        while (w_cnt < w_mark) @(posedge wr_clk);
        wr_stop = 1;                          // 源头停写
        while (r_cnt < w_cnt) @(posedge rd_clk);  // 排空到真正空（同阶段B，D 依赖空起步）
        $display("  w_cnt=%0d r_cnt=%0d err=%0d count=%0d", w_cnt, r_cnt, err_cnt, data_count);

        // ---------- D. 写满 / 读空 ----------
        $display("=== 阶段D：写满（读停）→ 检查 full 与写入数 → 全读空 ===");
        wr_half = 5; rd_half = 5;
        rd_stop = 1;                              // 源头停读（写 rd_en=0 会被随机激励覆盖）
        wr_stop = 0; wr_cont = 1;                 // 从空开始连续写满
        full_cnt = w_cnt;
        while (!full) @(posedge wr_clk);          // 一直写到满（恰好 DEPTH 个写）
        wr_stop = 1;                              // 源头停写，防漏写污染读空检查
        @(posedge wr_clk); @(posedge wr_clk);
        $display("  full=%b 写入增量=%0d（期望 %0d） count=%0d（期望 %0d）",
                 full, w_cnt - full_cnt, DEPTH, data_count, DEPTH);
        if (w_cnt - full_cnt != DEPTH) begin
            err_cnt = err_cnt + 1;
            $display("  [ERR] 写满时写入数不是 DEPTH");
        end
        if (data_count != DEPTH) begin
            err_cnt = err_cnt + 1;
            $display("  [ERR] 写满后 data_count 不是 DEPTH");
        end
        r_mark = r_cnt + DEPTH;
        rd_stop = 0; rd_cont = 1;
        while (r_cnt < r_mark) @(posedge rd_clk);
        rd_stop = 1;                              // 源头停读
        repeat (4) @(posedge rd_clk);
        $display("  empty=%b（期望 1） count=%0d（期望 0）", empty, data_count);
        if (empty !== 1'b1) err_cnt = err_cnt + 1;
        if (data_count != 0) err_cnt = err_cnt + 1;

        // ---------- E. 运行中复位 ----------
        $display("=== 阶段E：运行中复位 ===");
        wr_stop = 0; wr_cont = 1; rd_stop = 1;    // 先写一部分进去（读停、不清空）
        repeat (20) @(posedge wr_clk);
        rst = 1;                                   // 打复位脉冲
        repeat (4) @(posedge wr_clk);
        if (!wr_rst_busy) begin
            err_cnt = err_cnt + 1;
            $display("  [ERR] 复位期间 wr_rst_busy 没拉高");
        end
        $display("  复位中：wr_rst_busy=%b rd_rst_busy=%b", wr_rst_busy, rd_rst_busy);
        wr_stop = 1;   // ★ 在释放复位前提前 6 拍停写：释放沿上激励读到的 wr_stop 已稳定为 1，
                        //   杜绝"释放拍 wr_en 仍输出旧值 1 → busy 恰好已清 → 计划外写入"的
                        //   同拍竞态；也封死 busy 清零→w_cnt 清零之间的漏写窗口（漏写的字进
                        //   FIFO，但 exp_mem 随后被清零覆盖 → 读侧全错位）
        repeat (6) @(posedge wr_clk);
        rst = 0;
        while (wr_rst_busy || rd_rst_busy) @(posedge wr_clk);
        repeat (4) @(posedge rd_clk);
        $display("  复位后：empty=%b（期望 1） full=%b（期望 0）", empty, full);
        if (empty !== 1'b1 || full !== 1'b0) err_cnt = err_cnt + 1;

        // 复位后重新收发：期望数组也从头开始记
        w_cnt = 0; r_cnt = 0; rd_fire_d = 0;
        wr_stop = 0; rd_stop = 0; wr_cont = 1; rd_cont = 1;
        while (w_cnt < 500) @(posedge wr_clk);
        wr_stop = 1;                              // 源头停写，排空 500 字
        while (r_cnt < 500) @(posedge rd_clk);
        $display("  复位后重收：w_cnt=%0d r_cnt=%0d err=%0d", w_cnt, r_cnt, err_cnt);

        // ---------- 汇总 ----------
        $display("========================================");
        $display("总写入 %0d 字，总读出 %0d 字，FIFO 水线峰值 %0d", w_cnt, r_cnt, max_used);
        if (err_cnt == 0)
            $display("[PASS] async_fifo：五个阶段全部通过（同步/异步/满空/复位）");
        else
            $display("[FAIL] err=%0d", err_cnt);
        $finish;
    end

    // ---------------- 超时兜底 ----------------
    initial begin
        #20_000_000;
        $display("[FAIL] simulation timeout w_cnt=%0d r_cnt=%0d err=%0d", w_cnt, r_cnt, err_cnt);
        $finish;
    end

endmodule