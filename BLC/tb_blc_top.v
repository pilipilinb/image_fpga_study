//========================================================================
// tb_blc_top.v —— BLC 第一级 AXIS 全协议自检 TB
//
// 四个场景（golden 记分板 0 误差 + 协议断言零违例才算过）：
//   A. 满速连续 2 帧（多帧 sof/eol 计数器重同步）
//   B. 汇随机 ready 50%，1 帧（反压透传）
//   C. 汇长拉低（压满），1 帧（反压丢数据检查：收发计数一致）
//   D. 双向随机（源 70% 气泡 + 汇 50%），1 帧
//
// golden 记分板（与被测逻辑不同源）：
//   入侧：s_fire 拍把 s_axis_tdata 抄进 exp 队列（源发什么记什么）
//   出侧：第 k 个消费像素 → r=k/W, c=k%W → 相位 {r[0],c[0]} → 选 OB →
//         exp = (p < ob) ? 0 : (p-ob)；同时校验 out_sof/out_eol/out_phase
//
// 像素流：gen_data = (n*131+7) & 1023（131 与 1024 互素 → 均匀覆盖 0..1023，
//   满量程场景下大量像素 < OB 触发 clamp），帧连续编号不回绕。
//
// OB 取四通道不同值（ob_00=100 ob_01=64 ob_10=180 ob_11=32）——要点①的逐通道偏置。
//
// 协议断言（always 检查实现，违例计 err）：
//   1) s_axis 侧稳定性（源模型自身合规自检）
//   2) 简流出侧稳定性：out_valid=1 且未 ready → 下拍 valid 仍 1 且四字段不变
//   3) 复位期间 out_valid=0
//
// 落盘 blc_out.txt：每像素一行 "data phase sof eol"，供 verify_blc.py 独立复算。
//========================================================================
`timescale 1ns/1ps
`include "blc_top.v"

module tb_blc_top;

    localparam DW     = 10;
    localparam IMG_W  = 16;
    localparam IMG_H  = 12;
    localparam TOTAL  = IMG_W * IMG_H;
    localparam NFRAME = 5;                     // A2 + B1 + C1 + D1
    localparam OB00 = 10'd100, OB01 = 10'd64, OB10 = 10'd180, OB11 = 10'd32;

`ifdef EFIFO
    localparam EF = 1;             // 集成形态：入端弹性 FIFO 使能（-DEFIFO）
`else
    localparam EF = 0;             // 单级形态：直连（默认）
