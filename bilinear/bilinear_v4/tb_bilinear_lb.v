//========================================================================
// tb_bilinear_lb.v —— 行缓存版缩放全链路自检 TB（bilinear_v4）
// 验证内容：
//   1. 全帧 OUT_W×OUT_H 像素逐拍与参考模型比对 RGB 三通道
//   2. 流式输入握手：din_valid + in_ready 反压（每行随机气泡 + 行末延时，
//      压力验证行缓存的行就绪/行释放逻辑）
//   3. valid 链完整性：o_valid 恰 OUT_TOTAL 次（无假/漏有效）
//   4. 输出 output.coe（与 v3 同格式），供 verify_scale.py 做 PSNR
// 参考模型：与 RTL 完全一致的定点语义（与 v3 TB 相同：
//   sx_a = dx*STEP_X 累加等价、钳位、越界权重清零、右移 2FB 舍入饱和）
// 激励规范（守工程实践）：
//   - 控制信号 negedge 置位，避开 posedge 竞争
//   - 握手驱动：先设置 din/din_valid，等 in_ready 就绪再采样（每输入恰写一次）
//   - 停止后检查 o_valid 必须为 0（排空，防残留）
// 配置：-DSMALL 小图 / -DSCALE3 放大 3 倍 / -DDOWN2 缩小 2 倍，默认放大 2 倍
//========================================================================
`timescale 1ns/1ps
`include "bilinear_lb_top.v"

module tb_bilinear_lb;

    //---- 测试配置 ----
`ifdef SMALL
    localparam IN_W = 4;          // 合成小图
    localparam IN_H = 3;
`else
    localparam IN_W = 112;        // 真图
    localparam IN_H = 103;
`endif
`ifdef SCALE3
    localparam SCALE_N = 3; localparam SCALE_D = 1;
`elsif DOWN2
    localparam SCALE_N = 1; localparam SCALE_D = 2;
`else
    localparam SCALE_N = 2; localparam SCALE_D = 1;
`endif
    localparam FB    = 8;
    localparam OUT_W   = IN_W * SCALE_N / SCALE_D;
    localparam OUT_H   = IN_H * SCALE_N / SCALE_D;
    localparam OUT_TOTAL = OUT_W * OUT_H;
    localparam IN_TOTAL  = IN_W * IN_H;
`ifdef SMALL
    localparam INIT_FILE = "input_4x3.hex";
