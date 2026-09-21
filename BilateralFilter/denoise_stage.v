// ============================================================================
// denoise_stage.v —— 双边降噪级：简流(线性 RGB 3×10bit) → 3×3 窗口 → 双边核 → 简流
//
// 与 dpc_stage/demosaic_stage 同构（行缓存/反压/对齐框架一致），差异：
//   ① 行缓存 DW=30（{r,g,b} 打包为一个"像素"进行缓存，N=3 → 窗口 270bit）
//   ② 核 LAT=3（LUT 异步读吸收了一级）→ bypass 链与 sof/eol 对齐链均打 3 拍
//   ③ **bypass 等延迟旁路（M4 三模块统一接口）**：bypass=1 时 in_data 直通 out_data，
//     处理路径照跑（行缓存/核保持状态一致性），出口 mux 选边——等延迟是命门，
//     不等则 bypass 切换时 sof/eol 与数据错位。场景：半导体检测关降噪、
//     检测后单独走显示通路（算法边界的产品化表达）
// ============================================================================
`timescale 1ns/1ps

`ifndef DENOISE_STAGE_V_INC
`define DENOISE_STAGE_V_INC
`include "denoise_bilateral_core.v"
`include "axis_stream_fifo.v"
`include "line_buffer_fifo_nxn.v"

