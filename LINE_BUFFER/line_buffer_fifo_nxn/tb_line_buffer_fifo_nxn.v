//========================================================================
// tb_line_buffer_fifo_nxn.v —— FIFO 版 N×N 行缓存（pad 输出）自检 TB
//
// 判据（两条腿）：
//   1. TB 内建 golden 模型：整帧图像存二维数组，逐窗口按 replicate padding 重算
//      期望（ref_pix = img[clamp(r+i-K)][clamp(c+j-K)]），逐点比对，0 误差才算过
//   2. 双 DUT 对拍（`ifdef DUAL）：同激励同时喂已被验证的 BRAM 版
//      line_buffer_nxn_pad，输出窗口序列**位级全等**（最强判据）
//      注意：BRAM pad 版没有 out_ready，反压下两者节拍必然不同 —— 但窗口
//      **序列**（按输出先后）必须一致，所以对拍比较的是序列而不是拍对拍。
//
// 六个场景：
//   1. 连续流（in_valid 常 1 / out_ready 常 1）单帧 —— 预热 + 相位
//   2. 连续流 2 帧 —— 多帧连续（造行后 FIFO 内容不污染下一帧）
//   3. 入侧气泡（in_valid 随机 70%）
//   4. 出侧反压（out_ready 随机 50%）
//   5. 出侧长拉低（> 一行时间，压满各级 FIFO，验证冻结链无损）
//   6. 双向随机（最恶劣）
//
// 参数由编译期定义（默认 16×12 / N=3）：
//   iverilog -DTB_W=640 -DTB_H=8 -DTB_N=5 ...
//   iverilog -DDUAL ...        # 双 DUT 对拍（只适合小图）
//========================================================================
`timescale 1ns/1ps
`include "line_buffer_fifo_nxn.v"
`ifdef DUAL
`include "line_buffer_nxn_pad.v"      // 对照 DUT（-I 指向 ../line_buffer_nxn_pad）
`endif

module tb_line_buffer_fifo_nxn;

`ifdef TB_W
    localparam IMG_W = `TB_W;
`else
    localparam IMG_W = 16;
`endif
`ifdef TB_H
    localparam IMG_H = `TB_H;
`else
    localparam IMG_H = 12;
`endif
`ifdef TB_N
    localparam N = `TB_N;
`else
    localparam N = 3;
`endif

    localparam DW     = 10;
    localparam K      = (N-1)/2;
    localparam TOTAL  = IMG_W * IMG_H;      // 每帧窗口数
    localparam NSCEN  = 7;                  // 场景数（帧数之和，用于对拍数组大小）

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    // ---------------- DUT ----------------
    reg  [DW-1:0] in_data  = 0;
    reg           in_valid = 0;
    reg           in_sof   = 0;
    reg           in_eol   = 0;
    wire          in_ready;
    wire          out_valid;
    reg           out_ready = 1'b1;
    wire [N*N*DW-1:0] out_win;
    wire          out_sof, out_eol;

    line_buffer_fifo_nxn #(.DW(DW), .IMG_W(IMG_W), .IMG_H(IMG_H), .N(N)) dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_ready(in_ready),
        .in_data(in_data), .in_sof(in_sof), .in_eol(in_eol),
        .out_valid(out_valid), .out_ready(out_ready),
        .out_win_flat(out_win), .out_sof(out_sof), .out_eol(out_eol)
    );

`ifdef DUAL
    // ---------------- 对照 DUT：BRAM pad 版（独立驱动） ----------------
    //   ★ 不能用"两个 DUT 共用一条 in_valid"的做法：pad 版没有 out_ready、且造行期同样
    //     拉低 in_ready，共用会让两边互相钳制（实测会直接卡死）。
    //     正确做法：同一串像素数据、各自按自己的 ready 节奏握手 —— 窗口序列仍可比。
    //   ★ 已知问题（非本模块引入）：BRAM pad 版当前自身 TB 也超时（win=11309/23072
    //     err=0），原因是其 din_sof 复位吃掉了首个 beat 的计数 → 帧末造行触发条件
    //     (row==H-1 && col==W-1) 永不满足。所以本对拍在它修好前是**信息性**判据。
    reg           pad_dv = 0, pad_dsof = 0;
    reg [DW-1:0]  pad_din = 0;
    wire          pad_ready, pad_valid;
    wire [N*N*DW-1:0] pad_win;
    wire          pad_sof, pad_eol;
    line_buffer_nxn_pad #(.DW(DW), .IMG_W(IMG_W), .IMG_H(IMG_H), .N(N)) dut_pad (
        .clk(clk), .rst_n(rst_n),
        .din_valid(pad_dv), .din(pad_din), .din_sof(pad_dsof),
        .in_ready(pad_ready),
        .matrix_valid(pad_valid), .win_flat(pad_win),
        .out_sof(pad_sof), .out_eol(pad_eol)
    );