`endif

    reg aclk = 0, aresetn = 0;
    always #5 aclk = ~aclk;

    // ---------------- DUT ----------------
    wire [11:0] s_tdata;
    wire        s_tvalid, s_tlast, s_tuser;
    wire        s_tready;
    wire        out_valid, out_sof, out_eol;
    wire        out_ready;
    wire [DW-1:0] out_data;
    wire [1:0]  out_phase;

    blc_top #(.DW(DW), .ENTRY_FIFO_EN(EF)) dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
        .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
        .ob_00(OB00), .ob_01(OB01), .ob_10(OB10), .ob_11(OB11),
        .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data),
        .out_sof(out_sof), .out_eol(out_eol), .out_phase(out_phase)
    );

    // ---------------- 像素生成（满量程覆盖） ----------------
    function [DW-1:0] gen_data(input integer n);
        gen_data = (n * 131 + 7) & 1023;
    endfunction
    function gen_eol(input integer n);          // n = 帧内序号
        gen_eol = (n % IMG_W == IMG_W - 1);
    endfunction
    function gen_tuser(input integer n);        // n = 帧内序号
        gen_tuser = (n == 0);
    endfunction

    // ---------------- AXIS 源模型（规范 master：未 ready 时字段保持） ----------------
    integer    src_mode = 0;        // 0=停 1=连续 2=随机 70%
    reg        src_vld = 0;
    reg [11:0] src_dat;
    reg        src_lst, src_usr;
    integer    ngen = 0;            // 帧内已载入序号（控制 sof/eol 语义）
    integer    ntot  = 0;           // 全局已载入序号（数据跨帧连续，覆盖更多满量程样本）
    integer    nframe = 0;          // 已载入帧数
    integer    snd_target = 0;

    assign s_tdata  = src_dat;
    assign s_tvalid = src_vld;
    assign s_tlast  = src_lst;
    assign s_tuser  = src_usr;

    task src_load;                  // 载入第 ngen 个字（帧内语义），数据用全局序号
        begin
            src_dat = {2'b00, gen_data(ntot)};
            src_lst = gen_eol(ngen);
            src_usr = gen_tuser(ngen);
            ntot    = ntot + 1;
        end
    endtask

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            src_vld <= 1'b0;
        end else begin
            if (!src_vld) begin
                if (nframe < snd_target && (src_mode == 1 ||
                    (src_mode == 2 && (({$random} % 1000) < 700)))) begin
                    src_load; ngen <= ngen + 1;
                    if (ngen == IMG_W*IMG_H - 1) begin ngen <= 0; nframe <= nframe + 1; end
                    src_vld <= 1'b1;
                end
            end else if (s_tready) begin
                if (nframe < snd_target && src_mode != 0) begin
                    src_load; ngen <= ngen + 1;
                    if (ngen == IMG_W*IMG_H - 1) begin ngen <= 0; nframe <= nframe + 1; end
                    // src_vld 保持 1（背靠背）
                end else begin
                    src_vld <= 1'b0;    // 被消费后才允许撤 valid（规范）
                end
            end
            // valid 且未 ready：保持（规范）
        end
    end

    // ---------------- 汇模型 ----------------
    integer omode = 0;              // 0=常1 1=随机50% 2=长拉低
    reg  rdy_r = 0;
    integer drop_cnt = 0;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            rdy_r <= 1'b0; drop_cnt <= 0;
        end
        else if (omode == 0) rdy_r <= 1'b1;
        else if (omode == 1) rdy_r <= (({$random} % 1000) < 500);
        else begin
            if (drop_cnt > 0) begin drop_cnt <= drop_cnt - 1; rdy_r <= 1'b0; end
            else if (({$random} % 1000) < 30) begin drop_cnt <= 40 + ({$random} % 200); rdy_r <= 1'b0; end
            else rdy_r <= 1'b1;
        end
    end
    assign out_ready = rdy_r;

    // ---------------- golden 记分板 ----------------
    reg [DW-1:0] exp_in [0:NFRAME*TOTAL-1];   // 入侧收到的原始像素
    integer snd_cnt = 0, rcv_cnt = 0, err_cnt = 0;

    // 入侧：s_fire 抄写
    always @(posedge aclk) begin
        #1;
        if (aresetn && s_tvalid && s_tready) begin
            exp_in[snd_cnt] = s_tdata[DW-1:0];
            snd_cnt = snd_cnt + 1;
        end
    end

    // 出侧：逐拍比对
    integer fd;
    integer k, r, c, ph;
    reg [DW-1:0] p, ob, exp;
    reg [1:0] ph_exp;
    initial fd = $fopen("blc_out.txt", "w");
    always @(posedge aclk) begin
        #1;
        if (out_valid && out_ready) begin
            k  = rcv_cnt;
            r  = k / IMG_W;
            c  = k % IMG_W;
            ph = (r % 2) * 2 + (c % 2);        // {row&1, col&1}，范围 0..3
            ph_exp = ph;                       // 截 2bit
            case (ph_exp)
                2'b00: ob = OB00;
                2'b01: ob = OB01;
                2'b10: ob = OB10;
                default: ob = OB11;
            endcase
            p = exp_in[k];
            exp = (p < ob) ? {DW{1'b0}} : (p - ob);
            if (out_data !== exp || out_phase !== ph_exp ||
                out_sof !== ((k % TOTAL) == 0) || out_eol !== (((k+1) % IMG_W) == 0)) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 10)
                    $display("MISMATCH @%0t k=%0d (%0d,%0d): got(d=%0d ph=%0d sof=%b eol=%b) exp(d=%0d ph=%0d sof=%b eol=%b)",
                             $time, k, r, c, out_data, out_phase, out_sof, out_eol,
                             exp, ph_exp, (k % TOTAL) == 0, ((k+1) % IMG_W) == 0);
            end
            $fwrite(fd, "%0d %0d %0d %0d\n", out_data, out_phase, out_sof, out_eol);
            rcv_cnt = rcv_cnt + 1;
        end
    end

    // ---------------- 协议断言 ----------------
    // 1) s_axis 稳定性（源模型自检）
    reg        pv_sv, pv_sr;
    reg [11:0] pv_sd;
    reg        pv_sl, pv_su;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin pv_sv <= 0; pv_sr <= 0; end
        else begin
            if (pv_sv && !pv_sr) begin
                if (s_tvalid !== 1'b1) begin
                    err_cnt = err_cnt + 1;
                    $display("[ASSERT] @%0t s 侧 valid 未 ready 时撤销", $time);
                end
                if (s_tdata !== pv_sd || s_tlast !== pv_sl || s_tuser !== pv_su) begin
                    err_cnt = err_cnt + 1;
                    $display("[ASSERT] @%0t s 侧字段未 ready 时不稳定", $time);
                end
            end
            pv_sv <= s_tvalid; pv_sr <= s_tready;
            pv_sd <= s_tdata;  pv_sl <= s_tlast;  pv_su <= s_tuser;
        end
    end

    // 2) 简流出侧稳定性 + 3) 复位期 out_valid=0
    reg        pv_ov, pv_or;
    reg [DW-1:0] pv_od;
    reg        pv_os, pv_oe;
    reg [1:0]  pv_op;
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
                    $display("[ASSERT] @%0t 简流出侧 valid 未 ready 时撤销", $time);
                end
                if (out_data !== pv_od || out_sof !== pv_os || out_eol !== pv_oe || out_phase !== pv_op) begin
                    err_cnt = err_cnt + 1;
                    $display("[ASSERT] @%0t 简流出侧字段未 ready 时不稳定", $time);
                end
            end
            pv_ov <= out_valid; pv_or <= out_ready;
            pv_od <= out_data;  pv_os <= out_sof; pv_oe <= out_eol; pv_op <= out_phase;
        end
    end

    // ---------------- 场景流程 ----------------
    integer f;
    initial begin
`ifndef NOVCD
        $dumpfile("tb_blc_top.vcd");
        $dumpvars(0, tb_blc_top);
