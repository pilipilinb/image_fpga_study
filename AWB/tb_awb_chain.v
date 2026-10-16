// ============================================================================
// tb_awb_chain.v —— AWB 真增益整链实验 TB（住在 AWB/ 下）
//
// 【为什么在 AWB 目录】这是 AWB 的**算法实验**（真增益闭环在 8 级整链里跑，
//   借 FpgaIspChain 的 isp_chain_top 顶层，-I 引入）；链工程只保留集成与自己的回归。
//
// 数据（make_awb_chain_data.py 生成，均在 AWB/）：
//   awb_chain_in_img.hex   偏色传感级 RAW ×4 帧（帧0/1 增益 1.0、帧2/3 收敛增益）
//   awb_chain_exp_img.hex  闭环 golden（expa×2 + expb×2，位级比对）
//   （4 个 .coe 也在本目录：整链 RTL 的 $readmemh 走运行目录）
//
// 行为模型软核（与 tb_awb_loop 同构）：轮询 awb_frame_cnt → fc≥2 读统计快照
//   → 整数除法算增益 → 写写口；硬件帧首拍采样 ⇒ 帧 i 增益 = 帧 i-2 统计（N+2）。
//
// 判据：4 帧逐位比对 + tkeep/tuser/tlast 契约 + 反压稳定 + 收发计数一致
// 落盘：awb_chain_out.txt（供 verify_awb_chain.py 独立复算 + PSNR 报告）
//
// 编译（在 AWB/ 下；★ -I 要指到链目录与全部模块目录）：
//   $inc = "-I . -I ..\FpgaIspChain -I ..\BLC -I ..\Bayer_DPC_Demosaic -I ..\BilateralFilter `
//          -I ..\CCM -I ..\Gamma -I ..\Sharpen -I ..\AxisOut `
//          -I ..\line_buffer\line_buffer_fifo_nxn -I ..\fifo"
//   iverilog -o tb_awb_chain.vvp -DNOVCD $inc.Split(' ') tb_awb_chain.v
//   python ..\CCM\_run_wd.py vvp tb_awb_chain.vvp
// ============================================================================
`timescale 1ns/1ps
`include "isp_chain_top.v"

