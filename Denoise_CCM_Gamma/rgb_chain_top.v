// ============================================================================
// rgb_chain_top.v —— M5.2 RGB 三段链：降噪 → CCM → Gamma（可参数切换顺序做对照实验）
//
//   in(简流, 线性 RGB 3×10bit) ─► 降噪 ─► CCM ─► Gamma ─► out(简流, RGB888 24bit)
//                                  ↑______ SWAP_DC=1 时两级互换 ______↑
//
// 【本模块的两个目的】
//   ① 交付"三段链"这一级工程件：把 M4 三个模块按链路顺序串起来，跑通 30bit 进 / 24bit 出；
//   ② 提供**顺序可交换性实验**的唯一变量 —— `SWAP_DC`：
//        SWAP_DC=0（默认，本工程链路顺序）: 降噪 → CCM → Gamma
//        SWAP_DC=1（对照）              : CCM → 降噪 → Gamma
//      除这一个参数外，例化、参数、激励、判据全部相同 ⇒ 差异只可能来自"谁在前"。
//
// 【为什么这个顺序问题值得做实验】
//   降噪是**非线性**算子（值域权重依赖像素值本身），CCM 是**线性**矩阵乘（含 Q5.12 舍入 + 饱和）。
//   ⇒ 两者**不可交换**（linear∘nonlinear ≠ nonlinear∘linear），位级必然不同。
//   到底哪种更好，必须用"与无噪声理想图的 PSNR/SSIM"来定量回答，不能靠想当然。
//
// 【延迟账（用于理解链的相位，不影响功能）】
//   降噪：窗口寄存 1 + 核 6 = 7 拍（含行缓存 K·W+K，帧内还有造行期 in_ready=0 的空洞）
//   CCM ：2 拍         Gamma：1 拍
//   ⇒ SWAP_DC=0 时 in→out 总延迟 = 7 + 2 + 1 = 10 拍；SWAP_DC=1 时 = 2 + 7 + 1 = 10 拍
//     **总延迟与顺序无关**（加法交换律），所以两种顺序可以直接逐拍对齐比较。
//
// 【bypass 语义（沿用各模块，别混用）】
//   bp_denoise：**帧级**配置（含行缓存 → 只能在排空点切换，见 denoise_stage 头注释）
//   bp_ccm / bp_gamma：可**任意拍**切换（等延迟旁路，两路同 LAT、同 run 门控）
// ============================================================================
`timescale 1ns/1ps

`ifndef RGB_CHAIN_TOP_V_INC
`define RGB_CHAIN_TOP_V_INC
`include "denoise_stage.v"
`include "ccm_stage.v"
`include "gamma_stage.v"

