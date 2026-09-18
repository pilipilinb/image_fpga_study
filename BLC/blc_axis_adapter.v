// ============================================================================
// 模块：blc_axis_adapter —— BLC 第一级专属的 AXIS → 简流适配（承 CSI-2 RX）
//
// 干什么：把上游 AXIS(RAW10) 的 tdata[11:0]（1 pixel/clock 配置：低 10bit=像素、
//   高 2bit 补零，AXIS 字节对齐）剥成 10bit 简流像素，tuser→sof、tlast→eol、
//   tvalid/tready 握手透传。链路中间级全用简流，只有第一级需要本模块。
//
// 【为什么不解包双像素】实机 CSI-2 RX 的 tdata[23:0] 是 2 pixel/clock 承载总线；
//   项目默认把 IP 配成 1 pixel/clock（README 未来目标契约），每拍只有低位 10bit
//   有效 → 取低位即可，不需要双像素解包（解包留作双路并行的扩展项）。
//
// 【ENTRY_FIFO_EN 入端弹性 FIFO（集成时开，单级仿真默认关）】
//   下游行缓存帧末造行会 in_ready=0 持续 K*W+K 拍，源（CSI-2 RX）虽然能被 tready
//   反压，但链路集成时中间还隔着其他不可反压的段 → 首端放一个弹性 FIFO 兜住。
//   EN=1 时内部例化 fifo/axis_stream_fifo.v（M0.5 手写的 AXIS Data FIFO 对齐版，
//   侧带 tuser/tlast 同拍打包不丢语义），DW=12 把 tdata 原样装进去，出侧再剥位。
//   集成换 IP 时：把本模块的 axis_stream_fifo 换成官方 AXI4-Stream Data FIFO IP
//   即可（接口同名同语义）。
//
// 【简流出侧的稳定性】
//   EN=0（直连）：out_data 组合自 s_axis_tdata。AXIS 规范保证 tvalid=1 且 tready=0
//     时源保持 tdata 稳定 → 简流出侧 "valid 未 ready 时字段稳定" 天然成立。
//   EN=1：axis_stream_fifo 的 FWFT 输出级本身就满足稳定性（M0.5 已验证）。
// ============================================================================
`timescale 1ns/1ps

`ifndef BLC_AXIS_ADAPTER_V_INC
`define BLC_AXIS_ADAPTER_V_INC

`include "axis_stream_fifo.v"      // 依赖 fifo/axis_stream_fifo.v（-I 指向 fifo 目录；自带守卫防重）

module blc_axis_adapter #(
    parameter DW            = 10,     // 像素位宽（RAW10）
    parameter ENTRY_FIFO_EN = 0,      // 1=入端弹性 FIFO（集成时开）
    parameter FIFO_DEPTH    = 512     // 弹性 FIFO 深度（>= K*W+K 词即可吸收造行反压）
)(
    input  wire                aclk,        // 单时钟：1ppc 像素流与内部逻辑同域（跨域由上游 CDC 负责）
    input  wire                aresetn,     // 低有效（AXIS 惯例）
    // ---- AXIS 入（CSI-2 RX，1 pixel/clock）----
    input  wire [11:0]         s_axis_tdata,
    input  wire                s_axis_tvalid,
    output wire                s_axis_tready,
    input  wire                s_axis_tlast,
    input  wire                s_axis_tuser,
    // ---- 简流出（给 blc_core）----
    output wire                out_valid,
    input  wire                out_ready,
    output wire [DW-1:0]       out_data,
    output wire                out_sof,     // = tuser（帧首）
    output wire                out_eol      // = tlast（行末）
);

    generate
    if (ENTRY_FIFO_EN) begin : g_fifo
        // ---- 带入端弹性 FIFO：AXIS 全程，出侧 FWFT 解包 ----
        wire [11:0]  f_tdata;
        wire         f_tvalid, f_tready, f_tlast, f_tuser;
        axis_stream_fifo #(
            .DW(12), .DEPTH(FIFO_DEPTH),
            .TLAST_EN(1), .TUSER_EN(1), .TUSER_W(1)
        ) u_entry_fifo (
            .aclk(aclk), .aresetn(aresetn),
            .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready),
            .s_axis_tlast(s_axis_tlast), .s_axis_tuser(s_axis_tuser),
            .m_axis_tdata(f_tdata), .m_axis_tvalid(f_tvalid), .m_axis_tready(f_tready),
            .m_axis_tlast(f_tlast), .m_axis_tuser(f_tuser)
        );
        assign out_valid = f_tvalid;
        assign f_tready  = out_ready;
        assign out_data  = f_tdata[DW-1:0];   // 剥出像素（RAW10：低 10bit，[11:10] 是补零）
        assign out_sof   = f_tuser;
        assign out_eol   = f_tlast;
    end else begin : g_direct
        // ---- 直连：组合透传（见头部"简流出侧的稳定性"说明）----
        assign s_axis_tready = out_ready;
        assign out_valid     = s_axis_tvalid;
        assign out_data      = s_axis_tdata[DW-1:0];
        assign out_sof       = s_axis_tuser;
        assign out_eol       = s_axis_tlast;
    end
    endgenerate

endmodule

`endif  // BLC_AXIS_ADAPTER_V_INC
