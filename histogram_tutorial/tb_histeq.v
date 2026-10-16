//========================================================================
// tb_histeq.v —— 直方图均衡自检 TB（histogram_tutorial 工程，W2 帧级处理）
// 验证内容：
//   1. 全帧逐像素比对：参考模型 = 帧级独立重算（CSC 灰度 → 直方图 → CDF
//      → J=(cdf*K)>>S 饱和），与 RTL 逐位全等
//   2. 帧延迟验证：帧 0 只统计无输出（o_valid 必须为 0），帧 1 起输出
//   3. 帧 1/帧 2 输出一致性：三帧同图 → CDF0==CDF1 → 两帧输出应完全相同
//      （同时验证 ping-pong 角色互换后数值不变）
//   4. 窗口数核对：EXP_CNT = 2 帧 × H×W；行内随机气泡验证空拍容忍
// 激励规范（守工程实践）：negedge 置位、先设置后等待、超时兜底、VCD
// 帧间要求：din_valid 空白 ≥ 513 拍（CDF 257 + 清零 256），TB 给 640 拍
// 灰度化参考：与 DUT 内置 CSC（rgb_to_ycbcr_3stage）同系数同源——
//   Y=(47R+157G+16B+4096)>>8 + 四舍五入（res[7] 进位），与 RTL y_tmp 逐位一致
// 定点化参考：K=(255<<S)/N 用同一 localparam 推导（防硬编码不一致）
// 配置：-DSMALL 4×3 小图；默认 112×103 真实图；第一帧输出写 output.coe
//========================================================================
`timescale 1ns/1ps
`include "top_histeq.v"

module tb_histeq;

`ifdef SMALL
    localparam IMG_W = 4;
    localparam IMG_H = 3;
`else
    localparam IMG_W = 112;
    localparam IMG_H = 103;
`endif
    localparam IN_TOTAL = IMG_W * IMG_H;
    localparam N        = IN_TOTAL;
    localparam S        = 14;                       // 与 DUT 相同（防硬编码不一致）
    localparam K        = (255 << S) / N;           // 定点系数，与 DUT 推导一致
    localparam HW       = $clog2(N + 1);
    localparam OUT_FRAMES = 2;                      // 帧 1 + 帧 2（帧 0 无输出）
    localparam EXP_CNT  = OUT_FRAMES * IN_TOTAL;
`ifdef SMALL
    localparam INIT_FILE = "input_4x3.hex";
