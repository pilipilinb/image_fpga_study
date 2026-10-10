// ============================================================================
// awb_stub.v —— AWB 增益级（M5.3 占位实现：位置/接口/延迟与最终形态对齐）
//
// 【在链路里的位置】BLC → DPC → **AWB** → Demosaic
//   自动白平衡的"增益应用"必须在 **Bayer 域、去马赛克之前** 完成（工业主流）：
//   此时 R/Gr/Gb/B 四类像素各自独立、按相位乘不同增益即可；一旦进了 RGB 域，
//   去马赛克已经把四通道插值进同一个像素，再想逐通道校正就会把亮度/色度一起拧。
//
// 【本模块为什么叫 "stub"（M5.3 只做这些）】
//   · 增益端口 gain_00/01/10/11（Q2.8：1.0 = 2^8 = 256）由顶层提供；
//     四个都给 256 时 = **恒等直通**（位级与"不接 AWB"完全一致）。
//   · 真正的 AWB **统计**（分相位累加 + 软件闭环算增益）留 M6；本模块只做"乘"。
//   ⇒ M6 拿完整 AWB 替换本模块时，只要保持"Bayer 简流入出 + 1 拍延迟 + 同样 4 个
//     gain 端口"，链顶层与下游零改动（顶层已把 gain/统计端口预留在最终形态）。
//
// 【延迟 = 1 拍，为什么必须是 1 拍】
//   AWB 的"统计"是旁路（不进数据通路），数据通路上只有"乘增益"这一级。
//   把占位也定成 1 拍 ⇒ AWB 替换前后**整链总延迟不变** ⇒ 端到端 golden 无需重算。
//
// 【定点与饱和（沿用本项目"先算进定宽中间量"铁律）】
//   乘积 prod = in_data * gain       （PW = DW+GW 位）
//   out = (prod + 2^(GF-1)) >> GF    （round-half-up）
//   再饱和到 [0, 2^DW-1]：gain > 1 时会溢出（如 R 增益 2.0 把 800 抬到 1600），
//   直接截位会**回绕成暗像素**，必须上钳位（判据 = 乘积高位是否非零）。
// ============================================================================
`timescale 1ns/1ps

`ifndef AWB_STUB_V_INC
`define AWB_STUB_V_INC

module awb_stub #(
    parameter DW = 10,       // 像素位宽（Bayer RAW10）
    parameter GW = 10,       // 增益位宽
    parameter GF = 8         // 增益小数位：1.0 = 2^GF = 256（Q2.8）
)(
    input  wire          clk,
    input  wire          rst_n,
    // ---- 分相位增益（寄存器可配；占位/TB 全给 2^GF = 1.0）----
    input  wire [GW-1:0] gain_00,      // (row&1,col&1)=(0,0)：RGGB 下 = R
    input  wire [GW-1:0] gain_01,      // (0,1)：Gr
    input  wire [GW-1:0] gain_10,      // (1,0)：Gb
    input  wire [GW-1:0] gain_11,      // (1,1)：B
    // ---- 入侧简流（DPC 出，Bayer RAW10；in_phase 供按相位选增益）----
    input  wire          in_valid,
    output wire          in_ready,
    input  wire [DW-1:0] in_data,
    input  wire          in_sof,
    input  wire          in_eol,
    input  wire [1:0]    in_phase,     // = DPC 的 out_phase，与 in_data 同拍
    // ---- 出侧简流（Demosaic 入，Bayer RAW10）----
    output wire          out_valid,
    input  wire          out_ready,
    output wire [DW-1:0] out_data,
    output wire          out_sof,
    output wire          out_eol
);

    localparam LAT = 1;                      // ★ 与最终 AWB 的数据通路延迟一致
    localparam PW  = DW + GW;                // 乘积位宽（10+10=20）

    // ---- 反压：LAT=1 输出寄存器（与 blc_core 同构）----
    wire stall = out_valid && !out_ready;
    wire run   = !stall;
    assign in_ready = rst_n && run;

    // ---- 按相位选增益（组合；增益为寄存器/TB 常量，路径极短）----
    reg [GW-1:0] gsel;
    always @* begin
        case (in_phase)
            2'b00:   gsel = gain_00;
            2'b01:   gsel = gain_01;
            2'b10:   gsel = gain_10;
            default: gsel = gain_11;
        endcase
    end

    // ---- 乘增益 + round-half-up + 上饱和（定宽中间量，避免 32bit 表达式）----
    localparam [PW-1:0] RND = ({{(PW-1){1'b0}}, 1'b1}) << (GF-1);   // = 2^(GF-1)
    wire [PW-1:0] prod = in_data * gsel;          // ≤ 1023×1023 < 2^20
    wire [PW-1:0] rndv = prod + RND;
    wire [PW-1:0] shf  = rndv >> GF;
    wire [DW-1:0] sat  = (|shf[PW-1:DW]) ? {DW{1'b1}} : shf[DW-1:0];

    // ---- 输出寄存器（数据 + sof/eol/valid 同步打一拍）----
    reg [DW-1:0] dq;
    reg          sq, eq, vq;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dq <= {DW{1'b0}}; sq <= 1'b0; eq <= 1'b0; vq <= 1'b0;
        end
        else if (run) begin
            dq <= sat;
            sq <= in_sof;
            eq <= in_eol;
            vq <= in_valid;
        end
    end

    assign out_data  = dq;
    assign out_sof   = sq;
    assign out_eol   = eq;
    assign out_valid = vq;

endmodule

`endif  // AWB_STUB_V_INC
