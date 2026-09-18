// ============================================================================
// 模块：async_fifo —— 纯 Verilog 双时钟（异步）FIFO
//
// 干什么：跨时钟域传数据 + 做速率匹配/背压缓冲的通用基础件。
//   接口特意做成和 Xilinx FIFO Generator（独立时钟块）一致，方便把 IP 换成本模块：
//     wr_clk / rd_clk / rst / din / wr_en / rd_en / dout / empty / full
//     data_count / wr_rst_busy / rd_rst_busy
//
// 【读数据时机（重要）】本模块是"标准模式（Standard）"——与 Xilinx IP 的默认模式一致：
//   rd_en 拉高的下一拍，dout 才给出该数据。所以"每个字占一拍"的连续读是：
//     rd_en 常 1（配合 !empty），dout 会晚 1 拍但不会掉字。
//   （若将来需要 FWFT/首字直通：empty=0 时 dout 就已有效——加一级预取寄存器即可，README 有说明）
//
// 【为什么用格雷码】两个时钟域各自维护自己的指针（二进制做加减、格雷码做跨域）：
//   格雷码相邻两个数只变 1 位，跨时钟采样时最多"采到旧值或新值"，不会采出乱码，
//   所以只要各打 2 拍同步，就能安全地判断"空/满"。（这就是异步 FIFO 的核心技巧）
//
// 【空满判断】
//   空（读域）：读指针的"下一个值" == 同步过来的写指针
//   满（写域）：写指针的"下一个值" == {同步过来的读指针的高 2 位取反, 其余不变}
//   指针位宽 = AW+1（多出的最高位就是"绕圈位"，用来区分"空"和"满"）
//   ★ 空满判断必须"寄存一拍"再输出（Cummings 标准）：判断用的是 *_next（前瞻值），
//     而 *_next 又被 empty/full 门控 —— 直接 assign 输出会构成组合逻辑环，
//     占用数=1（空环）或 DEPTH-1（满环）且使能有效时无稳定解：vvp 零延迟无限震荡、
//     事件队列无限膨胀（实测 0.5s 吃 300MB+、时间冻结、超时兜底失效），综合也非法。
//
// 【复位】rst 高有效（同 Xilinx），两个时钟域各自"同步释放"：
//   同步期间对应的 *_rst_busy 为高，模块不工作；释放后 empty=1/full=0，可以正常用。
//   注意 BRAM 存储阵列本身不复位（物理上不可复位），复位只清指针 —— 所以复位后
//   不能读出复位前残留的数据（指针清零后 empty=1，天然读不到）。
//
// 【参数】DW 数据位宽；DEPTH 深度（必须是 2 的幂，默认 512）
// ============================================================================
`timescale 1ns/1ps

module async_fifo #(
    parameter DW    = 8,          // 数据位宽
    parameter DEPTH = 512         // 深度（必须 2 的幂）
)(
    input  wire             wr_clk,
    input  wire             rd_clk,
    input  wire             rst,             // 高有效复位（与 Xilinx FIFO IP 一致）
    input  wire [DW-1:0]    din,
    input  wire             wr_en,
    input  wire             rd_en,
    output reg  [DW-1:0]    dout,
    output wire             full,
    output wire             empty,
    output wire [$clog2(DEPTH):0] data_count, // 读时钟域视角的"可读字数"（0..DEPTH）
    output wire             wr_rst_busy,
    output wire             rd_rst_busy
);

    localparam AW = $clog2(DEPTH);            // 地址位宽；指针用 AW+1 位（多 1 位绕圈位）

    // ------------------------------------------------------------------------
    // 存储阵列：简单双口 BRAM（写口在 wr_clk，读口在 rd_clk）
    //   综合工具会推断成一块真正的双口 BRAM；仿真里两个 always 分别访问数组
    // ------------------------------------------------------------------------
    (* ram_style = "block" *) reg [DW-1:0] mem [0:DEPTH-1];

    // ------------------------------------------------------------------------
    // 指针与同步链
    // ------------------------------------------------------------------------
    reg  [AW:0] wbin,  wgray;                 // 写指针（二进制 / 格雷码）
    reg  [AW:0] rbin,  rgray;                 // 读指针（二进制 / 格雷码）
    reg  [AW:0] rgray_s1, rgray_s2;           // 读指针 → 写时钟域（2 级同步）
    reg  [AW:0] wgray_s1, wgray_s2;           // 写指针 → 读时钟域（2 级同步）

    // 复位同步器：异步断言（rst 一来就置 1）、同步释放（在各自时钟域里逐拍清 0）
    reg  [1:0] wr_rst_sync, rd_rst_sync;
    always @(posedge wr_clk or posedge rst) begin
        if (rst) wr_rst_sync <= 2'b11;
        else     wr_rst_sync <= {wr_rst_sync[0], 1'b0};
    end
    always @(posedge rd_clk or posedge rst) begin
        if (rst) rd_rst_sync <= 2'b11;
        else     rd_rst_sync <= {rd_rst_sync[0], 1'b0};
    end
    assign wr_rst_busy = wr_rst_sync[1];
    assign rd_rst_busy = rd_rst_sync[1];

    // ------------------------------------------------------------------------
    // 二进制 → 格雷码
    // ------------------------------------------------------------------------
    function [AW:0] bin2gray;
        input [AW:0] b;
        begin bin2gray = (b >> 1) ^ b; end
    endfunction

    // ------------------------------------------------------------------------
    // 写时钟域：写指针推进 + 满判断
    // ------------------------------------------------------------------------
    wire [AW:0] wbin_next  = wbin + ((wr_en && !full) ? 1'b1 : 1'b0);
    wire [AW:0] wgray_next = bin2gray(wbin_next);

    // 满：写指针下一个值 == {读指针高 2 位取反, 其余位不变}
    // 【必须寄存一拍，不能直接 assign】full 直接输出会构成
    //   full → wbin_next(写门控) → wgray_next → full 的组合逻辑环：
    //   占用数=DEPTH-1 且 wr_en=1 时无稳定解（零延迟震荡/综合非法）。
    //   前瞻语义：第 DEPTH 个写进行的那一拍 full_val 置 1，下一拍 full=1 挡住
    //   第 DEPTH+1 个写 —— 从空到满恰好成功写入 DEPTH 个字（TB 阶段D 判据）。
    reg  full_r;
    wire full_val = (wgray_next == {~rgray_s2[AW:AW-1], rgray_s2[AW-2:0]});
    always @(posedge wr_clk) begin
        if (wr_rst_busy) full_r <= 1'b0;
        else             full_r <= full_val;
    end
    assign full = full_r;

    always @(posedge wr_clk) begin
        if (wr_rst_busy) begin
            wbin  <= {AW+1{1'b0}};
            wgray <= {AW+1{1'b0}};
        end
        else begin
            wbin  <= wbin_next;
            wgray <= wgray_next;
        end
    end

    // 写存储（只在真正写得进时写）
    always @(posedge wr_clk) begin
        if (wr_en && !full && !wr_rst_busy)
            mem[wbin[AW-1:0]] <= din;
    end

    // 读指针 → 写时钟域（2 级同步）
    always @(posedge wr_clk) begin
        if (wr_rst_busy) begin
            rgray_s1 <= {AW+1{1'b0}};
            rgray_s2 <= {AW+1{1'b0}};
        end
        else begin
            rgray_s1 <= rgray;
            rgray_s2 <= rgray_s1;
        end
    end

    // ------------------------------------------------------------------------
    // 读时钟域：读指针推进 + 空判断 + 数据输出（标准模式：rd_en 下一拍给数）
    // ------------------------------------------------------------------------
    wire rd_fire    = rd_en && !empty;                       // 真正读走一个字
    wire [AW:0] rbin_next  = rbin + (rd_fire ? 1'b1 : 1'b0);
    wire [AW:0] rgray_next = bin2gray(rbin_next);

    // 【必须寄存一拍，不能直接 assign】empty 直接输出会构成
    //   empty → rd_fire(读门控) → rbin_next → rgray_next → empty 的组合逻辑环：
    //   占用数=1 且 rd_en=1 时无稳定解（零延迟震荡/综合非法）。
    //   前瞻语义：最后一个字被读走的那一拍 empty_val 置 1，下一拍 empty=1 挡住
    //   后续读 —— 不会过读。
    reg  empty_r;
    wire empty_val = (rgray_next == wgray_s2);               // 读指针下一个值 == 同步来的写指针
    always @(posedge rd_clk) begin
        if (rd_rst_busy) empty_r <= 1'b1;
        else             empty_r <= empty_val;
    end
    assign empty = empty_r;

    always @(posedge rd_clk) begin
        if (rd_rst_busy) begin
            rbin   <= {AW+1{1'b0}};
            rgray  <= {AW+1{1'b0}};
            dout   <= {DW{1'b0}};
        end
        else begin
            rbin  <= rbin_next;
            rgray <= rgray_next;
            if (rd_fire)
                dout <= mem[rbin[AW-1:0]];                   // 标准模式：下一拍出数
        end
    end

    // 写指针 → 读时钟域（2 级同步）
    always @(posedge rd_clk) begin
        if (rd_rst_busy) begin
            wgray_s1 <= {AW+1{1'b0}};
            wgray_s2 <= {AW+1{1'b0}};
        end
        else begin
            wgray_s1 <= wgray;
            wgray_s2 <= wgray_s1;
        end
    end

    // ------------------------------------------------------------------------
    // data_count：读时钟域视角（同步过来的写指针 - 本地读指针）
    //   注意：跨域同步有 2~3 拍延迟，所以这个数比"真实剩余字数"略保守（偏小），
    //   用来做"剩多少水"的判断足够；要绝对精确只能在单时钟域使用。
    // ------------------------------------------------------------------------
    function [AW:0] gray2bin;
        input [AW:0] g;
        integer i;
        begin
            gray2bin[AW] = g[AW];
            for (i = AW-1; i >= 0; i = i - 1)
                gray2bin[i] = gray2bin[i+1] ^ g[i];
        end
    endfunction

    wire [AW:0] wbin_sync_r = gray2bin(wgray_s2);
    assign data_count = wbin_sync_r - rbin;                  // 位宽 AW+1，差值天然落在 0..DEPTH

endmodule