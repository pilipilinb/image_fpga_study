// ============================================================================
// demosaic_bilinear_dw.v —— 双线性去马赛克核（DW 参数化版）
//
// 来源：Demosaic/demosaic_bilinear.v（已验证的 8bit 版本）——算法逻辑零改动，仅位宽参数化：
//   ① win_flat 200bit → N*N*DW；② 小组和 cross4 [9:0] → [DW+1:0]（4×DW 相加）；
//   ③ side2/updn2 [8:0] → [DW:0]（2×DW）；④ 输出 [7:0] → [DW-1:0]
// 算法（见原文件头）：按窗口中心相位选公式，缺的通道用同色邻居平均补出：
//   R/B 中心：G = 十字 4 邻均值(>>2)，B/R = 对角 4 邻均值(>>2)
//   Gr/Gb 中心：G = 中心直通，R/B = 左右/上下 2 邻均值(>>1)
//   RGGB 相位：00=R 01=Gr(左右 R 上下 B) 10=Gb(左右 B 上下 R) 11=B
// >> 截断不舍入（与 Python 参考逐位一致）。流水：组合 + 1 级寄存（LAT=1）。
// ============================================================================
`timescale 1ns/1ps

module demosaic_bilinear_dw #(
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

    // 拆窗口：W[k]，k = 行*5+列，W[12] = 中心
    wire [DW-1:0] W [0:24];
    genvar g;
    generate
        for (g = 0; g < 25; g = g + 1) begin : g_unpk
            assign W[g] = win_flat[g*DW +: DW];
        end
    endgenerate

    //========================================================================
    // 小组和（位宽：4×DW 相加最大 < 2^(DW+2)；2×DW < 2^(DW+1)）
    //   cross4 = 上下左右（中心 R/B 时这 4 格是 G）
    //   diag4  = 四个斜角（中心 R/B 时是 B/R）
    //   side2  = 左右（Gr/Gb 取 R 或 B）；updn2 = 上下（另一个色）
    //========================================================================
    wire [DW+1:0] cross4 = {2'b00, W[7]}  + {2'b00, W[17]} + {2'b00, W[11]} + {2'b00, W[13]};
    wire [DW+1:0] diag4  = {2'b00, W[6]}  + {2'b00, W[8]}  + {2'b00, W[16]} + {2'b00, W[18]};
    wire [DW:0]   side2  = {1'b0, W[11]} + {1'b0, W[13]};
    wire [DW:0]   updn2  = {1'b0, W[7]}  + {1'b0, W[17]};

    // 平均值（>>2 / >>1 截断，不四舍五入——与 Python 参考逐位一致）
    wire [DW-1:0] cross4_avg = cross4[DW+1:2];
    wire [DW-1:0] diag4_avg  = diag4[DW+1:2];
    wire [DW-1:0] side2_avg  = side2[DW:1];
    wire [DW-1:0] updn2_avg  = updn2[DW:1];

    //========================================================================
    // 按相位选公式（组合；结果打 1 级寄存器，三路同拍）
    //========================================================================
    reg [DW-1:0] r_c, g_c, b_c;
    always @(*) begin
        case (phase)
            PH_R: begin                     // 中心是 R
                r_c = W[12];
                g_c = cross4_avg;
                b_c = diag4_avg;
            end
            PH_B: begin                     // 中心是 B（R/B 对调）
                b_c = W[12];
                g_c = cross4_avg;
                r_c = diag4_avg;
            end
            PH_GR: begin                    // 中心是 Gr：左右是 R、上下是 B
                g_c = W[12];
                r_c = side2_avg;
                b_c = updn2_avg;
            end
            default: begin                  // PH_GB：左右是 B、上下是 R
                g_c = W[12];
                b_c = side2_avg;
                r_c = updn2_avg;
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
