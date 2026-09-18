//========================================================================
// demosaic_bilinear.v —— 双线性去马赛克核（Demosaic 工程，W3）
//
// 干什么：输入一个 5×5 的 Bayer 窗口（每格只有 R 或 G 或 B 一个值），
//         根据"窗口中心是什么颜色"，用周围邻居的平均值把缺的两个通道补出来，
//         输出完整的一个 RGB 像素。
//
// 【为什么知道中心是什么颜色】Bayer 排列是固定的（本工程用 RGGB）：
//     行0: R G R G ...        行1: G B G B ...
//   所以看中心的（行号奇偶, 列号奇偶）就知道它是什么：
//     (偶,偶)=R   (偶,奇)=Gr（左右是 R、上下是 B）   (奇,偶)=Gb   (奇,奇)=B
//   顶层把相位算好送进来（phase 端口）。
//
// 【补色公式（照伪代码"双线性插值版"，只做加减和移位，没有乘法器）】
//   中心是 R 时：
//     R = 中心自己（本来就有）
//     G = 上下左右 4 个 G 的平均  → (和)>>2
//     B = 四个斜角 4 个 B 的平均  → (和)>>2
//   中心是 B 时：R 和 B 的角色对调，公式一样
//   中心是 Gr/Gb（本来就是 G）：
//     G = 中心自己
//     R = 左右（或上下）2 个的平均 → (和)>>1
//     B = 另一个方向 2 个的平均   → (和)>>1
//
// 【为什么 >> 后面不加舍入】伪代码就是直接截断（>>2、>>1 不加 +2/+1），
//   本工程严格照做，这样和 Python 参考模型能逐位对得一模一样。
//
// 【位宽】4 个 8bit 相加最大 1020 < 2^10；2 个相加最大 510 < 2^9；
//   移位后回到 8bit（最大恰好 255），饱和判断是防御性保留。
//
// 流水：case 选公式 + 加法是组合逻辑，结果打 1 级寄存器输出（LAT=1），
//       valid 也打 1 拍，保证"数据和有效信号同拍"。
//========================================================================
`timescale 1ns/1ps

module demosaic_bilinear (
    input               clk,
    input               rst_n,
    input  [199:0]      win_flat,     // 5×5 窗口（25×8bit 打包）
    input  [1:0]        phase,        // 中心相位：00=R 01=Gr 10=Gb 11=B
    input               valid_in,
    output reg  [7:0]   r_out,
    output reg  [7:0]   g_out,
    output reg  [7:0]   b_out,
    output              valid_out
);

    localparam PH_R  = 2'b00;
    localparam PH_GR = 2'b01;
    localparam PH_GB = 2'b10;
    localparam PH_B  = 2'b11;

    //========================================================================
    // 把打包的窗口拆成 5×5 个 8bit 像素
    //   命名 W<行><列>：行0 = 最上一行，列0 = 最左一列，W22 = 中心
    //   （打包顺序由 line_buffer_nxn 决定：win_flat[(行*5+列)*8 +: 8]，
    //     已用 tb_nxn_n5.v 实测确认：行号越大越靠下、win_flat[199:192] = 右下角）
    //========================================================================
    wire [7:0] W00 = win_flat[0*8  +: 8];
    wire [7:0] W01 = win_flat[1*8  +: 8];
    wire [7:0] W02 = win_flat[2*8  +: 8];
    wire [7:0] W03 = win_flat[3*8  +: 8];
    wire [7:0] W04 = win_flat[4*8  +: 8];
    wire [7:0] W10 = win_flat[5*8  +: 8];
    wire [7:0] W11 = win_flat[6*8  +: 8];
    wire [7:0] W12 = win_flat[7*8  +: 8];
    wire [7:0] W13 = win_flat[8*8  +: 8];
    wire [7:0] W14 = win_flat[9*8  +: 8];
    wire [7:0] W20 = win_flat[10*8 +: 8];
    wire [7:0] W21 = win_flat[11*8 +: 8];
    wire [7:0] W22 = win_flat[12*8 +: 8];   // 中心
    wire [7:0] W23 = win_flat[13*8 +: 8];
    wire [7:0] W24 = win_flat[14*8 +: 8];
    wire [7:0] W30 = win_flat[15*8 +: 8];
    wire [7:0] W31 = win_flat[16*8 +: 8];
    wire [7:0] W32 = win_flat[17*8 +: 8];
    wire [7:0] W33 = win_flat[18*8 +: 8];
    wire [7:0] W34 = win_flat[19*8 +: 8];
    wire [7:0] W40 = win_flat[20*8 +: 8];
    wire [7:0] W41 = win_flat[21*8 +: 8];
    wire [7:0] W42 = win_flat[22*8 +: 8];
    wire [7:0] W43 = win_flat[23*8 +: 8];
    wire [7:0] W44 = win_flat[24*8 +: 8];

    //========================================================================
    // 四个公式里反复出现的"小组和"（组合逻辑，只算一次，省逻辑）
    //   cross4 = 上下左右 4 个格子的和（中心是 R/B 时，这 4 格都是 G）
    //   diag4  = 四个斜角格子的和（中心是 R/B 时，这 4 格是 B/R）
    //   side2  = 左右 2 格的和（Gr/Gb 用它取 R 或 B）
    //   updn2  = 上下 2 格的和（Gr/Gb 用它取另一个色）
    //========================================================================
    wire [9:0] cross4 = {2'b00, W12} + {2'b00, W32} + {2'b00, W21} + {2'b00, W23};
    wire [9:0] diag4  = {2'b00, W11} + {2'b00, W13} + {2'b00, W31} + {2'b00, W33};
    wire [8:0] side2  = {1'b0, W21} + {1'b0, W23};
    wire [8:0] updn2  = {1'b0, W12} + {1'b0, W32};

    // 平均值（截断，不四舍五入 —— 与伪代码/Python 参考一致）
    wire [7:0] cross4_avg = cross4[9:2];    // (和)>>2
    wire [7:0] diag4_avg  = diag4[9:2];
    wire [7:0] side2_avg  = side2[8:1];     // (和)>>1
    wire [7:0] updn2_avg  = updn2[8:1];

    //========================================================================
    // 按相位选公式（组合逻辑；结果打 1 级寄存器）
    // 用 {r,g,b} 三个临时量，最后统一寄存，保证三路同拍
    //========================================================================
    reg [7:0] r_c, g_c, b_c;
    always @(*) begin
        case (phase)
            PH_R: begin                     // 中心是 R
                r_c = W22;                  // 自己直通
                g_c = cross4_avg;           // 上下左右 4 个 G 平均
                b_c = diag4_avg;            // 斜角 4 个 B 平均
            end
            PH_B: begin                     // 中心是 B（和 R 一样，只是 R/B 对调）
                b_c = W22;
                g_c = cross4_avg;
                r_c = diag4_avg;
            end
            PH_GR: begin                    // 中心是 Gr：左右是 R、上下是 B
                g_c = W22;
                r_c = side2_avg;            // 左右 2 个 R 平均
                b_c = updn2_avg;            // 上下 2 个 B 平均
            end
            default: begin                  // PH_GB：中心是 Gb：左右是 B、上下是 R
                g_c = W22;
                b_c = side2_avg;            // 左右 2 个 B 平均
                r_c = updn2_avg;            // 上下 2 个 R 平均
            end
        endcase
    end

    //========================================================================
    // 输出寄存 + valid 打 1 拍（数据和有效信号一起走，LAT=1）
    //========================================================================
    reg valid_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_out   <= 8'd0;
            g_out   <= 8'd0;
            b_out   <= 8'd0;
            valid_r <= 1'b0;
        end else begin
            r_out   <= r_c;
            g_out   <= g_c;
            b_out   <= b_c;
            valid_r <= valid_in;
        end
    end

    assign valid_out = valid_r;

endmodule