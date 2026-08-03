// ============================================================================
// 模块：line_buffer_nxn —— 可复用参数化行缓存模板（无 padding，crop 输出）
// 功能：输出 N×N 像素窗口，窗口边长 N 可参数化（3x3/4x4/5x5...），
//       供 CSC / 缩放 / 卷积等下游算法复用。窗口右下角 = 当前像素。
//       每帧输出 (IMG_H-N+1)×(IMG_W-N+1) 个窗口（边缘一圈不出窗，crop）。
// 结构：N-1 块推断式 BRAM 级联做行延迟 + 对齐延迟链 + N 深横向移位窗。
//
// 【对齐原理】（本模板的核心，务必理解）
//   像素 P(r,c) 在 T 拍进 din：
//     - BRAM 第 m 块（m=1..N-1）在 T+(m-1) 拍被使能，T+m 拍出数 = P(r-m, c)；
//     - 窗口在 T+(N-1) 拍采样（valid_d[N-1]）；
//     - 所以 BRAM 第 m 块的读出要再打 (N-1-m) 拍才能对齐到窗口 —— 见 adly 延迟链；
//     - 当前像素 din 要打满 (N-1) 拍（pix_d[N-1]）才与最深一行对齐。
//   窗口行 win_col[i]（i=0 顶 .. i=N-1 底）：
//     i = N-1      → pix_d[N-1]              （当前行）
//     i = 0        → stream[N-1]             （最深 BRAM 读出，无需再打拍）
//     其余 i       → adly[N-1-i][i]          （BRAM(N-1-i) 读出再打 i 拍）
//
// 复位：计数器/流水/窗口用异步复位；BRAM 阵列物理不可复位，
//       各 BRAM 读输出寄存器用同步复位（if(!rst_n) 在 posedge clk 内）保推断。
// 资源：N-1 块 BRAM（深 IMG_W × 宽 DW）+ 对齐延迟链 + N×N 移位寄存器。
// ============================================================================
module line_buffer_nxn #(
    parameter DW    = 8,        // 像素位宽
    parameter IMG_W = 640,      // 图像宽度
    parameter IMG_H = 480,      // 图像高度
    parameter N     = 3         // 窗口边长 N×N（需 N>=2）
)(
    input  wire                    clk,
    input  wire                    rst_n,        // 低电平复位
    input  wire                    din_valid,    // 输入像素有效（可不连续）
    input  wire [DW-1:0]           din,          // 逐行光栅扫描输入

    output reg                     matrix_valid, // N×N 窗口有效
    // 窗口扁平输出：win_flat[(行*N+列)*DW +: DW]，行0=顶 列0=左，右下角=当前像素
    output wire [N*N*DW-1:0]       win_flat
);

    localparam AW = $clog2(IMG_W);   // 列地址位宽
    localparam RW = $clog2(IMG_H);   // 行计数位宽

    // ------------------------------------------------------------------------
    // 块1：行/列计数器 —— 跟踪当前输入像素坐标（同 3x3 版）
    // ------------------------------------------------------------------------
    reg [AW-1:0] col_cnt;
    reg [RW-1:0] row_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_cnt <= {AW{1'b0}};
            row_cnt <= {RW{1'b0}};
        end
        else if (din_valid) begin
            if (col_cnt == IMG_W - 1) begin
                col_cnt <= {AW{1'b0}};
                if (row_cnt == IMG_H - 1) row_cnt <= {RW{1'b0}};
                else                       row_cnt <= row_cnt + 1'b1;
            end
            else col_cnt <= col_cnt + 1'b1;
        end
    end

    // ------------------------------------------------------------------------
    // 块2：流水对齐链 valid_d / col_d / row_d / pix_d（s=0..N-1）
    //   s=0 为组合直通（= 原始输入），s>=1 逐级打拍；
    //   valid_d[s] 每拍都更新（追踪 valid），数据寄存器仅在 valid_d[s-1] 时更新。
    // ------------------------------------------------------------------------
    reg          valid_d [0:N-1];
    reg [AW-1:0] col_d   [0:N-1];
    reg [RW-1:0] row_d   [0:N-1];
    reg [DW-1:0] pix_d   [0:N-1];

    // s=0：组合直通
    always @(*) begin
        valid_d[0] = din_valid;
        col_d[0]   = col_cnt;
        row_d[0]   = row_cnt;
        pix_d[0]   = din;
    end

    genvar s;
    generate
    for (s = 1; s <= N-1; s = s + 1) begin : gen_pipe
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) valid_d[s] <= 1'b0;
            else        valid_d[s] <= valid_d[s-1];        // valid 每拍追踪
        end
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                col_d[s] <= {AW{1'b0}};
                row_d[s] <= {RW{1'b0}};
                pix_d[s] <= {DW{1'b0}};
            end
            else if (valid_d[s-1]) begin                    // 数据仅 valid 时打拍
                col_d[s] <= col_d[s-1];
                row_d[s] <= row_d[s-1];
                pix_d[s] <= pix_d[s-1];
            end
        end
    end
    endgenerate

    // ------------------------------------------------------------------------
    // 块3：N-1 块 BRAM 级联做行延迟
    //   BRAM 第 m 块：写 stream[m-1]、读旧值 → stream[m]（= 上 m 行），read-first。
    //   stream[m] 用扁平总线 stream_flat[(m-1)*DW +: DW] 承载。
    //   复位：阵列不可复位；读输出寄存器 rd 同步复位保推断。
    // ------------------------------------------------------------------------
    wire [(N-1)*DW-1:0] stream_flat;

    generate
    // 第 1 块：写当前像素 din
    if (N >= 2) begin : gen_bram1
        (* ram_style = "block" *) reg [DW-1:0] ram1 [0:IMG_W-1];
        reg [DW-1:0] rd1;
        always @(posedge clk) begin
            if (!rst_n) rd1 <= {DW{1'b0}};
            else if (valid_d[0]) begin
                rd1              <= ram1[col_d[0]];   // 先读（上一行）
                ram1[col_d[0]]   <= pix_d[0];         // 后写（当前行）
            end
        end
        assign stream_flat[0 +: DW] = rd1;
    end
    // 第 2..N-1 块：写上一块的读出
    genvar m;
    for (m = 2; m <= N-1; m = m + 1) begin : gen_bram
        (* ram_style = "block" *) reg [DW-1:0] ram [0:IMG_W-1];
        reg [DW-1:0] rd;
        always @(posedge clk) begin
            if (!rst_n) rd <= {DW{1'b0}};
            else if (valid_d[m-1]) begin
                rd               <= ram[col_d[m-1]];                 // 先读（上 m 行）
                ram[col_d[m-1]]  <= stream_flat[(m-2)*DW +: DW];     // 后写（上 m-1 行）
            end
        end
        assign stream_flat[(m-1)*DW +: DW] = rd;
    end
    endgenerate

    // ------------------------------------------------------------------------
    // 块4：对齐延迟链 adly —— 把 BRAM 第 m 块读出再打 (N-1-m) 拍对齐到窗口
    //   adly[m][k] = stream[m] 打 k 拍；索引 (m-1)*(N-1)+(k-1)，k=1..(N-1-m)。
    //   打拍使能打 valid_d[m+k-1]（stream[m] 在 valid_d[m] 有效，逐级顺延）。
    // ------------------------------------------------------------------------
    reg [DW-1:0] adly_flat [0:(N-1)*(N-1)-1];
    genvar mm, kk;
    generate
    for (mm = 1; mm <= N-1; mm = mm + 1) begin : gen_adly_m
        for (kk = 1; kk <= N-1-mm; kk = kk + 1) begin : gen_adly_k
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    adly_flat[(mm-1)*(N-1) + (kk-1)] <= {DW{1'b0}};
                else if (valid_d[mm+kk-1])
                    adly_flat[(mm-1)*(N-1) + (kk-1)] <=
                        (kk == 1) ? stream_flat[(mm-1)*DW +: DW]          // 首拍取 BRAM 读出
                                  : adly_flat[(mm-1)*(N-1) + (kk-2)];     // 后续级联
            end
        end
    end
    endgenerate

    // ------------------------------------------------------------------------
    // 块5：组装当前列的 N 行 win_col[i]（i=0 顶 .. N-1 底），全部已对齐
    // ------------------------------------------------------------------------
    reg [DW-1:0] win_col [0:N-1];
    integer wi;
    always @(*) begin
        win_col[N-1] = pix_d[N-1];                          // 底行 = 当前像素
        win_col[0]   = stream_flat[(N-2)*DW +: DW];         // 顶行 = 最深 BRAM 读出
        for (wi = 1; wi <= N-2; wi = wi + 1)                // 中间行 = adly[N-1-wi][wi]
            win_col[wi] = adly_flat[(N-2-wi)*(N-1) + (wi-1)];
    end

    // ------------------------------------------------------------------------
    // 块6：N×N 窗口横向移位 + matrix_valid
    //   valid_d[N-1] 每来一个对齐列，窗口左移一列，新列从右侧（j=N-1）进入。
    //   门控 row>=N-1 且 col>=N-1：屏蔽帧头 (N-1) 行、行头 (N-1) 列及上电脏数据。
    // ------------------------------------------------------------------------
    reg [DW-1:0] win_flat_reg [0:N*N-1];   // win_flat_reg[行*N+列]
    genvar i, j;
    generate
    for (i = 0; i <= N-1; i = i + 1) begin : gen_wrow
        for (j = 0; j <= N-1; j = j + 1) begin : gen_wcol
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    win_flat_reg[i*N + j] <= {DW{1'b0}};
                else if (valid_d[N-1]) begin
                    if (j == N-1) win_flat_reg[i*N + j] <= win_col[i];        // 新列进右缘
                    else          win_flat_reg[i*N + j] <= win_flat_reg[i*N + j + 1]; // 左移
                end
            end
        end
    end
    // 扁平输出
    for (i = 0; i <= N-1; i = i + 1) begin : gen_oi
        for (j = 0; j <= N-1; j = j + 1) begin : gen_oj
            assign win_flat[(i*N + j)*DW +: DW] = win_flat_reg[i*N + j];
        end
    end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) matrix_valid <= 1'b0;
        else        matrix_valid <= valid_d[N-1]
                                 && (row_d[N-1] >= N-1)
                                 && (col_d[N-1] >= N-1);
    end

endmodule
