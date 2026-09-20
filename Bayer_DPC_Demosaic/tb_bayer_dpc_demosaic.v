//========================================================================
// tb_bayer_dpc_demosaic.v —— M3 DPC→Demosaic 链自检 TB
//
// 期望值由 make_dpc_demosaic_data.py 预生成（Python 独立第二判据），TB 读入逐拍比对。
//
// 模式（编译宏）：
//   默认      ：协议场景，16×12×5 帧，像素 (n*131+7)&1023（跨帧连续），期望 exp_rgb_small_*.hex
//   -DIMG     ：图像链，112×103，输入 blc_dpc_in.hex（真图 BLC 后+坏点），期望 exp_rgb_img_*.hex
//   -DMHC     ：Demosaic 用 MHC 核（默认双线性），期望用 *_mhc.hex
//
// 场景（协议模式）：A 满速 2 帧 / B 汇随机 ready 50% / C 长拉低 / D 双向随机。
// 断言：出侧稳定性（valid 未 ready 时 data/sof/eol/phase 保持）、复位期 out_valid=0。
// 判据：期望比对 0 误差 + 断言零违例 + 收发计数一致（反压丢数检查）。
//========================================================================
`timescale 1ns/1ps
`include "bayer_dpc_demosaic_top.v"

module tb_bayer_dpc_demosaic;

`ifdef IMG
    localparam IMG_W = 112, IMG_H = 103;
`else
    localparam IMG_W = 16,  IMG_H = 12;
`endif
`ifdef MHC
    localparam SEL = 1;
`else
    localparam SEL = 0;
`endif

    localparam DW     = 10;
    localparam OW     = 10;                // 出侧通道位宽：线性 RGB 域保持 10bit（3*OW=30bit）；
                                           //   位宽缩减统一在 Gamma 出口（M4）
    localparam TOTAL  = IMG_W * IMG_H;
`ifdef IMG
    localparam NFRAME = 1;
`else
    localparam NFRAME = 5;
`endif

    reg aclk = 0, aresetn = 0;
    always #5 aclk = ~aclk;

    // ---------------- DUT ----------------
    reg  [DW-1:0] in_data;
    reg           in_sof, in_eol;
    wire          in_valid;                  // 由源模型 assign 驱动
    wire          in_ready;
    wire          out_valid, out_sof, out_eol;
    wire          out_ready;                 // 由汇模型 assign 驱动
    wire [3*OW-1:0] out_data;                // RGB888 {r,g,b} 各 8bit
    wire [1:0]    out_phase;

    bayer_dpc_demosaic_top #(
        .DW(DW), .IMG_W(IMG_W), .IMG_H(IMG_H), .N(5), .THR(128), .DEMOSAIC_SEL(SEL)
    ) dut (
        .clk(aclk), .rst_n(aresetn),
        .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data),
        .in_sof(in_sof), .in_eol(in_eol),
        .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data),
        .out_sof(out_sof), .out_eol(out_eol), .out_phase(out_phase)
    );

    // ---------------- 输入像素（协议模式自生成；IMG 模式读文件） ----------------
    reg [DW-1:0] img [0:NFRAME*TOTAL-1];
`ifndef IMG
    integer gi;
    initial for (gi = 0; gi < NFRAME*TOTAL; gi = gi + 1)
        img[gi] = (gi * 131 + 7) & 1023;
`endif

`ifdef IMG
    initial $readmemh("blc_dpc_in.hex", img);
