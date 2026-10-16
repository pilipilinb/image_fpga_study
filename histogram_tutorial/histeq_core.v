//========================================================================
// histeq_core.v —— 直方图均衡核心（W2 帧级处理：双 BRAM ping-pong）
//
// 这个模块做三件事（按时间顺序循环）：
//   1. 收下一帧的灰度像素，边收边数"每个灰度值出现了几次"（直方图统计）
//   2. 帧与帧之间的空白期，把统计表改造成"映射表"（CDF 前缀和）
//   3. 下一帧来的时候，每个像素查"映射表"输出均衡后的值 J
//
// 所以输出永远比输入晚 1 帧：帧 0 只统计不出图，帧 1 起才输出。
// （像素级处理如 CSC 是"来一个算一个"；帧级处理必须"先看完一整帧
//   才知道怎么映射"，这就是延迟 1 帧的原因）
//
// 两块 BRAM（ram0/ram1）轮流当"统计表"和"映射表"，一帧一换：
//   帧 0：ram0 统计、ram1 映射（垃圾，不输出）
//   帧 1：ram1 统计、ram0 映射（用帧 0 的 CDF）
//   帧 2：ram0 统计、ram1 映射（用帧 1 的 CDF）
//   ...就这样来回倒（ping-pong），所以谁也不会闲着
//
// 帧间空白期（v-blank）要做两件事，共需 257+256=513 拍：
//   A. 把"本帧统计表"原地改造成 CDF 表（供下一帧映射用）
//   B. 把"本帧映射表"清零（它下一帧要当统计表，必须从 0 开始）
//   TB 帧间给 640 拍空白；真实 1080p 的 v-blank 约 99000 拍，远够。
//========================================================================
`timescale 1ns/1ps

module histeq_core #(
    parameter IMG_W = 112,        // 图像宽
    parameter IMG_H = 103,        // 图像高
    parameter S     = 14          // 定点化右移位数（K=(255<<S)/N）
)(
    input               clk,
    input               rst_n,        // 低电平复位（异步）
    input  [7:0]        y,            // 8bit 灰度（CSC Y 通道），一帧一帧流进来
    input               y_en,         // 灰度有效：y_en=1 时 y 才是一个真像素
                                      // （行间/帧间的空白期 y_en 为 0）

    output reg  [7:0]   o_j,          // 均衡结果（8bit 灰度，帧 1 起有效）
    output              o_valid       // 与 o_j 同拍：=1 时 o_j 才是有效输出
);

    localparam N  = IMG_W * IMG_H;             // 每帧像素总数（112×103=11536）
    localparam HW = $clog2(N + 1);             // 一个 bin 最多能数到 N，14bit 够存
    localparam K  = (255 << S) / N;            // 定点系数：把"除以 N"变成"乘 K 再右移"
    localparam KW = $clog2(K + 1);             // K 的位宽（9bit）

    //========================================================================
    // 状态机：模块一共干 6 种活，每种是一个状态
    //   ST_PRE   开机先把统计表清成 0（BRAM 上电内容不定，必须写 0）
    //   ST_WAIT  等第一帧像素来（y_en 拉高）
    //   ST_STAT  统计期：像素来了就数直方图（边统计边输出上一帧的映射结果）
    //   ST_DRAIN 帧末停 2 拍：让最后几个像素的映射结果从流水线里吐完
    //   ST_CDF   空白期：把统计表改造成 CDF 表（累计分布）
    //   ST_CLEAR 空白期：把另一块表清零（它下一帧要当统计表用）
    //========================================================================
    localparam ST_STAT  = 3'd0;   // 统计期：数像素（数满一帧=帧结束判定）＋数直方图
    localparam ST_CDF   = 3'd1;   // 空白期：统计表 → CDF 表（257 拍）
    localparam ST_CLEAR = 3'd2;   // 空白期：映射表清零（256 拍），供下帧当统计表
    localparam ST_WAIT  = 3'd3;   // 等新帧第一像素
    localparam ST_PRE   = 3'd4;   // 仅开机一次）：清"统计表"（ram0，上电内容是垃圾）
    localparam ST_DRAIN = 3'd5;   // 帧末排空 2 拍：映射流水（读 1 拍+输出 1 拍）
                                  // 没吐完就被 CDF 抢走读口会丢最后像素（实测踩坑）

    reg [2:0] state, state_nxt;       // 当前状态 / 下一拍状态
    reg [1:0] frame_cnt;              // 已经统计完的帧数。
                                      // 帧 0 结束时变成 1，帧 1 结束时变成 2...
                                      // 用途①：frame_cnt>=1 才允许输出（帧 0 无映射表）
                                      // 用途②：它的最低位决定"本帧统计用哪块 BRAM"
    reg [1:0] drain_cnt;              // ST_DRAIN 里数 2 拍用的计数器（0→1→2）

    //------------------------------------------------------------------------
    // 像素计数：判断"一帧输完了没有"
    //   pix_cnt 每来一个有效像素 +1，数到 N-1（=11535）就停住不再加。
    //   这时如果 y_en 又变 0（帧末空白来了）→ frame_done=1 → 帧结束，去处理 CDF
    //------------------------------------------------------------------------
    reg [14:0] pix_cnt;
    wire       frame_full = (pix_cnt == N - 1);        // 一帧 N 个像素已收齐
    wire       frame_done = frame_full && !y_en;       // 收齐 + 空白 = 确认帧结束

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= ST_PRE;
            frame_cnt <= 2'd0;
            pix_cnt   <= 15'd0;
        end else begin
            state <= state_nxt;
            if (state == ST_STAT) begin
                if (frame_done) frame_cnt <= frame_cnt + 1'b1;  // 一帧干完，帧数+1
                if (y_en && !frame_full) pix_cnt <= pix_cnt + 1'b1;  // 数像素，数满即停
            end else if (state == ST_WAIT) begin
                if (y_en) pix_cnt <= 15'd1;     // 新帧第一个像素：计数从 1 开始
                else      pix_cnt <= 15'd0;
            end else begin
                pix_cnt <= 15'd0;                          // 其他状态不需要计数，清零
            end
            if (state == ST_DRAIN) drain_cnt <= drain_cnt + 1'b1;
            else                   drain_cnt <= 2'd0;
        end
    end

    //========================================================================
    // 两块 BRAM：ram0 和 ram1，每块 256 格（地址 0~255 = 灰度值），
    // 每格存一个 14bit 的数。每块都有独立的"写口"和"读口"（简单双口）：
    //   写口：wena=1 时把 wdata 存到 waddr 地址
    //   读口：每个时钟沿把 raddr 地址的内容读到 rdata（比地址晚 1 拍出来）
    // 为什么要双口：统计时同一拍要"读当前像素的计数"又"写回上一像素的计数"，
    // 两个地址不一样，单端口一个地址口做不到。
    //========================================================================
    reg [HW-1:0] ram0 [0:255];
    reg [HW-1:0] ram1 [0:255];

    reg          wena0, wena1;          // 写使能（=1 这一拍执行写入）
    reg  [7:0]   waddr0, waddr1;        // 写地址（0~255 = 写哪个灰度格子）
    reg  [HW-1:0] wdata0, wdata1;       // 写数据（要写进去的数）
    reg  [7:0]   raddr0, raddr1;        // 读地址（0~255 = 读哪个灰度格子）
    reg  [HW-1:0] rdata0, rdata1;       // 读数据（读口输出，比 raddr 晚 1 拍）

    // 注意读口的 write-first 写法（重要！）：
    // 如果这一拍"写口正在写地址 X"且"读口也在读地址 X"（同一个格子），
    // 读口输出 = 刚写进去的新值，而不是旧值。
    // 这是统计正确性的关键：连续两个像素灰度相同（比如都是 227）时，
    // 第二个像素读到的必须是第一个像素"+1 之后"的值，否则第二个 +1 会被覆盖丢
    // （iverilog 默认 read-first 会丢统计，实测 Σh 少 775，踩坑记录见 README）
    always @(posedge clk)   if (wena0) ram0[waddr0] <= wdata0;   // ram0 写口
    always @(posedge clk or negedge rst_n) begin                 // ram0 读口
        if (!rst_n) rdata0 <= {HW{1'b0}};
        else if (wena0 && raddr0 == waddr0) rdata0 <= wdata0;   // 写读同一格：给新值
        else                                rdata0 <= ram0[raddr0];   // 正常读：给旧值
    end
    always @(posedge clk)   if (wena1) ram1[waddr1] <= wdata1;   // ram1 写口
    always @(posedge clk or negedge rst_n) begin                 // ram1 读口
        if (!rst_n) rdata1 <= {HW{1'b0}};
        else if (wena1 && raddr1 == waddr1) rdata1 <= wdata1;
        else                                rdata1 <= ram1[raddr1];
    end

    //========================================================================
    // ★ stat_is_ram1：本帧的"统计表"是不是 ram1？（1=是，0=不是，那就是 ram0）
    //   frame_cnt 是最低位的 0/1 来回翻转的：帧 0、2、4...（偶数）统计用 ram0，
    //   帧 1、3、5...（奇数）统计用 ram1，另一块自然就是映射表。
    //   例：frame_cnt=0（帧 0 进行中）→ stat_is_ram1=0 → 统计写 ram0、映射读 ram1
    //       frame_cnt=1（帧 1 进行中）→ stat_is_ram1=1 → 统计写 ram1、映射读 ram0
    //========================================================================
    wire stat_is_ram1 = frame_cnt[0];

    //========================================================================
    // ★ cdf_sel：帧间空白期（CDF/CLEAR）该操作哪块表？= frame_cnt 最低位取反
    //   为什么要取反：frame_cnt 在"帧结束那一拍"就立刻 +1（翻成了下一帧的编号），
    //   但空白期要处理的还是"刚结束那一帧"的表，角色必须按上一帧算，所以取反。
    //   例：帧 0 刚结束，frame_cnt 已经 =1 → cdf_sel = 1^1 = 0
    //       → 统计表按"帧 0"算 = ram0（对 ram0 做 CDF 转换）✓
    //       → 映射表 = ram1（对 ram1 清零）✓
    //       如果不用 cdf_sel 而直接用 stat_is_ram1（此时=1），就会去给 ram1 做
    //       CDF、把 ram0 清零——统计结果被清掉、垃圾被做成表（实测帧 1 全 0）
    //========================================================================
    wire cdf_sel = frame_cnt[0] ^ 1'b1;

    //========================================================================
    // y_d1 / y_en_d1：把"当前像素"和"它有没有效"各延迟 1 拍，给统计写口用
    //   统计那一拍的写口要写的是"上一拍来的像素"（h+1 写回），
    //   所以要把 y 和 y_en 打一拍存档。y_d1=上一拍的灰度，y_en_d1=上一拍是否有效。
    //========================================================================
    reg [7:0] y_d1;
    reg       y_en_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_d1    <= 8'd0;
            y_en_d1 <= 1'b0;
        end else begin
            y_d1    <= y;
            y_en_d1 <= y_en;
        end
    end

    //========================================================================
    // CDF/CLEAR 扫描用的三个计数器：
    //   cdf_cnt = CDF 阶段扫地址用的（0 扫到 256，共 257 拍，257 = 256 格写回 + 首拍空转）
    //   clr_cnt = 清零阶段扫地址用的（0 扫到 255，共 256 拍）
    //   acc     = CDF 的累加器：acc = "从 0 号格子到当前格子的计数总和"
    // CDF 转换（把 h 表变成 CDF 表，原地进行）：
    //   每一拍：读口读 h[k]（晚 1 拍出），写口把"累计和"写回 k-1 号格子
    //   → 扫完 256 个格子后，格子 k 里存的就是 Σh[0..k]（前 k+1 个灰度的累计数）
    //========================================================================
    reg [8:0]  cdf_cnt;
    reg [7:0]  clr_cnt;
    reg [HW-1:0] acc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cdf_cnt <= 9'd0;
            clr_cnt <= 8'd0;
            acc     <= {HW{1'b0}};
        end else begin
            case (state)
                ST_CDF: begin
                    if (cdf_cnt == 9'd256) begin
                        cdf_cnt <= 9'd0;                    // 扫完（257 拍后）归零
                    end else begin
                        cdf_cnt <= cdf_cnt + 1'b1;
                        // 进 CDF 的头一拍（cdf_cnt=0）不累加，acc 保持 0；
                        // 从 cdf_cnt=1 起每拍 acc += 读口出来的 h[cdf_cnt-1]
                        if (cdf_cnt != 9'd0)
                            acc <= acc + (cdf_sel ? rdata1 : rdata0);   // 本帧统计表 这里rdata1指的就是CDF(k-1)
                        
                    end
                    clr_cnt <= 8'd0;
                end
                ST_CLEAR: begin
                    if (clr_cnt == 8'd255) 
                    clr_cnt <= 8'd0;  // 扫完 256 拍归零
                    else                  
                    clr_cnt <= clr_cnt + 1'b1;
                    cdf_cnt <= 9'd0;
                    acc     <= {HW{1'b0}};
                end
                ST_PRE: begin
                    if (clr_cnt == 8'd255) clr_cnt <= 8'd0;  // 开机清零扫 256 拍
                    else                  clr_cnt <= clr_cnt + 1'b1;
                    cdf_cnt <= 9'd0;
                    acc     <= {HW{1'b0}};
                end
                default: begin
                    cdf_cnt <= 9'd0;     // 非扫描状态：计数器全复位
                    clr_cnt <= 8'd0;
                    acc     <= {HW{1'b0}};
                end
            endcase
        end
    end

    //========================================================================
    // 端口分派（组合逻辑）：根据"现在处于什么状态"，决定两块 BRAM 的
    // 读口/写口各自接到哪里。一句话总结各状态的分派：
    //   STAT/WAIT/DRAIN：读口两块都读当前像素 y（一块要 +1 统计、一块要查表映射），
    //                    写口只写"统计表"那一块（RMW：h+1 写回 y_d1）
    //   CDF   ：读口读"统计表"的格子 cdf_cnt，写口把累计和写回 cdf_cnt-1
    //   CLEAR ：写口把"映射表"全部格子写 0（读口不用）
    //   PRE   ：写口把"统计表"全部格子写 0（读口不用）
    //========================================================================
    always @(*) begin
        wena0 = 1'b0;  wena1 = 1'b0;              // 默认不写
        waddr0 = 8'd0; waddr1 = 8'd0;
        wdata0 = {HW{1'b0}}; wdata1 = {HW{1'b0}};
        raddr0 = 8'd0; raddr1 = 8'd0;             // 默认读 0 号格（无实际意义）

        case (state)
            // WAIT 里 y_en 拉高的那一拍 = 新帧第一像素，按统计处理；
            // DRAIN 里保持 STAT 的分派，让最后像素的映射结果从流水里吐完
            // （DRAIN 期 y_en 已是 0，y_en_d1 也是 0，所以写口不会误写）
            ST_STAT, ST_WAIT, ST_DRAIN: begin
                raddr0 = y;
                raddr1 = y;
                if (stat_is_ram1) begin              // 本帧统计表是 ram1？
                    wena1  = y_en_d1;                // 只有上一拍确实来了像素才写
                    waddr1 = y_d1;                   // 上一拍像素的灰度（y 打 1 拍得到的存档）。不是当前像素
                    wdata1 = rdata1 + { {(HW-1){1'b0}}, 1'b1 };   // 原计数 +1  ，这里算的是h(k-1)
// waddr1 = y_d1：写地址 = 上一拍像素的灰度（y 打 1 拍得到的存档）。不是当前像素——当前像素的灰度在这一拍刚被读口"预约"读。
// rdata1：读口的同步输出寄存器。读口地址现在指向当前像素 227，但读口晚 1 拍，所以这一拍 rdata1 里还是上一拍地址（226）的内容 = h[226]。
// wdata1 = rdata1 + 1：h[226] + 1，即"灰度 226 出现次数 +1"，和写地址 226 正好配对——把上一拍进来的像素的账记上。      
   
                end else begin                       // 统计表是 ram0
                    wena0  = y_en_d1;
                    waddr0 = y_d1;
                    wdata0 = rdata0 + { {(HW-1){1'b0}}, 1'b1 };
                end
            end


             ST_CDF: begin
                // 读口扫 cdf_cnt（0..255），把统计表的格子和"累计和"配对写回
                //cdf_sel和stat_is_ram1相反，当RAM1在计算h(k)，RAM0在计算cdf(k)
                if (cdf_sel) begin
                    raddr1 = cdf_cnt[7:0];
                    wena1  = (cdf_cnt != 9'd0);       // 头一拍（cdf_cnt=0）没有前值，不写
                    waddr1 = cdf_cnt[7:0] - 8'd1;     // 写回上一拍扫过的格子
                    wdata1 = acc + rdata1;            // 累计和 = 之前的总和 + 刚读的 h[k],这里算的是CDF(k-1)
                end else begin
                    raddr0 = cdf_cnt[7:0];
                    wena0  = (cdf_cnt != 9'd0);
                    waddr0 = cdf_cnt[7:0] - 8'd1;
                    wdata0 = acc + rdata0;
                end
            end
            ST_CLEAR: begin
                // 把"映射表"从头到尾写 0（clr_cnt 扫 0..255）；映射表 = 统计表的反面
                if (cdf_sel) begin
                    wena0  = 1'b1;
                    waddr0 = clr_cnt;
                    wdata0 = {HW{1'b0}};
                end else begin
                    wena1  = 1'b1;
                    waddr1 = clr_cnt;
                    wdata1 = {HW{1'b0}};
                end
            end
            ST_PRE: begin
                // 开机清零：把"统计表"（此时是帧 0 的，frame_cnt=0 → ram0）全写 0
                if (stat_is_ram1) begin
                    wena1  = 1'b1;
                    waddr1 = clr_cnt;
                    wdata1 = {HW{1'b0}};
                end else begin
                    wena0  = 1'b1;
                    waddr0 = clr_cnt;
                    wdata0 = {HW{1'b0}};
                end
            end
            default: ;
        endcase
    end

    //========================================================================
    // 映射路径：像素 y 来了 → 查"映射表"里 CDF[y] → 乘 K 右移 S → 饱和 → 输出 J
    //   （J 就是均衡结果：CDF[y]/N 表示"灰度 y 排在全图前百分之几"，
    //    乘 255 映射成 0~255 的灰度值）
    // 时序：读口晚 1 拍出 CDF，再打 1 拍输出 → 比 y_en 晚 2 拍（valid 链 2 拍）
    //========================================================================
    // map_sel：映射该读哪块表？统计期用 stat_is_ram1 的反（另一块）；
    // 但 DRAIN 排空期 frame_cnt 已 +1，角色翻了，最后像素仍属于上一帧，
    // 所以 DRAIN 期要用"上一帧角色"cdf_sel（它们的反是同一块表）
    wire map_sel = (state == ST_DRAIN) ? cdf_sel : stat_is_ram1;
    wire [HW-1:0] cdf_rd = map_sel ? rdata0 : rdata1;   // 查表读出来的 CDF 值

    wire [HW+KW-1:0] j_prod = cdf_rd * K;          // CDF × K（14bit × 9bit = 23bit）
    wire [8:0]       j_raw  = j_prod >> S;         // 右移 S 位还原（0..382）
    wire [7:0]       j_sat  = (j_raw > 9'd255) ? 8'd255 : j_raw[7:0];  // 超 255 钳住

    reg  map_v1, map_v2;          // valid 链：map_v1 = y_en 打 1 拍，map_v2 再打 1 拍0
    // map_ok：帧 0 没有映射表，禁止输出（frame_cnt 在帧 0 结束时才变 1，
    // 所以 frame_cnt>=1 ⟺ 至少统计完一帧，映射表一定可用）
    wire map_ok = (frame_cnt >= 2'd1);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_j    <= 8'd0;
            map_v1 <= 1'b0;
            map_v2 <= 1'b0;
        end else begin
            map_v1 <= y_en && map_ok;
            map_v2 <= map_v1;
            o_j    <= j_sat;      // 每拍都寄存，与 map_v2 同拍有效
        end
    end
    assign o_valid = map_v2;

    //========================================================================
    // 状态跳转（下一拍去哪）：
    //   STAT 收满一帧+遇空白 → DRAIN（先吐完映射流水）
    //   DRAIN 数满 2 拍      → CDF（统计表→CDF 表）
    //   CDF 扫完 257 拍      → CLEAR（映射表清零）
    //   CLEAR 扫完 256 拍    → WAIT（等下一帧第一像素）
    //   WAIT 等到 y_en=1    → STAT（新一轮统计，frame_cnt 已 +1，角色已互换）
    //========================================================================
    always @(*) begin
        state_nxt = state;
        case (state)
            ST_STAT:  if (frame_done)                    state_nxt = ST_DRAIN;
            ST_DRAIN: if (drain_cnt == 2'd2)             state_nxt = ST_CDF;
            ST_CDF:   if (cdf_cnt == 9'd256)             state_nxt = ST_CLEAR;
            ST_CLEAR: if (clr_cnt == 8'd255)             state_nxt = ST_WAIT;
            ST_PRE:   if (clr_cnt == 8'd255)             state_nxt = ST_WAIT;
            ST_WAIT:  if (y_en)                          state_nxt = ST_STAT;
            default:                                     state_nxt = ST_STAT;
        endcase
    end

endmodule