// ============================================================================
// 模块：line_buffer_3x3_pad
// 功能：3x3 行缓存 + 窗口级 replicate padding（最近边缘像素复制）。
//       每帧输出 IMG_H*IMG_W 个窗口（每像素一个，w22 为窗口中心），
//       相比 line_buffer_3x3.v 的 (H-2)*(W-2) 内部窗口，补齐了四条边。
// 实现：四条边分治——
//       上边：窗口顶行是无效数据，输出级 mux 用中行复制（at_top）
//       左边：窗口左列是无效数据，输出级 mux 用中列复制（at_left）
//       右边：每行末尾插 1 个 flush 拍，把最右列重复移入一次（rflush）
//       下边：帧尾插一整行 flush 拍，只读 BRAM 不写，中/底行同取 line1（bflush）
// 时序前提（对输入流的要求，与真实视频 blanking 一致）：
//       h-blank：每行最后一个像素后 din_valid 至少拉低 1 拍
//       v-blank：每帧最后一个像素后 din_valid 至少拉低 IMG_W+8 拍
//       （没有空拍 flush 拍插不进去——连续流做 padding 需要 2 倍速时钟，物理不可行）
// 复位：同 line_buffer_3x3.v——BRAM 阵列不可复位；读出寄存器同步复位；
//       控制/流水寄存器低电平异步复位。
// 延迟：din 到窗口输出共 4 拍（stage1 + stage2 + 窗口移位 + 输出mux寄存）。
// ============================================================================
module line_buffer_3x3_pad #(
    parameter DW    = 8,        // 像素位宽
    parameter IMG_W = 640,      // 图像宽度（需 >= 2）
    parameter IMG_H = 480,      // 图像高度（需 >= 2）
    parameter AW    = 10        // 列地址位宽，需满足 2^AW >= IMG_W
)(
    input  wire            clk,
    input  wire            rst_n,        // 低电平复位
    input  wire            din_valid,    // 输入像素有效（行间/帧间需 blanking）
    input  wire [DW-1:0]   din,          // 输入像素，逐行光栅扫描顺序

    output reg             matrix_valid, // 窗口有效，每帧 IMG_H*IMG_W 次
    // 窗口命名：w<行><列>，w22 为中心像素；边缘窗口越界处已按 replicate 填充
    output reg  [DW-1:0]   w11, w12, w13,
    output reg  [DW-1:0]   w21, w22, w23,
    output reg  [DW-1:0]   w31, w32, w33
);

    localparam RW = $clog2(IMG_H);  // 行计数位宽自动推导

    // ------------------------------------------------------------------------
    // 块1：行/列计数器 —— 跟踪当前输入像素坐标（与原版相同）
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
    //flush:输入已经停了，但缓存里还压着没处理完的数据，需要额外的动作把它们赶出来
    // 块2：flush 控制信号声明（逻辑在块7，BRAM 读口要用所以提前声明）
    // bflush：帧尾整行 flush（下边缘）；rflush：行尾单拍 flush（右边缘）
    // ------------------------------------------------------------------------
    reg              bf_active;                  // 帧尾 flush 读进行中
    reg  [AW-1:0]    fcol;                       // flush 读地址
    wire             bflush_rd = bf_active;
    reg              bflush_dv;                  // flush 读数据有效（晚 1 拍）
    reg  [AW-1:0]    bcol_d;                     // 与 bflush_dv 对齐的列号
    reg              rflush_pend;                // 行尾 flush 拍待插入
    reg  [RW-1:0]    crow_saved;                 // 待插入 flush 拍的窗口中心行
    wire             rflush_fire;

    // ------------------------------------------------------------------------
    // 块3：line1 BRAM —— 缓存"上一行"（read-first，规则同原版）
    // 新增 bflush 只读分支：帧尾 din_valid=0 时按 fcol 读出 row H-1，不写
    // ------------------------------------------------------------------------
    (* ram_style="block" *) reg [DW-1:0] line1_ram [0:IMG_W-1];
    reg [DW-1:0] line1_rd;

    always @(posedge clk) begin
        if (!rst_n)
            line1_rd <= {DW{1'b0}};                       // 同步复位输出寄存器
        else if (din_valid) begin
            line1_rd            <= line1_ram[col_cnt];  // 先读（上一行）
            line1_ram[col_cnt]  <= din;                 // 后写（当前行）
        end
        else if (bflush_rd)
            line1_rd <= line1_ram[fcol];                // 帧尾只读：row H-1
    end

    // ------------------------------------------------------------------------
    // 块4：stage1 流水寄存器 —— 与 line1 读潜伏对齐（与原版相同）
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
    // 块5：line2 BRAM —— 缓存"上两行"（主通路用打拍地址 col_d1，同原版）
    // bflush 只读分支：与 line1 同拍同地址读——只读时无写迟延，两 RAM 天然对齐
    // ------------------------------------------------------------------------
    (* ram_style="block" *) reg [DW-1:0] line2_ram [0:IMG_W-1];
    reg [DW-1:0] line2_rd;

    always @(posedge clk) begin
        if (!rst_n)
            line2_rd <= {DW{1'b0}};
        else if (valid_d1) begin
            line2_rd            <= line2_ram[col_d1];   // 先读（上两行）
            line2_ram[col_d1]   <= line1_rd;            // 后写（上一行搬进来）
        end
        else if (bflush_rd)
            line2_rd <= line2_ram[fcol];                // 帧尾只读：row H-2
    end

    // ------------------------------------------------------------------------
    // 块6：stage2 流水寄存器 —— 与 line2 读潜伏对齐（与原版相同）
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
    // 块7：flush 控制
    // rflush（右边缘）：行末像素过 stage2 时置 pend，在下一个空拍发射一个
    //   "重复移入最右列"的拍——窗口从 (W-3,W-2,W-1) 变 (W-2,W-1,W-1)，天然 replicate
    // bflush（下边缘）：最后一个正常行的 rflush 发射后启动，fcol 扫 0..W-1
    //   只读两块 BRAM（line1=row H-1 / line2=row H-2），读完再补一个 rflush
    // ------------------------------------------------------------------------
    assign rflush_fire = rflush_pend && !valid_d2 && !bflush_dv;  // 空拍才发射
//crow_saved 行尾欠一拍时，把"这笔账是替哪个中心行欠的"记下来，因为还账时（fire 那拍）row_d2 可能已经变了，不能现算，只能提前存。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rflush_pend <= 1'b0;
            crow_saved  <= {RW{1'b0}};
        end
        else if (valid_d2 && (col_d2 == IMG_W-1) && (row_d2 >= 1)) begin
            rflush_pend <= 1'b1;                 // 正常行行末：中心行 = row_d2-1
            crow_saved  <= row_d2 - 1'b1;
/*为什么要crow_saved  <= row_d2 - 1'b1; 因为 row_d2 - 1'b1是真正的中心行
w11 w12 w13  ← line2_rd  = 行 r-2   （顶行）
w21 w22 w23  ← line1_d1  = 行 r-1   （中行）★ 中心在这
w31 w32 w33  ← din_d2    = 行 r     （底行，最新）
*/

        end
        else if (bflush_dv && (bcol_d == IMG_W-1)) begin
            rflush_pend <= 1'b1;                 // flush 行行末：中心行 = H-1
            crow_saved  <= IMG_H - 1;
        end
        else if (rflush_fire)
            rflush_pend <= 1'b0;
    end
//crow_saved == IMG_H-2 中心行 H-2 是最后一个正常行（输入行 H-1）产的，它的账都还完了，说明正常数据彻底走完 → 该启动帧尾回放了。这就是模块判断"一帧结束"的方式
    wire bf_start = rflush_fire && (crow_saved == IMG_H-2);  // 最后正常行发射完→启动帧尾 flush


    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bf_active <= 1'b0;
            fcol      <= {AW{1'b0}};
            bflush_dv <= 1'b0;
            bcol_d    <= {AW{1'b0}};
        end
        else begin
            bflush_dv <= bf_active;              // 读数据晚 1 拍有效
            bcol_d    <= fcol;
            if (bf_start) begin
                bf_active <= 1'b1;
                fcol      <= {AW{1'b0}};
            end
            else if (bf_active) begin
                if (fcol == IMG_W-1)
                    bf_active <= 1'b0;
                else
                    fcol <= fcol + 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------------
    // 块8：统一拍仲裁 + 窗口移位（stage3）
    // 三种拍互斥：正常拍(valid_d2) / 帧尾flush拍(bflush_dv) / 行尾flush拍(rflush_fire)
    // 中心坐标：正常拍 (row_d2-1, col_d2-1)；flush行 (H-1, bcol_d-1)；行尾 ( crow_saved, W-1)
    // ------------------------------------------------------------------------
    wire beat_en = valid_d2 || bflush_dv || rflush_fire;
    wire emit_ok = rflush_fire
                || (bflush_dv && (bcol_d >= 1))
                || (valid_d2 && (row_d2 >= 1) && (col_d2 >= 1));
    // at_top：中心行==0（顶行需复制）；at_left：中心列==0（左列需复制）
    wire at_top_in  = rflush_fire ? (crow_saved == 0) : (!bflush_dv && (row_d2 == 1));
    wire at_left_in = !rflush_fire && (bflush_dv ? (bcol_d == 1) : (col_d2 == 1));

    reg [DW-1:0] win11, win12, win13;
    reg [DW-1:0] win21, win22, win23;
    reg [DW-1:0] win31, win32, win33;

    // 移入数据三选一：行尾flush=重复最右列；帧尾flush=中/底行同取line1(row H-1复制)
    wire [DW-1:0] top_in = rflush_fire ? win13 : line2_rd;
    wire [DW-1:0] mid_in = rflush_fire ? win23 : (bflush_dv ? line1_rd : line1_d1);
    wire [DW-1:0] bot_in = rflush_fire ? win33 : (bflush_dv ? line1_rd : din_d2);

    reg win_valid, at_top_r, at_left_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            win_valid <= 1'b0;
            at_top_r  <= 1'b0;
            at_left_r <= 1'b0;
            {win11, win12, win13} <= {3{{DW{1'b0}}}};
            {win21, win22, win23} <= {3{{DW{1'b0}}}};
            {win31, win32, win33} <= {3{{DW{1'b0}}}};
        end
        else begin
            win_valid <= emit_ok;
            if (emit_ok) begin
                at_top_r  <= at_top_in;
                at_left_r <= at_left_in;
            end
            if (beat_en) begin
                {win11, win12, win13} <= {win12, win13, top_in};
                {win21, win22, win23} <= {win22, win23, mid_in};
                {win31, win32, win33} <= {win32, win33, bot_in};
            end
        end
    end

    // ------------------------------------------------------------------------
    // 块9：输出级 padding mux + 寄存（stage4）
    // 上边：顶行 ← 中行；左边：左列 ← 中列；右/下边已在移入数据时复制完成
    // ------------------------------------------------------------------------
    wire [DW-1:0] t1 = at_top_r ? win21 : win11;
    wire [DW-1:0] t2 = at_top_r ? win22 : win12;
    wire [DW-1:0] t3 = at_top_r ? win23 : win13;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            matrix_valid <= 1'b0;
            {w11, w12, w13} <= {3{{DW{1'b0}}}};
            {w21, w22, w23} <= {3{{DW{1'b0}}}};
            {w31, w32, w33} <= {3{{DW{1'b0}}}};
        end
        else begin
            matrix_valid <= win_valid;
            if (win_valid) begin
                w11 <= at_left_r ? t2    : t1;    w12 <= t2;    w13 <= t3;
                w21 <= at_left_r ? win22 : win21; w22 <= win22; w23 <= win23;
                w31 <= at_left_r ? win32 : win31; w32 <= win32; w33 <= win33;
            end
        end
    end

endmodule