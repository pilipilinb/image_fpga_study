// ============================================================================
// ccm_stage.v —— CCM 级：简流(线性 RGB 3×10bit) → 色彩校正矩阵 → 简流
//
// 【与降噪级（denoise_stage）的关键差异：bypass 实现方式不同】
//   降噪：处理路径含行缓存（延迟 K·W+K + 核 3 拍 ≈ 上万拍），两条路径延迟差
//         W+1 像素量级 → 只能"排空点切换"，且 bypass 用 axis_stream_fifo（可变延迟）
//   CCM ：逐像素点运算，**无行缓存**，核 LAT=2 → bypass 打同样 2 拍即可
//         ⇒ **等延迟旁路**：两路延迟严格相等，出口 mux 只切数据
//         ⇒ **可任意拍切换**（连帧中间切换都对），无需排空握手
//   结论：bypass 的实现方式由"处理路径延迟"决定——这是架构边界的一个对比点
//
// 【等延迟为什么成立】
//   两条路径都由同一个 run（= !stall）门控、都是 LAT=2：
//     处理路径：din 组合乘加 → aR_r(T1) → dout(T2)   ⇒ 输出 = f(in_data 的 T−2 拍)
//     旁路路径：bd0(T1) → bd1(T2)                     ⇒ 输出 = in_data 的 T−2 拍
//   ⇒ 同一拍出口 mux 选哪路，拿到的都是"同一输入像素"的结果（一个处理过、一个没处理）
//
// 【sof/eol 对齐】两路延迟相同，故打 2 拍的对齐链**两条路径共用**（LAT 必须 = 核级数）
//
// 【反压冻结】stall = out_valid && !out_ready → run=0 → 核内两级寄存 + 旁路链全部冻结
//   → in_ready=0 → 反压上传；恢复后无损续传
// ============================================================================
`timescale 1ns/1ps

`ifndef CCM_STAGE_V_INC
`define CCM_STAGE_V_INC
`include "ccm_core.v"

module ccm_stage #(
    parameter DW   = 10,    // 单通道位宽（线性 RGB 域）
    parameter FRAC = 12
)(
    input  wire            clk,
    input  wire            rst_n,
    input  wire            bypass,     // 1 = 旁路本模块算法（等延迟直通；可任意拍切换）
    // ---- 入侧简流（降噪出，线性 RGB 3×10bit）----
    input  wire            in_valid,
    output wire            in_ready,
    input  wire [3*DW-1:0] in_data,
    input  wire            in_sof,
    input  wire            in_eol,
    // ---- 出侧简流（线性 RGB 3×10bit）----
    output wire            out_valid,
    input  wire            out_ready,
    output wire [3*DW-1:0] out_data,
    output wire            out_sof,
    output wire            out_eol
);

    localparam CW  = 3*DW;
    localparam LAT = 2;                    // ★ 必须与 ccm_core 的流水级数一致

    // ---- 反压：冻结整条流水（两条路径同一门控 → 延迟关系恒定不变）----
    wire stall = out_valid && !out_ready;
    wire run   = !stall;
    assign in_ready = rst_n && run;

    // ---- 处理路径：CCM 核 ----
    wire          core_dv;
    wire [CW-1:0] core_dt;
    ccm_core #(.DW(DW), .FRAC(FRAC)) u_core (
        .clk(clk), .rst_n(rst_n),
        .din(in_data), .din_valid(in_valid),
        .run_en(run),
        .dout(core_dt), .dout_valid(core_dv)
    );

    // ---- bypass 等延迟链（LAT 拍，与核严格相等）----
    reg [CW-1:0] bd0, bd1;
    reg          bs0, bs1, be0, be1, bv0, bv1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bd0 <= {CW{1'b0}}; bd1 <= {CW{1'b0}};
            bs0 <= 1'b0; bs1 <= 1'b0; be0 <= 1'b0; be1 <= 1'b0;
            bv0 <= 1'b0; bv1 <= 1'b0;
        end else if (run) begin
            bd0 <= in_data;  bd1 <= bd0;
            bs0 <= in_sof;   bs1 <= bs0;
            be0 <= in_eol;   be1 <= be0;
            bv0 <= in_valid; bv1 <= bv0;
        end
    end

    // ---- 出口 mux：两路延迟相等 ⇒ 切换任意拍都不会错位 ----
    assign out_valid = bypass ? bv1  : core_dv;
    assign out_data  = bypass ? bd1  : core_dt;
    assign out_sof   = bs1;      // 两路同源、同延迟（LAT）→ 对齐链共用
    assign out_eol   = be1;

endmodule

`endif  // CCM_STAGE_V_INC