module tb_awb_chain;

    localparam IMG_W = 112, IMG_H = 103;
    localparam DW     = 10;
    localparam OW     = 8;
    localparam CW_IN  = 12;
    localparam CW_OUT = 3*OW;
    localparam TOTAL  = IMG_W * IMG_H;
    localparam NFRAME = 4;                    // 帧0/1 = 1.0；帧2/3 = 收敛增益
    localparam OFIFO  = 8;                    // 出端弹性 FIFO 深度取小 → 反压压进链内

    // 四通道黑电平（R/Gr/Gb/B），与 make_chain_data.py 一致
    localparam [DW-1:0] OB00 = 100, OB01 = 64, OB10 = 180, OB11 = 32;

    reg  aclk = 0, aresetn = 0;
    always #5 aclk = ~aclk;

    // ---------------- DUT（整链顶层，含 M6 真 AWB）----------------
    reg  [CW_IN-1:0]  s_tdata;
    reg               s_tlast, s_tuser;
    wire              s_tvalid;               // 源模型 assign
    wire              s_tready;
    wire              m_tready;               // 汇模型 assign
    wire [CW_OUT-1:0] m_tdata;
    wire [2:0]        m_tkeep;
    wire              m_tvalid, m_tlast, m_tuser;
    reg               bp_denoise = 0, bp_ccm = 0, bp_gamma = 0, bp_sharpen = 0;
    reg  [9:0]        sho_k = 128;            // k = 0.5
    reg  [9:0]        awbg_00 = 256, awbg_01 = 256, awbg_10 = 256, awbg_11 = 256;
    wire [31:0]       st00, st01, st10, st11; // AWB 统计快照组
    wire [31:0]       awb_fc;                 // 快照组帧号
    wire              awb_irq_w;

    isp_chain_top #(
        .DW(DW), .OW(OW), .IMG_W(IMG_W), .IMG_H(IMG_H),
        .N_DPC(5), .N_RGB(3), .THR(128), .DEMOSAIC_SEL(0), .FRAC(12),
        .KW(10), .K_FRAC(8), .AWB_GW(10), .AWB_GF(8),
        .ENTRY_FIFO_EN(0), .OUT_FIFO_DEPTH(OFIFO)
    ) dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
        .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
        .ob_00(OB00), .ob_01(OB01), .ob_10(OB10), .ob_11(OB11),
        .awb_gain_00(awbg_00), .awb_gain_01(awbg_01), .awb_gain_10(awbg_10), .awb_gain_11(awbg_11),
        .bp_denoise(bp_denoise), .bp_ccm(bp_ccm), .bp_gamma(bp_gamma), .bp_sharpen(bp_sharpen),
        .sharpen_k(sho_k),
        .awb_stat_00(st00), .awb_stat_01(st01), .awb_stat_10(st10), .awb_stat_11(st11),
        .awb_frame_cnt(awb_fc), .awb_irq(awb_irq_w),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready), .m_axis_tlast(m_tlast), .m_axis_tuser(m_tuser)
    );

    // ---------------- 数据加载 ----------------
    reg [DW-1:0]     src [0:NFRAME*TOTAL-1];
    reg [CW_OUT-1:0] exp [0:NFRAME*TOTAL-1];
    integer gi;
    initial begin
        $readmemh("awb_chain_in_img.hex", src);
        $readmemh("awb_chain_exp_img.hex", exp);
        for (gi = 0; gi < NFRAME*TOTAL; gi = gi + 1) begin
            if (src[gi] === {DW{1'bx}})     src[gi] = {DW{1'b0}};
            if (exp[gi] === {CW_OUT{1'bx}}) exp[gi] = {CW_OUT{1'b0}};
        end
    end

    // ---------------- 行为模型软核（轮询 fc → 读 stat → 算增益 → 写写口）----------------
    localparam CNT = TOTAL / 4;               // 2884（W·H/4 均匀口径）
    integer fc_seen = 0;
    integer m00i, m01i, m10i, m11i, mgi, ti;
    integer g00i, g01i, g10i, g11i;
    always @(posedge aclk) begin
        if (!aresetn) begin
            fc_seen = 0;
            awbg_00 <= 10'd256; awbg_01 <= 10'd256; awbg_10 <= 10'd256; awbg_11 <= 10'd256;
        end else if (awb_fc != fc_seen) begin
            fc_seen = awb_fc;
            if (awb_fc >= 2) begin
                m00i = st00 / CNT;
                m01i = st01 / CNT;
                m10i = st10 / CNT;
                m11i = st11 / CNT;
                mgi  = (m01i + m10i) >> 1;
                ti = (mgi << 8) / ((m00i > 0) ? m00i : 1);
                if (ti < 128) ti = 128; if (ti > 1023) ti = 1023; g00i = ti;
                ti = (mgi << 8) / ((m01i > 0) ? m01i : 1);
                if (ti < 128) ti = 128; if (ti > 1023) ti = 1023; g01i = ti;
                ti = (mgi << 8) / ((m10i > 0) ? m10i : 1);
                if (ti < 128) ti = 128; if (ti > 1023) ti = 1023; g10i = ti;
                ti = (mgi << 8) / ((m11i > 0) ? m11i : 1);
                if (ti < 128) ti = 128; if (ti > 1023) ti = 1023; g11i = ti;
                awbg_00 <= g00i[9:0]; awbg_01 <= g01i[9:0];
                awbg_10 <= g10i[9:0]; awbg_11 <= g11i[9:0];
                $display("SOFT-AWB fc=%0d stat=(%0d,%0d,%0d,%0d) gain=(%0d,%0d,%0d,%0d)",
                         awb_fc, st00, st01, st10, st11, g00i, g01i, g10i, g11i);
            end
        end
    end

    // ---------------- 源模型（AXIS Master：tdata[11:0] 低 10bit 有效）----------------
    integer ngen = 0;
    integer snd_limit = NFRAME*TOTAL;
    reg     src_vld = 0;
    reg     start = 0;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) src_vld <= 1'b0;
        else begin
            if (!src_vld) begin
                if (start && ngen < snd_limit) begin
                    s_tdata <= {2'b00, src[ngen]};
                    s_tuser <= (ngen % TOTAL == 0);
                    s_tlast <= ((ngen % IMG_W) == IMG_W - 1);
                    src_vld <= 1'b1;
                    ngen    <= ngen + 1;
                end
            end else if (s_tready) begin
                if (ngen < snd_limit) begin
                    s_tdata <= {2'b00, src[ngen]};
                    s_tuser <= (ngen % TOTAL == 0);
                    s_tlast <= ((ngen % IMG_W) == IMG_W - 1);
                    ngen    <= ngen + 1;
                end else src_vld <= 1'b0;    // 到限额真正撤 valid（排空语义）
            end
        end
    end
    assign s_tvalid = src_vld;

    // ---------------- 汇模型（恒 ready）----------------
    reg rdy_r = 0;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) rdy_r <= 0;
        else rdy_r <= 1'b1;
    end
    assign m_tready = rdy_r;

    // ---------------- 记分板 ----------------
    integer snd_cnt = 0, rcv_cnt = 0, err_cnt = 0;
    reg [CW_OUT-1:0] out_q;
    reg [2:0]        keep_q;
    reg              vl_q = 0, rdy_q = 0, usr_q = 0, lst_q = 0;
    integer fd;
    initial fd = $fopen("awb_chain_out.txt", "w");

    always @(posedge aclk) begin
        #1;
        if (aresetn && start && s_tvalid && s_tready) snd_cnt = snd_cnt + 1;
        if (m_tvalid && m_tready && start) begin
            $fwrite(fd, "%06X\n", m_tdata);
            if (m_tdata !== exp[rcv_cnt % (NFRAME*TOTAL)]) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8)
                    $display("MISMATCH @%0t #%0d: got=%06X exp=%06X",
                             $time, rcv_cnt, m_tdata, exp[rcv_cnt % (NFRAME*TOTAL)]);
            end
            if (m_tkeep !== 3'b111) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8) $display("TKEEP-ERR @%0t #%0d", $time, rcv_cnt);
            end
            if (m_tuser !== (rcv_cnt % TOTAL == 0)) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8) $display("TUSER-MISMATCH @%0t #%0d", $time, rcv_cnt);
            end
            if (m_tlast !== (((rcv_cnt + 1) % IMG_W) == 0)) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8) $display("TLAST-MISMATCH @%0t #%0d", $time, rcv_cnt);
            end
            rcv_cnt = rcv_cnt + 1;
        end
        // AXIS 稳定性：valid 未 ready 时字段必须保持（★ 用上一拍 ready）
        if (vl_q && !rdy_q && m_tvalid &&
            (m_tdata !== out_q || m_tkeep !== keep_q || m_tuser !== usr_q || m_tlast !== lst_q)) begin
            err_cnt = err_cnt + 1;
            if (err_cnt <= 8) $display("STABILITY-VIOLATION @%0t", $time);
        end
        vl_q = m_tvalid; rdy_q = m_tready; out_q = m_tdata; keep_q = m_tkeep;
        usr_q = m_tuser; lst_q = m_tlast;
    end

    // ---------------- 场景流程 ----------------
    initial begin
