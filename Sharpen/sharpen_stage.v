// ============================================================================
// sharpen_stage.v —— 锐化级：简流(RGB888 24bit) → 3×3 窗口 → USM 核 → 简流(RGB888)
//
// 与 denoise_stage 同构（同一套"行缓存 + 反压 + bypass"框架），差异：
//   ① 像素位宽 DW=8（3 通道 24bit）——输入来自 Gamma 出口（感知域）
//   ② 核 LAT=1（纯组合模糊/修正 + 输出寄存）
//   ③ 新增 k_gain 强度端口（k = k_gain/2^K_FRAC，帧级参数）
//
// 【bypass = 排空点切换（★ 与 CCM/Gamma 的"等延迟旁路"形成架构对比）】
//   处理路径含行缓存，延迟 ≈ K·W+K + 1（上千拍）；bypass 走 axis_stream_fifo（几拍）。
//   两路延迟差 W+1 像素量级 ⇒ 帧中间热切换必然错位 ⇒ 只能
//   "停源 → 等出口清空 → 切换 → 再发"。bypass 期间行缓存整体冻结（in_valid=0），
//   保住其内部 FIFO 占用恒 = IMG_W 的不变式（不冻结会丢未握手数据 → 行延迟变短 →
//   切回后窗口全错）。
//
// 【反压冻结】ostall = (bypass ? byp_v : core_dv) && !out_ready
//   → 核输出保持（run_en=0）+ 行缓存停 + bypass FIFO 停读 → in_ready=0 上传
// ============================================================================
`timescale 1ns/1ps

`ifndef SHARPEN_STAGE_V_INC
`define SHARPEN_STAGE_V_INC
`include "sharpen_core.v"
`include "axis_stream_fifo.v"
`include "line_buffer_fifo_nxn.v"

