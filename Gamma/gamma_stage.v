// ============================================================================
// gamma_stage.v —— Gamma 级：简流(线性 RGB 3×10bit) → 查表 → 简流(RGB888 3×8bit)
//
// 【本级的接口是"换位宽"的】输入 30bit，输出 24bit —— 全链位宽缩减在此完成。
//
// 【bypass 语义（★ 与 CCM/降噪都不同的一点）】
//   Gamma 是位宽缩减出口，**bypass 只能关"曲线"，不能关"位宽"**（下游 VDMA 要 8bit）。
//   ⇒ bypass 路径 = 线性 10→8：`(v+2)>>2`（round-half-up，无偏置）
//   ⇒ 语义：bypass=1 = "关掉 gamma 曲线，线性映射到 8bit"
//   （物理上不可能"输入原样输出"——位宽不同）
//
// 【等延迟旁路】旁路链打 1 拍 = 核 LAT ⇒ 两路延迟严格相等 ⇒ **可任意拍切换**
//   （同 CCM；对比降噪：处理路径含行缓存、延迟上万拍，只能排空点切换）
//
// 【反压冻结】stall = out_valid && !out_ready → run=0 →
//   核内 BRAM 读停 + 输出保持；旁路链停；in_ready=0 → 反压上传
// ============================================================================
`timescale 1ns/1ps

`ifndef GAMMA_STAGE_V_INC
`define GAMMA_STAGE_V_INC
`include "gamma_core.v"

module gamma_stage #(
    parameter DW = 10,     // 输入单通道位宽
    parameter OW = 8       // 输出单通道位宽（RGB888）
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire              bypass,     // 1 = 关 gamma 曲线（线性 10→8；可任意拍切换）
    // ---- 入侧简流（CCM 出，线性 RGB 3×10bit）----
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

    localparam LAT = 1;                    // ★ 必须与 gamma_core 的流水级数一致

    // ---- 反压：冻结整条流水（两路同门控 → 延迟关系恒定）----
    wire stall = out_valid && !out_ready;
    wire run   = !stall;
    assign in_ready = rst_n && run;

    // ---- 处理路径：Gamma 核 ----
    wire             core_dv;
    wire [3*OW-1:0]  core_dt;
    gamma_core #(.DW(DW), .OW(OW)) u_core (
        .clk(clk), .rst_n(rst_n),
        .din(in_data), .din_valid(in_valid),
        .run_en(run),
        .dout(core_dt), .dout_valid(core_dv)
    );

    // ---- bypass 路径：线性 10→8（round-half-up + 饱和），打 1 拍与核等延迟 ----
    //   (v + 2^(DW-OW-1)) >> (DW-OW) 里的 **+半个除数 = 四舍五入**（floor((v+0.5·2^n)/2^n)）
    //   不加它就只有截断 → 平均 −0.375 LSB 的系统性偏暗。
    //   ★ 必须饱和：v=1022/1023 时 round 结果是 256，超出 OW=8 的 255，
    //     直接截位会**回绕成 0**（最亮的像素变纯黑）——本项在自检 TB 里被漏过，
    //     因为 TB 期望用了同一个表达式（golden 与 DUT 共享同一 bug），
    //     现在由 verify_gamma.py 的"穷举 bypass"判据独立把关。
    //   注意：先算进定宽 reg 再拼接——移位量用无宽度常量时，拼接操作数会被判"宽度不定"
    function [OW-1:0] lin8;
        input [DW-1:0] v;
        reg   [DW:0]   t;                                     // 多留 1 位：容纳 256
        begin
            t    = (v + (1 << (DW-OW-1))) >> (DW-OW);
            lin8 = (t > ((1 << OW) - 1)) ? {OW{1'b1}} : t[OW-1:0];
        end
    endfunction

    wire [OW-1:0]   bpR = lin8(in_data[3*DW-1 -: DW]);
    wire [OW-1:0]   bpG = lin8(in_data[2*DW-1 -: DW]);
    wire [OW-1:0]   bpB = lin8(in_data[   DW-1:   0]);
    wire [3*OW-1:0] byp_d = { bpR, bpG, bpB };

    reg [3*OW-1:0] bd0;
    reg            bs0, be0, bv0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bd0 <= {3*OW{1'b0}}; bs0 <= 1'b0; be0 <= 1'b0; bv0 <= 1'b0;
        end else if (run) begin
            bd0 <= byp_d; bs0 <= in_sof; be0 <= in_eol; bv0 <= in_valid;
        end
    end

    // ---- 出口 mux（两路延迟相等 ⇒ 可任意拍切换）----
    assign out_valid = bypass ? bv0  : core_dv;
    assign out_data  = bypass ? bd0  : core_dt;
    assign out_sof   = bs0;       // 两路同源、同延迟（LAT）→ 对齐链共用
    assign out_eol   = be0;

endmodule

`endif  // GAMMA_STAGE_V_INC
