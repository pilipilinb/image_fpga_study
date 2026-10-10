// ============================================================================
// dpc_stage.v —— DPC 级：简流(Bayer,DW) → 5×5 窗口 → 包络检测核 → 简流
//
// 与旧 top_dpc.v（DPC 工程）的差别 = 接口适配，算法核零改动（见 dpc_envelope_dw.v）：
//   ① 行缓存：line_buffer_nxn(crop 版, 8bit, 无握手) → line_buffer_fifo_nxn
//      （pad 版：H×W 全尺寸输出 + out_ready 反压，M1 已验证）
//   ② 握手：简流 valid/ready + sof/eol；反压 = 冻结链（见下）
//   ③ 位宽：DW 参数化（RAW10）
//   ④ 相位来源：不再用"输入相位打 5 拍延迟链"对齐（旧行缓存延迟拍数与气泡相关），
//      而是**窗口输出侧自算**——窗口序列天然是光栅序，用 out_valid/out_sof/out_eol
//      驱动一个与 blc_core 同构的中心坐标计数器（out_sof 清零 / out_eol 行进列清），
//      任意反压/气泡下与窗口严格同拍。BLC 的 out_phase 在 TB 里做交叉校验用。
//
// 【★ M5.3 时序修复：为什么在"行缓存→核"之间插一级窗口寄存器】
//   本模块是 M3 交付的，早于"M5.1 时序预检铁律"。整链 OOC 综合（isp_chain_top @150MHz）
//   实测：唯一违例路径就是本级的 **行缓存 pad mux（sel_row/sel_col + 9:1 mux，组合）
//   → 核内极值树/比较 → dout_reg**，26 级 / WNS −0.939ns（10 个失败端点全在 dout_reg）。
//   修法=M5.1 同款：在 pad mux 之后、核之前插一级 **窗口寄存器** win_q（不改共用的
//   line_buffer_fifo_nxn，保护 M1/M3 占用不变式），把那一整条长组合路径切成两拍
//   ⇒ 处理路径延迟 LAT = 窗口寄存器(1) + 核(1) = 2。sof/eol/相位对齐链同步改为 2 拍。
//
// 【反压结构】ostall = dpc_valid && !out_ready → lb_ready = !ostall，win_q/ph_q/wv_q
//   同步冻结 + 核 hold_in=ostall（输出寄存器保持）→ 输出稳定（简流稳定性）。
//   ostall 时窗口/相位不变 → 核每拍重算同一窗口、寄存器每拍重写同值；解除后推进。
//   核输入拍 = lb.out_valid && lb.out.ready（fire_w），相位计数器在该拍推进。
// ============================================================================
`timescale 1ns/1ps

`ifndef DPC_STAGE_V_INC
`define DPC_STAGE_V_INC
`include "dpc_envelope_dw.v"
`include "line_buffer_fifo_nxn.v"   // M1 行缓存（-I 指向 line_buffer/line_buffer_fifo_nxn）

module dpc_stage #(
    parameter DW    = 10,
    parameter IMG_W = 640,
    parameter IMG_H = 480,
    parameter N     = 5,
    parameter THR   = 128      // 8bit 版 32 的 RAW10 等比值
)(
    input  wire          clk,
    input  wire          rst_n,
    // ---- 入侧简流（BLC 出，Bayer 域）----
    input  wire          in_valid,
    output wire          in_ready,
    input  wire [DW-1:0] in_data,
    input  wire          in_sof,
    input  wire          in_eol,
    // ---- 出侧简流（Bayer 域，坏点已校正）----
    output wire          out_valid,
    input  wire          out_ready,
    output wire [DW-1:0] out_data,
    output wire          out_sof,
    output wire          out_eol,
    output wire [1:0]    out_phase     // 窗口中心相位（供下级/调试）
);

    localparam K = (N - 1) / 2;

    // ---- 行缓存（pad 全尺寸 + 反压）----
    wire          lb_valid, lb_sof, lb_eol, lb_ready;
    wire [N*N*DW-1:0] lb_win;

    line_buffer_fifo_nxn #(
        .DW(DW), .IMG_W(IMG_W), .IMG_H(IMG_H), .N(N)
    ) u_lb (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_ready(in_ready),
        .in_data(in_data), .in_sof(in_sof), .in_eol(in_eol),
        .out_valid(lb_valid), .out_ready(lb_ready),
        .out_win_flat(lb_win), .out_sof(lb_sof), .out_eol(lb_eol)
    );

    // ---- 反压：输出寄存器（核自带）被下游占住 → 冻结行缓存 ----
    wire ostall;
    assign lb_ready = !ostall;

    // ---- 窗口中心相位计数器（fire_w 拍读 = 当前窗口中心相位；与 blc_core 同构）----
    localparam AW = $clog2(IMG_W);
    localparam RW = $clog2(IMG_H + 2);
    reg [RW-1:0] row_cnt;
    reg [AW-1:0] col_cnt;
    wire fire_w = lb_valid && lb_ready;        // 本拍核正在采样这个窗口

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_cnt <= {RW{1'b0}};
            col_cnt <= {AW{1'b0}};
        end
        else if (fire_w) begin
            if (lb_sof) begin
                row_cnt <= {RW{1'b0}};
                col_cnt <= {{(AW-1){1'b0}}, 1'b1};  // 本拍窗口中心 (0,0)，下一拍 (0,1)
            end
            else if (lb_eol) begin
                col_cnt <= {AW{1'b0}};
                row_cnt <= row_cnt + 1'b1;
            end
            else begin
                col_cnt <= (col_cnt == IMG_W - 1) ? {AW{1'b0}} : (col_cnt + 1'b1);
            end
        end
    end

    reg [1:0] ph_win;
    always @(*) begin
        ph_win = lb_sof ? 2'b00 : {row_cnt[0], col_cnt[0]};   // sof 拍强制 00（抹跨帧残留）
    end

    // ---- ★ 步 1：窗口寄存器（切在 pad mux 之后、核之前）----
    //   lb_ready = !ostall ⇒ ostall 时行缓存输出本身冻结，此处同步冻结即保持对齐。
    localparam LAT_WIN  = 1;
    localparam LAT_CORE = 1;                 // = dpc_envelope_dw 的流水级数
    localparam LAT      = LAT_WIN + LAT_CORE;  // = 2，sof/eol/相位对齐链深度
    reg [N*N*DW-1:0] win_q;
    reg [1:0]        ph_q;
    reg              wv_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            win_q <= {(N*N*DW){1'b0}};
            ph_q  <= 2'b00;
            wv_q  <= 1'b0;
        end else if (!ostall) begin
            win_q <= lb_win;
            ph_q  <= ph_win;
            wv_q  <= lb_valid;
        end
    end

    // ---- DPC 核（LAT=1；hold_in=ostall 时输出寄存器保持）----
    wire [DW-1:0] dpc_dout;
    wire          dpc_valid;

    dpc_envelope_dw #(
        .DW(DW), .THR(THR)
    ) u_dpc (
        .clk(clk), .rst_n(rst_n),
        .win_flat(win_q),
        .phase(ph_q),
        .valid_in(wv_q),
        .hold_in(ostall),              // ostall 期间核输出寄存器保持（防覆盖丢数）
        .dout(dpc_dout),
        .valid_out(dpc_valid)
    );
    assign ostall = dpc_valid && !out_ready;

    // ---- sof/eol/phase 与核输出对齐（窗口寄存器 1 + 核 1 = 2 拍）----
    //   ★ 深度必须 = LAT_WIN + LAT_CORE；漏一级/多一级都会让 sof/eol 与数据错位。
    reg        sof_c0, sof_r;
    reg        eol_c0, eol_r;
    reg [1:0]  ph_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sof_c0 <= 1'b0; sof_r <= 1'b0;
            eol_c0 <= 1'b0; eol_r <= 1'b0;
            ph_r   <= 2'b00;
        end
        else if (!ostall) begin
            sof_c0 <= lb_sof;
            sof_r  <= sof_c0;
            eol_c0 <= lb_eol;
            eol_r  <= eol_c0;
            ph_r   <= ph_q;            // ph_q 是"核正在处理的那个窗口"的相位 → 再打 1 拍与 dout 同拍
        end
        // ostall：保持（与 dpc_dout 的"重写同值"一致）
    end

    assign out_valid = dpc_valid;
    assign out_data  = dpc_dout;
    assign out_sof   = sof_r;
    assign out_eol   = eol_r;
    assign out_phase = ph_r;

endmodule

`endif  // DPC_STAGE_V_INC
