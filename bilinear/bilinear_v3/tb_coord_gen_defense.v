//========================================================================
// tb_coord_gen_defense.v —— coord_gen 帧内防御专项验证 TB
// 验证内容：
//   1. 帧1（正常）: 全帧 224×206 拍逐拍与参考模型比对坐标/权重，done 恰 1 拍
//   2. 帧2（违约）: done 后继续拉 pixel_en，验证 valid_out 拉低、坐标冻结不越界
//   3. 帧3（重启）: start 重启后坐标从 (0,0) 重新开始
// 自检记分板，结束打印 [PASS]/[FAIL]
// 时序要点: 所有控制信号在 negedge 置位，比较在 posedge（pixel_en 门控），
//           避免与 DUT 时钟沿竞争导致参考模型错位。
//========================================================================
`timescale 1ns/1ps
`include "coord_gen.v"

module tb_coord_gen_defense;

    localparam IN_WIDTH   = 112;
    localparam IN_HEIGHT  = 103;
    localparam OUT_WIDTH  = 224;
    localparam OUT_HEIGHT = 206;
    localparam FRAC_BITS  = 8;
    localparam XW = $clog2(IN_WIDTH)  + 1;
    localparam YW = $clog2(IN_HEIGHT) + 1;
    localparam STEP_X = ((IN_WIDTH  << FRAC_BITS) + OUT_WIDTH/2)  / OUT_WIDTH;
    localparam STEP_Y = ((IN_HEIGHT << FRAC_BITS) + OUT_HEIGHT/2) / OUT_HEIGHT;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg start = 1'b0;
    reg pixel_en = 1'b0;
    wire [XW-1:0]        src_x_int;
    wire [YW-1:0]        src_y_int;
    wire [FRAC_BITS-1:0] u_frac;
    wire [FRAC_BITS-1:0] v_frac;
    wire valid_out;
    wire done;

    coord_gen #(
        .IN_WIDTH(IN_WIDTH),   .IN_HEIGHT(IN_HEIGHT),
        .OUT_WIDTH(OUT_WIDTH), .OUT_HEIGHT(OUT_HEIGHT),
        .FRAC_BITS(FRAC_BITS)
    ) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .pixel_en(pixel_en),
        .src_x_int(src_x_int), .src_y_int(src_y_int),
        .u_frac(u_frac), .v_frac(v_frac),
        .valid_out(valid_out), .done(done)
    );

    always #5 clk = ~clk;

    // 参考模型（与 DUT 推进逻辑完全一致的整数模拟）
    integer exp_x_cnt = 0, exp_y_cnt = 0;
    integer exp_x_accum = 0, exp_y_accum = 0;
    integer err_cnt = 0, done_cnt = 0;
    integer frame1_ok = 0, frame2_ok = 0, frame3_ok = 0;
    integer f2_cnt = 0, f3_cnt = 0;
    integer frame1_pixels = OUT_WIDTH * OUT_HEIGHT;
    reg [7:0] f2_base_x = 0, f2_base_y = 0;

    // 参考模型推进（阻塞赋值，比较之后调用）
    task next_exp;
        begin
            if (exp_x_cnt == OUT_WIDTH - 1) begin
                exp_x_cnt = 0; exp_x_accum = 0;
                if (exp_y_cnt != OUT_HEIGHT - 1) begin
                    exp_y_cnt = exp_y_cnt + 1;
                    exp_y_accum = exp_y_accum + STEP_Y;
                end
            end else begin
                exp_x_cnt = exp_x_cnt + 1;
                exp_x_accum = exp_x_accum + STEP_X;
            end
        end
    endtask

    // 逐拍采样与比对（posedge 触发，pixel_en 门控，读"当前像素"组合输出）
    always @(posedge clk) begin
        if (frame1_ok && pixel_en) begin
            if (src_x_int !== ((exp_x_accum >> FRAC_BITS) & ((1<<XW)-1))) begin
                err_cnt = err_cnt + 1;
                $display("x mismatch @%0t: got %0d exp %0d", $time,
                    src_x_int, (exp_x_accum >> FRAC_BITS) & ((1<<XW)-1));
            end
            if (src_y_int !== ((exp_y_accum >> FRAC_BITS) & ((1<<YW)-1))) begin
                err_cnt = err_cnt + 1;
                $display("y mismatch @%0t: got %0d exp %0d", $time,
                    src_y_int, (exp_y_accum >> FRAC_BITS) & ((1<<YW)-1));
            end
            if (u_frac !== (exp_x_accum & ((1<<FRAC_BITS)-1))) begin
                err_cnt = err_cnt + 1;
                $display("u mismatch @%0t: got %0d exp %0d", $time,
                    u_frac, exp_x_accum & ((1<<FRAC_BITS)-1));
            end
            if (v_frac !== (exp_y_accum & ((1<<FRAC_BITS)-1))) begin
                err_cnt = err_cnt + 1;
                $display("v mismatch @%0t: got %0d exp %0d", $time,
                    v_frac, exp_y_accum & ((1<<FRAC_BITS)-1));
            end
            if (!valid_out) begin
                err_cnt = err_cnt + 1;
                $display("valid_out low during frame1 @%0t", $time);
            end
            if (done) done_cnt = done_cnt + 1;
            next_exp;   // 推进参考模型到下一像素
        end
        else if (frame2_ok && pixel_en) begin
            // 违约场景：第一拍记录冻结基准，后续拍必须与基准一致；
            // valid_out 必须拉低、坐标不得越界、done 不得再拉高
            if (f2_cnt == 0) begin
                f2_base_x = src_x_int;
                f2_base_y = src_y_int;
            end else begin
                if (src_x_int !== f2_base_x) begin
                    err_cnt = err_cnt + 1;
                    $display("frame2: x not frozen @%0t: got %0d exp %0d",
                        $time, src_x_int, f2_base_x);
                end
                if (src_y_int !== f2_base_y) begin
                    err_cnt = err_cnt + 1;
                    $display("frame2: y not frozen @%0t: got %0d exp %0d",
                        $time, src_y_int, f2_base_y);
                end
            end
            if (valid_out) begin
                err_cnt = err_cnt + 1;
                $display("frame2: valid_out should be 0 @%0t", $time);
            end
            if (src_y_int > IN_HEIGHT-1 || src_x_int > IN_WIDTH-1) begin
                err_cnt = err_cnt + 1;
                $display("frame2: coordinate out of range @%0t: (%0d,%0d)",
                    $time, src_x_int, src_y_int);
            end
            if (done) begin
                err_cnt = err_cnt + 1;
                $display("frame2: done should be 0 @%0t", $time);
            end
            f2_cnt = f2_cnt + 1;
        end
        else if (frame3_ok && pixel_en) begin
            // 重启后第一拍必须从头开始
            if (f3_cnt == 0) begin
                if (src_x_int !== 0 || src_y_int !== 0 || !valid_out) begin
                    err_cnt = err_cnt + 1;
                    $display("frame3: restart first pixel not (0,0) @%0t (%0d,%0d) v=%0d",
                        $time, src_x_int, src_y_int, valid_out);
                end
            end
            f3_cnt = f3_cnt + 1;
        end
    end

    initial begin
        $dumpfile("tb_coord_gen_defense.vcd");
        $dumpvars(0, tb_coord_gen_defense);

        // 复位；所有控制信号在 negedge 置位，避开 posedge 竞争
        #25 rst_n = 1;
        @(negedge clk); start = 1;
        @(negedge clk); start = 0;
        @(negedge clk); frame1_ok = 1;
        // 帧1：正常驱动全帧
        repeat (frame1_pixels) begin
            @(negedge clk);
            pixel_en = 1;
        end
        @(negedge clk); pixel_en = 0;
        frame1_ok = 0;
        #40;
        // 帧2：违约——done 后继续拉 pixel_en（错误的 TB 行为）
        frame2_ok = 1;
        repeat (5) begin
            @(negedge clk);
            pixel_en = 1;
        end
        @(negedge clk); pixel_en = 0;
        frame2_ok = 0;
        #40;
        // 帧3：start 重启
        @(negedge clk); start = 1;
        @(negedge clk); start = 0;
        frame3_ok = 1;
        repeat (3) begin
            @(negedge clk);
            pixel_en = 1;
        end
        @(negedge clk); pixel_en = 0;
        frame3_ok = 0;
        #40;
        // 汇总
        if (done_cnt != 1) begin
            err_cnt = err_cnt + 1;
            $display("done count = %0d, expected 1", done_cnt);
        end
        $display("========================================");
        if (err_cnt == 0) $display("[PASS] coord_gen defense OK, done=%0d", done_cnt);
        else              $display("[FAIL] errors=%0d", err_cnt);
        $finish;
    end

endmodule