`endif
        aresetn = 0;
        repeat (10) @(posedge aclk);
        aresetn = 1;
        repeat (5) @(posedge aclk);

        $display("=== 参数：IMG_W=%0d IMG_H=%0d DW=%0d OB={%0d,%0d,%0d,%0d} ===",
                 IMG_W, IMG_H, DW, OB00, OB01, OB10, OB11);
        $display("=== 场景A：满速连续 2 帧 ===");
        snd_target = 2; src_mode = 1; omode = 0;
        while (rcv_cnt < 2*TOTAL) @(posedge aclk);

        $display("=== 场景B：汇随机 ready 50%%，1 帧 ===");
        snd_target = 3; src_mode = 1; omode = 1;
        while (rcv_cnt < 3*TOTAL) @(posedge aclk);

        $display("=== 场景C：汇长拉低，1 帧 ===");
        snd_target = 4; src_mode = 1; omode = 2;
        while (rcv_cnt < 4*TOTAL) @(posedge aclk);

        $display("=== 场景D：双向随机，1 帧 ===");
        snd_target = NFRAME; src_mode = 2; omode = 1;
        while (rcv_cnt < NFRAME*TOTAL) @(posedge aclk);

        repeat (10) @(posedge aclk);
        $fclose(fd);

        $display("========================================");
        $display("入侧 fire %0d 字，出侧收 %0d 字（期望 %0d）——反压丢数检查：%s",
                 snd_cnt, rcv_cnt, NFRAME*TOTAL,
                 (snd_cnt == NFRAME*TOTAL && rcv_cnt == NFRAME*TOTAL) ? "一致" : "不一致[ERR]");
        if (snd_cnt != NFRAME*TOTAL || rcv_cnt != NFRAME*TOTAL) err_cnt = err_cnt + 1;
        if (err_cnt == 0)
            $display("[PASS] blc_top：四场景 golden 全等（0 误差）+ 协议断言零违例");
        else
            $display("[FAIL] err=%0d", err_cnt);
        $finish;
    end

    // 超时兜底
    initial begin
        #(NFRAME * TOTAL * 300 + 2000000);
        $display("[FAIL] simulation timeout snd=%0d rcv=%0d err=%0d", snd_cnt, rcv_cnt, err_cnt);
        $finish;
    end

endmodule
