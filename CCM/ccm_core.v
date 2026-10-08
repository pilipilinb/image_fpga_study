// ============================================================================
// ccm_core.v —— 色彩校正矩阵核（CCM，线性 RGB 域 10bit×3，LAT=2）
//
// 算法（与 make_ccm_data.py 的 ccm_ref 位级同构）：
//   acc[i] = Σ_k M_int[i][k]·v_k            （有符号；i=输出通道=行，k=输入通道=列）
//   out[i] = clamp((acc[i] + 2^(FRAC-1)) >>> FRAC, 0, (1<<DW)-1)
//
// 【定点化 Q5.12】
//   系数 = floor(M·2^FRAC + 0.5)，再把"行和残差"补到对角项 ⇒ 行和精确 = 2^FRAC
//     ⇒ 灰阶输入 r=g=b=v ⇒ acc = 4096v ⇒ 输出 = v（逐位严格保持，无 1/4096 直流偏色）
//   FRAC=12 → 系数分辨率 1/4096 ≈ 0.024%
//
// 【位宽与上界证明（10bit 输入；伪代码注释的 25bit 是按 8bit 算的，不够）】
//   MW=16 有符号（|M_int| ≤ 2^15）；输入 v ≤ 1023 → 扩成 DW+1=11bit 有符号
//     （10bit 无符号最大 1023 > 10bit 有符号最大 511，必须扩 1 位）
//   乘积 |C·v| ≤ 2^15 × 1023 = 33,521,664 < 2^25.0  → PW = MW+DW+1 = 27bit 有符号
//   |acc| ≤ 3 × 2^15 × 1023 = 100,564,992 < 2^26.6 → AW = 28bit 有符号 ✓ 无溢出
//   （本矩阵实际 |acc| ≤ (7046+2540+410)×1023 ≈ 2^23.3，余量充足）
//
// 【为什么饱和不可省】负系数做减法会出负值、对角>1 会超上限
//   → clamp[0,1023] 是 CCM 唯一的兜底；少了它会输出非法值域
//
// 【流水 LAT=2】T0 组合：9 个有符号乘 + 3 组 3 项加树；T1 寄存 acc；
//               T2 舍入(+2^11)/算术右移/饱和（组合）→ 输出寄存
//               （时序宽松时可压成 LAT=1：乘加+舍入+clamp 全组合后一次寄存——
//                 全链唯一必须用 DSP 的一级，DSP48 内部带加法器，实测可收）
//
// 【反压】run_en = !stall：T1/T2 两级寄存统一门控；冻结时输出整组保持（简流稳定）
// ============================================================================
`timescale 1ns/1ps

`ifndef CCM_CORE_V_INC
`define CCM_CORE_V_INC

module ccm_core #(
    parameter DW   = 10,    // 单通道位宽
    parameter FRAC = 12,    // 系数定点小数位（Q?.12）
    parameter MW   = 16,    // 系数位宽（有符号）
    parameter AW   = 28     // 累加器位宽（有符号）
)(
    input  wire            clk,
    input  wire            rst_n,
    input  wire [3*DW-1:0] din,        // {r,g,b}
    input  wire            din_valid,
    input  wire            run_en,     // = !stall：流水全局冻结门控
    output reg  [3*DW-1:0] dout,
    output reg             dout_valid
);

    localparam PW = MW + DW + 1;                                 // 乘积位宽（有符号）
    localparam signed [AW-1:0] MAXV_S   = (1 << DW) - 1;         // 输出上限（10bit → 1023）
    localparam signed [AW-1:0] RND_HALF = {{(AW-FRAC){1'b0}}, 1'b1, {(FRAC-1){1'b0}}};  // 2^(FRAC-1) 相当于四舍五入的那个0.5

    // ------------------------------------------------------------------------
    // 系数表：行优先（i*3+k），9 行 16bit 有符号十六进制
    //   $readmemh 与 Python golden 同源生成 → 天然消除"系数定点化不一致"
    // ------------------------------------------------------------------------
    reg signed [MW-1:0] C [0:8];
    initial $readmemh("ccm_coef.coe", C);

    // ------------------------------------------------------------------------
    // T0 组合：拆输入（扩 1 位成有符号）→ 9 个有符号乘 → 3 组加树
    // ------------------------------------------------------------------------
    wire signed [DW:0] sr = {1'b0, din[3*DW-1 -: DW]};    // R
    wire signed [DW:0] sg = {1'b0, din[2*DW-1 -: DW]};    // G
    wire signed [DW:0] sb = {1'b0, din[    DW-1:   0]};   // B

    wire signed [PW-1:0] p0 = C[0] * sr;   // 行0(R')：R 的份量
    wire signed [PW-1:0] p1 = C[1] * sg;
    wire signed [PW-1:0] p2 = C[2] * sb;
    wire signed [PW-1:0] p3 = C[3] * sr;   // 行1(G')
    wire signed [PW-1:0] p4 = C[4] * sg;
    wire signed [PW-1:0] p5 = C[5] * sb;
    wire signed [PW-1:0] p6 = C[6] * sr;   // 行2(B')
    wire signed [PW-1:0] p7 = C[7] * sg;
    wire signed [PW-1:0] p8 = C[8] * sb;

    wire signed [AW-1:0] accR = p0 + p1 + p2;   // 3 项加权和 = R' 的分子（★有符号）
    wire signed [AW-1:0] accG = p3 + p4 + p5;
    wire signed [AW-1:0] accB = p6 + p7 + p8;

    // ------------------------------------------------------------------------
    // T1：累加结果寄存（DSP → 加树的关键路径独立一拍）
    // ------------------------------------------------------------------------
    reg signed [AW-1:0] aR_r, aG_r, aB_r;
    reg                 vld1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aR_r <= {AW{1'b0}}; aG_r <= {AW{1'b0}}; aB_r <= {AW{1'b0}}; vld1 <= 1'b0;
        end else if (run_en) begin
            aR_r <= accR; aG_r <= accG; aB_r <= accB; vld1 <= din_valid;
        end
    end

    // ------------------------------------------------------------------------
    // T2：round-half-up（+2^(FRAC-1)）→ 算术右移 → 饱和（组合）→ 输出寄存
    //   ★ 加法两侧都必须有符号，否则 Verilog 按无符号做算术移位 → 负数全错
    // ------------------------------------------------------------------------
    wire signed [AW-1:0] sR = (aR_r + RND_HALF) >>> FRAC;
    wire signed [AW-1:0] sG = (aG_r + RND_HALF) >>> FRAC;
    wire signed [AW-1:0] sB = (aB_r + RND_HALF) >>> FRAC;

    function [DW-1:0] sat;
        input signed [AW-1:0] x;
        begin
            if (x[AW-1])         sat = {DW{1'b0}};      // 负（减法项压过头）→ 0
            else if (x > MAXV_S) sat = {DW{1'b1}};      // 超上限（增益项溢出）→ 全 1
            else                 sat = x[DW-1:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout <= {3*DW{1'b0}}; dout_valid <= 1'b0;
        end else if (run_en) begin
            dout       <= {sat(sR), sat(sG), sat(sB)};
            dout_valid <= vld1;
        end
        // run_en=0（stall）：输出整组保持
    end

endmodule

`endif  // CCM_CORE_V_INC
