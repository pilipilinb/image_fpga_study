//========================================================================
// tb_bilinear_interp.v —— bilinear_interp_8b 自检 TB（计划 Step 2 验证）
// 验证内容：
//   1. 边界用例：u/v 四角 0/255、纯色、0.5 权重舍入、饱和 255
//   2. 随机用例：$random 生成权重与 4 像素，与定点参考模型逐拍比对
//   3. valid 链：每 50 拍插 3 拍无效，验证 valid_out 无假有效、无漏有效
// 参考模型：与 RTL 同定点算法（1-u = 256-u，四项和右移 16 + 舍入位 + 饱和）
// 比对方式：参考队列（FIFO）——valid_in 时压入参考值，valid_out 时弹出比对，
//           以 DUT 自身 valid 链为同步基准，天然对齐，同时验证 valid 与数据一致
//========================================================================
`timescale 1ns/1ps
`include "bilinear_interp_8b.v"

module tb_bilinear_interp;

    localparam FB  = 8;
    localparam QDEPTH = 4096;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg [FB-1:0] u_frac = 8'd0, v_frac = 8'd0;
    reg [7:0] p00 = 8'd0, p01 = 8'd0, p10 = 8'd0, p11 = 8'd0;
    reg valid_in = 1'b0;
    wire [7:0] pix_out;
    wire valid_out;

    bilinear_interp_8b #(.FRAC_BITS(FB)) dut (
        .clk(clk), .rst_n(rst_n),
        .u_frac(u_frac), .v_frac(v_frac),
        .p00(p00), .p01(p01), .p10(p10), .p11(p11),
        .valid_in(valid_in),
        .pix_out(pix_out), .valid_out(valid_out)
    );

    always #5 clk = ~clk;

    //---- 参考模型（与 RTL 同定点算法）----
    function integer ref_interp;
        input [7:0] u, v;
        input [7:0] a, b, c, d;
        integer w00, w01, w10, w11, sum, rounded;
        begin
            w00 = (256-u) * (256-v);
            w01 = u * (256-v);
            w10 = (256-u) * v;
            w11 = u * v;
            sum = w00*a + w01*b + w10*c + w11*d;
            rounded = (sum >> 16) + ((sum >> 15) & 1);
            ref_interp = (rounded > 255) ? 255 : rounded;
        end
    endfunction

    //---- 参考队列（valid_in 压入 / valid_out 弹出比对）----
    integer queue [0:QDEPTH-1];
    integer q_head = 0, q_tail = 0, q_count = 0;
    integer err_cnt = 0, total_chk = 0;

    //---- 激励生成（negedge 更新，避开 posedge 竞争）----
    task set_input;
        input [7:0] u, v, a, b, c, d;
        begin
            u_frac = u; v_frac = v;
            p00 = a; p01 = b; p10 = c; p11 = d;
            if (valid_in) begin
                queue[q_tail] = ref_interp(u, v, a, b, c, d);
                q_tail = (q_tail + 1) % QDEPTH;
                q_count = q_count + 1;
            end
        end
    endtask

    //---- 输出比对（posedge 后 #1 读寄存器输出，以 DUT valid_out 为触发）----
    always @(posedge clk) begin
        #1;
        if (valid_out) begin
            total_chk = total_chk + 1;
            if (q_count == 0) begin
                err_cnt = err_cnt + 1;
                $display("QUEUE UNDERFLOW (false valid_out) @%0t pix=%0d", $time, pix_out);
            end else begin
                if (pix_out !== queue[q_head]) begin
                    err_cnt = err_cnt + 1;
                    if (err_cnt <= 10)
                        $display("MISMATCH @%0t: got %0d exp %0d", $time, pix_out, queue[q_head]);
                end
                q_head = (q_head + 1) % QDEPTH;
                q_count = q_count - 1;
            end
        end
    end

    integer n;

    initial begin
        $dumpfile("tb_bilinear_interp.vcd");
        $dumpvars(0, tb_bilinear_interp);

        #25 rst_n = 1;
        @(negedge clk);

        //---- 边界用例（每拍一个，valid_in=1）----
        valid_in = 1'b1;
        set_input(8'd0,   8'd0,   8'd17, 8'd0,  8'd0,  8'd0);   @(negedge clk);  // u=v=0    → p00
        set_input(8'd255, 8'd0,   8'd0,  8'd17, 8'd0,  8'd0);   @(negedge clk);  // u=1,v=0  → p01
        set_input(8'd0,   8'd255, 8'd0,  8'd0,  8'd17, 8'd0);   @(negedge clk);  // u=0,v=1  → p10
        set_input(8'd255, 8'd255, 8'd0,  8'd0,  8'd0,  8'd17);  @(negedge clk);  // u=v=1    → p11
        set_input(8'd89,  8'd200, 8'd128,8'd128,8'd128,8'd128); @(negedge clk);  // 纯色     → 128
        set_input(8'd128, 8'd128, 8'd255,8'd255,8'd255,8'd255); @(negedge clk);  // 全 255   → 255（饱和）
        set_input(8'd1,   8'd1,   8'd0,  8'd0,  8'd0,  8'd0);   @(negedge clk);  // 全 0     → 0
        set_input(8'd128, 8'd128, 8'd0,  8'd255,8'd255,8'd0);   @(negedge clk);  // 水平两项 → (255+255)/4=127.5→128
        set_input(8'd128, 8'd128, 8'd255,8'd0,  8'd0,  8'd255); @(negedge clk);  // 对角     → 128
        set_input(8'd0,   8'd0,   8'd255,8'd128,8'd64, 8'd32);  @(negedge clk);  // u=v=0    → p00=255

        //---- 随机用例（2000 拍：先设置再等待，避免上一拍残留被重复采样；
        //     每 50 拍插 3 拍无效验证 valid 链）----
        for (n = 0; n < 2000; n = n + 1) begin
            if ((n % 50) >= 47) begin
                valid_in = 1'b0;
            end else begin
                valid_in = 1'b1;
                set_input(($random & 8'hFF), ($random & 8'hFF),
                          ($random & 8'hFF), ($random & 8'hFF),
                          ($random & 8'hFF), ($random & 8'hFF));
            end
            @(negedge clk);
        end

        //---- 冲刷流水线（先置无效再等待，验证 valid 链清空）----
        valid_in = 1'b0;
        for (n = 0; n < 12; n = n + 1) begin
            @(negedge clk);
        end
        #40;

        //---- 汇总 ----
        $display("========================================");
        if (err_cnt == 0 && total_chk > 0 && q_count == 0)
            $display("[PASS] bilinear_interp_8b OK, %0d checks, queue drained", total_chk);
        else
            $display("[FAIL] errors=%0d checks=%0d queue_left=%0d", err_cnt, total_chk, q_count);
        $finish;
    end

endmodule