`else
    localparam INIT_FILE = "input.hex";
`endif

    // 与 RTL 一致的步进
    localparam STEP_X = ((IN_W << FB) + OUT_W/2) / OUT_W;
    localparam STEP_Y = ((IN_H << FB) + OUT_H/2) / OUT_H;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg start = 1'b0;
    reg [23:0] din = 24'd0;
    reg din_valid = 1'b0;
    wire in_ready;
    wire [7:0] o_r, o_g, o_b;
    wire o_valid, o_done;

    bilinear_lb_top #(
        .IN_WIDTH (IN_W), .IN_HEIGHT(IN_H),
        .SCALE_N(SCALE_N), .SCALE_D(SCALE_D),
        .FRAC_BITS(FB)
    ) dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .din(din), .din_valid(din_valid), .in_ready(in_ready),
        .o_r(o_r), .o_g(o_g), .o_b(o_b), .o_valid(o_valid), .o_done(o_done)
    );

    always #5 clk = ~clk;

    //---- 输入图像（$readmemh 加载）----
    reg [23:0] img [0:IN_TOTAL-1];
    initial $readmemh(INIT_FILE, img);

    //---- 参考模型（与 v3 TB 相同：定点语义完全一致）----
    function integer pix_ch;
        input integer px;
        input integer chan;
        begin
            if (chan == 0)      pix_ch = (px >> 16) & 8'hFF;
            else if (chan == 1) pix_ch = (px >>  8) & 8'hFF;
            else                pix_ch = px        & 8'hFF;
        end
    endfunction

    function integer ref_pix;
        input integer dx, dy;
        input integer chan;
        integer sx_a, sy_a, sx, sy, u, v, u1, v1;
        integer sx_c, sx1_c, sy_c, sy1_c;
        integer w00, w01, w10, w11, sum, rounded;
        begin
            sx_a = dx * STEP_X;   sy_a = dy * STEP_Y;
            sx = sx_a >> FB;      u = sx_a & ((1<<FB)-1);
            sy = sy_a >> FB;      v = sy_a & ((1<<FB)-1);
            sx_c  = (sx   > IN_W-1) ? IN_W-1 : sx;
            sx1_c = (sx+1 > IN_W-1) ? IN_W-1 : sx+1;
            sy_c  = (sy   > IN_H-1) ? IN_H-1 : sy;
            sy1_c = (sy+1 > IN_H-1) ? IN_H-1 : sy+1;
            if (sx >= IN_W-1) u = 0;
            if (sy >= IN_H-1) v = 0;
            u1 = (1<<FB) - u;     v1 = (1<<FB) - v;
            w00 = u1 * v1;  w01 = u * v1;  w10 = u1 * v;  w11 = u * v;
            sum = w00 * pix_ch(img[sy_c*IN_W   + sx_c],  chan)
                + w01 * pix_ch(img[sy_c*IN_W   + sx1_c], chan)
                + w10 * pix_ch(img[sy1_c*IN_W  + sx_c],  chan)
                + w11 * pix_ch(img[sy1_c*IN_W  + sx1_c], chan);
            rounded = (sum >> (2*FB)) + ((sum >> (2*FB-1)) & 1);
            ref_pix = (rounded > 255) ? 255 : rounded;
        end
    endfunction

    //---- 记分板 ----
    integer out_cnt = 0, err_cnt = 0, done_cnt = 0;
    integer dx, dy;

    always @(posedge clk) begin
        #1;
        if (o_valid) begin
            if (out_cnt < OUT_TOTAL) begin
                dx = out_cnt % OUT_W;
                dy = out_cnt / OUT_W;
                if (o_r !== ref_pix(dx, dy, 0)) begin
                    err_cnt = err_cnt + 1;
                    if (err_cnt <= 10)
                        $display("R  MISMATCH @%0t pix#%0d(%0d,%0d): got %0d exp %0d",
                                 $time, out_cnt, dx, dy, o_r, ref_pix(dx, dy, 0));
                end
                if (o_g !== ref_pix(dx, dy, 1)) begin
                    err_cnt = err_cnt + 1;
                    if (err_cnt <= 10)
                        $display("G  MISMATCH @%0t pix#%0d(%0d,%0d): got %0d exp %0d",
                                 $time, out_cnt, dx, dy, o_g, ref_pix(dx, dy, 1));
                end
                if (o_b !== ref_pix(dx, dy, 2)) begin
                    err_cnt = err_cnt + 1;
                    if (err_cnt <= 10)
                        $display("B  MISMATCH @%0t pix#%0d(%0d,%0d): got %0d exp %0d",
                                 $time, out_cnt, dx, dy, o_b, ref_pix(dx, dy, 2));
                end
            end else begin
                err_cnt = err_cnt + 1;
                $display("FALSE o_valid @%0t (已超 %0d 像素)", $time, OUT_TOTAL);
            end
            out_cnt = out_cnt + 1;
        end
        if (o_done) done_cnt = done_cnt + 1;
    end

    //---- 输出 COE（独立写计数，避免与记分板 out_cnt 的跨 always 竞态）----
    integer fd;
    integer w_cnt = 0;
    initial begin
        fd = $fopen("output.coe", "w");
        $fwrite(fd, "memory_initialization_radix=16;\n");
        $fwrite(fd, "memory_initialization_vector=\n");
    end
    always @(posedge clk) begin
        #1;
        if (o_valid && w_cnt < OUT_TOTAL) begin
            $fwrite(fd, "%02X%02X%02X,\n", o_r, o_g, o_b);
            w_cnt <= w_cnt + 1;
        end
    end

    //---- 激励：流式握手驱动（negedge 置位 + 先设置后等待 + 随机气泡/行延时）----
    integer r, c, i;
    initial begin
        $dumpfile("tb_bilinear_lb.vcd");
        $dumpvars(0, tb_bilinear_lb);

        #25 rst_n = 1;
        @(negedge clk);
        @(negedge clk); start = 1;
        @(negedge clk); start = 0;

        for (r = 0; r < IN_H; r = r + 1) begin
            for (c = 0; c < IN_W; c = c + 1) begin
                // 行内气泡（约 20%）：din_valid 拉低一拍（仅在写侧就绪时才有意义）
                if ({$random} % 5 == 0) begin
                    din_valid = 1'b0;
                    @(negedge clk);
                end
                // 握手驱动：先设置，等 in_ready 就绪，再采样写入
                din       = img[r * IN_W + c];
                din_valid = 1'b1;
                while (!in_ready) @(negedge clk);   // 写侧被反压则等待
                @(negedge clk);                     // 写入采样
            end
            // 行末延时（0~3 拍）：压力验证行切换/行就绪恢复
            din_valid = 1'b0;
            repeat ({$random} % 4) @(negedge clk);
        end
        din_valid = 1'b0;

        // 等输出排空（读侧继续读最后两行直到 OUT_TOTAL 像素）
        while (out_cnt < OUT_TOTAL) @(negedge clk);
        #40;
        if (o_valid) begin
            err_cnt = err_cnt + 1;
            $display("FALSE o_valid after drain @%0t", $time);
        end
        // 汇总
        $display("========================================");
        if (err_cnt == 0 && out_cnt == OUT_TOTAL && done_cnt == 1) begin
            $display("[PASS] bilinear_lb_top OK: %0d 像素全对 (OUT=%0dx%0d, INIT=%s)",
                     out_cnt, OUT_W, OUT_H, INIT_FILE);
        end else begin
            $display("[FAIL] errors=%0d out_count=%0d/%0d done=%0d INIT=%s",
                     err_cnt, out_cnt, OUT_TOTAL, done_cnt, INIT_FILE);
        end
        $fclose(fd);
        $finish;
    end

    //---- 超时兜底（带诊断打印：定位反压死锁）----
    initial begin
        #(IN_TOTAL * 40 + OUT_TOTAL * 40 + 1000000);
        $display("[FAIL] timeout: w=%0d sy=%0d sy01=%0d rd_ready=%b wr_ready=%b in_ready=%b o_valid=%b out_cnt=%0d",
                 dut.u_cache.w, dut.sy, dut.u_cache.sy01,
                 dut.u_cache.rd_ready, dut.u_cache.wr_ready, in_ready, o_valid, out_cnt);
        $finish;
    end

endmodule