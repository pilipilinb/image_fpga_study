// ============================================================================
// axis_out_adapter.v —— 出端适配器：简流(RGB888) → AXIS(RGB888 → VDMA S2MM)
//
// 干什么（M5 交付的"出端适配 + 出端弹性 FIFO"，架构图上写作 [出端适配+出端FIFO]）：
//   ① 协议转换：本项目内部各级用"简流"（in_valid/in_ready/in_data/in_sof/in_eol），
//      而 VDMA S2MM / AXI4-Stream 汇要求标准 AXIS 四件套：
//        in_data → m_axis_tdata[23:0]
//        in_sof  → m_axis_tuser        （帧首 = SOF，1 拍）
//        in_eol  → m_axis_tlast        （行末 = EOL，1 拍）
//        in_valid/in_ready → tvalid/tready
//   ② tkeep 生成：RGB888 每拍都是 3 个"满"字节 ⇒ **tkeep ≡ 3'b111**（常数，无逻辑）
//   ③ 弹性 FIFO（复用 M0.5 的 axis_stream_fifo）：做速率匹配 + 反压缓冲，
//      VDMA 侧 tready 拉低时把反压平滑回传到链路（"反压通路"的末端一级）。
//
// 【S2MM 侧契约（M5 验收逐条）】
//   · 每帧首拍 tuser=1，其余拍 tuser=0
//   · 每行末拍 tlast=1，其余拍 tlast=0
//   · tkeep=3'b111 恒成立（24bit = 3 字节）
//   · 每帧像素数 = H×W（对应 VDMA 的 HSIZE/VSIZE 与分辨率一致）
//   · AXIS 稳定性：tvalid=1 且 tready=0 时 tdata/tkeep/tuser/tlast 保持
//   · 复位期 tvalid=0
//
// 【与入端（BLC 的 blc_axis_adapter）对称】
//   入端：AXIS(RAW10) → 简流；出端：简流 → AXIS(RGB888)。两端都用 axis_stream_fifo
//   承担弹性。**CDC（像素时钟 vs 系统时钟）留集成阶段**（本工程假设 2）：单级仿真用
//   同频；上板时把 axis_stream_fifo 换成"AXIS Data FIFO IP + 独立时钟"即得到异步弹性。
//
// 【为什么"转换本身"这么薄】
//   简流与 AXIS 的差别只在字段命名与 sideband：数据宽度一致、握手语义一致（valid/ready
//   同拍消费）。真正需要硬件的是**弹性缓冲**，这正是 FIFO 存在的理由——把两件事放同一个
//   模块是为了在架构图里对应"出端适配+出端FIFO"这一个方块，集成时 FIFO 整体换 IP、
//   转换逻辑零改动。
// ============================================================================
`timescale 1ns/1ps

`ifndef AXIS_OUT_ADAPTER_V_INC
`define AXIS_OUT_ADAPTER_V_INC
`include "axis_stream_fifo.v"

module axis_out_adapter #(
    parameter DW      = 24,      // 数据位宽（RGB888 打包，与 Gamma/锐化出口一致）
    parameter DEPTH   = 512,     // 弹性 FIFO 深度（2 的幂）；实机可取 1024/2048
    parameter KEEP_W  = DW/8     // tkeep 位宽 = 字节数（24bit → 3）
)(
    input  wire            clk,
    input  wire            rst_n,          // 低有效（与链路内部一致；FIFO 内部转 aresetn）
    // ---- 简流入（锐化出，RGB888）----
    input  wire [DW-1:0]   in_data,
    input  wire            in_valid,
    output wire            in_ready,
    input  wire            in_sof,         // 帧首 → tuser
    input  wire            in_eol,         // 行末 → tlast
    // ---- AXIS Master 出（→ VDMA S2MM）----
    output wire [DW-1:0]   m_axis_tdata,
    output wire [KEEP_W-1:0] m_axis_tkeep,
    output wire            m_axis_tvalid,
    input  wire            m_axis_tready,
    output wire            m_axis_tlast,
    output wire            m_axis_tuser
);

    // ---- 弹性 FIFO（FWFT + sideband；容量 = DEPTH+1）----
    axis_stream_fifo #(
        .DW(DW), .DEPTH(DEPTH), .TLAST_EN(1), .TUSER_EN(1), .TUSER_W(1)
    ) u_fifo (
        .aclk(clk), .aresetn(rst_n),
        .s_axis_tdata(in_data),
        .s_axis_tvalid(in_valid),
        .s_axis_tready(in_ready),
        .s_axis_tlast(in_eol),
        .s_axis_tuser(in_sof),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast),
        .m_axis_tuser(m_axis_tuser)
    );

    // ---- tkeep：RGB888 = 3 个满字节 ⇒ 恒 111（无逻辑，纯接线）----
    assign m_axis_tkeep = {KEEP_W{1'b1}};

endmodule

`endif  // AXIS_OUT_ADAPTER_V_INC
