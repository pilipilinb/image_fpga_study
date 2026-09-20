// ============================================================================
// demosaic_stage.v —— Demosaic 级：简流(Bayer,DW) → 5×5 窗口 → 去马赛克核 → 简流(RGB)
//
// 与 dpc_stage.v 完全同构（行缓存/相位/反压结构一致），差别只在核与输出：
//   核：demosaic_bilinear_dw / demosaic_mhc_dw 二选一（DEMOSAIC_SEL 参数，
//       两核接口一致，"换核不改线"——沿用 Demosaic 工程的结论）
//   输出：out_data = {r, g, b} 打包 3*DW（RAW10 域 RGB，折 8bit 留给后级/显示前）
// 相位：与 dpc_stage 相同，窗口输出侧自算（out_sof/out_eol 驱动光栅计数器），
//   不吃上游传来的像素相位——经过 5×5 行缓存后窗口中心相位 = 输入相位延迟
//   K*(W+1) 个有效拍，自算比延迟链干净且任意反压/气泡下严格对齐。
// ============================================================================
`timescale 1ns/1ps

`ifndef DEMOSAIC_STAGE_V_INC
`define DEMOSAIC_STAGE_V_INC
`include "demosaic_bilinear_dw.v"
`include "demosaic_mhc_dw.v"
`include "line_buffer_fifo_nxn.v"

module demosaic_stage #(
    parameter DW           = 10,
    parameter OW           = 8,      // 输出通道位宽：RGB888 契约（3*8=24bit，对齐 VDMA S2MM tdata[23:0]）
                                     //   RAW10→8bit 在出口 >>2 折算（显示域）；OW=DW 时直通不折算
    parameter IMG_W        = 640,
    parameter IMG_H        = 480,
    parameter N            = 5,
    parameter DEMOSAIC_SEL = 0       // 0=双线性 1=MHC（接口一致，换核不改线）
)(
    input  wire          clk,
    input  wire          rst_n,
    // ---- 入侧简流（DPC 出，Bayer 域 RAW10）----
    input  wire          in_valid,
    output wire          in_ready,
    input  wire [DW-1:0] in_data,
    input  wire          in_sof,
    input  wire          in_eol,
    // ---- 出侧简流（RGB 域，{r,g,b} 打包 3*OW）----
    output wire          out_valid,
    input  wire          out_ready,
    output wire [3*OW-1:0] out_data,  // {r, g, b}，各 OW 位（RGB888 = 24bit）
    output wire          out_sof,
    output wire          out_eol,
    output wire [1:0]    out_phase
);

    // ---- 行缓存 ----
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

    wire ostall;
    assign lb_ready = !ostall;

    // ---- 窗口中心相位计数器（与 dpc_stage/blc_core 同构）----
    localparam AW = $clog2(IMG_W);
    localparam RW = $clog2(IMG_H + 2);
    reg [RW-1:0] row_cnt;
    reg [AW-1:0] col_cnt;
    wire fire_w = lb_valid && lb_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_cnt <= {RW{1'b0}};
            col_cnt <= {AW{1'b0}};
        end
        else if (fire_w) begin
            if (lb_sof) begin
                row_cnt <= {RW{1'b0}};
                col_cnt <= {{(AW-1){1'b0}}, 1'b1};
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
        ph_win = lb_sof ? 2'b00 : {row_cnt[0], col_cnt[0]};
    end

    // ---- 去马赛克核（LAT=1 寄存器即输出寄存器；换核不改线）----
    wire [DW-1:0] r_c, g_c, b_c;
    wire          dm_valid;

    generate
        if (DEMOSAIC_SEL == 0) begin : g_bilinear
            demosaic_bilinear_dw #(.DW(DW)) u_dm (
                .clk(clk), .rst_n(rst_n),
                .win_flat(lb_win), .phase(ph_win), .valid_in(lb_valid),
                .hold_in(ostall),          // ostall 期间核输出寄存器保持（防覆盖丢数）
                .r_out(r_c), .g_out(g_c), .b_out(b_c), .valid_out(dm_valid)
            );
        end else begin : g_mhc
            demosaic_mhc_dw #(.DW(DW)) u_dm (
                .clk(clk), .rst_n(rst_n),
                .win_flat(lb_win), .phase(ph_win), .valid_in(lb_valid),
                .hold_in(ostall),          // ostall 期间核输出寄存器保持（防覆盖丢数）
                .r_out(r_c), .g_out(g_c), .b_out(b_c), .valid_out(dm_valid)
            );
        end
    endgenerate
    assign ostall = dm_valid && !out_ready;

    // ---- sof/eol/phase 与核输出对齐 ----
    reg        sof_r, eol_r;
    reg [1:0]  ph_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sof_r <= 1'b0;
            eol_r <= 1'b0;
            ph_r  <= 2'b00;
        end
        else if (!ostall) begin
            sof_r <= lb_sof;
            eol_r <= lb_eol;
            ph_r  <= ph_win;
        end
    end

    assign out_valid = dm_valid;
    // RAW10 → RGB888 出口折算：核内保持 DW=10bit 精度插值（中间不加噪），
    //   显示域出口 >>2 截断（1023→255）。OW=DW 时移位量为 0 直通。
    //   三通道同移位 → {r,g,b} 同拍打包，无对齐问题。
    generate
        if (OW == DW) begin : g_ow_direct
            assign out_data = {r_c, g_c, b_c};
        end else begin : g_ow_fold
            assign out_data = {r_c[DW-1:DW-OW], g_c[DW-1:DW-OW], b_c[DW-1:DW-OW]};
        end
    endgenerate
    assign out_sof   = sof_r;
    assign out_eol   = eol_r;
    assign out_phase = ph_r;

endmodule

`endif  // DEMOSAIC_STAGE_V_INC
