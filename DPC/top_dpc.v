//========================================================================
// top_dpc.v —— 坏点校正顶层（DPC 工程）
//
// 数据流（Bayer 进、Bayer 出，每拍一个像素）：
//
//   din[7:0] ──► line_buffer_nxn（N=5：攒出 5×5 窗口）
//                    │ win_flat（25 个像素打包成 200bit）
//                    ▼
//               dpc_envelope（同色邻居取极值 → 双阈值判定 → 亮点/死点替换）
//                    ▲
//               phase（相位）＝ 告诉核"中心是 R 还是 G 还是 B"，决定用哪组同色邻居
//                    ▲
//   行/列计数器 ──► 由行列奇偶算相位 ──► 打 5 拍对齐窗口
//
// 【相位为什么要打 5 拍】同 Demosaic 工程实测结论：
//   窗口比输入晚 5 拍（adly 对齐链 4 拍 + matrix_valid 自身寄存 1 拍），
//   而且相位链必须"每拍都移"（与窗口链同构），否则输入有气泡时会错位。
//
// 【相位怎么算】RGGB：
//   (行偶,列偶)=R  (行偶,列奇)=Gr  (行奇,列偶)=Gb  (行奇,列奇)=B
//   窗口中心 = 右下角往回 2 行 2 列，2 是偶数 → 奇偶不变 → 直接用右下角的相位即可。
//
// 输出尺寸：5×5 窗口要求四周各 2 圈，所以输出比输入小 4（裁掉边缘）：
//   112×103 → 108×99
//========================================================================
`timescale 1ns/1ps

module top_dpc #(
    parameter IMG_W = 112,     // 输入 Bayer 图宽
    parameter IMG_H = 103,     // 输入 Bayer 图高
    parameter AW    = 8,       // 列计数位宽
    parameter RW    = 8,       // 行计数位宽
    parameter PH_D  = 5,       // 相位延迟级数（实测 = N-1 + 1）
    parameter THR   = 32       // 坏点判定阈值
)(
    input               clk,
    input               rst_n,
    input  [7:0]        din,          // Bayer 原始数据（每拍一个像素，行优先）
    input               din_valid,
    output [7:0]        o_dout,       // 校正后的 Bayer 数据
    output              o_valid
);

    localparam N = 5;                 // 5×5 窗口

    //========================================================================
    // 1) 行/列计数器（只在 din_valid 时推进）
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
                // 【关键】行号到最后一帧末要回绕到 0！否则多帧连续喂时，
                // 第二帧的行号从 IMG_H 继续加，相位奇偶就全反了（踩过的坑）
                row_cnt <= (row_cnt == IMG_H - 1) ? {RW{1'b0}} : (row_cnt + 1'b1);
            end else begin
                col_cnt <= col_cnt + 1'b1;
            end
        end
    end

    //========================================================================
    // 2) 相位（RGGB）：00=R 01=Gr 10=Gb 11=B
    //========================================================================
    wire ph_r  = ~row_cnt[0] & ~col_cnt[0];
    wire ph_gr = ~row_cnt[0] &  col_cnt[0];
    wire ph_gb =  row_cnt[0] & ~col_cnt[0];

    wire [1:0] phase_now = ph_r  ? 2'b00 :
                           ph_gr ? 2'b01 :
                           ph_gb ? 2'b10 : 2'b11;

    // 相位打 PH_D 拍，与窗口对齐（每拍都移，与窗口延迟链同构）
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
    wire             matrix_valid;
    wire [N*N*8-1:0] win_flat;

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
    // 4) 坏点校正核（相位 phase_win 与 matrix_valid 同拍）
    //因为nxn窗口下matrix_valid表示打了n拍，所以phase_win也要打n拍
    //========================================================================
    dpc_envelope #(.THR(THR)) u_dpc (
        .clk      (clk),
        .rst_n    (rst_n),
        .win_flat (win_flat),
        .phase    (phase_win),
        .valid_in (matrix_valid),
        .dout     (o_dout),
        .valid_out(o_valid)
    );

endmodule