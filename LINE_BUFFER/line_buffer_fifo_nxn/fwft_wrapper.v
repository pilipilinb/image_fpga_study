// ============================================================================
// 模块：fwft_wrapper —— 把"标准读模式"FIFO 包装成 FWFT（首字直通）
//
// 干什么：async_fifo 是标准读模式（rd_en 拉高的下一拍 dout 才有效）。行缓存级联
//   要求"数据与 valid 同拍"（否则每级斜一拍像素），所以在外面套一层预取寄存器，
//   对外表现与 Xilinx FIFO Generator 的 "First-Word Fall Through" 模式完全一致：
//     · out_vld=1 时 dout 已持有最老的那个字（未消费它就不会变）
//     · 消费一拍（pop）后，下一拍 dout 自动换成下一个字
//
// 【预取策略】std_rd = !empty && (!vld_r || pop)
//   - 输出寄存器空着 → 只要 FIFO 里有字就预取（尽快把最老的字摆到 dout）
//   - 输出寄存器被消费 → 同拍预取下一个字（无缝续流，连续流不掉速）
//   - 输出寄存器有效且没被消费 → 不预取（保持稳定，这是下游能"冻结"我们的前提）
//   注意 async_fifo 的 empty 是"寄存一拍 + 前瞻"的，且跨域同步链让它略偏保守；
//   在行缓存里 FIFO 恒有 IMG_W 个字的占用，empty 稳定为 0，不影响时序。
//
// 【push/pop 配对约定（行缓存的关键）】
//   本 wrapper 不做任何配对检查，由上层保证"预热后每个 beat 同拍 push+pop"。
//   唯一例外是预热期（pop 不来）：那时 out_vld 会停在第一个字上，属于预期行为
//   （上层用 beat 计数门控输出，不会用这段脏数据）。
//
// 【换官方 IP 路径】Vivado FIFO Generator（Independent Clocks）勾选
//   "First Word Fall Through"，端口与本 wrapper + async_fifo 同名同义：
//   rst/rst_busy/empty/full/din/wr_en/dout/rd_en。替换时删掉本 wrapper 与
//   async_fifo，把 FIFO Generator 按同名直连即可，上层零改动。
//   （IP 仿真模型加密，iverilog 编不了，需用同一套 TB 在 Vivado xsim 重跑）
// ============================================================================
`timescale 1ns/1ps

`ifndef FWFT_WRAPPER_V_INC
`define FWFT_WRAPPER_V_INC

`include "async_fifo.v"          // 依赖：fifo/async_fifo.v（自带同名守卫；-I 指向 fifo 目录）

module fwft_wrapper #(
    parameter DW    = 10,        // 数据位宽
    parameter DEPTH = 1024       // 深度（2 的幂；行缓存用 ≥ IMG_W+1 即可）
)(
    input  wire          clk,
    input  wire          rst_n,      // 低有效（工程习惯；内部转成 FIFO 的高有效）
    // 入侧：写入一个字（与 pop 由上层配对驱动）
    input  wire          push,
    input  wire [DW-1:0] din,
    // 出侧：FWFT 语义
    input  wire          pop,        // 消费一个字
    output wire [DW-1:0] dout,       // 与 out_vld 同拍有效
    output wire          out_vld,
    // 复位同步状态（同步释放期间上层必须停手）
    output wire          busy
);

    localparam AW = $clog2(DEPTH);

    wire          full, empty;
    wire [DW-1:0] fifo_dout;
    wire [AW:0]   data_count;
    wire          wr_busy, rd_busy;

    reg vld_r;   // 输出寄存器（= FIFO 自己的 dout 寄存器）里是否躺着未消费的字

    // 预取条件：FIFO 非空，且（输出寄存器空 或 本拍被消费）
    wire std_rd = !empty && (!vld_r || pop);

    async_fifo #(.DW(DW), .DEPTH(DEPTH)) u_fifo (
        .wr_clk (clk),
        .rd_clk (clk),
        .rst    (!rst_n),          // async_fifo 是高有效复位
        .din    (din),
        .wr_en  (push),
        .rd_en  (std_rd),
        .dout   (fifo_dout),
        .full   (full),
        .empty  (empty),
        .data_count (data_count),
        .wr_rst_busy(wr_busy),
        .rd_rst_busy(rd_busy)
    );

    // vld_r 与 async_fifo 的 dout 同步推进：
    //   std_rd 那一拍发起读取，下一拍 dout 变成读出的字 → 此时 vld_r 置 1
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)     vld_r <= 1'b0;
        else if (std_rd) vld_r <= 1'b1;   // 预取成功（下一拍数据就位）
        else if (pop)    vld_r <= 1'b0;   // 消费掉且没有新预取
    end

    assign dout    = fifo_dout;
    assign out_vld = vld_r;
    assign busy    = wr_busy | rd_busy;

endmodule

`endif  // FWFT_WRAPPER_V_INC
