// ============================================================================
// axis_stream_fifo —— 手写 AXI4-Stream Data FIFO（单时钟域，带 tuser/tlast 侧带）
//
// 干什么：链路首尾的弹性 FIFO。入侧接 AXIS 源（如 CSI-2 RX / BLC 出端），
//   出侧接 AXIS 汇（如 BLC 入端 / VDMA S2MM），做速率匹配 + 反压缓冲。
//   接口与 Xilinx AXI4-Stream Data FIFO IP 同名同语义，集成时可整体替换为 IP。
//
// 【与 async_fifo 的三点差异】
//   1) 单时钟：AXIS 是 aclk 单时钟协议（跨域由 CDC 层负责），不需要格雷码双域
//      指针——空满直接比较本域指针即可。
//   2) 侧带打包：tuser/tlast 与 tdata 拼成一个宽字 {tuser, tlast, tdata} 进出
//      同一块 BRAM，天然保证"数据与语义逐拍对位不错位"——这正是官方 AXIS Data
//      FIFO 比"FIFO Generator + 手动侧带"省事的地方，手写也要做到。
//   3) AXIS 语义的输出级：AXIS 规范要求 m_axis_tvalid=1 时 tdata/tlast/tuser
//      必须有效且在 ready 之前保持稳定。所以内部做"输出寄存器 + 自动预取"
//      （即 FWFT 结构）：BRAM 里最老的字提前搬进输出寄存器，tvalid 就是
//      输出寄存器的有效标志。连续流时"消费一拍、预取一拍"无缝衔接零气泡。
//      副作用：总容量 = DEPTH（BRAM）+ 1（输出寄存器）= DEPTH+1 字，
//      与 Xilinx FWFT 模式 FIFO 的容量语义一致（写满判据见 TB 阶段C）。
//
// 【空满判断为什么无组合环】async_fifo 踩过"full 参与 wptr_next 门控、
//   wptr_next 又决定 full"的组合环（vvp 事件风暴 22.6GB）。本模块满判断
//   直接比较两个寄存器的当前值（wptr/rptr），不前瞻、不参与自身门控，
//   物理上不存在环。代价是 full 滞后一拍：第 DEPTH 个写进行的那拍 full=0
//   （写入成功），下一拍 full=1 挡住第 DEPTH+1 个——从空写满恰好 DEPTH 个
//   BRAM 字 + 输出寄存器 1 字 = DEPTH+1 个，不会溢出。
//
// 【复位】AXIS 标准 aresetn 低有效、异步断言同步释放（两级同步器）。
//   复位期间 m_axis_tvalid=0（AXIS 规范要求）；BRAM 阵列不可复位（物理限制），
//   指针清零 + 输出级 valid 清零后天然读不到残留数据。
//
// 【参数】
//   DW       数据位宽（链路里 RAW10 用 10，RGB888 用 24；默认 8 对齐 IP 最小档）
//   DEPTH    深度（2 的幂）
//   TLAST_EN 1=tlast 侧带存储并透传；0=端口恒 0、不占存储位宽
//   TUSER_EN 1=tuser 侧带存储并透传；0=端口恒 0、不占存储位宽
//   TUSER_W  tuser 位宽（链路里 1bit=帧首 SOF）
// ============================================================================
`timescale 1ns/1ps

module axis_stream_fifo #(
    parameter DW       = 8,          // 数据位宽
    parameter DEPTH    = 512,        // 深度（必须 2 的幂）
    parameter TLAST_EN = 1,          // tlast 侧带使能
    parameter TUSER_EN = 1,          // tuser 侧带使能
    parameter TUSER_W  = 1           // tuser 位宽
)(
    input  wire                aclk,
    input  wire                aresetn,           // AXIS 标准：低有效
    // ---- Slave 侧（入） ----
    input  wire [DW-1:0]       s_axis_tdata,
    input  wire                s_axis_tvalid,
    output wire                s_axis_tready,
    input  wire                s_axis_tlast,
    input  wire [TUSER_W-1:0]  s_axis_tuser,
    // ---- Master 侧（出） ----
    output wire [DW-1:0]       m_axis_tdata,
    output wire                m_axis_tvalid,
    input  wire                m_axis_tready,
    output wire                m_axis_tlast,
    output wire [TUSER_W-1:0]  m_axis_tuser
);

    localparam AW = $clog2(DEPTH);                 // 地址位宽；指针 AW+1 位（多 1 位绕圈位）
    // 内部打包字位宽（EN=0 的侧带不占存储）
    localparam TL_W = TLAST_EN ? 1 : 0;
    localparam TU_W = TUSER_EN ? TUSER_W : 0;
    localparam TW   = DW + TL_W + TU_W;

    // ------------------------------------------------------------------------
    // 存储阵列：打包字 {tuser, tlast, tdata} 单口写、单口读（同时钟 BRAM）
    // ------------------------------------------------------------------------
    (* ram_style = "block" *) reg [TW-1:0] mem [0:DEPTH-1];

    // ------------------------------------------------------------------------
    // 复位同步器：异步断言、同步释放（释放后空/满标志才有效）
    // ------------------------------------------------------------------------
    reg [1:0] rst_sync;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) rst_sync <= 2'b11;
        else          rst_sync <= {rst_sync[0], 1'b0};
    end
    wire rst_busy = rst_sync[1];                   // 1=复位同步期间，指针钳 0

    // ------------------------------------------------------------------------
    // 打包 / 解包（generate 分支避免 0 宽度拼接的非法语法）
    // ------------------------------------------------------------------------
    reg [TW-1:0] w_word;
    generate
        if (TLAST_EN && TUSER_EN) begin : pk_full
            always @* w_word = {s_axis_tuser, s_axis_tlast, s_axis_tdata};
        end else if (TLAST_EN) begin : pk_tlast
            always @* w_word = {s_axis_tlast, s_axis_tdata};
        end else if (TUSER_EN) begin : pk_tuser
            always @* w_word = {s_axis_tuser, s_axis_tdata};
        end else begin : pk_none
            always @* w_word = s_axis_tdata;
        end
    endgenerate

    // ------------------------------------------------------------------------
    // 指针与空满（同域：直接比较当前寄存器值，无组合环）
    // ------------------------------------------------------------------------
    reg  [AW:0] wptr, rptr;                        // AW+1 位：高位是绕圈位
    reg         out_vld;                           // 输出寄存器持有有效字
    reg  [TW-1:0] out_word;                        // 输出寄存器（BRAM 读出打一拍）

    // 满：低 AW 位相等且绕圈位不同（mem 里恰好 DEPTH 个字）
    //   比较当前值 → 滞后一拍置位，从空写满恰好 DEPTH 个 BRAM 写（见头部说明）
    wire full     = (wptr[AW] != rptr[AW]) && (wptr[AW-1:0] == rptr[AW-1:0]);
    // mem 非空：指针不等（含绕圈位）
    wire mem_occ  = (wptr != rptr);

    // AXI-Stream 握手
    assign s_axis_tready = !full;                  // 非满即可收（复位期间 full=0、
                                                   //   tready=1；但规范源复位期不发数，
                                                   //   mem 脏写被清零指针屏蔽，无害）
    wire s_fire = s_axis_tvalid && s_axis_tready;  // 真正写入一个字
    assign m_axis_tvalid = out_vld;
    wire m_fire = out_vld && m_axis_tready;        // 真正读走一个字

    // 预取：mem 有字 且（输出级空 或 本拍被消费）——保证 tvalid 拍 tdata 已有效
    wire prefetch = mem_occ && (!out_vld || m_fire);

    wire [AW:0] wptr_next = wptr + (s_fire    ? 1'b1 : 1'b0);
    wire [AW:0] rptr_next = rptr + (prefetch  ? 1'b1 : 1'b0);

    // ------------------------------------------------------------------------
    // 指针 / 输出级（out_word 是数据寄存器，可复位；mem 阵列不可复位）
    // ------------------------------------------------------------------------
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            wptr     <= {(AW+1){1'b0}};
            rptr     <= {(AW+1){1'b0}};
            out_vld  <= 1'b0;
            out_word <= {TW{1'b0}};
        end else if (rst_busy) begin
            // 同步释放期间保持复位值（与 async_fifo 的 busy 语义一致）
            wptr     <= {(AW+1){1'b0}};
            rptr     <= {(AW+1){1'b0}};
            out_vld  <= 1'b0;
            out_word <= {TW{1'b0}};
        end else begin
            wptr <= wptr_next;
            rptr <= rptr_next;
            if (prefetch) begin
                out_word <= mem[rptr[AW-1:0]];     // 预取最老字（同步读，打一拍）
                out_vld  <= 1'b1;                  // 消费+预取同拍：无缝续流
            end else if (m_fire) begin
                out_vld <= 1'b0;                   // 消费且 mem 空：输出级清空
            end
            // 其他情况保持（tvalid=1 未 ready：out_word 不变 → AXIS 稳定性要求）
        end
    end

    // 写存储（s_fire 与预取读不可能同址：同址即 full，而 full 时 s_fire=0）
    always @(posedge aclk) begin
        if (s_fire && !rst_busy)
            mem[wptr[AW-1:0]] <= w_word;
    end

    // ------------------------------------------------------------------------
    // 输出解包（从 out_word 取各字段；EN=0 的端口恒 0）
    // ------------------------------------------------------------------------
    generate
        if (TLAST_EN && TUSER_EN) begin : up_full
            assign m_axis_tdata  = out_word[DW-1:0];
            assign m_axis_tlast  = out_word[DW];
            assign m_axis_tuser  = out_word[DW+TL_W+TU_W-1 -: TU_W];  // tlast 占 1bit，tuser 在其上
        end else if (TLAST_EN) begin : up_tlast
            assign m_axis_tdata  = out_word[DW-1:0];
            assign m_axis_tlast  = out_word[DW];
            assign m_axis_tuser  = {TUSER_W{1'b0}};
        end else if (TUSER_EN) begin : up_tuser
            assign m_axis_tdata  = out_word[DW-1:0];
            assign m_axis_tlast  = 1'b0;
            assign m_axis_tuser  = out_word[DW+TL_W+TU_W-1 -: TU_W];  // 无 tlast，tuser 紧贴 tdata
        end else begin : up_none
            assign m_axis_tdata  = out_word[DW-1:0];
            assign m_axis_tlast  = 1'b0;
            assign m_axis_tuser  = {TUSER_W{1'b0}};
        end
    endgenerate

endmodule
