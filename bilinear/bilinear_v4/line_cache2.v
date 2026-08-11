//========================================================================
// line_cache2.v —— 3 行环形行缓存（bilinear_v4 版，行缓存版缩放核心）
// 功能：流式像素输入（光栅顺序），按源坐标 (sy,sx) 随机读 2×2 邻域
//       替代 v3 的 4 份整图 ROM，存储恒定 3 行（与图像高度无关）
//
// 原理（配 line_buffer_principle.html 理解）：
//   - 3 行环形：源行 r 存槽位 r%3；写 1 行 + 读 2 行（双线性窗口 {sy,sy+1}）正好 3 行
//   - 写侧游标 w：光栅顺序写第 w 行，行写完 w+1
//   - 读侧窗口：coord_gen 输出源坐标 (sy,sx)，只需窗口顶行 sy+1 已写完
//   - 反压两条判定式（核心，写死）：
//       wr_ready = 槽位 w%3 的旧行(w-3)已被读侧滑过   // 写侧不覆盖读侧还在用的行
//       rd_ready = (sy01 < w)                          // 窗口顶行已写完
//     - 放大（写快读慢）：写侧追上读窗口后 wr_ready=0 暂停，等读侧滑动释放槽位
//     - 缩小（写慢读快）：读侧要的行没写完，rd_ready=0 暂停，等写侧
//     - 帧末排空：读侧完成后 sy 停住，写侧仍可写完剩余行（旧行已被滑过），
//       不会像"w<=sy01"规则那样卡死（缩小场景输出先完成、输入未喂完）
//     - 谁落后谁等待，无死锁（3 行环形保证写读差 ≤3 时总有解）
//
// 存储：reg 数组 = 分布式 RAM（多读口自由组合，组合读 0 拍潜伏）
//   大图升级路径：每行换 BRAM（1W2R 需双块或分拍读），行就绪/反压逻辑不变；
//   注意 BRAM 读变同步（1 拍）时顶层需补对齐寄存
//
// 地址钳位：sx/sy 及 +1 越界钳位（与 v3 一致），钳位后 sy01==sy 时行就绪判定依旧成立
// 复位：存储阵列不复位（脏数据由 rd_ready 门控屏蔽，守 BRAM 铁律精神）
// 帧边界：帧末排空由顶层控制（输入结束后写侧停，读侧继续读已写行）
//========================================================================
`timescale 1ns/1ps

module line_cache2 #(
    parameter DW         = 24,     // 像素位宽（RGB888）
    parameter IN_WIDTH   = 112,    // 行宽
    parameter IN_HEIGHT  = 103     // 行数
)(
    input                       clk,
    input                       rst_n,       // 低电平复位（异步）

    // 写口（流式输入，光栅顺序）
    input  [DW-1:0]             din,
    input                       din_valid,
    output                      wr_ready,    // 写反压：拉低时输入应暂停

    // 读口（源坐标来自 coord_gen，组合）
    input  [RW-1:0]             rd_sy,       // 源 y（可能越界，内部钳位）
    input  [CW-1:0]             rd_sx,       // 源 x
    output                      rd_ready,    // 行就绪：拉低时坐标不应推进

    // 4 邻居输出（组合，与 rd_sy/rd_sx 同拍）
    output [DW-1:0]             dout00,      // P(sy,   sx)
    output [DW-1:0]             dout10,      // P(sy,   sx+1)
    output [DW-1:0]             dout01,      // P(sy+1, sx)
    output [DW-1:0]             dout11       // P(sy+1, sx+1)
);

    // 位宽派生
    localparam CW = $clog2(IN_WIDTH)  + 1;   // 源 x 位宽（容纳累加越界到 IN_W）
    localparam RW = $clog2(IN_HEIGHT) + 1;   // 源 y 位宽
    localparam WW = $clog2(IN_WIDTH);        // 写列计数位宽（0..IN_W-1）
    localparam WROW = $clog2(IN_HEIGHT) + 1; // 写行计数位宽（w 最大 IN_H）

    //========================================================================
    // 存储：3 行环形（分布式 RAM，组合读）
    //========================================================================
    reg [DW-1:0] line [0:2] [0:IN_WIDTH-1];

    //========================================================================
    // 写侧状态
    //========================================================================
    reg [WROW-1:0] w;          // 正在写行号（0 基；已写完 0..w-1 行）
    reg [WW-1:0]   wr_col;     // 写列（0..IN_W-1）

    // 读窗口（钳位后）：双线性需要 sy 与 sy+1 两行
    wire [RW-1:0] sy00 = (rd_sy      > IN_HEIGHT-1) ? IN_HEIGHT-1 : rd_sy;
    wire [RW-1:0] sy01 = (rd_sy + 1'b1 > IN_HEIGHT-1) ? IN_HEIGHT-1 : rd_sy + 1'b1;

    // 反压判定（核心规则）
    // 写侧：槽位 w%3 里的旧行是 w-3（第 3 次轮到该槽位才可能冲突）；
    //   旧行 w-3 已被读侧滑过（读窗口底 sy00 > w-3）才允许覆盖。
    //   前 3 行槽位从未写过，无条件可写。帧末读侧停滞后仍能写完剩余行。
    assign wr_ready = ((w < 3) || (sy00 > w - 3)) && (w < IN_HEIGHT);
    assign rd_ready = (sy01 < w);                       // 窗口顶行已写完

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w      <= {WROW{1'b0}};
            wr_col <= {WW{1'b0}};
        end
        else if (din_valid && wr_ready) begin
            line[w % 3][wr_col] <= din;
            if (wr_col == IN_WIDTH - 1) begin
                wr_col <= {WW{1'b0}};
                w      <= w + 1'b1;      // 行写完，推进
            end
            else begin
                wr_col <= wr_col + 1'b1;
            end
        end
    end

    //========================================================================
    // 读侧：地址钳位 + 组合读 4 邻居
    //========================================================================
    wire [CW-1:0] sx00 = (rd_sx      > IN_WIDTH-1)  ? IN_WIDTH-1  : rd_sx;
    wire [CW-1:0] sx10 = (rd_sx + 1'b1 > IN_WIDTH-1)? IN_WIDTH-1  : rd_sx + 1'b1;

    assign dout00 = line[sy00 % 3][sx00];
    assign dout10 = line[sy00 % 3][sx10];
    assign dout01 = line[sy01 % 3][sx00];
    assign dout11 = line[sy01 % 3][sx10];

endmodule