`else
    localparam INIT_FILE = "input.hex";
`endif
    localparam TOTAL_FRAMES = 3;                    // 输入 3 帧（同图）

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg [23:0] din = 24'd0;
    reg din_valid = 1'b0;
    wire [7:0] o_j;
    wire o_valid;

    top_histeq #(
        .IMG_W(IMG_W), .IMG_H(IMG_H), .S(S)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .din(din), .din_valid(din_valid),
        .o_j(o_j), .o_valid(o_valid)
    );

    always #5 clk = ~clk;

    //---- 输入图像：三帧同一张真图（验证帧 1/帧 2 输出一致性）----
    reg [23:0] img [0:IN_TOTAL-1];
    initial $readmemh(INIT_FILE, img);

    //---- CSC Y 通道灰度化（与 DUT 内 rgb_to_ycbcr_3stage 逐位同源）----
    function integer csc_y;
        input integer px;
        integer r, g, b, res;
        begin
            r = (px >> 16) & 8'hFF;
            g = (px >>  8) & 8'hFF;
            b = px        & 8'hFF;
            res = 47 * r + 157 * g + 16 * b + 4096;   // 定点 ×256 + 16×256
            csc_y = (res >> 8) + ((res >> 7) & 1);    // 右移8 + 四舍五入
        end
    endfunction

    //---- 参考模型：按帧预计算 灰度 → 直方图 → CDF（帧级独立重算）----
    integer gy    [0:TOTAL_FRAMES-1] [0:IN_TOTAL-1];   // 每帧灰度
    integer hist  [0:TOTAL_FRAMES-1] [0:255];          // 每帧直方图
    integer cdf   [0:TOTAL_FRAMES-1] [0:255];          // 每帧累积分布
    integer f, i, k, acc;
    initial begin
        for (f = 0; f < TOTAL_FRAMES; f = f + 1) begin
            for (i = 0; i < IN_TOTAL; i = i + 1) begin
                gy[f][i] = csc_y(img[i]);
            end
            // 直方图统计（每帧独立从 0 开始）
            for (k = 0; k < 256; k = k + 1) hist[f][k] = 0;
            for (i = 0; i < IN_TOTAL; i = i + 1)
                hist[f][gy[f][i]] = hist[f][gy[f][i]] + 1;
            // CDF 前缀和
            acc = 0;
            for (k = 0; k < 256; k = k + 1) begin
                acc = acc + hist[f][k];
                cdf[f][k] = acc;
            end
        end
    end

    //---- 参考输出函数：第 out_f 帧输出（用第 out_f 帧 CDF 映射其输入灰度）----
    function integer ref_j;
        input integer out_f;
        input integer idx;
        integer v, prod;
        begin
            v = gy[out_f + 1][idx];                 // 该输出帧的输入灰度
            prod = cdf[out_f][v] * K;               // (cdf × K) >> S
            ref_j = prod >> S;
            if (ref_j > 255) ref_j = 255;           // 饱和（与 RTL 一致）
        end
    endfunction

    //---- 记分板 ----
    integer out_cnt = 0, err_cnt = 0;
    integer of, idx, exp_val;
    reg frame0_valid_ok = 1'b0;

    always @(posedge clk) begin
        #1;
        if (o_valid) begin
            if (out_cnt < EXP_CNT) begin
                of  = out_cnt / IN_TOTAL;           // 0 → DUT 帧 1，1 → DUT 帧 2
                idx = out_cnt % IN_TOTAL;
                exp_val = ref_j(of, idx);
                if (o_j !== exp_val[7:0]) begin
                    err_cnt = err_cnt + 1;
                    if (err_cnt <= 10)
                        $display("J MISMATCH @%0t out_f%0d px#%0d(%0d,%0d): got %0d exp %0d | y=%0d rdata0=%0d rdata1=%0d stat=%0d st=%0d fc=%0d",
                                 $time, of, out_cnt, idx / IMG_W, idx % IMG_W, o_j, exp_val,
                                 dut.u_histeq.y, dut.u_histeq.rdata0, dut.u_histeq.rdata1,
                                 dut.u_histeq.stat_is_ram1, dut.u_histeq.state, dut.u_histeq.frame_cnt);
                end
            end else begin
                err_cnt = err_cnt + 1;
                $display("FALSE o_valid @%0t (已超 %0d 像素)", $time, EXP_CNT);
            end
            out_cnt = out_cnt + 1;
        end
    end

    //---- 帧 0 期间 o_valid 不得拉高（帧延迟验证，由记分板 FALSE 检测兜底）----

    //---- 输出 COE：第一帧输出（DUT 帧 1 结果）写 output.coe，供 Python 验证 ----
    integer fd, w_cnt = 0;
    initial begin
        fd = $fopen("output.coe", "w");
        $fwrite(fd, "memory_initialization_radix=16;\n");
        $fwrite(fd, "memory_initialization_vector=\n");
    end
    always @(posedge clk) begin
        #1;
        if (o_valid && w_cnt < IN_TOTAL) begin
            $fwrite(fd, "%02X,\n", o_j);
            w_cnt <= w_cnt + 1;
        end
    end

    //---- 激励：3 帧同图，行内随机气泡 + 行末延时 + 帧间 640 拍空白 ----
    integer frame_i, r, c;
    initial begin
        $dumpfile("tb_histeq.vcd");
        $dumpvars(0, tb_histeq);

        #25 rst_n = 1;
        // 等 PRE 上电清零完成（256 拍）再喂数据：core 只有 PRE 完成后（WAIT）
        // 才接受首帧像素统计，提前喂会将帧 0 全部丢弃导致全局错位 1 帧（实测踩坑）
        while (dut.u_histeq.state != 3'd3) @(negedge clk);   // 3 = ST_WAIT
        repeat (8) @(negedge clk);   // 余量（CSC 同步复位释放也在 PRE 期内覆盖）

        for (frame_i = 0; frame_i < TOTAL_FRAMES; frame_i = frame_i + 1) begin
            for (r = 0; r < IMG_H; r = r + 1) begin
                for (c = 0; c < IMG_W; c = c + 1) begin
                    if ({$random} % 5 == 0) begin
                        din_valid = 1'b0;
                        @(negedge clk);
                    end
                    din       = img[r*IMG_W + c];
                    din_valid = 1'b1;
                    @(negedge clk);
                end
                din_valid = 1'b0;                     // 行末空拍（气泡蓄意）
                repeat (1 + {$random} % 3) @(negedge clk);
            end
            din_valid = 1'b0;                          // 帧间空白 ≥513 拍
            repeat (640) @(negedge clk);
        end

        // 等输出排空（输出延迟 1 帧 + 流水）
        while (out_cnt < EXP_CNT) @(negedge clk);
        #40;

        $display("========================================");
        if (err_cnt == 0 && out_cnt == EXP_CNT)
            $display("[PASS] histeq OK: %0d 像素全对（2 输出帧，帧0无输出验证，INIT=%s）",
                     out_cnt, INIT_FILE);
        else
            $display("[FAIL] errors=%0d out=%0d/%0d INIT=%s",
                     err_cnt, out_cnt, EXP_CNT, INIT_FILE);
        $fclose(fd);
        $finish;
    end

    //---- 超时兜底 ----
    initial begin
        #(IN_TOTAL * 120 + 4000000);
        $display("[FAIL] simulation timeout (out_cnt=%0d EXP=%0d)", out_cnt, EXP_CNT);
        $finish;
    end

endmodule