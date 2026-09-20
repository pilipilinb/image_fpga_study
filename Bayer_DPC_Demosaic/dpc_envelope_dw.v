// ============================================================================
// dpc_envelope_dw.v —— 包络检测坏点校正核（DW 参数化版）
//
// 来源：DPC/dpc_envelope.v（已验证的 8bit 版本）——算法逻辑零改动，仅位宽参数化：
//   ① win_flat 200bit → N*N*DW（RAW10 下 5×5×10 = 250bit）
//   ② 像素拆线 / 极值函数 [7:0] → [DW-1:0]
//   ③ 阈值加法 9bit → DW+2 bit（W22+THR、mx+THR 都是无符号非负加法）
// 算法（见原文件头详细推导）：
//   同色邻居取极值 → 中心 P > mx+thr 为亮点（抄 mx）；P+thr < mn 为死点（抄 mn）；
//   否则原样。同色判定 = 绝对相位 = 中心相位 XOR 相对位置奇偶（窗口数组下标）：
//     even8 = 行列都偶的 8 个 → R/B 中心用；odd4 = 都奇的 4 个 → 仅 G 用；
//     G（Gr/Gb 合并）= even8 ∪ odd4 = 12 个。
// RAW10 阈值建议：THR 按 DW 等比放大（8bit 用 32 → 10bit 用 128，保持 12.5% 比例）。
// 流水：组合判定 + 1 级寄存（LAT=1），valid 同拍。
// ============================================================================
`timescale 1ns/1ps

module dpc_envelope_dw #(
    parameter DW  = 10,     // 像素位宽（RAW10）
    parameter THR = 128     // 坏点判定阈值（8bit 版默认 32，RAW10 等比 128）
)(
    input               clk,
    input               rst_n,
    input  [25*DW-1:0]  win_flat,     // 5×5 窗口（25×DW 打包，(行*5+列)*DW，行0=顶 列0=左）
    input  [1:0]        phase,        // 中心相位：00=R 01=Gr 10=Gb 11=B
    input               valid_in,
    input               hold_in,      // = 下级 ostall：1 时输出寄存器保持（简流稳定性，
                                      //   防"上游已弹出、结果未取走却被下一窗口覆盖"丢数）
    output reg  [DW-1:0] dout,        // 校正后的中心像素（Bayer 域）
    output              valid_out
);

    localparam PH_R  = 2'b00;
    localparam PH_GR = 2'b01;
    localparam PH_GB = 2'b10;
    localparam PH_B  = 2'b11;

    //========================================================================
    // 拆窗口：W[k] = win_flat[(行*5+列)*DW +: DW]，行0 最上、列0 最左，W[12] = 中心
    //   下标对照（旧命名 → 数组下标）：W00→0 W01→1 ... W44→24（k = 行*5+列）
    //========================================================================
    wire [DW-1:0] W [0:24];
    genvar g;
    generate
        for (g = 0; g < 25; g = g + 1) begin : g_unpk
            assign W[g] = win_flat[g*DW +: DW];
        end
    endgenerate

    // 两输入取小/取大（树形拼成极值树）
    function [DW-1:0] mn2; input [DW-1:0] a, b; begin mn2 = (a < b) ? a : b; end endfunction
    function [DW-1:0] mx2; input [DW-1:0] a, b; begin mx2 = (a > b) ? a : b; end endfunction

    //========================================================================
    // 同色邻居分组（窗口下标）：
    //   even8（行列都偶，中心不算）= W0 W2 W4 W10 W14 W20 W22 W24 → R/B 用
    //   odd4（都奇，对角）          = W6 W8 W16 W18              → 仅 G 用
    //   G 相位（Gr/Gb 合并）        = even8 ∪ odd4 = 12 个
    //========================================================================
    wire [DW-1:0] even_min = mn2(mn2(mn2(W[0],  W[2]),  mn2(W[4],  W[10])),
                                 mn2(mn2(W[14], W[20]), mn2(W[22], W[24])));
    wire [DW-1:0] even_max = mx2(mx2(mx2(W[0],  W[2]),  mx2(W[4],  W[10])),
                                 mx2(mx2(W[14], W[20]), mx2(W[22], W[24])));
    wire [DW-1:0] odd_min  = mn2(mn2(W[6], W[8]),  mn2(W[16], W[18]));
    wire [DW-1:0] odd_max  = mx2(mx2(W[6], W[8]),  mx2(W[16], W[18]));
    wire [DW-1:0] g12_min  = mn2(even_min, odd_min);
    wire [DW-1:0] g12_max  = mx2(even_max, odd_max);

    wire       is_g   = (phase == PH_GR) || (phase == PH_GB);
    wire [DW-1:0] nb_min = is_g ? g12_min : even_min;
    wire [DW-1:0] nb_max = is_g ? g12_max : even_max;

    //========================================================================
    // 判定 + 替换（组合；结果打 1 级寄存器）
    //   亮点：P > mx + thr；死点：P + thr < mn（加法改写避开减法负数，两边非负）
    //   加法位宽 DW+2：W22/THR 各最大 2^DW-1，和最大 < 2^(DW+1)+2^DW
    //========================================================================
    wire [DW+1:0] p_plus_thr  = W[12]  + THR;
    wire [DW+1:0] mx_plus_thr = nb_max + THR;

    reg [DW-1:0] d_c;
    always @(*) begin
        if ({2'b00, W[12]} > mx_plus_thr)
            d_c = nb_max;                      // 亮点 → 抄最亮的同色邻居
        else if (p_plus_thr < {2'b00, nb_min})
            d_c = nb_min;                      // 死点 → 抄最暗的同色邻居
        else
            d_c = W[12];                       // 正常 → 原样通过
    end

    //========================================================================
    // 输出寄存 + valid 打 1 拍（LAT=1）；hold_in=1 时整组保持（等下游取走）
    //========================================================================
    reg valid_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout    <= {DW{1'b0}};
            valid_r <= 1'b0;
        end else if (!hold_in) begin
            dout    <= d_c;
            valid_r <= valid_in;
        end
        // hold_in：dout/valid_r 全保持
    end

    assign valid_out = valid_r;

endmodule
