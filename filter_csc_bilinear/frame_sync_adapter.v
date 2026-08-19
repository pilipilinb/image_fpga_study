//========================================================================
// frame_sync_adapter.v —— 级间 blanking 重生成器 v2（带小 FIFO，pad 版级联用）
// 背景：line_buffer_3x3_pad 依赖输入带 blanking（h-blank≥1、v-blank≥W+8），
//   但 pad 版模块的输出是连续流（每拍 1 窗口，无行末/帧末空拍）——直接级联
//   到下一个 pad 版模块时，下一级插不了 rflush/bflush，会输出错误。
// v1 教训：零缓冲"插空拍"在连续输入下会丢数据（插空拍期间输入照来）。
// v2：输入先进小 FIFO（写侧连续），读侧按"行结构"调度：
//   每行读 W 个有效 → 停 HBLANK 拍（行末空拍）→ 下一行；读完 H 行 → 停 VBLANK 拍
//   （帧末空拍）→ 等下一帧（FIFO 空时读侧自然停）。
// 【溢出证明（为什么 512 深度足够，不需要整帧）】读侧只比写侧多"插空拍"的
//   额外拍：帧内累计 ≈ HBLANK×H（206）+ 帧末 VBLANK 在输入停止后发生（不增加
//   占用）→ 最大占用 ≈ 206 < 512。相比缩放模块的 4 倍速差（整帧 FIFO），
//   这里速率差只是"格式重塑"的几百拍，小 FIFO 即可。
// 状态机：IDLE(等帧首) → ROW_ACT(读 W 个) ⇄ HBLANK(HB 拍) → VBLANK(帧末) → IDLE
//========================================================================
`timescale 1ns/1ps

module frame_sync_adapter #(
    parameter IMG_W = 112,      // 图像宽（= 每行有效像素数）
    parameter IMG_H = 103,      // 图像高（= 行数）
    parameter HBLANK = 2,       // 行末空拍数（pad 要求 ≥1）
    parameter VBLANK = 120,     // 帧末空拍数（pad 要求 ≥ IMG_W+8）
    parameter DEPTH  = 512,     // FIFO 深度（≥ HBLANK×IMG_H + 裕量即可）
    parameter AW     = 9,       // FIFO 地址位宽（log2(DEPTH)）
    parameter CW     = 8,       // 列计数位宽
    parameter RW     = 8,       // 行计数位宽
    parameter VW     = 8        // v-blank 计数位宽
)(
    input                clk,
    input                rst_n,
    input  [23:0]        din,        // 上级连续窗口流
    input                din_valid,
    output [23:0]        dout,       // 下级带 blanking 帧流
    output               dout_valid
);

    //========================================================================
    // 输入缓冲（内置组合读小 FIFO）
    // 为什么不用 axis_fifo：其读侧"挂起 valid"由 rd_en 打拍产生，而调度需要
    //   由 valid 判断是否读——首拍互等死锁。组合读 FIFO（数据 = mem[rptr]、
    //   valid = count>0、消费即 rptr+1）无此问题，且 512×24 用分布式 RAM 足够。
    //========================================================================
    (* ram_style = "distributed" *) reg [23:0] mem [0:DEPTH-1];
    reg [AW-1:0] wptr, rptr;
    reg [AW:0]   cnt;      // 占用数
    wire        rd_en;    // 读使能（本行有效期且有数据）

    wire fifo_empty = (cnt == 0);
    wire fifo_nowempty = !fifo_empty;
    assign rd_en      = (state == S_ROW) && fifo_nowempty;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr <= {AW{1'b0}};
            rptr <= {AW{1'b0}};
            cnt  <= {(AW+1){1'b0}};
        end else begin
            if (din_valid) begin
                mem[wptr] <= din;
                wptr      <= wptr + 1'b1;
            end
            if (rd_en)
                rptr <= rptr + 1'b1;
            case ({din_valid, rd_en})
                2'b10: cnt <= cnt + 1'b1;
                2'b01: cnt <= cnt - 1'b1;
                default: cnt <= cnt;
            endcase
        end
    end

    // 输出 = 组合读出的数据（无挂起延迟，行结构精确）
    assign dout_valid = rd_en;
    assign dout       = mem[rptr];

    //========================================================================
    // 读调度状态机
    //========================================================================
    localparam S_IDLE   = 2'd0;
    localparam S_ROW    = 2'd1;    // 读本行 W 个有效像素
    localparam S_HBLANK = 2'd2;    // 行末空拍
    localparam S_VBLANK = 2'd3;    // 帧末空拍

    reg [1:0]   state;
    reg [CW-1:0] col_cnt;
    reg [RW-1:0] row_cnt;
    reg [VW-1:0] vb_cnt;
    reg [1:0]   hb_cnt;

    wire last_col = (col_cnt == IMG_W - 1);
    wire last_row = (row_cnt == IMG_H - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            col_cnt <= {CW{1'b0}};
            row_cnt <= {RW{1'b0}};
            vb_cnt  <= {VW{1'b0}};
            hb_cnt  <= 2'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (fifo_nowempty) begin      // 有数据即起步（不能用挂起 valid，会互等）
                        state   <= S_ROW;
                        col_cnt <= {CW{1'b0}};
                        row_cnt <= {RW{1'b0}};
                    end
                end
                S_ROW: begin
                    if (rd_en) begin
                        if (last_col) begin
                            if (last_row) begin
                                // 帧末最后一像素：输出后进 v-blank
                                state  <= S_VBLANK;
                                vb_cnt <= {VW{1'b0}};
                            end else begin
                                state  <= S_HBLANK;
                                hb_cnt <= 2'd0;
                                row_cnt <= row_cnt + 1'b1;
                            end
                            col_cnt <= {CW{1'b0}};
                        end else begin
                            col_cnt <= col_cnt + 1'b1;
                        end
                    end
                end
                S_HBLANK: begin
                    if (hb_cnt == HBLANK - 1)
                        state <= S_ROW;
                    else
                        hb_cnt <= hb_cnt + 1'b1;
                end
                S_VBLANK: begin
                    if (vb_cnt == VBLANK - 1)
                        state <= S_IDLE;
                    else
                        vb_cnt <= vb_cnt + 1'b1;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule