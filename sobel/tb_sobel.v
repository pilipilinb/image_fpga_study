//========================================================================
// tb_sobel.v —— 3×3 Sobel 边缘检测自检 TB（sobel 工程）
// 验证内容：
//   1. 全帧逐窗口比对：参考模型 = 独立整数重算（RGB888 → CSC 灰度(Y) → 3×3
//      replicate padding → Gx/Gy 差分 → AMBM 幅值 → >>2 → 饱和/阈值），
//      与 RTL 逐位全等
//   2. 零梯度不变性：第二帧喂全 0x808080 纯色图，梯度必须全 0
//   3. 阈值可配：帧0 thresh=64 / 帧1 thresh=48 两档，边缘图随阈值变化
//   4. 窗口数核对：两帧各 IMG_H×IMG_W（pad 版全尺寸，无 crop 偏移）；
//      行内/行间随机气泡验证空拍容忍
// 灰度化参考：与 DUT 内置 CSC（rgb_to_ycbcr_3stage）同系数同源——
//   Y = (0.183R + 0.614G + 0.062B) + 16，系数 ×256 定点(47/157/16) + 4096，
//   右移 8 位 + 四舍五入（result[7] 进位），与 RTL 的 y_tmp 逐位一致
// 激励规范（守工程实践）：negedge 置位、先设置后等待、超时兜底、VCD
// pad 版硬性要求：行末 din_valid 拉低 ≥1 拍（h-blank，rflush 插拍）；
//      帧末拉低 ≥ IMG_W+8 拍（v-blank，bflush 整行回放）——crop 版 TB 没有
// 配置：-DSMALL 4×3 小图；默认 112×103 真实图；第一帧幅值写 output.coe
//========================================================================
`timescale 1ns/1ps
`include "top_sobel.v"

module tb_sobel;

`ifdef SMALL
    localparam IMG_W = 4;
    localparam IMG_H = 3;
`else
    localparam IMG_W = 112;
    localparam IMG_H = 103;
`endif
    localparam IN_TOTAL = IMG_W * IMG_H;
    localparam WIN_PER_FRAME = IMG_W * IMG_H;   // pad 版全尺寸：每像素一窗口
    localparam EXP_CNT  = WIN_PER_FRAME * 2;    // 两帧（真实/纯色）
`ifdef SMALL
    localparam INIT_FILE = "input_4x3.hex";
