//========================================================================
// axis_fifo.v —— 同步 FIFO（AXI-Stream 风格握手，链路速率匹配用）
// 功能：写侧无背压连续写入，读侧 tready 门控消费——隔离"无背压前级流水"
//       （高斯/中值/CSC）与"带反压的缩放模块（in_ready）"之间的速率差。
// 放置位置：gaussian → median → CSC（无背压，每拍 1 像素）
//            ↓ 本 FIFO 吸收整帧
//            bilinear_lb_top（放大 2 倍读侧慢，in_ready 周期性拉低）
//
// 【为什么不溢出（链路专用证明）】
//   深度 = 2^14 = 16384 > 一帧像素数 10692（108×99）；
//   任意时刻 FIFO 占用 ≤ 累计写入 ≤ 整帧像素数 < 深度 → 写侧永不写满，
//   读侧即使完全不消费也不会丢数据（放大时读侧至少也在按节奏消费）。
//
// 【AXIS 握手语义】
//   写侧：s_tvalid（前级输出有效）合 s_tready（= !full）才真正写入
//   读侧：BRAM 同步读 1 拍潜伏——rd_en 打拍产生 m_tvalid 与 m_tdata 对齐：
//         当拍 rd_en=1（FIFO 非空且 m_tready=1）→ 下一拍 tdata/tvalid 有效
//
// 复位：存储阵列不可复位（BRAM 铁律）；指针/count/寄存器异步复位
//========================================================================
`timescale 1ns/1ps

module axis_fifo #(
    parameter DATA_W  = 24,        // 数据位宽（YUV 打包）
    parameter DEPTH   = 16384,     // 深度（2 的幂，≥ 一帧像素数）
    parameter AW      = 14         // 地址位宽（log2(DEPTH)）
)(
    input                   clk,
    input                   rst_n,

    // 写侧（前级 CSC 输出，无背压）
    input                  s_tvalid,    // 写有效
    input  [DATA_W-1:0]    s_tdata,     // 写数据
    output                 s_tready,    // 可写（= !full；链路上恒 1）

    // 读侧（缩放模块输入，tready = in_ready）
    output                 m_tvalid,    // 读数据有效（与 m_tdata 同拍）
    output [DATA_W-1:0]    m_tdata,     // 读数据
    input                  m_tready,    // 消费者可接收（反向压）
    output                 fifo_empty   // 组合"空"标志（供帧调度用，非对齐信号）
);

    //========================================================================
    // 存储（推断 BRAM，同步读）
    //========================================================================
    (* ram_style = "block" *) reg [DATA_W-1:0] mem [0:DEPTH-1];

    //========================================================================
    // 指针与计数
    //========================================================================
    reg [AW-1:0] wptr;
    reg [AW-1:0] rptr;
    reg [AW:0]   count;        // 占用数（15bit，能表示 0..DEPTH）

    wire        full  = (count == DEPTH);
    wire        empty = (count == 0);
    wire        wr_en = s_tvalid && !full;
    wire        rd_en = !empty && m_tready;

    assign s_tready  = !full;
    assign fifo_empty = empty;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr  <= {AW{1'b0}};
            rptr  <= {AW{1'b0}};
            count <= {(AW+1){1'b0}};
        end else begin
            if (wr_en) begin
                mem[wptr] <= s_tdata;
                wptr      <= wptr + 1'b1;
            end
            if (rd_en)
                rptr <= rptr + 1'b1;
            case ({wr_en, rd_en})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end

    //========================================================================
    // 读数据通路（BRAM 同步读 1 拍 + valid 保持语义）
    // 【关键（本链路踩过的坑）】rvalid 不能只打一拍（rvalid<=rd_en）：
    //   数据呈现拍若遇消费者反压（tready=0），下拍 valid 会被清 0，
    //   数据在 FIFO 与消费者之间悬空丢失（实测差 95 像素）。
    //   正确语义：valid 保持到"交付完成"（tvalid && tready 同拍）——
    //   rd_en=1 时加载新数据并保持 valid；tready=1 时才算交付并清 valid。
    //========================================================================
    reg [DATA_W-1:0] rdata_reg;
    reg              rvalid_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rdata_reg  <= {DATA_W{1'b0}};
            rvalid_reg <= 1'b0;
        end else begin
            if (rd_en) begin
                rdata_reg  <= mem[rptr];
                rvalid_reg <= 1'b1;
            end else if (m_tready) begin
                // 空闲且消费者就绪：清除 pending（无数据时保持 0）
                rvalid_reg <= 1'b0;
            end
        end
    end

    assign m_tvalid = rvalid_reg;
    assign m_tdata  = rdata_reg;

endmodule