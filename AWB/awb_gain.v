// ============================================================================
// awb_gain.v —— M6 AWB 增益应用级（Bayer 域逐像素，LAT=1；awb_stub 的最终版）
//
// 【在链路里的位置】DPC → awb_stat → [awb_gain] → Demosaic
//   替换 M5.3 的 awb_stub：保持"Bayer 简流入出 + 1 拍延迟 + 4 个 gain 端口"，
//   增量 = active/inactive 寄存器对 + ★ 采样与首像素同拍生效。
//
// 【写口 / active / 帧边界采样（评审实锤的核心细节）】
//   · 写口（inactive，gain_00..11 端口）：软核/TB 随时可写，写入永不阻塞；
//   · active 寄存器：像素实际使用的增益，复位 = 2^GF（1.0 恒等）；
//   · 每个 SOF fire 拍：active ← 写口值（4 路整组原子采样，一拍全搬）；
//   · ★ 乘法组合选源 = fire&&sof ? 写口 : active：
//     SOF 拍本身是本帧第 1 个像素（相位 00）——若照"先采样后使用"的写法，
//     首像素会拿到上一帧的 active ⇒ 帧内恒定被破坏、逐帧位级验收失败。
//     SOF 拍 stall（未 fire）时 in_sof 与数据一起保持，解除后仍是同一拍语义。
//
// 【定点与饱和（沿用 stub，M5.3 已验证的写法）】

/*伪代码如下
# ---- PL：逐像素应用（输入 in 8bit、gain 16bit；输出 out 8bit）----
function wb_apply(in, gain):
    product = in * gain                  # 8bit × 16bit = 24bit
    product = product + (1 << 11)         # 加半个 LSB 做四舍五入（关键！见下）
    result  = product >> 12              # 去掉 12 位小数位
    if result > 255:                     # 增益后可能溢出
        return 255                       # 饱和钳位
    return result

等效于
//   prod = in * gain_now            （PW = DW+GW 位）
//   out  = (prod + 2^(GF-1)) >> GF  （round-half-up）
//   再饱和到 [0, 2^DW-1]：gain > 1 会溢出（R 增益 2.0 把 800 抬到 1600），
//   直接截位会回绕成暗像素，必须上钳位（判据 = 乘积高位是否非零）。
//   ★ 组合选源比 stub 多一级 mux（写口/active），时序量与 stub 同量级。

*/

// ============================================================================
`timescale 1ns/1ps
`ifndef AWB_GAIN_V_INC
`define AWB_GAIN_V_INC

module awb_gain #(
    parameter DW = 10,       // 像素位宽（Bayer RAW10）
    parameter GW = 10,       // 增益位宽
    parameter GF = 8         // 增益小数位：1.0 = 2^GF = 256（Q2.8）
)(
    input  wire          clk,
    input  wire          rst_n,
    // ---- 写口（inactive：仿真=顶层端口/TB 直驱；上板=AXI-Lite 从机寄存器）----
    input  wire [GW-1:0] gain_00,
    input  wire [GW-1:0] gain_01,
    input  wire [GW-1:0] gain_10,
    input  wire [GW-1:0] gain_11,
    // ---- 入侧简流（awb_stat 出，Bayer RAW10；in_phase 供按相位选增益）----
    input  wire          in_valid,
    output wire          in_ready,
    input  wire [DW-1:0] in_data,
    input  wire          in_sof,
    input  wire          in_eol,
    input  wire [1:0]    in_phase,
    // ---- 出侧简流（Demosaic 入，Bayer RAW10）----
    output wire          out_valid,
    input  wire          out_ready,
    output wire [DW-1:0] out_data,
    output wire          out_sof,
    output wire          out_eol
);

    localparam [GW-1:0] ONE = ({{(GW-1){1'b0}}, 1'b1} << GF);   // 2^GF = 1.0
    localparam PW = DW + GW;                                     // 20
    localparam [PW-1:0] RND = {{(PW-1){1'b0}}, 1'b1} << (GF-1);  // 2^(GF-1)

    // ---- 反压：LAT=1 输出寄存器（与 stub / blc_core 同构）----
    wire stall = out_valid && !out_ready;
    wire run   = !stall;
    assign in_ready = rst_n && run;
    wire fire    = in_valid && in_ready;
    wire sof_pix = fire && in_sof;       // 采样条件：本拍是本帧首像素且真正通过
    // ★ mux 选择**不接 ready**：若写成 fire&&sof，反压链（out_ready→…→in_ready）会
    //   一路组合到乘法器输入 ⇒ 整链关键路径（OOC 实测 18 级/+1.323ns，源头是
    //   out_adapter 的 FIFO 指针）。用 in_valid&&sof 语义完全等价（stall 拍结果
    //   本来就会被丢弃；真正 fire 那拍输入仍保持），但把 ready 链从数据路摘掉。
    wire sof_sel = in_valid && in_sof;

    // ---- active 寄存器组（复位 = 1.0；像素实际使用值）----
    reg [GW-1:0] act_00, act_01, act_10, act_11;

    // ---- 相位选择（组合）：写口 / active 各一 ----
    reg [GW-1:0] wr_sel, act_sel;
    always @* begin
        case (in_phase)
            2'b00:   wr_sel = gain_00;
            2'b01:   wr_sel = gain_01;
            2'b10:   wr_sel = gain_10;
            default: wr_sel = gain_11;
        endcase
        case (in_phase)
            2'b00:   act_sel = act_00;
            2'b01:   act_sel = act_01;
            2'b10:   act_sel = act_10;
            default: act_sel = act_11;
        endcase
    end

    // ---- ★ 组合选源：SOF 首像素直接用写口值（否则首像素吃到旧 active）----
    wire [GW-1:0] gsel = sof_sel ? wr_sel : act_sel;

    // ---- 乘增益 + round-half-up + 上饱和（定宽中间量，避免 32bit 表达式）----
    wire [PW-1:0] prod = in_data * gsel;
    //四舍五入
    wire [PW-1:0] rndv = prod + RND;
    wire [PW-1:0] shf  = rndv >> GF;
    //饱和保护
    wire [DW-1:0] sat  = (|shf[PW-1:DW]) ? {DW{1'b1}} : shf[DW-1:0];

    // ---- 输出寄存器（数据 + sof/eol/valid 同步打一拍；run 门控冻结）----
    reg [DW-1:0] dq;
    reg          sq, eq, vq;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            act_00 <= ONE; act_01 <= ONE; act_10 <= ONE; act_11 <= ONE;
            dq <= {DW{1'b0}}; sq <= 1'b0; eq <= 1'b0; vq <= 1'b0;
        end
        else if (run) begin
            if (sof_pix) begin            // 帧边界采样（4 路整组原子）
                act_00 <= gain_00;
                act_01 <= gain_01;
                act_10 <= gain_10;
                act_11 <= gain_11;
            end
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

`endif  // AWB_GAIN_V_INC