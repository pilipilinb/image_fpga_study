// ============================================================================
// awb_stat.v —— M6 AWB 四相位统计级（旁挂观察者，0 拍透传）
//
// 【在链路里的位置】DPC → [awb_stat] → awb_gain → Demosaic
//   统计 tap 放在 DPC 出（= gain 入，原始 RAW 域）：
//   · DPC 用绝对阈值判缺陷，必须在原始域完成（不受增益漂移影响）；
//   · 先修坏点再统计 → 亮/暗坏点（1023/0）不会污染统计；
//   · 开环统计（不含自身增益）——灰世界是"比值"运算，不会振荡。
//
// 【为什么 0 拍透传】数据通路组合直连、统计是"旁挂累加"：
//   不插流水、不占拍、不参与握手 ⇒ 加这一级不改变整链总延迟与 golden。
//
// 【统计语义（与 make_awb_data.py / 软核注释位级同构）】
//   · 只在 fire 拍（in_valid && in_ready）累加——stall 期数据冻结但 valid
//     保持，按 valid 累加会把同一像素数很多次（★ 反压重复计数坑）；
//   · SOF fire 拍（帧首像素）做"原子搬家"：
//       shadow ← work    （上一帧全量，不含本拍像素）
//       work   ← 本拍像素（新组从本拍重启，其余相位清零）
//     ★ 不是"清零"——清零会吞掉每帧第一个像素；
//       frame_cnt + 1；irq 拉高 1 拍（软核"有新的统计了"的信号）。
//   · 复位后第一次封存取得的 shadow 是初值 0（无效）⇒ 软核规则：
//     "fc ≥ 2 才使用，且读到的统计对应帧 fc-1"。
//
// 【帧号/中断时序】fc 与 shadow 在 SOF fire 拍同步更新 ⇒ 下一拍同时可见；
//   irq 为寄存器脉冲：sof fire 的下一拍为高、恰 1 拍宽，与 fc 新值同拍。
// ============================================================================
`timescale 1ns/1ps
`ifndef AWB_STAT_V_INC
`define AWB_STAT_V_INC

module awb_stat #(
    parameter DW = 10            // Bayer RAW10
)(
    input  wire          clk,
    input  wire          rst_n,
    // ---- 入侧简流（DPC 出，Bayer RAW10；phase 与数据同拍）----
    input  wire          in_valid,
    output wire          in_ready,
    input  wire [DW-1:0] in_data,
    input  wire          in_sof,
    input  wire          in_eol,
    input  wire [1:0]    in_phase,
    // ---- 出侧简流（0 拍透传，接 awb_gain）----
    output wire          out_valid,
    input  wire          out_ready,
    output wire [DW-1:0] out_data,
    output wire          out_sof,
    output wire          out_eol,
    output wire [1:0]    out_phase,
    // ---- 快照组（软核/从机读；fc 随快照组同拍更新）----
    output wire [31:0]   stat_00,
    output wire [31:0]   stat_01,
    output wire [31:0]   stat_10,
    output wire [31:0]   stat_11,
    output wire [31:0]   frame_cnt,
    output wire          irq
);

    // ---- 0 拍透传（数据通路零改动）----
    assign out_valid = in_valid;
    assign out_data  = in_data;
    assign out_sof   = in_sof;
    assign out_eol   = in_eol;
    assign out_phase = in_phase;
    assign in_ready  = rst_n && out_ready;

    // ---- fire：数据真正通过的那一拍 ----
    wire          fire     = in_valid && in_ready;
    wire          sof_fire = fire && in_sof;
    wire [31:0]   px       = {{(32 - DW){1'b0}}, in_data};   // 零扩展到 32bit

    // ---- 工作组（本帧累加）/ 快照组（上一帧，软核读）/ 帧号 / 中断 ----
    reg [31:0] work_00, work_01, work_10, work_11;
    reg [31:0] shap_00, shap_01, shap_10, shap_11; //上一帧打完包的完整结果,只在帧切换时变化，其他时候冻结，用来打包给软核读取
    reg [31:0] fc;
    reg        irq_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            work_00 <= 32'd0; work_01 <= 32'd0; work_10 <= 32'd0; work_11 <= 32'd0;
            shap_00 <= 32'd0; shap_01 <= 32'd0; shap_10 <= 32'd0; shap_11 <= 32'd0;
            fc      <= 32'd0;
            irq_r   <= 1'b0;
        end
        else begin
            irq_r <= sof_fire;                   // 1 拍脉冲（sof fire 的下一拍为高）
            if (fire) begin
                if (in_sof) begin
                    // ---- 原子搬家：上一帧全量 → 快照组；工作组从本拍像素重启 ----
                    shap_00 <= work_00;
                    shap_01 <= work_01;
                    shap_10 <= work_10;
                    shap_11 <= work_11;
                    work_00 <= (in_phase == 2'b00) ? px : 32'd0;
                    work_01 <= (in_phase == 2'b01) ? px : 32'd0;
                    work_10 <= (in_phase == 2'b10) ? px : 32'd0;
                    work_11 <= (in_phase == 2'b11) ? px : 32'd0;
                    fc      <= fc + 32'd1;
                end
                else begin
                    // ---- 常规累加：按相位入组 ----
                    case (in_phase)
                        2'b00:   work_00 <= work_00 + px;
                        2'b01:   work_01 <= work_01 + px;
                        2'b10:   work_10 <= work_10 + px;
                        default: work_11 <= work_11 + px;
                    endcase
                end
            end
        end
    end

    assign stat_00   = shap_00;
    assign stat_01   = shap_01;
    assign stat_10   = shap_10;
    assign stat_11   = shap_11;
    assign frame_cnt = fc;
    assign irq       = irq_r;

endmodule

`endif  // AWB_STAT_V_INC