`ifndef NOVCD
        $dumpfile("tb_awb_chain.vcd");
        $dumpvars(0, tb_awb_chain);
`endif
        aresetn = 0;
        repeat (10) @(posedge aclk);
        aresetn = 1;
        repeat (10) @(posedge aclk);

        $display("=== AWB 整链闭环：偏色 RAW 4 帧（帧0/1 增益 1.0，帧2/3 收敛增益）===");
        start = 1; snd_limit = NFRAME*TOTAL;
        while (rcv_cnt < NFRAME*TOTAL) @(posedge aclk);
        start = 0;
        repeat (80) @(posedge aclk);
        $fclose(fd);
        $display("========================================");
        if (snd_cnt != NFRAME*TOTAL || rcv_cnt != NFRAME*TOTAL) err_cnt = err_cnt + 1;
        $display("入侧 fire %0d 出侧收 %0d", snd_cnt, rcv_cnt);
        if (err_cnt == 0)
            $display("[PASS] awb_chain：4 帧位级全等（帧0/1 基线 + 帧2/3 收敛）+ S2MM 契约 + 反压稳定");
        else
            $display("[FAIL] awb_chain err=%0d", err_cnt);
        $finish;
    end

    // ---------------- 超时兜底 ----------------
    initial begin
        #(NFRAME * TOTAL * 6000 + 20000000);
        $display("[FAIL] timeout snd=%0d rcv=%0d err=%0d", snd_cnt, rcv_cnt, err_cnt);
        $finish;
    end

endmodule