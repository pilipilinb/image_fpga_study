// ============================================================================
// denoise_bilateral_core.v —— 双边滤波降噪核（线性 RGB 域，10bit×3，LAT=3）
//
// 算法（与 make_denoise_data.py 的 bilateral_ref 位级同构，见工程要点.md）：
//   d   = |ΔR|+|ΔG|+|ΔB|（L1，≤3069）
//   wr  = (d>CUT) ? 0 : LUT[d]，LUT[d]=round(63·exp(−d²/2σ_r²))，σ_r=120/CUT=374
//   w   = spatial[i][j]×wr，spatial=[1 2 1;2 4 2;1 2 1]（移位实现，0 乘法器）
//   numR/G/B += w×v，den += w（三通道共用一个 den）
//   out = sat_1023( (num×inv + 2^19) >> 20 )，inv = ROM[den−252] = round(2^20/den)
//
// 【三个定点技巧（面试点）】
//   ① 值域核查 LUT 而不算 exp：FPGA 没有 exp，且 d>CUT=3.11σ 后 round 值恒 0，
//     512 项（1 个分布式 ROM）够用，88% 的名义表项是浪费
//   ② 归一化除法 → 倒数 ROM + 1 次乘法：inv=round(2^20/den) 一次查表，
//     三个通道共用（den 只开一个）；den 下界 252 = 中心项 spatial4×wr63 恒存在
//   ③ round-half-up：+2^19 再 >>20，无偏置
//
// 【流水 LAT=3（拍级安排）】
//   T0 组合：9 邻居各自 d → 值域 LUT **异步读**（分布式 ROM；单数组 9 读口，
//           综合器自动做 read-port replication）→ wr → w×v（27 个 8×10 小乘）
//           → 加树 → numR/G/B/den 组合值
//   T1 末：num/den 寄存（第 1 拍）
//   T2：addr = den−252 → 倒数 ROM 同步读（BRAM，1 拍）→ T2 末 inv_r；num 同拍打 → num_q
//   T3：乘+round+移位+饱和（组合）→ T3 末输出寄存 = dout
//   ★ 上板时序紧的拆法：LUT 改同步读拆一级（LAT=4）——文档面试点
//
// 【乘法位宽（上界证明）】
//   num ≤ den×1023（每项 w×v ≤ w×1023，Σw=den）恒成立
//   ⇒ num×inv ≤ den×1023×(2^20/den + 0.5) ≤ 1023·2^20 + den×511 < 2^30
//   ⇒ (乘积+2^19) 的 [29:20] 就是 10bit 结果且天然 ≤1023；
//     饱和改看 34bit 乘积的高位 [33:30]（取位后比较恒假，是无效防御）
//
// 【反压/冻结】run_en = !stall（stage 传入）：全部流水寄存器 + ROM 读使能统一门控；
//   stall 期间行缓存同步冻结（输入不动），流水原地保持，恢复无缝（M3 hold_in 同族）。
// ============================================================================
`timescale 1ns/1ps

`ifndef DENOISE_BILATERAL_CORE_V_INC
`define DENOISE_BILATERAL_CORE_V_INC

module denoise_bilateral_core #(
    parameter DW      = 10,    // 单通道位宽
    parameter CUT     = 747,   // 值域截断点 = ceil(3.11σ_r)；σ_r=240（按 σ_n=48 标定）
    parameter INV_SH  = 20,    // 倒数定标 2^20
    parameter DEN_OFF = 252    // den 下界（中心项 4×63）
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire [9*3*DW-1:0]   win_flat,  // 3×3 窗口（9×30=270bit，k=行*3+列，W[4]=中心）
    input  wire                win_valid,
    input  wire                run_en,    // = !stall：流水全局冻结门控
    output reg  [3*DW-1:0]     dout,      // {r,g,b} 各 10bit
    output reg                 dout_valid
);

    localparam LUT_AW = 10;                // 值域 LUT：1024 项（CUT=747 需 ≥748）
    localparam ROM_AW = 10;                // 倒数 ROM：1024 项

    //========================================================================
    // 系数表（$readmemh 与 Python golden 同源生成——消除浮点/定点不一致）
    //========================================================================
    (* ram_style = "distributed" *) reg [5:0] range_lut [0:(1<<LUT_AW)-1];
    initial $readmemh("range_lut.coe", range_lut);
    (* ram_style = "block" *)       reg [12:0] inv_rom [0:(1<<ROM_AW)-1];
    initial $readmemh("inv_rom.coe", inv_rom);

    //========================================================================
    // 拆窗口：W[k] = win_flat[k*30 +: 30]，行0 顶、列0 左，W[4] = 中心（N=3）
    //========================================================================
    wire [3*DW-1:0] W [0:8];
    genvar g;
    generate
        for (g = 0; g < 9; g = g + 1) begin : g_unpk
            assign W[g] = win_flat[g*3*DW +: 3*DW];
        end
    endgenerate

    wire [DW-1:0] cR = W[4][3*DW-1:2*DW];
    wire [DW-1:0] cG = W[4][2*DW-1:  DW];
    wire [DW-1:0] cB = W[4][  DW-1:    0];

    function [DW-1:0] abs10; input [DW-1:0] a, b;
        abs10 = (a > b) ? (a - b) : (b - a);
    endfunction
    function [2*DW:0] l1_3ch;                   // 三通道 L1 距离（≤3069）
        input [DW-1:0] aR, aG, aB, bR, bG, bB;
        l1_3ch = abs10(aR, bR) + abs10(aG, bG) + abs10(aB, bB);
    endfunction

    //========================================================================
    // T0 组合：9 邻居各自 d → LUT 异步读 → wr → w×v → 加树
    //   邻居 k 的 spatial 系数（行*3+列 布局）：[0]=1 [1]=2 [2]=1
    //                                            [3]=2 [4]=4 [5]=2
    //                                            [6]=1 [7]=2 [8]=1
    //   wr×v 为 6×10 乘（17bit）；×spatial(≤4 移位) 后 ≤257796（18bit）；
    //   9 项和 ≤ 2^20（上界见文件头）
    //========================================================================
    wire [DW-1:0] vR [0:8];
    wire [DW-1:0] vG [0:8];
    wire [DW-1:0] vB [0:8];
    wire [2*DW:0] d9 [0:8];
    wire [5:0]    wr [0:8];
    genvar gi;
    generate
        for (gi = 0; gi < 9; gi = gi + 1) begin : g_px
            assign vR[gi] = W[gi][3*DW-1:2*DW];
            assign vG[gi] = W[gi][2*DW-1:  DW];
            assign vB[gi] = W[gi][  DW-1:    0];
            assign d9[gi] = l1_3ch(vR[gi], vG[gi], vB[gi], cR, cG, cB);
            // LUT 地址保护：d 12bit > 地址 9bit，越界 mux 在地址进 ROM 之前
            wire [LUT_AW-1:0] lut_a = (d9[gi] > CUT) ? {LUT_AW{1'b0}} : d9[gi][LUT_AW-1:0];
            assign wr[gi] = (d9[gi] > CUT) ? 6'd0 : range_lut[lut_a];
        end
    endgenerate

    // w = spatial×wr（1/2/4 移位，0 乘法器）
    wire [DW+7:0] w0 = {3'd0, wr[0]};        // ×1
    wire [DW+7:0] w1 = {2'd0, wr[1], 1'b0};  // ×2
    wire [DW+7:0] w2 = {3'd0, wr[2]};        // ×1
    wire [DW+7:0] w3 = {2'd0, wr[3], 1'b0};  // ×2
    wire [DW+7:0] w4 = {1'd0, wr[4], 2'b0};  // ×4（中心）
    wire [DW+7:0] w5 = {2'd0, wr[5], 1'b0};  // ×2
    wire [DW+7:0] w6 = {3'd0, wr[6]};        // ×1
    wire [DW+7:0] w7 = {2'd0, wr[7], 1'b0};  // ×2
    wire [DW+7:0] w8 = {3'd0, wr[8]};        // ×1

    // w×v（8×10 乘）+ 9 项加树
    wire [2*DW+7:0] nR = w0*vR[0] + w1*vR[1] + w2*vR[2] + w3*vR[3] + w4*vR[4] +
                        w5*vR[5] + w6*vR[6] + w7*vR[7] + w8*vR[8];
    wire [2*DW+7:0] nG = w0*vG[0] + w1*vG[1] + w2*vG[2] + w3*vG[3] + w4*vG[4] +
                        w5*vG[5] + w6*vG[6] + w7*vG[7] + w8*vG[8];
    wire [2*DW+7:0] nB = w0*vB[0] + w1*vB[1] + w2*vB[2] + w3*vB[3] + w4*vB[4] +
                        w5*vB[5] + w6*vB[6] + w7*vB[7] + w8*vB[8];
    wire [9:0]      dn = w0 + w1 + w2 + w3 + w4 + w5 + w6 + w7 + w8;   // ≤1008

    //========================================================================
    // T1：num/den 寄存（run_en 门控）
    //========================================================================
    reg [2*DW+1:0] numR_r, numG_r, numB_r;     // 22bit 载体（实际 ≤2^20）
    reg [9:0]      den_r;
    reg            vld1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            numR_r <= 0; numG_r <= 0; numB_r <= 0; den_r <= 10'd0; vld1 <= 1'b0;
        end else if (run_en) begin
            numR_r <= nR;
            numG_r <= nG;
            numB_r <= nB;
            den_r  <= dn;
            vld1   <= win_valid;
        end
    end

    //========================================================================
    // T2：倒数 ROM 同步读（addr = den−252）+ num 打拍对齐（对齐点）
    //========================================================================
    wire [ROM_AW-1:0] rom_a = den_r - DEN_OFF;      // den ≥ 252 恒成立（中心项兜底）
    reg  [12:0]       inv_r;
    reg  [2*DW+1:0]   numR_q, numG_q, numB_q;
    reg               vld2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            inv_r <= 13'd0;
            numR_q <= 0; numG_q <= 0; numB_q <= 0; vld2 <= 1'b0;
        end else if (run_en) begin
            inv_r  <= inv_rom[rom_a];               // BRAM 同步读 1 拍
            numR_q <= numR_r;                       // ★ num 与 inv 同拍对齐
            numG_q <= numG_r;
            numB_q <= numB_r;
            vld2   <= vld1;
        end
    end

    //========================================================================
    // T3：乘 + round(+2^19) + >>20 + 饱和（组合）→ 输出寄存
    //   乘积 21×13=34bit；上界 < 2^30（文件头证明）→ 取 [29:20] 为 10bit 结果；
    //   饱和看高位 [33:30]（防御性——数学上恒 0）
    //========================================================================
    wire [33:0] pr_full = numR_q * inv_r;
    wire [33:0] pg_full = numG_q * inv_r;
    wire [33:0] pb_full = numB_q * inv_r;
    wire [29:0] pr30 = pr_full[29:0] + 30'h80000;           // +2^19 round-half-up
    wire [29:0] pg30 = pg_full[29:0] + 30'h80000;
    wire [29:0] pb30 = pb_full[29:0] + 30'h80000;
    wire        satR = |pr_full[33:30];
    wire        satG = |pg_full[33:30];
    wire        satB = |pb_full[33:30];
    wire [DW-1:0] oR = satR ? {DW{1'b1}} : pr30[29:20];
    wire [DW-1:0] oG = satG ? {DW{1'b1}} : pg30[29:20];
    wire [DW-1:0] oB = satB ? {DW{1'b1}} : pb30[29:20];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout       <= {3*DW{1'b0}};
            dout_valid <= 1'b0;
        end else if (run_en) begin
            dout       <= {oR, oG, oB};
            dout_valid <= vld2;
        end
        // run_en=0（stall）：输出整组保持（简流稳定性）
    end

endmodule

`endif  // DENOISE_BILATERAL_CORE_V_INC