`else
    localparam INIT_FILE = "input.hex";
`endif

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg [23:0] din = 24'd0;          // RGB888（DUT 内置 CSC 转灰度）
    reg din_valid = 1'b0;
    reg [7:0] thresh = 8'd64;
    wire [7:0] o_mag, o_edge;
    wire o_valid;

    top_sobel #(
        .IMG_W(IMG_W), .IMG_H(IMG_H), .AW($clog2(IMG_W)+1)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .din(din), .din_valid(din_valid), .thresh(thresh),
        .o_mag(o_mag), .o_edge(o_edge), .o_valid(o_valid)
    );

    always #5 clk = ~clk;

    //---- 输入图像：第一帧从文件读，第二帧纯色 0x808080 ----
    reg [23:0] img   [0:IN_TOTAL-1];
    reg [23:0] solid [0:IN_TOTAL-1];
    integer si;
    initial begin
        $readmemh(INIT_FILE, img);
        for (si = 0; si < IN_TOTAL; si = si + 1)
            solid[si] = 24'h808080;
    end

    //---- CSC Y 通道灰度化（与 DUT 内 rgb_to_ycbcr_3stage 逐位同源）----
    //   Y = (47R + 157G + 16B + 4096) 右移8位 + 四舍五入（result[7] 进位）
    //   = RTL: mult(×256系数) → add(+16×256) → result → y_tmp = res>>8 + res[7]
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

    //---- 按帧取像素：帧0=img（真实图），帧1=solid（纯色）----
    function integer frame_pix;
        input integer fr;
        input integer rr, cc;
        begin
            if (fr == 0) frame_pix = img[rr*IMG_W + cc];
            else         frame_pix = solid[rr*IMG_W + cc];
        end
    endfunction

    //---- replicate 边界取像素：越界复制边缘（与 pad 行缓存规则一致），
    //     返回 CSC 灰度值（与 DUT 内灰度化同源）----
    function integer pix_repl;
        input integer fr;
        input integer rr, cc;
        integer r2, c2;
        begin
            r2 = (rr < 0) ? 0 : ((rr >= IMG_H) ? IMG_H - 1 : rr);
            c2 = (cc < 0) ? 0 : ((cc >= IMG_W) ? IMG_W - 1 : cc);
            pix_repl = csc_y(frame_pix(fr, r2, c2));
        end
    endfunction

    //---- 参考模型：返回未饱和的 mag>>2 原始值（9bit，0..382）----
    //   与 RTL 逐位全等的整数协议：
    //   取像素 → CSC 灰度（同上）→ 3×3 邻域（replicate）→ gx/gy → abs
    //   → max/min → mag = M + (m>>1) → 返回 mag >> 2
    //   饱和/阈值在记分板完成（RTL 比较用的是原始 m8 而非饱和值）
    function integer ref_sobel;
        input integer fr;
        input integer rr, cc;
        integer p00, p01, p02, p10, p11, p12, p20, p21, p22;
        integer gx, gy, ax, ay, M, m, mag;
        begin
            p00 = pix_repl(fr, rr-1, cc-1); p01 = pix_repl(fr, rr-1, cc); p02 = pix_repl(fr, rr-1, cc+1);
            p10 = pix_repl(fr, rr,   cc-1); p11 = pix_repl(fr, rr,   cc); p12 = pix_repl(fr, rr,   cc+1);
            p20 = pix_repl(fr, rr+1, cc-1); p21 = pix_repl(fr, rr+1, cc); p22 = pix_repl(fr, rr+1, cc+1);
            gx = (p02 + (p12 << 1) + p22) - (p00 + (p10 << 1) + p20);   // ±1020
            gy = (p20 + (p21 << 1) + p22) - (p00 + (p01 << 1) + p02);   // ±1020
            ax = (gx < 0) ? -gx : gx;
            ay = (gy < 0) ? -gy : gy;
            M  = (ax >= ay) ? ax : ay;      // max
            m  = (ax >= ay) ? ay : ax;      // min
            mag = M + (m >> 1);             // AMBM α=1 β=0.5，整数右移 1 位截断
            ref_sobel = mag >> 2;           // 与 RTL m8 = mag_r[11:2] 同截断
        end
    endfunction

    //---- 记分板：EXP_CNT 个窗口逐一比对两路输出 ----
    integer out_cnt = 0, err_cnt = 0;
    integer k, wr, wc, frame, exp_mag, exp_edge;
    reg [7:0] thresh_f0 = 8'd64, thresh_f1 = 8'd48;

    always @(posedge clk) begin
        #1;
        if (o_valid) begin
            if (out_cnt < EXP_CNT) begin
                k     = out_cnt % WIN_PER_FRAME;
                frame = out_cnt / WIN_PER_FRAME;
                wr = k / IMG_W;              // pad 版无偏移：窗口 k 直接对应 (k/W, k%W)
                wc = k % IMG_W;
                exp_mag  = ref_sobel(frame, wr, wc);
                if (exp_mag > 255) exp_mag = 255;                    // 饱和
                if (o_mag !== exp_mag[7:0]) begin
                    err_cnt = err_cnt + 1;
                    if (err_cnt <= 10)
                        $display("MAG MISMATCH @%0t f%0d win#%0d(%0d,%0d): got %0d exp %0d",
                                 $time, frame, out_cnt, wr, wc, o_mag, exp_mag);
                end
                exp_edge = (ref_sobel(frame, wr, wc) > (frame ? thresh_f1 : thresh_f0)) ? 255 : 0;
                if (o_edge !== exp_edge[7:0]) begin
                    err_cnt = err_cnt + 1;
                    if (err_cnt <= 10)
                        $display("EDGE MISMATCH @%0t f%0d win#%0d(%0d,%0d): got %0d exp %0d",
                                 $time, frame, out_cnt, wr, wc, o_edge, exp_edge);
                end
            end else begin
                err_cnt = err_cnt + 1;
                $display("FALSE o_valid @%0t (已超 %0d 窗口)", $time, EXP_CNT);
            end
            out_cnt = out_cnt + 1;
        end
    end

    //---- 输出 COE：仅第一帧（真实图）幅值写 output.coe，供 Python 独立验证 ----
    integer fd;
    integer w_cnt = 0;
    initial begin
        fd = $fopen("output.coe", "w");
        $fwrite(fd, "memory_initialization_radix=16;\n");
        $fwrite(fd, "memory_initialization_vector=\n");
    end
    always @(posedge clk) begin
        #1;
        if (o_valid && w_cnt < WIN_PER_FRAME) begin
            $fwrite(fd, "%02X,\n", o_mag);
            w_cnt <= w_cnt + 1;
        end
    end

    //---- 激励：两帧（真实图 → 纯色），行末空拍 ≥1（h-blank）+ 随机气泡，
    //     帧末空拍 ≥ IMG_W+8（v-blank）----
    integer frame_i, r, c;
    initial begin
        $dumpfile("tb_sobel.vcd");
        $dumpvars(0, tb_sobel);

        #25 rst_n = 1;
        // 等内部同步复位释放：CSC（rgb_to_ycbcr_3stage）是异步复位同步释放，
        // i_rst_n 拉高后内部 rst_n 还要 2 拍才释放——提前喂数据会丢第一拍像素，
        // 导致行缓存行列计数错位、窗口输出稀疏错乱（踩坑实测，勿删）
        repeat (16) @(negedge clk);

        for (frame_i = 0; frame_i < 2; frame_i = frame_i + 1) begin
            thresh = (frame_i == 0) ? thresh_f0 : thresh_f1;
            for (r = 0; r < IMG_H; r = r + 1) begin
                for (c = 0; c < IMG_W; c = c + 1) begin
                    if ({$random} % 5 == 0) begin   // 行内随机气泡
                        din_valid = 1'b0;
                        @(negedge clk);
                    end
                    din       = (frame_i == 0) ? img[r*IMG_W + c] : 24'h808080;
                    din_valid = 1'b1;
                    @(negedge clk);
                end
                din_valid = 1'b0;                    // h-blank：行末 ≥1 拍
                repeat (1 + {$random} % 3) @(negedge clk);
            end
            din_valid = 1'b0;                        // v-blank：帧末 ≥ IMG_W+8 拍
            repeat (IMG_W + 8) @(negedge clk);
        end

        // 等流水排空（含 bflush 回放产出的最后一帧窗口）
        while (out_cnt < EXP_CNT) @(negedge clk);
        #40;

        $display("========================================");
        if (err_cnt == 0 && out_cnt == EXP_CNT)
            $display("[PASS] sobel OK: %0d 窗口全对（2 帧 thresh=%0d/%0d，INIT=%s）",
                     out_cnt, thresh_f0, thresh_f1, INIT_FILE);
        else
            $display("[FAIL] errors=%0d out=%0d/%0d INIT=%s", err_cnt, out_cnt, EXP_CNT, INIT_FILE);
        $fclose(fd);
        $finish;
    end

    //---- 超时兜底 ----
    initial begin
        #(IN_TOTAL * 80 + 2000000);
        $display("[FAIL] simulation timeout");
        $finish;
    end

endmodule