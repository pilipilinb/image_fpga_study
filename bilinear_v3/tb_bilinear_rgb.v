//========================================================================
// tb_bilinear_rgb.v —— bilinear_rgb_top 全链路自检 TB（计划 Step 6）
// 验证内容：
//   1. 全帧 OUT_W×OUT_H 像素逐拍与参考模型比对 RGB 三通道
//   2. valid 链完整性：o_valid 必须恰好 OUT_TOTAL 次（无假有效、无漏有效）
//   3. o_done 帧末标志恰 1 拍
//   4. 输出 output.coe（与 MATLAB COE 同格式），供 verify_scale.py 做 PSNR
// 参考模型：与 RTL 完全一致的定点语义
//   - 坐标：sx_a = dx*STEP_X（累加等价），sx = sx_a>>FB，u = sx_a[FB-1:0]
//   - 钳位：sx/sy 及 +1 钳到 [0, IN-1]（与顶层地址钳位一致）
//   - 权重清零：越界方向 u/v 清 0（与顶层 clamp_u/clamp_v 一致）
//   - 插值：1-u = 2^FB - u，四项和右移 2FB + 舍入位 + 饱和 255
// 比对基准：out_cnt（o_valid 计数）反推 (dx,dy)，与 DUT 输出一一对应
//   （本场景无气泡——pixel_en 逐拍连续，o_valid 与像素序号严格对应）
// 激励规范（守工程实践）：
//   - 控制信号在 negedge 置位，避开 posedge 竞争
//   - 先设置后等待（pixel_en=1 再 @(negedge clk)），每个输入恰采样一次
//   - 停止后检查 o_valid 必须为 0（排空，防残留）
// 配置：iverilog 加 -DSMALL 跑合成小图（Step 8），默认跑真图 input.hex；
//   缩放倍数：默认放大 2 倍，-DSCALE3 放大 3 倍，-DDOWN2 缩小 2 倍，-DDOWN3 缩小 3 倍
//   iverilog -DSMALL -I <v3目录> -o tb.vvp tb_bilinear_rgb.v
//   iverilog        -I <v3目录> -o tb.vvp tb_bilinear_rgb.v
//========================================================================
`timescale 1ns/1ps
`include "bilinear_rgb_top.v"

module tb_bilinear_rgb;

    //---- 测试配置 ----
`ifdef SMALL
    localparam IN_W = 4;          // 合成小图（Step 8，RGB 三通道不同分量）
    localparam IN_H = 3;
`else
    localparam IN_W = 112;        // 真图（Step 9，feibi resize）
    localparam IN_H = 103;
`endif
    // 缩放倍数（分子/分母）：放大 N 倍 = N/1，缩小 N 倍 = 1/N
    //   -DSCALE3 放大 3 倍（Step 10），-DDOWN2 缩小 2 倍，-DDOWN3 缩小 3 倍
`ifdef SCALE3
    localparam SCALE_N = 3; localparam SCALE_D = 1;
`elsif DOWN2
    localparam SCALE_N = 1; localparam SCALE_D = 2;
`elsif DOWN3
    localparam SCALE_N = 1; localparam SCALE_D = 3;
`else
    localparam SCALE_N = 2; localparam SCALE_D = 1;   // 默认放大 2 倍
`endif
    localparam FB    = 8;
    localparam OUT_W   = IN_W * SCALE_N / SCALE_D;   // 整数除法截断
    localparam OUT_H   = IN_H * SCALE_N / SCALE_D;
    localparam OUT_TOTAL = OUT_W * OUT_H;
`ifdef SMALL
    localparam INIT_FILE = "input_4x3.hex";
`else
    localparam INIT_FILE = "input.hex";