module sharpen_stage #(
    parameter DW     = 8,        // 单通道位宽（RGB888）
    parameter IMG_W  = 640,
    parameter IMG_H  = 480,
    parameter N      = 3,
    parameter KW     = 10,
    parameter K_FRAC = 8
)(
    input  wire            clk,
    input  wire            rst_n,
    input  wire            bypass,     // 1 = 旁路本模块算法（排空点切换；帧级配置）
    input  wire [KW-1:0]   k_gain,     // 锐化强度分子（k = k_gain/2^K_FRAC）
    // ---- 入侧简流（Gamma 出，RGB888 24bit）----
    input  wire            in_valid,
    output wire            in_ready,
    input  wire [3*DW-1:0] in_data,
    input  wire            in_sof,
    input  wire            in_eol,
    // ---- 出侧简流（RGB888 24bit）----
    output wire            out_valid,
    input  wire            out_ready,
    output wire [3*DW-1:0] out_data,
    output wire            out_sof,
    output wire            out_eol
);

    localparam CW  = 3*DW;     // 打包位宽 24bit
    // ★【步 1/2 · 拆流水】处理路径总延迟 = 窗口寄存器(1) + 核流水(2)
    //   原设计 LAT=1：行缓存 pad mux（sel_row/sel_col + 9:1 mux，组合）与核内
    //   加法树/乘法/饱和全挤在一拍 ⇒ OOC 实测 35 级 / WNS −1.93ns @150MHz。
    //   这里在"行缓存输出→核"之间插一级窗口寄存器（不动共用的 line_buffer_fifo_nxn，
    //   保护 M1/M3 已验证的 FIFO 占用不变式），再由核内 LAT=2 再切一刀。
    localparam LAT_CORE = 2;   // ★ 必须与 sharpen_core 的流水级数一致
    localparam LAT_WIN  = 1;   // 窗口寄存器
    localparam LAT      = LAT_WIN + LAT_CORE;   // = sof/eol 对齐链深度

    // ---- 行缓存（pad 全尺寸 + 反压）----
    wire              lb_valid, lb_sof, lb_eol, lb_ready;
    wire              lb_inready;               // 行缓存接纳节拍（造行期=0）
    wire [N*N*CW-1:0] lb_win;

    line_buffer_fifo_nxn #(
        .DW(CW), .IMG_W(IMG_W), .IMG_H(IMG_H), .N(N)
    ) u_lb (
        .clk(clk), .rst_n(rst_n),
        // ★ bypass 期行缓存整体冻结（in_valid=0）：保住"FIFO 占用恒 = IMG_W"不变式
        .in_valid(in_valid && !bypass),
        .in_ready(lb_inready),                  // 独立 wire：不与 stage 的 in_ready 同线（双驱动）
        .in_data(in_data), .in_sof(in_sof), .in_eol(in_eol),
        .out_valid(lb_valid), .out_ready(lb_ready),
        .out_win_flat(lb_win), .out_sof(lb_sof), .out_eol(lb_eol)
    );

    // ---- 反压：按"当前实际输出"判定 ----
    wire          core_dv;
    wire [CW-1:0] core_dt;
    wire          byp_v;
    wire          ostall;
    assign lb_ready = !ostall;

    // ---- ★ 步 1：窗口寄存器（切在 pad mux 之后、核之前）----
    //   lb_ready = !ostall ⇒ ostall 时行缓存输出本身冻结，此处同步冻结即可保持对齐；
    //   valid 打一拍与数据同行，sof/eol 走下面的 LAT 级对齐链。
    reg [N*N*CW-1:0] win_q;
    reg              wv_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            win_q <= {N*N*CW{1'b0}};
            wv_q  <= 1'b0;
        end else if (!ostall) begin
            win_q <= lb_win;
            wv_q  <= lb_valid;
        end
    end

    // ---- USM 核（LAT=2）----
    sharpen_core #(.DW(DW), .N(N), .KW(KW), .K_FRAC(K_FRAC)) u_core (
        .clk(clk), .rst_n(rst_n),
        .win_flat(win_q),
        .win_valid(wv_q),
        .k_gain(k_gain),
        .run_en(!ostall),
        .dout(core_dt),
        .dout_valid(core_dv)
    );

    // ---- bypass 延迟线 = axis_stream_fifo（M0.5 现成件：FWFT + 侧带 + 反压）----
    wire          byp_ready, byp_sof, byp_eol;
    wire [CW-1:0] byp_dt;
    axis_stream_fifo #(
        .DW(CW), .DEPTH(4), .TLAST_EN(1), .TUSER_EN(1), .TUSER_W(1)
    ) u_byp (
        .aclk(clk), .aresetn(rst_n),
        .s_axis_tdata(in_data),
        .s_axis_tvalid(in_valid && bypass),
        .s_axis_tready(byp_ready),
        .s_axis_tlast(in_eol),
        .s_axis_tuser(in_sof),
        .m_axis_tdata(byp_dt),
        .m_axis_tvalid(byp_v),
        .m_axis_tready(out_ready),
        .m_axis_tlast(byp_eol),
        .m_axis_tuser(byp_sof)
    );

    // ---- 入侧接纳（两条路径解耦）----
    assign in_ready = bypass ? byp_ready : lb_inready;

    assign ostall = (bypass ? byp_v : core_dv) && !out_ready;

    // ---- sof/eol 对齐：处理路径打 LAT 拍（窗口寄存器 1 + 核 2 = 3，与 core_dv 对齐）----
    //   ★ 深度必须 = LAT_WIN + LAT_CORE；漏一级/多一级都会让 sof/eol 与数据错位
    reg sof_c0, sof_c1, sof_c2, eol_c0, eol_c1, eol_c2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            {sof_c0, sof_c1, sof_c2} <= 3'b0;
            {eol_c0, eol_c1, eol_c2} <= 3'b0;
        end else if (!ostall) begin
            sof_c0 <= lb_sof;  sof_c1 <= sof_c0;  sof_c2 <= sof_c1;
            eol_c0 <= lb_eol;  eol_c1 <= eol_c0;  eol_c2 <= eol_c1;
        end
    end

    // ---- 出口 mux（排空点切换后选边）----
    assign out_valid = bypass ? byp_v   : core_dv;
    assign out_data  = bypass ? byp_dt  : core_dt;
    assign out_sof   = bypass ? byp_sof : sof_c2;
    assign out_eol   = bypass ? byp_eol : eol_c2;

endmodule

`endif  // SHARPEN_STAGE_V_INC
