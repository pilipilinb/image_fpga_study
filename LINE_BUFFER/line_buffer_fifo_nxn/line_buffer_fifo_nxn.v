// ============================================================================
// 模块：line_buffer_fifo_nxn —— FIFO 版参数化 N×N 行缓存（pad 输出 + 简流反压）
//
// 干什么：把逐行光栅扫描的像素流变成 N×N 窗口流，输出与输入同尺寸（每帧 H×W 个
//   窗口，每个输入像素一个窗口），边缘用 replicate padding（边界复制）补齐。
//   定位：8 级 ISP 链路（BLC→DPC→Demosaic→降噪→AWB→CCM→Gamma→锐化）每一级
//   复用的唯一行缓存形态。
//
// 【与 BRAM pad 版（line_buffer_nxn_pad）的关系】
//   功能等价：同样的窗口中心模型（窗口中心 w[K][K] = 当前输出像素）、同样的 pad
//   规则、同样的 sof/eol 语义。区别只在行延迟的实现与其带来的能力：
//     · 行延迟用 N-1 个 FIFO（经 fwft_wrapper 包成 FWFT）级联，而不是 N-1 块 BRAM
//     · ⇒ 输出侧有 out_ready 握手，**可被下游反压**（BRAM pad 版无握手做不到）
//     · ⇒ 集成时 FIFO 整体换成 Xilinx FIFO Generator / AXIS Data FIFO IP
//   代价：帧末造行期 in_ready=0 持续 K*W+K 拍，上游要靠入端弹性 FIFO 吸收
//         （模块本身刻意不做入端 FIFO，保持单一职责 —— 见计划 4.3）
//
// 【行延迟怎么用 FIFO 做（本模块的原理核心）】
//   一个 FIFO 的"延迟"= 它内部当前占用字数。要让第 m 级 FIFO 的输出等于"m 行
//   之前同一列的像素"，就必须让它恒有 IMG_W 个字的占用：
//     · 预热：前 IMG_W 个 beat 只写不读 → 占用 0 → IMG_W
//     · 之后：每个 beat 同拍 写+读（配对）→ 占用恒为 IMG_W
//     · 冻结（下游反压 / 上游气泡）时 写读一起停 → 占用不变、数据原地保留
//   于是"第 n 个 beat 写进去的字，在第 n+IMG_W 个 beat 被读出"，而"相隔 IMG_W 个
//   beat"在行光栅扫描里恰好 = "上一行的同一列"。
//   级联：第 m 级的输入 = 第 m-1 级的输出 ⇒ 第 m 级输出滞后 m 行。
//   ★ 铁律：占用必须严格等于 IMG_W，所以预热结束后"写读必须同拍配对"，
//     既不能只读不写（占用下降 → 延迟变小 → 行错位），也不能只写不读。
//     FIFO 深度取 ≥ IMG_W+1（占用恒为 IMG_W < 深度）保证永不 full、push 永不丢。
//
// 【为什么不需要 adly 对齐延迟链（BRAM 版必需）】
//   FWFT 让"数据 + 有效"同拍出现：第 m 级输出与本拍输入在同一列 c 上，只差行号。
//   所以列向量 col_vec[i] 直接拼装就对齐了，不必再补延迟链；横向移位窗的使能也是
//   本拍 beat（不是 BRAM 版那种延迟 N-1 拍的 valid_d[N-1]）。
//
// 【帧末造行（pad 的代价）】
//   最后 K 行的窗口需要"还不存在的未来行"、最后 K 列的窗口需要"越界的列"。靠把
//   最后一行数据循环多送 K*W+K 拍，把窗口链推过去，让这些窗口有机会吐出来。
//   FIFO 版做法：造行期把第 1 级 FIFO 的输出**原地回写**（pop 一个字、同拍 push
//   回同一个字）→ FIFO 内容原地旋转 → 天然按列循环吐出最后一行数据。
//   （BRAM 版是用 fcol 地址循环扫实现的同构操作）
//   stage2..N-1 照常弹出，被推出的旧行数据靠下一帧帧头自然冲掉。
//
// 【反压冻结链（本模块相对 BRAM pad 版的真正增量）】
//   out_ready=0 且输出寄存器里已有窗口（stall）
//     → freeze：所有 FIFO 停写停读、横向移位窗停、计数器停、in_ready=0
//     → 反压逐级上传（各级 FIFO 不再推进，入端 in_ready=0 → 上游停写）
//   恢复：out_ready=1 → 窗口被取走 → 冻结解除 → 无损续传（FIFO 保序，不会乱序/丢数）
//   ⇒ 模块内部没有"输入弹性"：反压直达上游。这是刻意设计，弹性由链路首尾的
//     AXIS Data FIFO / 入端 FIFO 承担。
//
// 【窗口相位（推导结论，TB 用 golden 模型逐点验证）】
//   第 m 级 FIFO 输出 = 本拍输入的前 m 行、同列；
//   列向量 col_vec[i] = 行 (r-(N-1)+i)、列 c（i=0 顶 .. i=N-1 底 = 本拍输入像素）；
//   横向移位窗在"移位后一拍"给出完整窗口，其中心 = 当前 beat 往前第 K 拍那个 beat
//   的坐标（列跨行回绕时自然对应到上一行末端的中心）。
//   ⇒ 按 beat 顺序正好是光栅序：第 (K*W+K+1) 个 beat 出中心 (0,0) 的窗口，
//     最后一个出中心 (H-1,W-1)，共 H*W 个。造行拍数 = K*W+K。
//   ★ 帧首 K 行/列窗口为什么也对：越界格由输出级 mux 钳位到"边界格"取值，而
//     被钳位选中的那些格子恰好都是真实 beat 位置；FIFO 预热期的脏数据只出现在
//     永远不会被钳位选中的位置（左上 K×K 区域）。
//
// 【in_sof / in_eol 的角色】
//   in_sof（=tuser 帧首）：给了就把 beat/行列计数强制归零（强同步，更稳）；
//     不给也能工作（造行结束会自己归零，帧连续时相位不漂）。
//   in_eol（=tlast 行末）：用于校验/重同步 —— eol 到拍若列计数不在 W-1，按行末
//     强制对齐（正常对齐时与自然计数行为完全一致，等于免费的一致性保险）。
//     内部流水仍以 beat 计数为主，上游把 eol 悬空也不影响功能。
// ============================================================================
`timescale 1ns/1ps

`ifndef LINE_BUFFER_FIFO_NXN_V_INC
`define LINE_BUFFER_FIFO_NXN_V_INC
`include "fwft_wrapper.v"

module line_buffer_fifo_nxn #(
    parameter DW    = 10,       // 像素位宽（Bayer/RAW10 域用 10）
    parameter IMG_W = 640,      // 图像宽度（需 >= N）
    parameter IMG_H = 480,      // 图像高度（需 >= N）
    parameter N     = 5         // 窗口边长（必须是奇数，N>=3）
)(
    input  wire              clk,
    input  wire              rst_n,          // 低有效复位
    // ---- 入侧简流（完整握手）----
    input  wire              in_valid,
    output wire              in_ready,       // 造行期 / FIFO 忙 / 冻结 时为 0
    input  wire [DW-1:0]     in_data,        // 逐行光栅扫描
    input  wire              in_sof,         // 帧首（=tuser）
    input  wire              in_eol,         // 行末（=tlast），用于校验/重同步
    // ---- 出侧简流（完整握手）----
    output wire              out_valid,      // 窗口有效
    input  wire              out_ready,      // 下游可收
    output wire [N*N*DW-1:0] out_win_flat,   // (行*N+列)*DW，行0=顶 列0=左
    output wire              out_sof,        // 该窗口中心是 (0,0)
    output wire              out_eol         // 该窗口中心列是 W-1
);

    localparam K  = (N - 1) / 2;                       // 半窗宽（N 为奇数）
    localparam AW = $clog2(IMG_W);                     // 列地址位宽
    localparam RW = $clog2(IMG_H + 2*K);               // 行计数位宽（造行会推到 H+K）
    localparam DEPTH_FIFO = (1 << $clog2(IMG_W + 1));  // ≥ IMG_W+1，占用恒 IMG_W 永不 full
    localparam TOTAL_WIN  = IMG_H * IMG_W;             // 每帧窗口数
    // 1-based beat 序号区间：第 (K*W+K+1) 个 beat 出中心 (0,0)，到 END_BEAT 出中心 (H-1,W-1)
    localparam START_BEAT  = K*IMG_W + K + 1;
    localparam END_BEAT    = START_BEAT + TOTAL_WIN - 1;   // = (H+K)*W + K
    localparam FLUSH_BEATS = K*IMG_W + K;                  // 帧末造行注入的 beat 数

    // ========================================================================
    // 声明区（寄存器 + 组合信号），全部放在逻辑之前
    // ========================================================================
    reg [31:0]   beat_cnt;      // 本帧已送入流水线的 beat 数（0-based）
    reg [RW-1:0] row_cnt;       // 当前 beat 的行
    reg [AW-1:0] col_cnt;       // 当前 beat 的列
    reg          flush_active;  // 造行中
    reg [31:0]   fc;            // 造行拍计数：0 为过渡拍，1..FLUSH_BEATS 为注入拍
    reg          primed;        // 预热完成（此后写读配对，占用恒 IMG_W）
    reg [RW-1:0] ocr;           // 下一个要输出窗口的中心行
    reg [AW-1:0] occ;           // 下一个要输出窗口的中心列
    reg [RW-1:0] lc_r;          // 锁存：正在输出窗口的中心行（mux 用）
    reg [AW-1:0] lc_c;          // 锁存：正在输出窗口的中心列
    reg          out_valid_r, out_sof_r, out_eol_r;
    reg [DW-1:0] win_reg [0:N*N-1];

    wire [(N-1)*DW-1:0] fifo_dout_flat;
    wire [N-2:0]        fifo_vld_flat;
    wire [N-2:0]        fifo_busy_flat;
    wire [N*DW-1:0]     col_vec;
    wire [N*N*DW-1:0]   win_out_flat;

    // ---- 握手与推进（组合）----
    wire busy     = |fifo_busy_flat;                  // 某个 FIFO 复位同步中
    wire stall    = out_valid_r && !out_ready;        // 输出寄存器有窗口但下游没收
    wire pipe_go  = !stall && !busy;                  // 本拍允许推进
    assign in_ready = rst_n && pipe_go && !flush_active;

    wire din_valid    = in_valid && in_ready;         // 真实输入握手成功
    // 【为什么最后一个造行拍要用 flush_last 而不是 flush_done 电平】fc==FLUSH_BEATS 是电平，
    //   若下游反压正好卡在这一拍，它会持续为高；而 beat 注入要等 pipe_go。用未门控的电平去
    //   清 ocr/occ 计数，会在"还没注入最后一拍"时就把窗口坐标清零 → 帧末窗口内容/sof 全错。
    wire flush_done   = flush_active && (fc == FLUSH_BEATS);    // 电平（仅用于 FSM 判据）
    wire flush_last   = flush_active && (fc == FLUSH_BEATS) && pipe_go;  // 真正注入最后一拍
    wire flush_fire   = flush_active && (fc != 0) && pipe_go;   // 造行注入拍（fc=0 是过渡拍）
    wire shift_fire   = din_valid || flush_fire;      // 本拍确实推进一个 beat
    wire beat_sof     = in_valid && in_ready && in_sof;
    wire end_of_frame = in_valid && in_ready && !flush_active &&
                        (row_cnt == IMG_H - 1) && (col_cnt == IMG_W - 1);
    wire [DW-1:0] beat_pix = flush_fire ? fifo_dout_flat[0 +: DW]  // 造行：原地回写第 1 级输出
                                        : in_data;
    wire [31:0]   beat_idx = beat_sof ? 32'd1 : (beat_cnt + 32'd1);
    wire emit_fire = shift_fire && (beat_idx >= START_BEAT) && (beat_idx <= END_BEAT);

    // ========================================================================
    // 计数器与造行 FSM
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) beat_cnt <= 32'd0;
        else if (shift_fire) begin
            if (flush_last)    beat_cnt <= 32'd0;      // 造行结束 → 下一帧重新起算
            else if (beat_sof) beat_cnt <= 32'd1;      // 本拍是第 1 个 beat
            else               beat_cnt <= beat_cnt + 32'd1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_cnt <= {RW{1'b0}};
            col_cnt <= {AW{1'b0}};
        end
        else if (shift_fire) begin
            if (beat_sof || flush_last) begin
                row_cnt <= {RW{1'b0}};
                col_cnt <= {AW{1'b0}};
            end
            else if (din_valid && in_eol) begin      // eol 重同步：按行末强对齐
                col_cnt <= {AW{1'b0}};
                row_cnt <= row_cnt + 1'b1;
            end
            else if (col_cnt == IMG_W - 1) begin
                col_cnt <= {AW{1'b0}};
                row_cnt <= row_cnt + 1'b1;
            end
            else begin
                col_cnt <= col_cnt + 1'b1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flush_active <= 1'b0;
            fc           <= 32'd0;
        end
        else if (!flush_active) begin
            if (end_of_frame && pipe_go) begin
                flush_active <= 1'b1;
                fc           <= 32'd0;
            end
        end
        else if (pipe_go) begin
            if (fc == FLUSH_BEATS) flush_active <= 1'b0;
            else                   fc <= fc + 32'd1;
        end
    end

    // ========================================================================
    // N-1 级 FIFO 级联：第 m 级输入 = 第 m-1 级输出（第 1 级吃原始像素流）
    //   写：shift_fire（每拍一个 beat）
    //   读：shift_fire && primed（预热后与写严格配对 → 占用恒 = IMG_W）
    // ========================================================================
    // 预热完成：第 IMG_W 个 beat 结束时置位（此后开始 pop）
    //   不随帧清零（FIFO 内容跨帧保持、占用恒 IMG_W），只有复位才清
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) primed <= 1'b0;
        else if (shift_fire && (beat_cnt == IMG_W - 1)) primed <= 1'b1;
    end

    genvar m;
    generate
    for (m = 1; m <= N-1; m = m + 1) begin : g_fifo
        wire [DW-1:0] din_m  = (m == 1) ? beat_pix : fifo_dout_flat[(m-2)*DW +: DW];
        wire [DW-1:0] dout_m;
        wire          vld_m, busy_m;
        fwft_wrapper #(.DW(DW), .DEPTH(DEPTH_FIFO)) u_fwft (
            .clk(clk), .rst_n(rst_n),
            .push(shift_fire),
            .din(din_m),
            .pop(shift_fire && primed),
            .dout(dout_m),
            .out_vld(vld_m),
            .busy(busy_m)
        );
        assign fifo_dout_flat[(m-1)*DW +: DW] = dout_m;
        assign fifo_vld_flat[m-1]  = vld_m;
        assign fifo_busy_flat[m-1] = busy_m;
    end
    endgenerate

    // ---- 列向量：col_vec[i] = 行 (r-(N-1)+i)、列 c 的像素 ----
    //   i = N-1 是本拍输入；i 越小越靠上（越旧的行）
    assign col_vec[(N-1)*DW +: DW] = beat_pix;
    genvar ii;
    generate
    for (ii = 0; ii <= N-2; ii = ii + 1) begin : g_col
        // i 对应第 (N-1-i) 级 FIFO（i=0 → 最深的一级 → 最上面的行）
        assign col_vec[ii*DW +: DW] = fifo_dout_flat[(N-2-ii)*DW +: DW];
    end
    endgenerate

    // ========================================================================
    // 横向移位窗：每个 beat 推进一列 N 行，N 拍后窗内是连续的 N 列
    //   使能 = shift_fire（冻结时不移位，数据原地保留）
    // ========================================================================
    genvar i, j;
    generate
    for (i = 0; i <= N-1; i = i + 1) begin : g_wrow
        for (j = 0; j <= N-1; j = j + 1) begin : g_wcol
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    win_reg[i*N + j] <= {DW{1'b0}};
                else if (shift_fire) begin
                    if (j == N-1) win_reg[i*N + j] <= col_vec[i*DW +: DW];
                    else          win_reg[i*N + j] <= win_reg[i*N + j + 1];
                end
            end
        end
    end
    endgenerate

    // ========================================================================
    // 输出窗口中心坐标（独立计数，只随窗口输出推进）
    //   ★ 为什么不直接用 row_cnt/col_cnt：造行期列计数会回绕（真实列 W-1+K 被记成
    //     K-1），坐标会算错；用"每吐一个窗口 +1"的独立计数器才是干净的光栅坐标。
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ocr <= {RW{1'b0}};
            occ <= {AW{1'b0}};
        end
        else if (beat_sof || flush_last) begin
            ocr <= {RW{1'b0}};                 // 帧首/造行结束：窗口坐标归零
            occ <= {AW{1'b0}};
        end
        else if (emit_fire) begin
            if (occ == IMG_W - 1) begin
                occ <= {AW{1'b0}};
                ocr <= ocr + 1'b1;
            end
            else begin
                occ <= occ + 1'b1;
            end
        end
    end

    // ========================================================================
    // 输出寄存器：emit 拍之后的下一拍，移位窗里才是完整窗口 → 打一拍输出
    //   冻结（pipe_go=0）时不更新：out_valid_r 保持、窗口数据保持 → 下游所见稳定
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lc_r <= {RW{1'b0}};
            lc_c <= {AW{1'b0}};
            out_valid_r <= 1'b0;
            out_sof_r   <= 1'b0;
            out_eol_r   <= 1'b0;
        end
        else if (pipe_go) begin
            if (emit_fire) begin
                lc_r        <= ocr;
                lc_c        <= occ;
                out_sof_r   <= (ocr == {RW{1'b0}}) && (occ == {AW{1'b0}});
                out_eol_r   <= (occ == IMG_W - 1);
                out_valid_r <= 1'b1;
            end
            else if (out_valid_r && out_ready) begin
                out_valid_r <= 1'b0;           // 被下游取走且本拍没有新窗口
            end
        end
    end

    // ========================================================================
    // 输出级 padding mux（与 BRAM pad 版同构）
    //   窗口第 (i,j) 格本该装源坐标 (中心行+i-K, 中心列+j-K) 的像素；越界就钳到
    //   边界（这就是 replicate padding），再反推"这个源坐标在窗内的位置"去取值。
    // ========================================================================
    function [15:0] sel_row;
        input [15:0] ii;
        input [15:0] ocr_v;
        integer      sr;
        begin
            sr = ocr_v + ii - K;
            if (sr < 0)       sr = 0;
            if (sr > IMG_H-1) sr = IMG_H - 1;
            sel_row = sr - ocr_v + K;
        end
    endfunction

    function [15:0] sel_col;
        input [15:0] jj;
        input [15:0] occ_v;
        integer      sc;
        begin
            sc = occ_v + jj - K;
            if (sc < 0)       sc = 0;
            if (sc > IMG_W-1) sc = IMG_W - 1;
            sel_col = sc - occ_v + K;
        end
    endfunction

    genvar oi, oj;
    generate
    for (oi = 0; oi <= N-1; oi = oi + 1) begin : g_out_i
        for (oj = 0; oj <= N-1; oj = oj + 1) begin : g_out_j
            wire [15:0] ri = sel_row(oi, lc_r);
            wire [15:0] cj = sel_col(oj, lc_c);
            assign win_out_flat[(oi*N + oj)*DW +: DW] = win_reg[ri*N + cj];
        end
    end
    endgenerate

    assign out_win_flat = win_out_flat;
    assign out_valid    = out_valid_r;
    assign out_sof      = out_sof_r;
    assign out_eol      = out_eol_r;

endmodule

`endif  // LINE_BUFFER_FIFO_NXN_V_INC