`endif

    wire rdy_eff = in_ready;      // 本 DUT 自己的 ready

    // ---------------- 输入图像（递增序列，便于肉眼/脚本查规律） ----------------
    reg [DW-1:0] img [0:TOTAL-1];
    integer p;
    initial begin
        for (p = 0; p < TOTAL; p = p + 1)
            img[p] = p[DW-1:0];
    end

    // ---------------- golden 参考：replicate padding ----------------
    function [DW-1:0] ref_pix;
        input integer r, c, i, j;
        integer sr, sc;
        begin
            sr = r + i - K;
            if (sr < 0)       sr = 0;
            if (sr > IMG_H-1) sr = IMG_H - 1;
            sc = c + j - K;
            if (sc < 0)       sc = 0;
            if (sc > IMG_W-1) sc = IMG_W - 1;
            ref_pix = img[sr * IMG_W + sc];
        end
    endfunction

    // ---------------- 收到的窗口落盘（供 verify_fifo_nxn.py 独立复核） ----------------
    //   每行一个窗口，N*N 个十进制字段（行主序，行0=顶 列0=左）；窗口按接收先后排列，
    //   即"帧内光栅序、帧间顺序"，所以第 k 行对应：帧 = k/(H*W)、中心 = (k%(H*W))/W, (k%(H*W))%W
    integer fd_win;
    initial fd_win = $fopen("fifo_wins.txt", "w");

    // ---------------- 记分板 ----------------
    integer win_idx   = 0;      // 本帧已收窗口数
    integer tot_win   = 0;      // 全程窗口总数
    integer err_cnt   = 0;
    integer send_cnt  = 0;      // 已发送像素数
    integer ready_low = 0;      // in_ready=0 的拍数（造行/冻结开销观测）
    integer r, c, i, j;
    reg [DW-1:0] got, exp;

    always @(posedge clk) begin
        #1;
        if (!in_ready) ready_low = ready_low + 1;

        if (out_valid && out_ready) begin
            r = win_idx / IMG_W;
            c = win_idx % IMG_W;
            for (i = 0; i < N; i = i + 1) begin
                for (j = 0; j < N; j = j + 1) begin
                    got = out_win[(i*N + j)*DW +: DW];
                    exp = ref_pix(r, c, i, j);
                    if (got !== exp) begin
                        err_cnt = err_cnt + 1;
                        if (err_cnt <= 8)
                            $display("MISMATCH @%0t 窗口#%0d 中心(%0d,%0d) 格(%0d,%0d): got %0d exp %0d",
                                     $time, win_idx, r, c, i, j, got, exp);
                    end
                end
            end
            if (out_sof !== ((r == 0) && (c == 0))) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8) $display("SOF 位置错 @%0t 窗口#%0d 中心(%0d,%0d)", $time, win_idx, r, c);
            end
            if (out_eol !== (c == IMG_W - 1)) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 8) $display("EOL 位置错 @%0t 窗口#%0d 中心(%0d,%0d)", $time, win_idx, r, c);
            end
            win_idx = win_idx + 1;
            tot_win = tot_win + 1;
            // 落盘（同上顺序）
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1)
                    $fwrite(fd_win, "%0d ", out_win[(i*N + j)*DW +: DW]);
            $fwrite(fd_win, "\n");
        end
    end

`ifdef DUAL
    // ---------------- 双 DUT 窗口序列收集 ----------------
    localparam MAXW = NSCEN * TOTAL + 8;
    reg [N*N*DW-1:0] win_q_fifo [0:MAXW-1];
    reg [N*N*DW-1:0] win_q_pad  [0:MAXW-1];
    integer qf = 0, qp = 0;
    integer pwin_idx = 0;            // pad DUT 本帧窗口数（用于帧对齐）
    integer dual_err = 0;            // 对拍不等数（信息性，不计入判据）
    always @(posedge clk) begin
        #1;
        if (out_valid && out_ready) begin win_q_fifo[qf] = out_win; qf = qf + 1; end
        if (pad_valid)              begin win_q_pad[qp]  = pad_win; qp = qp + 1; pwin_idx = pwin_idx + 1; end
    end
`endif

`ifdef DBG
    // ---------------- 调试：盯帧末最后几个窗口的 emit / 造行 beat ----------------
    localparam END_BEAT_D = (K*IMG_W + K + 1) + TOTAL - 1;
    integer dbg_emit = 0;
    integer dbg_flush_emit = 0;
