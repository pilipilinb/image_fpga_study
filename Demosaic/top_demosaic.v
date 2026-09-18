//========================================================================
// top_demosaic.v —— 去马赛克顶层（Demosaic 工程，W3）
//
// 数据流（一条流水线，从头到尾都是"每拍一个像素"）：
//
//   din[7:0] ──► line_buffer_nxn（N=5：先把 5×5 的窗口攒出来）
//                    │ win_flat（25 个像素打包成 200bit）
//                    ▼
//               demosaic_bilinear（按中心相位补出 RGB）
//                    ▲
//               phase（相位）＝ 告诉核"窗口中心是什么颜色"
//                    ▲
//   行/列计数器 ──► 由行列奇偶算出相位 ──► 打 4 拍对齐窗口
//
// 【相位为什么要打 4 拍】
//   line_buffer_nxn 不是"当拍进、当拍出"：它要攒够 5 行才出窗口，
//   实测窗口比输入晚 4 拍（L=4，见 tb_nxn_n5.v 的测量结果）。
//   所以"窗口有效"的那一刻，行/列计数器已经数到 4 个像素之后了。
//   相位必须跟着窗口走 → 把相位也延迟 4 拍，才能和窗口对上是同一个点。
//
// 【相位怎么算】RGGB 排列：
//     行0: R G R G ...        行1: G B G B ...
//   (行偶,列偶)=R  (行偶,列奇)=Gr  (行奇,列偶)=Gb  (行奇,列奇)=B
//   注意：窗口中心 = 右下角往回 2 行 2 列，2 是偶数 → 奇偶不变
//        所以"右下角的相位"就等于"中心的相位"，直接用它即可。
//
// 输出尺寸：5×5 窗口要求四周各够 2 圈，所以输出比输入小 4：
//   112×103 → 108×99（裁剪掉边缘，边缘像素没有完整邻居）
//========================================================================
`timescale 1ns/1ps

module top_demosaic #(
    parameter IMG_W = 112,     // 输入 Bayer 图宽
    parameter IMG_H = 103,     // 输入 Bayer 图高
    parameter AW    = 8,       // 列计数位宽
    parameter RW    = 8,       // 行计数位宽
    parameter PH_D  = 5,       // 相位延迟级数（与窗口对齐；由 TB 扫描确定）
    parameter MHC   = 0        // 去马赛克算法：0=双线性，1=MHC（带细节校正）
)(
    input               clk,
    input               rst_n,
    input  [7:0]        din,          // Bayer 原始数据（每拍一个像素，行优先）
    input               din_valid,
    output [7:0]        o_r,          // 去马赛克后的 R
    output [7:0]        o_g,          // 去马赛克后的 G
    output [7:0]        o_b,          // 去马赛克后的 B
    output              o_valid
);

    localparam N = 5;                 // 5×5 窗口

    //========================================================================
    // 1) 行/列计数器：数当前输入像素在哪一行哪一列（只在 din_valid 时推进）
    //========================================================================
    reg [AW-1:0] col_cnt;
    reg [RW-1:0] row_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_cnt <= {AW{1'b0}};
            row_cnt <= {RW{1'b0}};
        end else if (din_valid) begin
            if (col_cnt == IMG_W - 1) begin
                col_cnt <= {AW{1'b0}};
                // 【关键】行号帧末要回绕到 0！否则多帧连续喂时第二帧的行号
                // 从 IMG_H 继续加、相位奇偶全反（DPC 工程三帧测试时暴露的坑，
                // 此处同步修正——原来的两帧测试被纯色帧掩盖未发现）
                row_cnt <= (row_cnt == IMG_H - 1) ? {RW{1'b0}} : (row_cnt + 1'b1);
            end else begin
                col_cnt <= col_cnt + 1'b1;
            end
        end
    end

    //========================================================================
    // 2) 由"当前像素"的行列奇偶算相位（RGGB）
    //    相位编码：00=R  01=Gr  10=Gb  11=B
    //========================================================================
    wire ph_r  = ~row_cnt[0] & ~col_cnt[0];
    wire ph_gr = ~row_cnt[0] &  col_cnt[0];
    wire ph_gb =  row_cnt[0] & ~col_cnt[0];

    wire [1:0] phase_now = ph_r  ? 2'b00 :
                           ph_gr ? 2'b01 :
                           ph_gb ? 2'b10 : 2'b11;

    // 相位打 PH_D 拍，与窗口对齐（窗口比输入晚若干拍，TB 扫描 PH_D 确定）
    // 【关键】这里必须“每拍都移”（不用 din_valid 使能）：
    //   因为窗口那边的延迟链（valid_d[N-1]）是纯拍数延迟（气泡拍也照样走），
    //   相位链必须和它同构，两者才能在气泡下也保持对齐。
    reg [1:0] ph_pipe [0:PH_D-1];
    integer pi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (pi = 0; pi < PH_D; pi = pi + 1)
                ph_pipe[pi] <= 2'b00;
        end else begin
            ph_pipe[0] <= phase_now;
            for (pi = 1; pi < PH_D; pi = pi + 1)
                ph_pipe[pi] <= ph_pipe[pi-1];
        end
    end

    wire [1:0] phase_win = ph_pipe[PH_D-1];

    //========================================================================
    // 3) 5×5 窗口生成（复用 line_buffer_nxn）
    //========================================================================
    wire               matrix_valid;
    wire [N*N*8-1:0]   win_flat;

    line_buffer_nxn #(
        .DW     (8),
        .IMG_W  (IMG_W),
        .IMG_H  (IMG_H),
        .N      (N)
    ) u_win (
        .clk         (clk),
        .rst_n       (rst_n),
        .din_valid   (din_valid),
        .din         (din),
        .matrix_valid(matrix_valid),
        .win_flat    (win_flat)
    );

    //========================================================================
    // 4) 去马赛克核（相位 phase_win 与 matrix_valid 同拍）
    //    两种算法接口完全一样，用 MHC 参数选一个（换核不改线）
    //========================================================================
    generate
        if (MHC == 0) begin : g_bilinear
            demosaic_bilinear u_core (
                .clk      (clk),
                .rst_n    (rst_n),
                .win_flat (win_flat),
                .phase    (phase_win),
                .valid_in (matrix_valid),
                .r_out    (o_r),
                .g_out    (o_g),
                .b_out    (o_b),
                .valid_out(o_valid)
            );
        end else begin : g_mhc
            demosaic_mhc u_core_mhc (
                .clk      (clk),
                .rst_n    (rst_n),
                .win_flat (win_flat),
                .phase    (phase_win),
                .valid_in (matrix_valid),
                .r_out    (o_r),
                .g_out    (o_g),
                .b_out    (o_b),
                .valid_out(o_valid)
            );
        end
    endgenerate

endmodule