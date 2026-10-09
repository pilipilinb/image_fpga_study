// ============================================================================
// sharpen_core.v —— USM 锐化核（RGB888，LAT=1）
//
// 算法（与 make_sharpen_data.py 的 sharpen_ref 位级同构）：
//   _ 3×3 高斯模糊（核 [1 2 1;2 4 2;1 2 1]，Σ=16；复用降噪空间核，0 乘法器）：
//       sum  = (p00+p02+p20+p22) + 2·(p01+p10+p12+p21) + 4·p11   （≤16×255=4080）
//       blur = (sum + 8) >> 4                                     （round-half-up）
//   _ USM：out = clip( orig + k·(orig − blur) )，orig = 窗口中心像素
//       修正量用 **"符号-幅值"两路**（不用有符号乘/算术右移）：
//         d   = |orig − blur|                       （无符号，≤255）
//         adj = (d·k_gain + 2^(K_FRAC−1)) >> K_FRAC （幅值 round-half-up）
//         out = (orig ≥ blur) ? orig + adj : orig − adj  → 再饱和到 [0,255]
//       ★ 为什么不用 `signed diff * k >>> FRAC`：Verilog 里 signed 与无符号常量相加
//         会把整式翻成无符号（经典坑），且负数算术右移是 floor 而非就近取整；RTL 与
//         Python golden 只要一处 floor、一处就近就会对不上。幅值两路语义唯一、无歧义。
//
// 【资源】0 乘法器（高斯） + 3 个 a*b（修正量，≤255×1023<2^18，DSP 或 LUT 皆可）
//   —— 标量乘法器换来的"细节增强"，是本模块与降噪/CCM 的资源对比点。
//
// 【LAT = 1】组合算模糊/修正 → 输出寄存一拍。run_en 直接当寄存使能：
//   stall（下游不收）时输出原地保持（= 反压冻结"冻结+保持"铁律），无需额外 hold 寄存器。
//
// 【窗口来源】line_buffer_fifo_nxn（N=3，DW=3*DW_chan=24，pad 全尺寸）
//   win_flat[(i*3+j)*24 +: 24] = 第 i 行第 j 列 tap，{R,G,B}（R 在高位）
//   中心 tap = idx 4 = (1,1) = 当前输出像素 = USM 的 orig
//
// 【复位】纯数据寄存器，同步复位给定义值（无 BRAM 阵列）
// ============================================================================
`timescale 1ns/1ps

`ifndef SHARPEN_CORE_V_INC
`define SHARPEN_CORE_V_INC

module sharpen_core #(
    parameter DW     = 8,      // 单通道位宽（RGB888）
    parameter N      = 3,      // 窗口边长（本核固定 3×3 高斯，N 必须为 3）
    parameter KW     = 10,     // 强度 k_gain 位宽
    parameter K_FRAC = 8       // 强度小数位数：k = k_gain / 2^K_FRAC
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire [N*N*3*DW-1:0] win_flat,   // 3×3 窗口，每 tap 24bit {R,G,B}
    input  wire              win_valid,
    input  wire [KW-1:0]     k_gain,       // 锐化强度分子（k = k_gain/2^K_FRAC）
    input  wire              run_en,       // = !stall：兼作输出寄存使能（冻结门控）
    output reg  [3*DW-1:0]   dout,         // {R,G,B}
    output reg               dout_valid
);

    localparam CW  = 3*DW;                 // 单 tap 位宽（24）
    localparam MAXO = (1 << DW) - 1;       // 255
    // ★【步 0 · 显式定位宽】round 常量按运算位宽定宽。
    //   原写法 `prod + (1 << (K_FRAC-1))` 里的 `1<<7` 是**未定宽常量（32bit）**，
    //   按 Verilog 上下文位宽规则会把整个表达式抬到 32 位 ⇒ 加法器被撑宽、路径变长。
    //   定宽后：prod 只需 DW+KW+1 = 19bit（8×10 乘 ≤18bit，+128 后 19bit）。
    localparam [DW+KW:0] RND = (1 << (K_FRAC-1));

    // ------------------------------------------------------------------------
    // 从打包窗口取第 idx 个 tap 的第 ch 通道（0=R,1=G,2=B）
    //   打包约定：tap = {R, G, B}，R 在高位 ⇒ ch 的偏移 = (2-ch)*DW
    // ------------------------------------------------------------------------
    function [DW-1:0] ch_of;
        input [N*N*CW-1:0] win;
        input integer      idx;            // 0..N*N-1（行主序）
        input integer      ch;             // 0=R,1=G,2=B
        begin
            ch_of = win[idx*CW + (2-ch)*DW +: DW];
        end
    endfunction

    // ------------------------------------------------------------------------
    // 3×3 高斯加权和（角×1 边×2 心×4），max = 16×255 = 4080 < 2^12
    //   归并写法：等价于 [1 2 1;2 4 2;1 2 1] 逐点乘加，但只用加法 + 常数移位
    // ------------------------------------------------------------------------
    function [11:0] gsum;
        input [N*N*CW-1:0] win;
        input integer      ch;
        reg [DW-1:0] p0, p1, p2, p3, p4, p5, p6, p7, p8;
        reg [11:0]   corner, edge_w, ctr;
        begin
            p0 = ch_of(win, 0, ch); p1 = ch_of(win, 1, ch); p2 = ch_of(win, 2, ch);
            p3 = ch_of(win, 3, ch); p4 = ch_of(win, 4, ch); p5 = ch_of(win, 5, ch);
            p6 = ch_of(win, 6, ch); p7 = ch_of(win, 7, ch); p8 = ch_of(win, 8, ch);
            // ★ 步 0：先算进 12bit 定宽中间量，再乘 2/4 用**移位**（而非未定宽常量乘法）。
            //   原写法 `(p0+..)+2*(p1+..)+4*p4` 会因常量 2/4 是 32bit 而把整式抬到 32bit。
            //   注意：变量名不能叫 `edge`（Verilog 保留字，iverilog 直接报 syntax error）。
            corner = p0 + p2 + p6 + p8;                     // ≤1020
            edge_w = p1 + p3 + p5 + p7;                     // ≤1020
            ctr    = p4;
            gsum   = corner + (edge_w << 1) + (ctr << 2);   // ≤4080 < 2^12
        end
    endfunction

    function [DW-1:0] blur_of;
        input [N*N*CW-1:0] win;
        input integer      ch;
        reg [11:0] t;
        begin
            t       = gsum(win, ch) + 12'd8;               // 4088 < 2^12（定宽加数）
            blur_of = t[11:4];                             // /16 round-half-up → ≤255
        end
    endfunction

    // ------------------------------------------------------------------------
    // USM 单通道（符号-幅值两路，无任何 signed 运算）
    // ------------------------------------------------------------------------
    function [DW-1:0] usm;
        input [DW-1:0]  orig;
        input [DW-1:0]  blur;
        input [KW-1:0]  kg;
        reg   [DW+KW:0]   prod;                       // 8×10 乘 ≤18bit，+RND 后 19bit（定宽）
        reg   [DW+3:0]    adj;                        // ≤1019（12bit 足够）
        reg   [DW+4:0]    res;                        // orig+adj ≤1274（13bit）
        begin
            if (orig >= blur) begin
                prod = (orig - blur) * kg;
                adj  = (prod + RND) >> K_FRAC;        // 幅值 round-half-up
                res  = orig + adj;
                // 饱和：res 超过 DW 位的部分**只要有任意一位非零**就钳到满量程
                //   （等价于 res > MAXO，但避免与 32bit 常量比较产生宽比较器）
                usm  = (|res[DW+4:DW]) ? {DW{1'b1}} : res[DW-1:0];
            end else begin
                prod = (blur - orig) * kg;
                adj  = (prod + RND) >> K_FRAC;
                if (adj >= orig) usm = {DW{1'b0}};
                else             usm = orig - adj[DW-1:0];
            end
        end
    endfunction

    // ------------------------------------------------------------------------
    // 三通道组合计算（模糊 + 中心 orig → USM）
    // ------------------------------------------------------------------------
    wire [DW-1:0] bR = blur_of(win_flat, 0);
    wire [DW-1:0] bG = blur_of(win_flat, 1);
    wire [DW-1:0] bB = blur_of(win_flat, 2);
    wire [DW-1:0] oR = ch_of(win_flat, 4, 0);         // 中心 tap idx=4
    wire [DW-1:0] oG = ch_of(win_flat, 4, 1);
    wire [DW-1:0] oB = ch_of(win_flat, 4, 2);

    // ------------------------------------------------------------------------
    // ★【步 2 · 拆流水】T1：寄存 {orig, blur}
    //   原设计 LAT=1：pad mux → gsum → blur → diff → 乘 → round → 饱和 → 输出 全挤在一拍
    //   （OOC 实测 35 级 / WNS −1.93ns @150MHz）。这里把"窗口→模糊"与
    //   "差值→乘法→round→饱和"切成两拍，LAT 1→2。
    //   run_en=0（stall）时整组保持 → 冻结语义不变。
    // ------------------------------------------------------------------------
    localparam LAT = 2;                                 // ★ 必须与 sharpen_stage 对齐链一致
    reg [DW-1:0] oR_q, oG_q, oB_q, bR_q, bG_q, bB_q;
    reg          s1v;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            oR_q <= 0; oG_q <= 0; oB_q <= 0;
            bR_q <= 0; bG_q <= 0; bB_q <= 0;
            s1v  <= 1'b0;
        end else if (run_en) begin
            oR_q <= oR; oG_q <= oG; oB_q <= oB;
            bR_q <= bR; bG_q <= bG; bB_q <= bB;
            s1v  <= win_valid;
        end
    end

    // ------------------------------------------------------------------------
    // T2：USM（差/乘/round/饱和）→ 输出寄存
    // ------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout       <= {3*DW{1'b0}};
            dout_valid <= 1'b0;
        end else if (run_en) begin
            dout       <= { usm(oR_q, bR_q, k_gain),
                            usm(oG_q, bG_q, k_gain),
                            usm(oB_q, bB_q, k_gain) };
            dout_valid <= s1v;
        end
    end

endmodule

`endif  // SHARPEN_CORE_V_INC
