//========================================================================
// dpc_envelope.v —— 包络检测坏点校正核（DPC 工程）
//
// 干什么：拿 5×5 窗口，看中心像素 P 有没有"离同色邻居太远"：
//   太亮（比最亮的同色邻居还高出 thr 以上）→ 认为是亮点 → 抄最亮的邻居
//   太暗（比最暗的同色邻居还低出 thr 以上）→ 认为是死点 → 抄最暗的邻居
//   正常 → 原样输出
//
// 【什么是"同色邻居"】Bayer 图上中心可能是 R/G/B，只有同色的邻居才有可比性。
//   窗口中心固定占 (2,2)，窗口内相对位置 (i,j) 的"绝对颜色"要从中心相位 + 偏移量算：
//       绝对相位 = 中心相位 XOR (i%2, j%2)      ← 别漏掉 XOR 中心相位！
//   于是（窗口 25 点里，中心自己不算）：
//     中心 R（绝对 偶,偶）→ 同色 ⇔ i,j 都偶 → 8 个
//     中心 B（绝对 奇,奇）→ 同色 ⇔ i,j 都偶 → 8 个（跟 R 一样！）
//     中心 G（Gr/Gb，都算绿）→ 同色 ⇔ i,j 同奇偶（都偶 + 都奇）→ 12 个
//   踩过的坑：误把"相对奇奇"当成"绝对奇奇"，导致 B 相位只取了 4 个对角、
//   G 相位取错了 12 个位置——RTL 和 TB 参考同时写错、自检还是 PASS，
//   最后靠"Python 参考用绝对坐标独立实现"才抓出来（双参考的价值）。
//
// 【阈值比较用加法，不用减法】原公式是 P < mn − thr，但 mn−thr 可能变负数，
//   所以改写成 P + thr < mn —— 两边都是非负数，无符号比较就够了（同工程 CSC 思路）。
//
// 【窗口 25 点的命名】W<行><列>，行0 最上、列0 最左、W22 是中心。
// ============================================================================
`timescale 1ns/1ps

module dpc_envelope #(
    parameter THR = 32          // 坏点判定阈值：中心与同色邻居极值差超过它才算坏点
)(
    input               clk,
    input               rst_n,
    input  [199:0]      win_flat,     // 5×5 窗口（25×8bit 打包）
    input  [1:0]        phase,        // 中心相位：00=R 01=Gr 10=Gb 11=B
    input               valid_in,
    output reg  [7:0]   dout,         // 校正后的中心像素（Bayer 数据）
    output              valid_out
);

    localparam PH_R  = 2'b00;
    localparam PH_GR = 2'b01;
    localparam PH_GB = 2'b10;
    localparam PH_B  = 2'b11;

    //========================================================================
    // 拆窗口：W<行><列>（行0 最上、列0 最左、W22 中心）
    //========================================================================
    wire [7:0] W00 = win_flat[0*8  +: 8];
    wire [7:0] W01 = win_flat[1*8  +: 8];
    wire [7:0] W02 = win_flat[2*8  +: 8];
    wire [7:0] W03 = win_flat[3*8  +: 8];
    wire [7:0] W04 = win_flat[4*8  +: 8];
    wire [7:0] W10 = win_flat[5*8  +: 8];
    wire [7:0] W11 = win_flat[6*8  +: 8];
    wire [7:0] W12 = win_flat[7*8  +: 8];
    wire [7:0] W13 = win_flat[8*8  +: 8];
    wire [7:0] W14 = win_flat[9*8  +: 8];
    wire [7:0] W20 = win_flat[10*8 +: 8];
    wire [7:0] W21 = win_flat[11*8 +: 8];
    wire [7:0] W22 = win_flat[12*8 +: 8];   // 中心
    wire [7:0] W23 = win_flat[13*8 +: 8];
    wire [7:0] W24 = win_flat[14*8 +: 8];
    wire [7:0] W30 = win_flat[15*8 +: 8];
    wire [7:0] W31 = win_flat[16*8 +: 8];
    wire [7:0] W32 = win_flat[17*8 +: 8];
    wire [7:0] W33 = win_flat[18*8 +: 8];
    wire [7:0] W34 = win_flat[19*8 +: 8];
    wire [7:0] W40 = win_flat[20*8 +: 8];
    wire [7:0] W41 = win_flat[21*8 +: 8];
    wire [7:0] W42 = win_flat[22*8 +: 8];
    wire [7:0] W43 = win_flat[23*8 +: 8];
    wire [7:0] W44 = win_flat[24*8 +: 8];

    // 两输入的取小/取大（树形拼起来就是找极值，深度浅）
    function [7:0] mn2; 
    input [7:0] a, b; 
    begin mn2 = (a < b) ? a : b; 
    end 
    endfunction

    function [7:0] mx2; 
    input [7:0] a, b; 
    begin mx2 = (a > b) ? a : b; 
    end endfunction

    //========================================================================
    // 同色邻居分组（推导见文件头；关键：判断"同色"要比"绝对坐标奇偶"，
    //   而绝对相位 = 中心相位 XOR 相对位置奇偶 —— 别漏了 XOR 中心相位！）
    //     even8 = i,j 都偶的 8 个（W22 是中心不算）→ R 相位、B 相位都用它
    //     odd4  = i,j 都奇的 4 个（对角）      → 只有 G 相位用得上
    //     G 相位（Gr/Gb 合并）= even8 ∪ odd4 = 12 个
    //========================================================================
    // even8 组（都偶）：W00 W02 W04 W20 W24 W40 W42 W44
    wire [7:0] even_min = mn2(mn2(mn2(W00, W02), mn2(W04, W20)),
                              mn2(mn2(W24, W40), mn2(W42, W44)));
    wire [7:0] even_max = mx2(mx2(mx2(W00, W02), mx2(W04, W20)),
                              mx2(mx2(W24, W40), mx2(W42, W44)));
    // odd4 组（都奇）：W11 W13 W31 W33
    wire [7:0] odd_min  = mn2(mn2(W11, W13), mn2(W31, W33));
    wire [7:0] odd_max  = mx2(mx2(W11, W13), mx2(W31, W33));
    // G 相位 = even8 + odd4（12 个）
    wire [7:0] g12_min  = mn2(even_min, odd_min);
    wire [7:0] g12_max  = mx2(even_max, odd_max);

    // 按相位选组：G（Gr/Gb）用 12 个；R/B 用 even8（8 个）
    wire       is_g       = (phase == PH_GR) || (phase == PH_GB);
    wire [7:0] nb_min     = is_g ? g12_min : even_min;
    wire [7:0] nb_max     = is_g ? g12_max : even_max;

    //========================================================================
    // 判定 + 替换（组合；结果打 1 级寄存器）
    //   亮点：P >  mx + thr        （mx+thr 最大 510，用 9bit 装）
    //   死点：P + thr <  mn        （避开 mn−thr 的负数）
    //========================================================================
    wire [8:0] p_plus_thr  = {1'b0, W22}    + THR;   // 死点
    wire [8:0] mx_plus_thr = {1'b0, nb_max} + THR;  //亮点

    reg [7:0] d_c;
    always @(*) begin
        if ({1'b0, W22} > mx_plus_thr)
            d_c = nb_max;                      // 亮点 → 抄最亮的同色邻居
        else if (p_plus_thr < {1'b0, nb_min})
            d_c = nb_min;                      // 死点 → 抄最暗的同色邻居
        else
            d_c = W22;                         // 正常 → 原样通过
    end

    //========================================================================
    // 输出寄存 + valid 打 1 拍（LAT=1）
    //========================================================================
    reg valid_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout    <= 8'd0;
            valid_r <= 1'b0;
        end else begin
            dout    <= d_c;
            valid_r <= valid_in;
        end
    end

    assign valid_out = valid_r;

endmodule