module rgb_chain_top #(
    parameter DW      = 10,     // 单通道位宽（线性 RGB 域）
    parameter IMG_W   = 640,
    parameter IMG_H   = 480,
    parameter N       = 3,      // 降噪窗口边长
    parameter FRAC    = 12,     // CCM 系数小数位（Q5.12）
    parameter OW      = 8,      // 输出单通道位宽（RGB888）
    parameter SWAP_DC = 0       // ★ 0 = 降噪→CCM（本工程）; 1 = CCM→降噪（对照）
)(
    input  wire              clk,
    input  wire              rst_n,
    // ---- bypass（各段独立；语义见文件头）----
    input  wire              bp_denoise,
    input  wire              bp_ccm,
    input  wire              bp_gamma,
    // ---- 入侧简流（线性 RGB 3×10bit）----
    input  wire              in_valid,
    output wire              in_ready,
    input  wire [3*DW-1:0]   in_data,
    input  wire              in_sof,
    input  wire              in_eol,
    // ---- 出侧简流（RGB888 3×8bit）----
    output wire              out_valid,
    input  wire              out_ready,
    output wire [3*OW-1:0]   out_data,
    output wire              out_sof,
    output wire              out_eol
);

    // ---- 链首级 in_ready（谁在链首随 SWAP_DC 变，故先过局部 wire 再驱动端口）----
    wire              first_rdy;

    // ---- 中间/出口节点：dn_* 恒为"降噪级输出"，cc_* 恒为"CCM 级输出"（与位置无关）----
    //   改名会让阅读者误以为与顺序绑定；这里刻意用"级名"而不是"第几级"
    wire              dn_v, dn_rdy, dn_sof, dn_eol;
    wire [3*DW-1:0]   dn_d;
    wire              cc_v, cc_rdy, cc_sof, cc_eol;
    wire [3*DW-1:0]   cc_d;

    // ---- 送给 Gamma 的简流（= 两级里"最后那一级的输出"，随顺序变）----
    wire              g_v, g_rdy, g_sof, g_eol;
    wire [3*DW-1:0]   g_d;

    generate
    if (SWAP_DC == 0) begin : g_denoise_first
        // ---------------- 降噪 → CCM ----------------
        denoise_stage #(.DW(DW), .IMG_W(IMG_W), .IMG_H(IMG_H), .N(N)) u_dn (
            .clk(clk), .rst_n(rst_n), .bypass(bp_denoise),
            .in_valid(in_valid), .in_ready(first_rdy), .in_data(in_data),
            .in_sof(in_sof),   .in_eol(in_eol),
            .out_valid(dn_v),  .out_ready(dn_rdy),  .out_data(dn_d),
            .out_sof(dn_sof),  .out_eol(dn_eol)
        );
        ccm_stage #(.DW(DW), .FRAC(FRAC)) u_ccm (
            .clk(clk), .rst_n(rst_n), .bypass(bp_ccm),
            .in_valid(dn_v),  .in_ready(dn_rdy),  .in_data(dn_d),
            .in_sof(dn_sof),  .in_eol(dn_eol),
            .out_valid(cc_v), .out_ready(cc_rdy), .out_data(cc_d),
            .out_sof(cc_sof), .out_eol(cc_eol)
        );
        // CCM 是最后那一级 → 它的输出进 Gamma，它的 in_ready 由 Gamma 给出
        assign cc_rdy = g_rdy;
        assign g_v = cc_v; assign g_d = cc_d; assign g_sof = cc_sof; assign g_eol = cc_eol;
    end else begin : g_ccm_first
        // ---------------- CCM → 降噪（对照顺序）----------------
        ccm_stage #(.DW(DW), .FRAC(FRAC)) u_ccm (
            .clk(clk), .rst_n(rst_n), .bypass(bp_ccm),
            .in_valid(in_valid), .in_ready(first_rdy), .in_data(in_data),
            .in_sof(in_sof),   .in_eol(in_eol),
            .out_valid(cc_v),  .out_ready(cc_rdy),  .out_data(cc_d),
            .out_sof(cc_sof),  .out_eol(cc_eol)
        );
        denoise_stage #(.DW(DW), .IMG_W(IMG_W), .IMG_H(IMG_H), .N(N)) u_dn (
            .clk(clk), .rst_n(rst_n), .bypass(bp_denoise),
            .in_valid(cc_v),  .in_ready(cc_rdy),  .in_data(cc_d),
            .in_sof(cc_sof),  .in_eol(cc_eol),
            .out_valid(dn_v), .out_ready(dn_rdy), .out_data(dn_d),
            .out_sof(dn_sof), .out_eol(dn_eol)
        );
        // 降噪是最后那一级 → 它的输出进 Gamma
        assign dn_rdy = g_rdy;
        assign g_v = dn_v; assign g_d = dn_d; assign g_sof = dn_sof; assign g_eol = dn_eol;
    end
    endgenerate

    // ---- 第三级：Gamma（固定在全链最后，位宽在此 30bit → 24bit）----
    gamma_stage #(.DW(DW), .OW(OW)) u_gam (
        .clk(clk), .rst_n(rst_n), .bypass(bp_gamma),
        .in_valid(g_v),   .in_ready(g_rdy),   .in_data(g_d),
        .in_sof(g_sof),   .in_eol(g_eol),
        .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data),
        .out_sof(out_sof), .out_eol(out_eol)
    );

    assign in_ready = first_rdy;

endmodule

`endif  // RGB_CHAIN_TOP_V_INC