`ifdef DUAL
    integer viol_pad = 0;      // in_valid=1 但 pad 不收（应为 0）
    always @(posedge clk) begin
        #1;
        if (in_valid && !pad_ready) viol_pad = viol_pad + 1;
    end
`endif
    always @(posedge clk) begin
        #1;
        if (dut.emit_fire) begin
            dbg_emit = dbg_emit + 1;
            // 帧末/帧首附近的 emit 全打（catch 任何多余/错位 emit）
            if (dut.beat_idx >= END_BEAT_D - 6 || dut.beat_idx <= (K*IMG_W+K+1) + 1)
                $display("DBG emit T=%0t beat=%0d ocr=%0d occ=%0d flush=%b fc=%0d cnt=%0d",
                         $time, dut.beat_idx, dut.ocr, dut.occ, dut.flush_active, dut.fc, dbg_emit);
        end
        if (dut.shift_fire && dut.flush_active && dut.beat_idx >= END_BEAT_D - 3)
            $display("DBG flush T=%0t beat=%0d fc=%0d row=%0d col=%0d pix=%0d f1=%0d f2=%0d",
                     $time, dut.beat_idx, dut.fc, dut.row_cnt, dut.col_cnt, dut.beat_pix,
                     dut.fifo_dout_flat[0*DW +: DW], dut.fifo_dout_flat[1*DW +: DW]);
        if (out_valid && out_ready && win_idx >= TOTAL - 3) begin
            $display("DBG out T=%0t win#%0d lc=(%0d,%0d) sof=%b eol=%b win=%0d %0d %0d | %0d %0d %0d | %0d %0d %0d",
                     $time, win_idx, dut.lc_r, dut.lc_c, out_sof, out_eol,
                     out_win[0*DW +: DW], out_win[1*DW +: DW], out_win[2*DW +: DW],
                     out_win[3*DW +: DW], out_win[4*DW +: DW], out_win[5*DW +: DW],
                     out_win[6*DW +: DW], out_win[7*DW +: DW], out_win[8*DW +: DW]);
        end
        if (dut.flush_active && !dut.pipe_go)
            $display("DBG freeze-during-flush T=%0t fc=%0d ovr=%b ordy=%b", $time, dut.fc, out_valid, out_ready);
    end
`endif

    // ---------------- 输出反压驱动 ----------------
    integer omode = 0;          // 0=常 1，1=随机 50%，2=随机 + 长拉低
    integer drop_cnt = 0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_ready <= 1'b1;
            drop_cnt  <= 0;
        end
        else if (omode == 0) out_ready <= 1'b1;
        else if (omode == 1) out_ready <= (({$random} % 1000) < 500);
        else begin
            if (drop_cnt > 0) begin
                drop_cnt  <= drop_cnt - 1;
                out_ready <= 1'b0;
            end
            else if (({$random} % 1000) < 20) begin
                drop_cnt  <= 60 + ({$random} % 400);   // 长拉低：够压满深度 2W 的量级
                out_ready <= 1'b0;
            end
            else out_ready <= 1'b1;
        end
    end

    // ---------------- 场景驱动 ----------------
    integer imode = 0;          // 0=连续，1=随机 70%
    integer idx   = 0;          // 本帧已发送像素数
    integer dbg_wait = 0;
`ifdef DUAL
    integer pidx  = 0;          // pad DUT 本帧已发送像素数
`endif

    task run_frames(input integer nf, input integer mi, input integer om);
        integer f, guard, done, t_frame0, s_send0;
        begin
            imode = mi;
            omode = om;
            for (f = 0; f < nf; f = f + 1) begin
                idx = 0;
`ifdef DUAL
                pidx = 0;
`endif
                guard = 0;
                done  = 0;
                t_frame0 = $time;
                s_send0  = send_cnt;
                while (!done) begin
                    @(negedge clk);
                    // ---- 本 DUT 驱动 ----
                    if (idx < TOTAL && rdy_eff &&
                        (mi == 0 || (({$random} % 1000) < 700))) begin
                        in_valid = 1'b1;
                        in_data  = img[idx];
                        in_sof   = (idx == 0);
                        in_eol   = ((idx % IMG_W) == IMG_W - 1);
                        idx      = idx + 1;
                        send_cnt = send_cnt + 1;
                    end
                    else begin
                        in_valid = 1'b0;
                        in_sof   = 1'b0;
                        in_eol   = 1'b0;
                    end
`ifdef DUAL
                    // ---- 对照 DUT 驱动（同一像素序列、自己的 ready 节奏）----
                    if (pidx < TOTAL && pad_ready) begin
                        pad_dv   = 1'b1;
                        pad_din  = img[pidx];
                        pad_dsof = (pidx == 0);
                        pidx     = pidx + 1;
                    end
                    else begin
                        pad_dv   = 1'b0;
                        pad_dsof = 1'b0;
                    end