`endif

    // 与 RTL 一致的步进（coord_gen 的 localparam 算法）
    localparam STEP_X = ((IN_W << FB) + OUT_W/2) / OUT_W;
    localparam STEP_Y = ((IN_H << FB) + OUT_H/2) / OUT_H;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg start = 1'b0;
    reg pixel_en = 1'b0;
    wire [7:0] o_r, o_g, o_b;
    wire o_valid, o_done;

    bilinear_rgb_top #(
        .IN_WIDTH (IN_W), .IN_HEIGHT(IN_H),
        .SCALE_N(SCALE_N), .SCALE_D(SCALE_D),
        .FRAC_BITS(FB), .INIT_FILE(INIT_FILE)
    ) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .pixel_en(pixel_en),
        .o_r(o_r), .o_g(o_g), .o_b(o_b), .o_valid(o_valid), .o_done(o_done)
    );

    always #5 clk = ~clk;

    //---- 输入图像（$readmemh 加载，与 image_rom 同源）----
    reg [23:0] img [0:IN_W*IN_H-1];
    initial $readmemh(INIT_FILE, img);

    //---- 参考模型辅助：按通道取像素 ----
    function integer pix_ch;
        input integer px;
        input integer chan;   // 0=R 1=G 2=B
        begin
            if (chan == 0)      pix_ch = (px >> 16) & 8'hFF;
            else if (chan == 1) pix_ch = (px >>  8) & 8'hFF;
            else                pix_ch = px        & 8'hFF;
        end
    endfunction

    //---- 参考模型：期望像素（与 RTL 完全一致的定点语义）----
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
            // 钳位（与顶层地址钳位一致）
            sx_c  = (sx   > IN_W-1) ? IN_W-1 : sx;
            sx1_c = (sx+1 > IN_W-1) ? IN_W-1 : sx+1;
            sy_c  = (sy   > IN_H-1) ? IN_H-1 : sy;
            sy1_c = (sy+1 > IN_H-1) ? IN_H-1 : sy+1;
            // 越界方向权重清零（与顶层 clamp_u/clamp_v 一致）
            if (sx >= IN_W-1) u = 0;
            if (sy >= IN_H-1) v = 0;
            u1 = (1<<FB) - u;     v1 = (1<<FB) - v;
            // 四项加权和（p00=左上 P(sy,sx)，p01=右上，p10=左下，p11=右下）
            w00 = u1 * v1;  w01 = u * v1;  w10 = u1 * v;  w11 = u * v;
            sum = w00 * pix_ch(img[sy_c*IN_W   + sx_c],  chan)
                + w01 * pix_ch(img[sy_c*IN_W   + sx1_c], chan)
                + w10 * pix_ch(img[sy1_c*IN_W  + sx_c],  chan)
                + w11 * pix_ch(img[sy1_c*IN_W  + sx1_c], chan);
            // 右移 2FB + 舍入位 + 饱和（与核的 9 位防回绕等价）
            rounded = (sum >> (2*FB)) + ((sum >> (2*FB-1)) & 1);
            ref_pix = (rounded > 255) ? 255 : rounded;
        end
    endfunction

    //---- 记分板 ----
    integer out_cnt = 0, err_cnt = 0, done_cnt = 0;
    integer dx, dy;

    always @(posedge clk) begin
        #1;   // 读 DUT 寄存输出稳定值（守工程规范）
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
                // 假有效：像素数超出帧内
                err_cnt = err_cnt + 1;
                $display("FALSE o_valid @%0t (已超 %0d 像素)", $time, OUT_TOTAL);
            end
            out_cnt = out_cnt + 1;
        end
        if (o_done) done_cnt = done_cnt + 1;
    end

    //---- 输出 COE（与 MATLAB 格式一致，供 verify_scale.py / 显示）----
    integer fd;
    initial begin
        fd = $fopen("output.coe", "w");
        $fwrite(fd, "memory_initialization_radix=16;\n");
        $fwrite(fd, "memory_initialization_vector=\n");
    end
    always @(posedge clk) begin
        #1;
        if (o_valid && out_cnt < OUT_TOTAL)
            $fwrite(fd, "%02X%02X%02X,\n", o_r, o_g, o_b);
    end

    //---- 激励（守规范：negedge 置位 + 先设置后等待）----
    integer i;
    initial begin
        $dumpfile("tb_bilinear_rgb.vcd");
        $dumpvars(0, tb_bilinear_rgb);

        #25 rst_n = 1;
        @(negedge clk);
        // 帧启动
        @(negedge clk); start = 1;
        @(negedge clk); start = 0;
        // 逐拍驱动全帧（先设置后等待，每输入恰采样一次）
        for (i = 0; i < OUT_TOTAL; i = i + 1) begin
            pixel_en = 1;
            @(negedge clk);
        end
        // 停止输入（防残留被重复采样）
        pixel_en = 0;
        // 冲排流水线（ROM 1 拍 + LAT 8 + 余量）
        repeat (20) @(negedge clk);
        #40;
        // 停止后 o_valid 必须为 0（排空检查）
        if (o_valid) begin
            err_cnt = err_cnt + 1;
            $display("FALSE o_valid after input stop @%0t", $time);
        end
        // 汇总
        $display("========================================");
        if (err_cnt == 0 && out_cnt == OUT_TOTAL && done_cnt == 1) begin
            $display("[PASS] bilinear_rgb_top OK: %0d 像素全对 (OUT=%0dx%0d, INIT=%s)",
                     out_cnt, OUT_W, OUT_H, INIT_FILE);
        end else begin
            $display("[FAIL] errors=%0d out_count=%0d/%0d done=%0d INIT=%s",
                     err_cnt, out_cnt, OUT_TOTAL, done_cnt, INIT_FILE);
        end
        $fclose(fd);
        $finish;
    end

    //---- 超时兜底 ----
    initial begin
        #(OUT_TOTAL * 25 + 200000);
        $display("[FAIL] simulation timeout");
        $finish;
    end

endmodule