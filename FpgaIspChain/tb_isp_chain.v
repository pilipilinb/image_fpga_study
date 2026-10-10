//========================================================================
// tb_isp_chain.v —— M5.3 八级 ISP 整链自检 TB（AXIS(RAW10) 进 / AXIS(RGB888) 出）
//
// 编译（TB 头部 `include 顶层，只编译 TB）：
//   small: iverilog -o tb_isp_chain.vvp -DNOVCD -I . -I ..\BLC -I ..\Bayer_DPC_Demosaic \
//          -I ..\BilateralFilter -I ..\CCM -I ..\Gamma -I ..\Sharpen -I ..\AxisOut \
//          -I ..\line_buffer\line_buffer_fifo_nxn -I ..\fifo tb_isp_chain.v
//   img  : 同上去掉 -DNOVCD、加 -DIMG
//   跑：vvp tb_isp_chain.vvp（★ 一律在看门狗下跑）→ verify_isp_chain.py
//
// 期望由 make_chain_data.py 预生成：chain_in_small/img.hex（RAW10）
//                                   exp_small/img.hex（末端 RGB888 24bit）
//
// 场景（small）：A 满速 2 帧 / B 汇随机 50% / C 汇长拉低 40~240 拍（都做期望比对）
//   ★ 链里有 **4 个含行缓存的级**（DPC/Demosaic/降噪/锐化），每帧末各有造行期
//     （in_ready=0 若干拍），所以"收够 2 帧"必须靠 rcv_cnt 判据等待，不能按拍数估。
//   ★ 出端弹性 FIFO 深度取小（OFIFO=8）——把反压真正压到 8 级内部，
//     才能验证"整链反压冻结链 + 位级不变"。
//
// 检查项：
//   ① 末端逐位比对（期望文件）     ② tkeep≡3'b111    ③ tuser=帧首 / tlast=行末
//   ④ AXIS 稳定性（tvalid=1 且 tready=0 时 tdata/tkeep/tuser/tlast 保持）
//   ⑤ 入侧 fire 数 == 出侧收数 == 期望帧数像素数
//   IMG 模式：额外把 s1..s7 逐级输出落盘（供 verify 做逐级插桩 + 定位）
//========================================================================
`timescale 1ns/1ps
`include "isp_chain_top.v"

`ifdef IMG
`define SINGLE_FRAME
`endif

module tb_isp_chain;

`ifdef IMG
    localparam IMG_W = 112, IMG_H = 103;
`else
    localparam IMG_W = 16,  IMG_H = 12;
`endif
    localparam DW     = 10;
    localparam OW     = 8;
    localparam CW_IN  = 12;
    localparam CW_OUT = 3*OW;
    localparam TOTAL  = IMG_W * IMG_H;
    localparam OFIFO  = 8;                    // 出端弹性 FIFO 深度（小 → 反压压进链内）
`ifdef SINGLE_FRAME
    localparam NFRAME = 1;
`else
    localparam NFRAME = 6;                    // 3 个场景 × 2 帧
`endif

    // 四通道黑电平（R/Gr/Gb/B），与 make_chain_data.py 一致
    localparam [DW-1:0] OB00 = 100, OB01 = 64, OB10 = 180, OB11 = 32;
    localparam [9:0]    GAIN1 = 256;          // AWB 增益 1.0（Q2.8）

    reg  aclk = 0, aresetn = 0;
    always #5 aclk = ~aclk;

    // ---------------- DUT（含两端 AXIS 适配）----------------
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
    wire [31:0]       st00, st01, st10, st11; // AWB 统计占位

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
        .awb_gain_00(GAIN1), .awb_gain_01(GAIN1), .awb_gain_10(GAIN1), .awb_gain_11(GAIN1),
        .bp_denoise(bp_denoise), .bp_ccm(bp_ccm), .bp_gamma(bp_gamma), .bp_sharpen(bp_sharpen),
        .sharpen_k(sho_k),
        .awb_stat_00(st00), .awb_stat_01(st01), .awb_stat_10(st10), .awb_stat_11(st11),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready), .m_axis_tlast(m_tlast), .m_axis_tuser(m_tuser)
    );

    // ---------------- 数据加载 ----------------
    reg [DW-1:0]     src [0:NFRAME*TOTAL-1];
    reg [CW_OUT-1:0] exp [0:NFRAME*TOTAL-1];
    integer gi;
    initial begin
`ifdef IMG
        $readmemh("chain_in_img.hex", src);
        $readmemh("exp_img.hex", exp);