`endif
                    guard = guard + 1;
`ifdef DUAL
                    // 两边本帧都完成才进下一帧；pad 版当前有缺陷 → 有界等待，不卡死
                    if (idx >= TOTAL && win_idx >= TOTAL && pidx >= TOTAL && pwin_idx >= TOTAL)
                        done = 1;
                    else if (guard > 40000) begin
                        $display("  [WARN] DUAL 等待超时（pad 版缺陷）：idx=%0d win=%0d pidx=%0d pwin=%0d",
                                 idx, win_idx, pidx, pwin_idx);
                        done = 1;
                    end
`else
                    if (idx >= TOTAL && win_idx >= TOTAL) done = 1;
`endif
                end
                @(negedge clk);
                in_valid = 1'b0; in_sof = 1'b0; in_eol = 1'b0;
`ifdef DUAL
                pad_dv = 1'b0; pad_dsof = 1'b0;
                pwin_idx = 0;
`endif
                $display("  帧结束 T=%0t：本帧窗口 %0d（期望 %0d）累计 %0d err=%0d | 本帧拍=%0d 发送beat=%0d 拍/beat=%0d",
                         $time, win_idx, TOTAL, tot_win, err_cnt,
                         ($time - t_frame0) / 10, send_cnt - s_send0,
                         ((send_cnt - s_send0) > 0) ? (($time - t_frame0) / 10) / (send_cnt - s_send0) : 0);
                win_idx  = 0;                       // 进入下一帧，记分板窗口计数归零
            end
        end
    endtask

    // ---------------- 主流程 ----------------
    initial begin
`ifndef NOVCD
        $dumpfile("tb_line_buffer_fifo_nxn.vcd");
        $dumpvars(0, tb_line_buffer_fifo_nxn);
`endif

        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        $display("=== 参数：IMG_W=%0d IMG_H=%0d N=%0d DW=%0d （K=%0d）===", IMG_W, IMG_H, N, DW, K);
        $display("=== 场景1：连续流 单帧 ===");
        run_frames(1, 0, 0);
        $display("=== 场景2：连续流 2 帧（多帧连续）===");
        run_frames(2, 0, 0);
        $display("=== 场景3：入侧气泡（随机 70%%）===");
        run_frames(1, 1, 0);
        $display("=== 场景4：出侧反压（随机 50%%）===");
        run_frames(1, 0, 1);
        $display("=== 场景5：出侧长拉低（>一行）===");
        run_frames(1, 0, 2);
        $display("=== 场景6：双向随机 ===");
        run_frames(1, 1, 1);

        repeat (20) @(negedge clk);

        // ---------------- 双 DUT 对拍（信息性判据） ----------------
`ifdef DUAL
        $display("=== 双 DUT 对拍（FIFO 版 vs BRAM pad 版，信息性） ===");
        $display("  窗口数：fifo=%0d pad=%0d（pad 版少的部分源于其自身缺陷：帧末造行触发条件失效）", qf, qp);
        for (p = 0; p < qf && p < qp; p = p + 1) begin
            if (win_q_fifo[p] !== win_q_pad[p]) begin
                dual_err = dual_err + 1;
                if (dual_err <= 8)
                    $display("  [DIFF] 窗口 #%0d 位级不等（信息性，不计入判据）", p);
            end
        end
        $display("  公共前缀 %0d 个窗口中位级不等 %0d 个", (qf < qp) ? qf : qp, dual_err);
        $display("  （判据是 golden 记分板；对拍待 pad 版修好后转为硬判据）");
`endif

        $display("========================================");
        $display("发送像素 %0d 个，接收窗口 %0d 个（期望 %0d）", send_cnt, tot_win, NSCEN*TOTAL);
        $display("in_ready=0 拍数 %0d（造行 + 冻结开销）", ready_low);
        $fclose(fd_win);
        if (err_cnt == 0 && tot_win == NSCEN*TOTAL)
            $display("[PASS] line_buffer_fifo_nxn：六场景 golden 记分板全部通过（0 误差）");
        else
            $display("[FAIL] err=%0d 窗口=%0d/%0d", err_cnt, tot_win, NSCEN*TOTAL);
        $finish;
    end

    // ---------------- 超时兜底 ----------------
    //   按场景矩阵最坏情况给足余量（长拉低场景吞吐会掉一个量级）
    initial begin
        #(NSCEN * (TOTAL * 200 + IMG_W * 200 + 2000000));
        $display("[FAIL] simulation timeout 窗口=%0d err=%0d", tot_win, err_cnt);
        $finish;
    end

endmodule