module denoise_stage #(
    parameter DW    = 10,      // 单通道位宽（线性 RGB 域）
    parameter IMG_W = 640,
    parameter IMG_H = 480,
    parameter N     = 3
)(
    input  wire            clk,
    input  wire            rst_n,
    input  wire            bypass,     // 1 = 旁路本模块算法（等延迟直通；帧级配置，sof 边界切换）
    // ---- 入侧简流（Demosaic 出，线性 RGB 3×10bit）----
    input  wire            in_valid,
    output wire            in_ready,
    input  wire [3*DW-1:0] in_data,
    input  wire            in_sof,
    input  wire            in_eol,
    // ---- 出侧简流（线性 RGB 3×10bit）----
    output wire            out_valid,
    input  wire            out_ready,
    output wire [3*DW-1:0] out_data,
    output wire            out_sof,
    output wire            out_eol
);

    localparam CW = 3*DW;      // 打包位宽 30bit

    // ---- 行缓存（pad 全尺寸 + 反压）----
    wire             lb_valid, lb_sof, lb_eol, lb_ready;
    wire             lb_inready;               // 行缓存的接纳节拍（造行期=0，★必须用这个门控源）
    wire [N*N*CW-1:0] lb_win;

    line_buffer_fifo_nxn #(
        .DW(CW), .IMG_W(IMG_W), .IMG_H(IMG_H), .N(N)
    ) u_lb (
        .clk(clk), .rst_n(rst_n),
        // ★ bypass 期行缓存整体冻结（in_valid=0）：其内部 FIFO 占用恒 = IMG_W 的
        //   不变式被完整保留，切回处理路径时帧首 sof 重同步即可继续（切换只在
        //   排空点发生）。若不冻结，bypass 期行缓存会丢掉未握手数据 → 占用下降 →
        //   行延迟变短 → 切回后窗口全错。
        .in_valid(in_valid && !bypass),
        // in_ready 输出接独立 wire（造行期=0）：不能与 stage 的 in_ready 同 wire
        // （双驱动冲突成 X），也不能丢弃（处理路径必须尊重造行反压）
        .in_ready(lb_inready),
        .in_data(in_data), .in_sof(in_sof), .in_eol(in_eol),
        .out_valid(lb_valid), .out_ready(lb_ready),
        .out_win_flat(lb_win), .out_sof(lb_sof), .out_eol(lb_eol)
    );

    // ---- 反压：按"当前实际输出"判定（bypass 切换时源不同）----
    wire        core_dv;
    wire [CW-1:0] core_dt;
    wire        byp_vld;                       // bypass 延迟链末级 valid
    wire        ostall;
    assign lb_ready = !ostall;

    // ---- 双边核（LAT=3；run_en=反压门控全局冻结）----
    denoise_bilateral_core #(.DW(DW)) u_core (
        .clk(clk), .rst_n(rst_n),
        .win_flat(lb_win),
        .win_valid(lb_valid),
        .run_en(!ostall),
        .dout(core_dt),
        .dout_valid(core_dv)
    );

    // ---- bypass 延迟线 = axis_stream_fifo（M0.5 现成件：FWFT + 侧带 + 反压）----
    // 【为什么不用手写 3 级寄存链（TB 场景 E 实锤的两个坑）】
    //   ① 链的"接纳节拍"与"前进节拍"是两个独立节拍：接纳 = fire（in_valid&&in_ready，
    //     与行缓存同拍消费）；前进 = 出口允许。造行期 in_ready=0（行缓存不收新数）
    //     但链内已有的数据必须继续流出到出口——单一使能无法同时表达，会出现
    //     "恒定值重复输出"或"卡死"。
    //   ② 排空点切换方案下 bypass 路径只需保序不需与核等延迟 → 延迟可变的 FWFT
    //     FIFO 完全够用，且 sof/eol 侧带/反压全是现成协议件。
    //   写节拍：bypass=1 时与行缓存同拍消费同一 in_data（数据分叉两路）；
    //   bypass=0 时不写（切换前已排空，FIFO 保持空）。
    wire        byp_ready, byp_v, byp_sof, byp_eol;
    wire [CW-1:0] byp_dt;
    axis_stream_fifo #(
        .DW(CW), .DEPTH(4), .TLAST_EN(1), .TUSER_EN(1), .TUSER_W(1)
    ) u_byp (
        .aclk(clk), .aresetn(rst_n),
        .s_axis_tdata(in_data),
        // 写节拍 = 输入握手（bypass 模式下 in_ready 只由 byp_ready 决定，见下）
        .s_axis_tvalid(in_valid && bypass),
        .s_axis_tready(byp_ready),
        .s_axis_tlast(in_eol),
        .s_axis_tuser(in_sof),
        .m_axis_tdata(byp_dt),
        .m_axis_tvalid(byp_v),
        .m_axis_tready(out_ready),
        .m_axis_tlast(byp_eol),
        .m_axis_tuser(byp_sof)
    );

    // 入侧接纳（两条路径完全解耦，各自只对自己负责）：
    //   bypass=1 → 只需 bypass FIFO 接得住（行缓存已冻结，不参与）
    //   bypass=0 → 只需行缓存接得住（造行期 lb_inready=0 → 反压上传）
    assign in_ready = bypass ? byp_ready : lb_inready;

    assign ostall = (bypass ? byp_v : core_dv) && !out_ready;

    // ---- sof/eol 对齐：处理路径打 3 拍（与核 LAT 对齐；bypass 路径已在延迟链里）----
    reg sof_c0, sof_c1, sof_c2, eol_c0, eol_c1, eol_c2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            {sof_c0, sof_c1, sof_c2} <= 0;
            {eol_c0, eol_c1, eol_c2} <= 0;
        end else if (!ostall) begin
            sof_c0 <= lb_sof;  sof_c1 <= sof_c0;  sof_c2 <= sof_c1;
            eol_c0 <= lb_eol;  eol_c1 <= eol_c0;  eol_c2 <= eol_c1;
        end
    end

    // ---- bypass 链的 sof/eol 由 axis_stream_fifo 侧带透传（m_axis_tuser/tlast）----

    // ---- 出口 mux（排空点切换后选边）----
    assign out_valid = bypass ? byp_v   : core_dv;
    assign out_data  = bypass ? byp_dt  : core_dt;
    assign out_sof   = bypass ? byp_sof : sof_c2;
    assign out_eol   = bypass ? byp_eol : eol_c2;

endmodule

`endif  // DENOISE_STAGE_V_INC
