// ============================================================================
// demosaic_mhc_dw.v —— MHC 版去马赛克核（DW 参数化版）
//
// 来源：Demosaic/demosaic_mhc.v（已验证的 8bit 版本）——算法逻辑零改动，仅位宽参数化：
//   ① win_flat → N*N*DW；② 小组和/移位管道 [9:0]/[10:0]/[12:0] → 按 DW 推导；
//   ③ mhc8 函数 [12:0] → [MW-1:0]，MW = DW+4（8bit 时 13bit 不变语义，RAW10 时 14bit）；
//   ④ 饱和上限 255 → (1<<DW)-1
// 算法（见原文件头）：双线性平均 + 细节校正（"均值 + 高通"还锐度），0 乘法器：
//   R/B 中心：G = (4·W22 + 2·十字G − 远端十字) >> 3；B/R = (4·W22 + 2·对角 − 远端十字) >> 3
//   Gr/Gb 中心：R/B = (2·W22 + 2·近端2 − 远端2) >> 2
//   权重和都是 2 的幂（4+2×4−4=8 → >>3；2+2×2−2=4 → >>2）
// 【负数与超量程】远端项可能比加项大（暗处）→ 正负分开、负钳 0；强边缘可超量程 → 钳满。
//   与工程 CSC"正负分开相加"做法一致。流水：组合 + 1 级寄存（LAT=1），
//   接口与双线性核完全一致，顶层"换核不改线"。
// ============================================================================
`timescale 1ns/1ps

module demosaic_mhc_dw #(
    parameter DW = 10      // 像素位宽（RAW10）
)(
    input               clk,
    input               rst_n,
    input  [25*DW-1:0]  win_flat,     // 5×5 窗口（25×DW 打包，(行*5+列)*DW）
    input  [1:0]        phase,        // 中心相位：00=R 01=Gr 10=Gb 11=B
    input               valid_in,
    input               hold_in,      // = 下级 ostall：1 时输出寄存器保持（简流稳定性）
    output reg  [DW-1:0] r_out,
    output reg  [DW-1:0] g_out,
    output reg  [DW-1:0] b_out,
    output              valid_out
);

    localparam PH_R  = 2'b00;
    localparam PH_GR = 2'b01;
    localparam PH_GB = 2'b10;
    localparam PH_B  = 2'b11;

    localparam MW = DW + 4;             // 中间量位宽：4×(2^DW-1) + 2×(2^(DW+2)-2) < 2^(DW+4)
    localparam [DW-1:0] SAT = {DW{1'b1}};   // 饱和上限（8bit=255，RAW10=1023）

    // 拆窗口：W[k]，k = 行*5+列，W[12] = 中心
    wire [DW-1:0] W [0:24];
    genvar g;
    generate
        for (g = 0; g < 25; g = g + 1) begin : g_unpk
            assign W[g] = win_flat[g*DW +: DW];
        end
    endgenerate

    //========================================================================
    // 公用小组和（DW+2 位：4×DW 或 2×DW 相加最大 < 2^(DW+2)）
    //========================================================================
    wire [DW+1:0] cross4    = {2'b00, W[7]}  + {2'b00, W[17]} + {2'b00, W[11]} + {2'b00, W[13]}; // 十字 4
    wire [DW+1:0] diag4     = {2'b00, W[6]}  + {2'b00, W[8]}  + {2'b00, W[16]} + {2'b00, W[18]}; // 对角 4
    wire [DW+1:0] side2_far = {2'b00, W[10]} + {2'b00, W[14]};   // 左右远端
    wire [DW+1:0] updn2_far = {2'b00, W[2]}  + {2'b00, W[22]};   // 上下远端
    wire [DW+1:0] side2     = {2'b00, W[11]} + {2'b00, W[13]};   // 左右
    wire [DW+1:0] updn2     = {2'b00, W[7]}  + {2'b00, W[17]};   // 上下
    wire [DW+2:0] far4      = {1'b0, side2_far} + {1'b0, updn2_far}; // 远端十字 4 个

    //========================================================================
    // MHC 小函数：out = sat( (pos_a + pos_b − neg) >> sh )，负钳 0、超钳 SAT
    //   pos_a = 中心项（×4 或 ×2 放大，DW+2 位）；pos_b = 邻居项（×2 放大，DW+3 位）
    //   neg = 远端项（DW+3 位）；和最大 < 2^(DW+4) → MW = DW+4 位
    //========================================================================
    function [DW-1:0] mhc_sat;
        input [MW-1:0] pos_a;    // 中心项（×4 或 ×2 放大）
        input [MW-1:0] pos_b;    // 邻居项（×2 放大）
        input [MW-1:0] neg;      // 远端项（要减掉的）
        input [3:0]    sh;       // 右移位数（R/B 相位=3，G 相位=2）
        reg   [MW-1:0] diff;
        begin
            diff = pos_a + pos_b;
            if (diff > neg) begin
                diff = (diff - neg) >> sh;
                mhc_sat = (diff > SAT) ? SAT : diff[DW-1:0];
            end else begin
                mhc_sat = {DW{1'b0}};   // 负数（暗处细节项过大）→ 钳到 0
            end
        end
    endfunction

    //========================================================================
    // 按相位选公式（组合；结果打 1 级寄存器）
    //   移位拼位与 8bit 版同构：{W22,2'b00}=×4、{1'b0,cross4,1'b0}=cross4×2
    //========================================================================
    reg [DW-1:0] r_c, g_c, b_c;
    always @(*) begin
        case (phase)
            PH_R: begin
                r_c = W[12];
                g_c = mhc_sat({2'b00, W[12], 2'b00}, {1'b0, cross4, 1'b0}, far4, 4'd3);
                b_c = mhc_sat({2'b00, W[12], 2'b00}, {1'b0, diag4,  1'b0}, far4, 4'd3);
            end
            PH_B: begin
                b_c = W[12];
                g_c = mhc_sat({2'b00, W[12], 2'b00}, {1'b0, cross4, 1'b0}, far4, 4'd3);
                r_c = mhc_sat({2'b00, W[12], 2'b00}, {1'b0, diag4,  1'b0}, far4, 4'd3);
            end
            PH_GR: begin
                g_c = W[12];
                r_c = mhc_sat({1'b0, W[12], 1'b0}, {1'b0, side2, 1'b0}, {1'b0, side2_far}, 4'd2);
                b_c = mhc_sat({1'b0, W[12], 1'b0}, {1'b0, updn2, 1'b0}, {1'b0, updn2_far}, 4'd2);
            end
            default: begin                                            // PH_GB
                g_c = W[12];
                b_c = mhc_sat({1'b0, W[12], 1'b0}, {1'b0, side2, 1'b0}, {1'b0, side2_far}, 4'd2);
                r_c = mhc_sat({1'b0, W[12], 1'b0}, {1'b0, updn2, 1'b0}, {1'b0, updn2_far}, 4'd2);
            end
        endcase
    end

    //========================================================================
    // 输出寄存 + valid 打 1 拍（数据和有效信号同拍，LAT=1）；hold_in=1 时整组保持
    //========================================================================
    reg valid_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_out   <= {DW{1'b0}};
            g_out   <= {DW{1'b0}};
            b_out   <= {DW{1'b0}};
            valid_r <= 1'b0;
        end else if (!hold_in) begin
            r_out   <= r_c;
            g_out   <= g_c;
            b_out   <= b_c;
            valid_r <= valid_in;
        end
        // hold_in：r/g/b/valid 全保持
    end

    assign valid_out = valid_r;

endmodule