`else
        $readmemh("chain_in_small.hex", src);
        $readmemh("exp_small.hex", exp);
`endif
        for (gi = 0; gi < NFRAME*TOTAL; gi = gi + 1) begin
            if (src[gi] === {DW{1'bx}})     src[gi] = {DW{1'b0}};
            if (exp[gi] === {CW_OUT{1'bx}}) exp[gi] = {CW_OUT{1'b0}};
        end
    end

    // ---------------- 源模型（AXIS Master：tdata[11:0] 低 10bit 有效）----------------
    integer imode = 0;              // 0=连续 1=随机70%
    integer ngen = 0;
    integer snd_limit = 960;
    reg     src_vld = 0;
    reg     start = 0;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) src_vld <= 1'b0;
        else begin
            if (!src_vld) begin
                if (start && ngen < snd_limit &&
                    (imode == 0 || (({$random} % 1000) < 700))) begin
                    s_tdata <= {2'b00, src[ngen % (NFRAME*TOTAL)]};
                    s_tuser <= (ngen % TOTAL == 0);
                    s_tlast <= ((ngen % IMG_W) == IMG_W - 1);
                    src_vld <= 1'b1;
                    ngen    <= ngen + 1;
                end
            end else if (s_tready) begin
                if (ngen < snd_limit) begin
                    s_tdata <= {2'b00, src[ngen % (NFRAME*TOTAL)]};
                    s_tuser <= (ngen % TOTAL == 0);
                    s_tlast <= ((ngen % IMG_W) == IMG_W - 1);
                    ngen    <= ngen + 1;
                end else src_vld <= 1'b0;
            end
        end
    end
    assign s_tvalid = src_vld;

    // ---------------- 汇模型（AXIS Slave：tready 模式）----------------
    integer omode = 0;              // 0=恒 ready 1=随机50% 2=长拉低
    reg  rdy_r = 0;
    integer drop_cnt = 0;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin rdy_r <= 0; drop_cnt <= 0; end
        else if (omode == 0) rdy_r <= 1'b1;
        else if (omode == 1) rdy_r <= (({$random} % 1000) < 500);
        else begin
            if (drop_cnt > 0) begin drop_cnt <= drop_cnt - 1; rdy_r <= 0; end
            else if (({$random} % 1000) < 20) begin
                drop_cnt <= 40 + ({$random} % 200); rdy_r <= 0;
            end else rdy_r <= 1'b1;
        end
    end
    assign m_tready = rdy_r;

    // ---------------- 记分板 ----------------
    integer snd_cnt = 0, rcv_cnt = 0, err_cnt = 0, dbg_n = 0;
    reg [CW_OUT-1:0] out_q;
    reg [2:0]        keep_q;
    reg              vl_q = 0, rdy_q = 0, usr_q = 0, lst_q = 0;
    integer fd;
    initial begin
`ifdef IMG
        fd = $fopen("isp_out_img.txt", "w");
`else
        fd = $fopen("isp_out_small.txt", "w");
`endif
    end

    always @(posedge aclk) begin
        #1;
        // 入侧 fire 计数
        if (aresetn && start && s_tvalid && s_tready) begin
            snd_cnt = snd_cnt + 1;
            if (dbg_n < 8) begin
                $display("DBG-SND t=%0t n=%0d data=%03X tuser=%b tlast=%b",
                         $time, snd_cnt-1, s_tdata[9:0], s_tuser, s_tlast);
                dbg_n = dbg_n + 1;
            end
        end
        // 出侧逐位比对 + 语义检查
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
                if (err_cnt <= 8) $display("TKEEP-ERR @%0t #%0d keep=%b", $time, rcv_cnt, m_tkeep);
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
        // AXIS 稳定性：valid 未 ready 时字段必须保持
        if (vl_q && !rdy_q && m_tvalid &&
            (m_tdata !== out_q || m_tkeep !== keep_q || m_tuser !== usr_q || m_tlast !== lst_q)) begin
            err_cnt = err_cnt + 1;
            if (err_cnt <= 8) $display("STABILITY-VIOLATION @%0t", $time);
        end
        vl_q = m_tvalid; rdy_q = m_tready; out_q = m_tdata; keep_q = m_tkeep;
        usr_q = m_tuser; lst_q = m_tlast;
    end

    // ---------------- ★ 逐级插桩（IMG 模式：s1..s7 落盘，供 verify 逐级比对/定位）----------------
`ifdef IMG
    integer fd1, fd2, fd3, fd4, fd5, fd6, fd7;
    initial begin
        fd1 = $fopen("isp_s1_img.txt", "w");
        fd2 = $fopen("isp_s2_img.txt", "w");
        fd3 = $fopen("isp_s3_img.txt", "w");
        fd4 = $fopen("isp_s4_img.txt", "w");
        fd5 = $fopen("isp_s5_img.txt", "w");
        fd6 = $fopen("isp_s6_img.txt", "w");
        fd7 = $fopen("isp_s7_img.txt", "w");
    end
    always @(posedge aclk) begin
        #1;
        if (dut.s1_v && dut.s1_rdy) $fwrite(fd1, "%03X\n", dut.s1_d);
        if (dut.s2_v && dut.s2_rdy) $fwrite(fd2, "%03X\n", dut.s2_d);
        if (dut.s3_v && dut.s3_rdy) $fwrite(fd3, "%03X\n", dut.s3_d);
        if (dut.s4_v && dut.s4_rdy) $fwrite(fd4, "%08X\n", dut.s4_d);
        if (dut.s5_v && dut.s5_rdy) $fwrite(fd5, "%08X\n", dut.s5_d);
        if (dut.s6_v && dut.s6_rdy) $fwrite(fd6, "%08X\n", dut.s6_d);
        if (dut.s7_v && dut.s7_rdy) $fwrite(fd7, "%06X\n", dut.s7_d);
    end
`endif

    // ---------------- ★ stall 测量（M5.3：级间到底要不要弹性 FIFO、插多深）----------------
    // 节点 0=整链入口(s_axis)；1..8=各级输出。测"该节点 valid 且未 ready"的连续拍数
    // （= 该节点被下游压住的最长时长）。同相/错相看各节点 stall 段是否重合。
    wire [8:0] vb = {dut.s8_v, dut.s7_v, dut.s6_v, dut.s5_v, dut.s4_v, dut.s3_v, dut.s2_v, dut.s1_v, s_tvalid};
    wire [8:0] rb = {dut.s8_rdy, dut.s7_rdy, dut.s6_rdy, dut.s5_rdy, dut.s4_rdy, dut.s3_rdy, dut.s2_rdy, dut.s1_rdy, s_tready};
    integer mst [0:8], run [0:8], epi [0:8], tot [0:8];
    integer kk;
    initial for (kk = 0; kk < 9; kk = kk + 1) begin
        mst[kk] = 0; run[kk] = 0; epi[kk] = 0; tot[kk] = 0;
    end
    always @(posedge aclk) begin
        #1;
        for (kk = 0; kk < 9; kk = kk + 1) begin
            if (aresetn && start && vb[kk] && !rb[kk]) begin
                run[kk] = run[kk] + 1;
                if (run[kk] > mst[kk]) mst[kk] = run[kk];
                if (run[kk] == 1)     epi[kk] = epi[kk] + 1;
                tot[kk] = tot[kk] + 1;
            end else if (!start) run[kk] = 0;
        end
    end

    task st_print;
        integer j;
        begin
            $display("  节点 0=入口, 1..8=各级 : max连续 段数 总stall拍");
            for (j = 0; j < 9; j = j + 1)
                $display("      node%0d : max=%6d  seg=%4d  tot=%7d", j, mst[j], epi[j], tot[j]);
        end
    endtask

    // ---------------- 场景流程 ----------------
    initial begin
        aresetn = 0;
        repeat (10) @(posedge aclk);
        aresetn = 1;
        repeat (10) @(posedge aclk);

`ifdef IMG
        // 真图尺寸下连发 4 帧（同一帧循环），锚定"真实宽度下造行期有多长"：
        //   单帧只会在收完所有输入后才造行（源已发完 → 看不到 stall），
        //   必须多帧连续才能让"上一帧造行期"与"下一帧数据"重叠出真实反压。
        $display("=== IMG 模式（8 级整链，%0d×%0d，连发 4 帧）===", IMG_W, IMG_H);
        imode = 0; omode = 0; start = 1; snd_limit = 4*TOTAL;
        while (rcv_cnt < 4*TOTAL) @(posedge aclk);
        start = 0;
        repeat (80) @(posedge aclk);
        $display("--- stall 测量[IMG 4帧 · 出端恒 ready] ---");
        st_print;
`else
        $display("=== 场景A：满速 2 帧 ===");
        imode = 0; omode = 0; start = 1; snd_limit = 2*TOTAL;
        while (rcv_cnt < 2*TOTAL) @(posedge aclk);
        start = 0;
        repeat (50) @(posedge aclk);
        $display("--- stall 测量[场景A 满速 · 出端恒 ready] ---");
        st_print;

        $display("=== 场景B：汇随机 50%%，2 帧 ===");
        imode = 0; omode = 1; start = 1; snd_limit = 4*TOTAL;
        while (rcv_cnt < 4*TOTAL) @(posedge aclk);
        start = 0;
        repeat (50) @(posedge aclk);
        $display("--- stall 测量[场景B 汇随机50%%] ---");
        st_print;

        $display("=== 场景C：汇长拉低（40~240 拍），2 帧 ===");
        imode = 0; omode = 2; start = 1; snd_limit = 6*TOTAL;
        while (rcv_cnt < 6*TOTAL) @(posedge aclk);
        start = 0;
        $display("--- stall 测量[场景C 汇长拉低 40~240] ---");
        st_print;
`endif

        repeat (80) @(posedge aclk);
        $fclose(fd);
`ifdef IMG
        $fclose(fd1); $fclose(fd2); $fclose(fd3); $fclose(fd4);
        $fclose(fd5); $fclose(fd6); $fclose(fd7);
`endif
        $display("========================================");
`ifdef IMG
        if (snd_cnt != 4*TOTAL || rcv_cnt != 4*TOTAL) err_cnt = err_cnt + 1;
`else
        if (snd_cnt != 6*TOTAL || rcv_cnt != 6*TOTAL) err_cnt = err_cnt + 1;
`endif
        $display("入侧 fire %0d 出侧收 %0d", snd_cnt, rcv_cnt);
        if (err_cnt == 0)
            $display("[PASS] isp_chain：末端逐位全等（0 误差）+ tkeep/tuser/tlast 契约 + 反压稳定");
        else
            $display("[FAIL] isp_chain err=%0d", err_cnt);
        $finish;
    end

    // ---------------- 超时兜底 ----------------
    initial begin
        #(NFRAME * TOTAL * 6000 + 20000000);
        $display("[FAIL] timeout snd=%0d rcv=%0d err=%0d", snd_cnt, rcv_cnt, err_cnt);
        $finish;
    end

endmodule