`endif
`ifdef IMG
  `ifdef MHC
    initial $readmemh("exp_rgb_img_mhc.hex", exp_mem);
  `else
    initial $readmemh("exp_rgb_img_bilinear.hex", exp_mem);
  `endif
`else
  `ifdef MHC
    initial $readmemh("exp_rgb_small_mhc.hex", exp_mem);
  `else
    initial $readmemh("exp_rgb_small_bilinear.hex", exp_mem);
  `endif
`endif

    // ---------------- 源模型（简流规范 master） ----------------
    integer    imode = 0;             // 0=连续 1=随机 70%
    integer    snd_target = NFRAME * TOTAL;
    integer    ngen = 0;
    reg        src_vld = 0;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            src_vld  <= 1'b0;
        end else begin
            if (!src_vld) begin
                if (ngen < snd_target &&
                    (imode == 0 || (({$random} % 1000) < 700))) begin
                    in_data  <= img[ngen];
                    in_sof   <= (ngen % TOTAL == 0);
                    in_eol   <= ((ngen % IMG_W) == IMG_W - 1);
                    src_vld  <= 1'b1;
                    ngen     <= ngen + 1;
                end
            end else if (in_ready) begin
                if (ngen < snd_target && imode != 99) begin
                    in_data  <= img[ngen];
                    in_sof   <= (ngen % TOTAL == 0);
                    in_eol   <= ((ngen % IMG_W) == IMG_W - 1);
                    ngen     <= ngen + 1;
                end else begin
                    src_vld <= 1'b0;
                end
            end
        end
    end
    assign in_valid = src_vld;

    // ---------------- 汇模型 ----------------
    integer omode = 0;
    reg  rdy_r = 0;
    integer drop_cnt = 0;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin rdy_r <= 1'b0; drop_cnt <= 0; end
        else if (omode == 0) rdy_r <= 1'b1;
        else if (omode == 1) rdy_r <= (({$random} % 1000) < 500);
        else begin
            if (drop_cnt > 0) begin drop_cnt <= drop_cnt - 1; rdy_r <= 1'b0; end
            else if (({$random} % 1000) < 20) begin drop_cnt <= 40 + ({$random} % 200); rdy_r <= 1'b0; end
            else rdy_r <= 1'b1;
        end
    end
    assign out_ready = rdy_r;

    // ---------------- 期望比对（RGB888：{r,g,b} 各 8bit，Python pack8 同构） ----------------
    reg [3*OW-1:0] exp_mem [0:NFRAME*TOTAL-1];
    integer snd_cnt = 0, rcv_cnt = 0, err_cnt = 0;
    integer fd;
    initial fd = $fopen("dpc_dm_out.txt", "w");

    always @(posedge aclk) begin
        #1;
        if (aresetn && in_valid && in_ready) snd_cnt = snd_cnt + 1;
        if (out_valid && out_ready) begin
            if (out_data !== exp_mem[rcv_cnt] ||
                out_sof !== ((rcv_cnt % TOTAL) == 0) ||
                out_eol !== (((rcv_cnt + 1) % IMG_W) == 0)) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8)
                    $display("MISMATCH @%0t #%0d (%0d,%0d): got(%06X s%b e%b) exp(%06X s%b e%b)",
                             $time, rcv_cnt, rcv_cnt / IMG_W, rcv_cnt % IMG_W,
                             out_data, out_sof, out_eol,
                             exp_mem[rcv_cnt], (rcv_cnt % TOTAL) == 0, ((rcv_cnt + 1) % IMG_W) == 0);
            end
            $fwrite(fd, "%08X\n", out_data);
            rcv_cnt = rcv_cnt + 1;
        end
    end

    // ---------------- 断言：出侧稳定性 + 复位期 valid=0 ----------------
    reg          pv_ov, pv_or;
    reg [3*OW-1:0] pv_od;
    reg          pv_os, pv_oe;
    reg [1:0]    pv_op;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin pv_ov <= 0; pv_or <= 0; end
        else begin
            if (!aresetn && out_valid) begin
                err_cnt = err_cnt + 1;
                $display("[ASSERT] @%0t 复位期间 out_valid=1", $time);
            end
            if (pv_ov && !pv_or) begin
                if (out_valid !== 1'b1) begin
                    err_cnt = err_cnt + 1;
                    $display("[ASSERT] @%0t 出侧 valid 未 ready 时撤销", $time);
                end
                if (out_data !== pv_od || out_sof !== pv_os || out_eol !== pv_oe || out_phase !== pv_op) begin
                    err_cnt = err_cnt + 1;
                    $display("[ASSERT] @%0t 出侧字段未 ready 时不稳定", $time);
                end
            end
            pv_ov <= out_valid; pv_or <= out_ready;
            pv_od <= out_data;  pv_os <= out_sof; pv_oe <= out_eol; pv_op <= out_phase;
        end
    end

    // ---------------- 场景流程 ----------------
    initial begin
`ifndef NOVCD
        $dumpfile("tb_bayer_dpc_demosaic.vcd");
        $dumpvars(0, tb_bayer_dpc_demosaic);
`endif
        aresetn = 0;
        repeat (10) @(posedge aclk);
        aresetn = 1;
        repeat (5) @(posedge aclk);

`ifdef IMG
        $display("=== 参数：IMG 模式 IMG_W=%0d IMG_H=%0d DW=%0d THR=128 ===", IMG_W, IMG_H, DW);
`else
        $display("=== 参数：SMALL 模式 IMG_W=%0d IMG_H=%0d DW=%0d THR=128 ===", IMG_W, IMG_H, DW);
`endif
        $display("=== Demosaic 核：%s ===", SEL ? "MHC" : "BILINEAR");

`ifdef IMG
        // 图像链：单帧连续流（图像质量由 Python 链评估，这里验证 RTL=期望）
        $display("=== 场景IMG：连续流 1 帧 ===");
        imode = 0; omode = 0;
        while (rcv_cnt < TOTAL) @(posedge aclk);
`else
        $display("=== 场景A：满速 2 帧 ===");
        snd_target = 2 * TOTAL; imode = 0; omode = 0;
        while (rcv_cnt < 2*TOTAL) @(posedge aclk);

        $display("=== 场景B：汇随机 ready 50%%，1 帧 ===");
        snd_target = 3 * TOTAL; imode = 0; omode = 1;
        while (rcv_cnt < 3*TOTAL) @(posedge aclk);

        $display("=== 场景C：汇长拉低，1 帧 ===");
        snd_target = 4 * TOTAL; imode = 0; omode = 2;
        while (rcv_cnt < 4*TOTAL) @(posedge aclk);

        $display("=== 场景D：双向随机，1 帧 ===");
        snd_target = 5 * TOTAL; imode = 1; omode = 1;
        while (rcv_cnt < 5*TOTAL) @(posedge aclk);
`endif

        repeat (10) @(posedge aclk);
        $fclose(fd);

        $display("========================================");
        $display("入侧 fire %0d，出侧收 %0d（期望 %0d）——反压丢数检查：%s",
                 snd_cnt, rcv_cnt, NFRAME*TOTAL,
                 (snd_cnt == NFRAME*TOTAL && rcv_cnt == NFRAME*TOTAL) ? "一致" : "不一致[ERR]");
        if (snd_cnt != NFRAME*TOTAL || rcv_cnt != NFRAME*TOTAL) err_cnt = err_cnt + 1;
        if (err_cnt == 0)
            $display("[PASS] bayer_dpc_demosaic：期望比对全等（0 误差）+ 断言零违例");
        else
            $display("[FAIL] err=%0d", err_cnt);
        $finish;
    end

    // 超时兜底
    initial begin
        #(NFRAME * TOTAL * 300 + 5000000);
        $display("[FAIL] simulation timeout snd=%0d rcv=%0d err=%0d", snd_cnt, rcv_cnt, err_cnt);
        $finish;
    end

endmodule
