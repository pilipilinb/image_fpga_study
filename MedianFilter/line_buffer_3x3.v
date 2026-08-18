// ============================================================================
// 模块：line_buffer_3x3
// 功能：3x3 行缓存（Line Buffer），用 2 个推断式 BRAM 缓存上两行，
//       配合 3 组横向移位寄存器输出 3x3 像素窗口，用于卷积/滤波/边缘检测。
// 复位：低电平复位 rst_n——计数器/流水线/valid 用异步复位（negedge rst_n 进敏感表）；
//       BRAM 用 (* ram_style="block" *) 强制走 block RAM，存储阵列物理不可复位
//       （BRAM 原语无内容复位管脚），其读输出寄存器 line1_rd/line2_rd 用同步复位
//       给定义值 0（不进敏感表，保推断），复位前读出的 x 靠 row/col>=2 门控屏蔽。
// 时序：BRAM 同步读潜伏 1 拍；line2 级整体比 line1 级晚 1 拍；
//       输入 din 到窗口输出共 3 拍延迟（stage1 + stage2 + 窗口寄存器）。
// 资源：2 块 BRAM（深度 IMG_W × 位宽 DW），少量 LUT/FF。
// ============================================================================
module line_buffer_3x3 #(
    parameter DW    = 8,        // 像素位宽
    parameter IMG_W = 640,      // 图像宽度（每行像素数）
    parameter IMG_H = 480,      // 图像高度（行数）
    parameter AW    = 10        // 列地址位宽，需满足 2^AW >= IMG_W
)(
    input  wire            clk,
    input  wire            rst_n,        // 低电平复位
    input  wire            din_valid,    // 输入像素有效（可不连续）
    input  wire [DW-1:0]   din,          // 输入像素，逐行光栅扫描顺序

    output reg             matrix_valid, // 3x3 窗口有效
    // 窗口命名：w<行><列>，w11 为最老行最左列，w33 为当前行当前列
    output reg  [DW-1:0]   w11, w12, w13,   // 上两行
    output reg  [DW-1:0]   w21, w22, w23,   // 上一行
    output reg  [DW-1:0]   w31, w32, w33    // 当前行
);

    localparam RW = $clog2(IMG_H);  // 行计数位宽自动推导，避免 IMG_H 超范围时静默溢出

    // ------------------------------------------------------------------------
    // 块1：行/列计数器 —— 跟踪当前输入像素在图像中的坐标
    // 列计数到 IMG_W-1 归零并使行计数 +1；行计数到 IMG_H-1 归零（帧结束）
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
                if (row_cnt == IMG_H - 1)
                    row_cnt <= {RW{1'b0}};
                else
                    row_cnt <= row_cnt + 1'b1;
            end
            else begin
                col_cnt <= col_cnt + 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------------
    // 块2：line1 BRAM —— 缓存"上一行"
    // read-first 写法：同拍同地址先读旧值（上一行同列像素）再写新值（当前像素）
    // 复位策略：(* ram_style="block" *) 强制 block RAM；存储阵列 line1_ram 物理不可
    //          复位（BRAM 原语无内容复位管脚）；读输出寄存器 line1_rd 用同步复位
    //          （if(!rst_n) 在 posedge clk 内、不进敏感表）给定义值 0，保 BRAM 推断。
    // ------------------------------------------------------------------------
    (* ram_style="block" *) reg [DW-1:0] line1_ram [0:IMG_W-1]; // 上一行像素
    reg [DW-1:0] line1_rd;               // 读潜伏 1 拍：上一行像素

    always @(posedge clk) begin
        if (!rst_n)
            line1_rd <= {DW{1'b0}};                       // 同步复位输出寄存器
        else if (din_valid) begin
            line1_rd            <= line1_ram[col_cnt];  // 先读（旧值 = 上一行）
            line1_ram[col_cnt]  <= din;                 // 后写（新值 = 当前行）
        end
    end

    // ------------------------------------------------------------------------
    // 块3：stage1 流水寄存器 —— 与 line1 读潜伏对齐（延 1 拍）
    // din/col/row/valid 全部打一拍，保证与 line1_rd 同属同一列
    // ------------------------------------------------------------------------
    reg [DW-1:0] din_d1;
    reg [AW-1:0] col_d1;
    reg [RW-1:0] row_d1;
    reg          valid_d1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_d1 <= 1'b0;
            din_d1   <= {DW{1'b0}};
            col_d1   <= {AW{1'b0}};
            row_d1   <= {RW{1'b0}};
        end
        else begin
            valid_d1 <= din_valid;
            if (din_valid) begin
                din_d1 <= din;
                col_d1 <= col_cnt;
                row_d1 <= row_cnt;
            end
        end
    end

    // ------------------------------------------------------------------------
    // 块4：line2 BRAM —— 缓存"上两行"
    // 写数据是 line1 的读结果（晚 1 拍才有效），因此本级用 stage1 的
    // 地址 col_d1 / 使能 valid_d1，整级时序比 line1 级晚 1 拍 —— 关键对齐点
    // ------------------------------------------------------------------------
    // 复位策略：同块2，line2_ram 物理不可复位，line2_rd 用同步复位给定义值 0
    (* ram_style="block" *) reg [DW-1:0] line2_ram [0:IMG_W-1]; // 上两行像素
    reg [DW-1:0] line2_rd;               // 读潜伏 1 拍：上两行像素

    always @(posedge clk) begin
        if (!rst_n)
            line2_rd <= {DW{1'b0}};                       // 同步复位输出寄存器
        else if (valid_d1) begin
            line2_rd            <= line2_ram[col_d1];   // 先读（上两行）
            line2_ram[col_d1]   <= line1_rd;            // 后写（上一行搬进来）
        end
    end

    // ------------------------------------------------------------------------
    // 块5：stage2 流水寄存器 —— 与 line2 读潜伏对齐（再延 1 拍）
    // 至此三行数据在同一拍、同一列上对齐：
    //   line2_rd = 上两行 | line1_d1 = 上一行 | din_d2 = 当前行
    // ------------------------------------------------------------------------
    reg [DW-1:0] din_d2;
    reg [DW-1:0] line1_d1;
    reg [AW-1:0] col_d2;
    reg [RW-1:0] row_d2;
    reg          valid_d2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_d2 <= 1'b0;
            din_d2   <= {DW{1'b0}};
            line1_d1 <= {DW{1'b0}};
            col_d2   <= {AW{1'b0}};
            row_d2   <= {RW{1'b0}};
        end
        else begin
            valid_d2 <= valid_d1;
            if (valid_d1) begin
                din_d2   <= din_d1;
                line1_d1 <= line1_rd;
                col_d2   <= col_d1;
                row_d2   <= row_d1;
            end
        end
    end

    // ------------------------------------------------------------------------
    // 块6：3x3 窗口移位寄存器 + 窗口有效标志
    // 每来一个对齐像素，窗口整体左移一列，新像素从右侧（第 3 列）进入；
    // matrix_valid 与窗口寄存器同拍更新，天然对齐；
    // 门控条件 row>=2 且 col>=2：屏蔽帧头两行、行头两列以及上电 BRAM 脏数据
    // ------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            matrix_valid <= 1'b0;
            {w11, w12, w13} <= {3{{DW{1'b0}}}};
            {w21, w22, w23} <= {3{{DW{1'b0}}}};
            {w31, w32, w33} <= {3{{DW{1'b0}}}};
        end
        else begin
            matrix_valid <= valid_d2 && (col_d2 >= 2) && (row_d2 >= 2);
            if (valid_d2) begin
                {w11, w12, w13} <= {w12, w13, line2_rd};  // 上两行
                {w21, w22, w23} <= {w22, w23, line1_d1};  // 上一行
                {w31, w32, w33} <= {w32, w33, din_d2};    // 当前行
            end
        end
    end

endmodule