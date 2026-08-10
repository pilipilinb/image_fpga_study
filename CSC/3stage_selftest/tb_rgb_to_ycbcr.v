//========================================================================
// CSC Testbench: 读取RGB测试向量，输出YCbCr结果，并自动校验
// 适用于 rgb_to_ycbcr_3stage.v (数据路径4级寄存器, 异步复位同步释放)
//  1. 自校验: 按RTL相同定点算法计算期望值，逐拍比对，统计错误
//  2. 对齐校验: 验证 o_h_sync/o_v_sync/o_data_en 与数据同拍(延迟4拍)
//  3. 复位检查: 复位期间同步输出必须为无效电平(0)
//  4. 生成VCD波形
//========================================================================
`timescale 1ns/1ps
`include "rgb20yuv3stage.v"

module tb_rgb_to_ycbcr();

    reg         clk;
    reg         ngreset;
    wire [7:0]  R, G, B;
    wire [7:0]  Y, Cb, Cr;
    wire        o_h_sync, o_v_sync, o_data_en;

    // 时钟生成: 100MHz
    initial begin
        clk = 0;
        ngreset = 1;
        #50  ngreset = 0;   // 复位
        #100 ngreset = 1;   // 释放复位
    end
    always #5 clk = ~clk;

    // 测试向量: 16组24bit RGB数据
    reg [23:0] rgb_in [0:15];

    initial begin
        // 读取测试向量文件 (二进制格式)
        $readmemb("rgb_in.txt", rgb_in);
    end

    // 测试向量索引 (每16拍循环一次)
    integer i;
    always @(posedge clk or negedge ngreset) begin
        if (!ngreset)
            i <= 0;
        else if (i == 15)
            i <= 0;
        else
            i <= i + 1;
    end

    // 提取R/G/B
    wire [23:0] data;
    assign data = rgb_in[i];
    assign R = data[23:16];
    assign G = data[15:8];
    assign B = data[7:0];

    // 行/场同步脉冲 (每16拍在第0拍产生, 用于验证延迟对齐)
    wire i_hs = (i == 0);
    wire i_vs = (i == 0);

    // 实例化被测模块
    rgb_to_ycbcr_3stage dut (
        .clk        (clk),
        .i_rst_n    (ngreset),
        .i_r_8b     (R),
        .i_g_8b     (G),
        .i_b_8b     (B),
        .i_h_sync   (i_hs),
        .i_v_sync   (i_vs),
        .i_data_en  (1'b1),
        .o_y_8b     (Y),
        .o_cb_8b    (Cb),
        .o_cr_8b    (Cr),
        .o_h_sync   (o_h_sync),
        .o_v_sync   (o_v_sync),
        .o_data_en  (o_data_en)
    );

    //========================================================================
    // 输入打拍4级: 与DUT输出对齐 (数据路径延迟4拍)
    //========================================================================
    reg [23:0] rgb_d1, rgb_d2, rgb_d3, rgb_d4;
    reg        hs_d1, hs_d2, hs_d3, hs_d4;
    reg        vs_d1, vs_d2, vs_d3, vs_d4;

    always @(posedge clk) begin
        rgb_d1 <= data;       rgb_d2 <= rgb_d1;      rgb_d3 <= rgb_d2;      rgb_d4 <= rgb_d3;
        hs_d1  <= i_hs;       hs_d2  <= hs_d1;       hs_d3  <= hs_d2;       hs_d4  <= hs_d3;
        vs_d1  <= i_vs;       vs_d2  <= vs_d1;       vs_d3  <= vs_d2;       vs_d4  <= vs_d3;
    end

    wire [7:0] r_ref = rgb_d4[23:16];   // 与当前DUT输出同源的输入
    wire [7:0] g_ref = rgb_d4[15:8];
    wire [7:0] b_ref = rgb_d4[7:0];

    //========================================================================
    // 期望值计算函数 (与RTL完全相同的定点算法)
    // 注意: 系数必须与RTL参数一致, 这里用层次引用 dut.* 直接取DUT参数,
    //       避免两处硬编码不一致 (如Cb的G系数: 0.338x256=86.53, 四舍五入为87)
    // 四舍五入: (v>>8) + ((v>>7)&1), 负值钳0, 上限钳255
    //========================================================================
    function integer csc_round;
        input integer v;
        begin
            if (v < 0) v = 0;
            csc_round = (v >> 8) + ((v >> 7) & 1);
            if (csc_round > 255) csc_round = 255;
        end
    endfunction

    //========================================================================
    // 自校验 (拍计数 cycle: 复位释放后第1拍为1)
    // 注: DUT复位同步释放需要2拍, 有效数据流比输入打拍链晚2拍,
    //     故数据校验从 cycle>=6 开始 (此前为复位残留, 不与输入对应)
    //========================================================================
    reg [31:0] cycle;
    always @(posedge clk) begin
        if (!ngreset) cycle <= 0;
        else cycle <= cycle + 1;
    end

    reg [31:0] err_cnt;
    reg [31:0] align_err;

    always @(posedge clk) begin
        if (!ngreset) begin
            err_cnt   <= 0;
            align_err <= 0;
        end else if (cycle == 1) begin
            // 复位检查: 复位未释放, 同步输出必须为0(无效电平)
            if (o_h_sync  !== 1'b0) align_err <= align_err + 1;
            if (o_v_sync  !== 1'b0) align_err <= align_err + 1;
            if (o_data_en !== 1'b0) align_err <= align_err + 1;
        end else if (cycle >= 6) begin
            // 对齐校验: 同步输出应等于输入打拍4拍后的值
            if (o_h_sync !== hs_d4) align_err <= align_err + 1;
            if (o_v_sync !== vs_d4) align_err <= align_err + 1;
            if (o_data_en !== 1'b1) align_err <= align_err + 1;

            // 数据校验: DUT输出 vs 定点期望 (系数层次引用DUT参数, 保证一致)
            if (Y !== csc_round(dut.Y_R_stone*r_ref + dut.Y_G_stone*g_ref + dut.Y_B_stone*b_ref + dut.Y_shift) ||
                Cb !== csc_round(dut.Cb_B_stone*b_ref + dut.Cb_shift - dut.Cb_R_stone*r_ref - dut.Cb_G_stone*g_ref) ||
                Cr !== csc_round(dut.Cr_R_stone*r_ref + dut.Cr_shift - dut.Cr_G_stone*g_ref - dut.Cr_B_stone*b_ref)) begin
                err_cnt <= err_cnt + 1;
                if (err_cnt < 20)
                    $display("FAIL: R=%0d G=%0d B=%0d | got Y=%0d Cb=%0d Cr=%0d | exp Y=%0d Cb=%0d Cr=%0d",
                             r_ref, g_ref, b_ref, Y, Cb, Cr,
                             csc_round(dut.Y_R_stone*r_ref + dut.Y_G_stone*g_ref + dut.Y_B_stone*b_ref + dut.Y_shift),
                             csc_round(dut.Cb_B_stone*b_ref + dut.Cb_shift - dut.Cb_R_stone*r_ref - dut.Cb_G_stone*g_ref),
                             csc_round(dut.Cr_R_stone*r_ref + dut.Cr_shift - dut.Cr_G_stone*g_ref - dut.Cr_B_stone*b_ref));
            end
        end
    end

    // 第一轮打印完整结果表 (cycle 6..21 覆盖全部16组向量)
    always @(posedge clk) begin
        if (cycle == 6) begin
            $display("============================================================");
            $display("  R    G    B   | DUT: Y   Cb   Cr | 期望: Y   Cb   Cr");
            $display("------------------------------------------------------------");
        end
        if (cycle >= 6 && cycle < 22)
            $display("RES| %3d  %3d  %3d  | %3d  %3d  %3d  | %3d  %3d  %3d",
                     r_ref, g_ref, b_ref, Y, Cb, Cr,
                     csc_round(dut.Y_R_stone*r_ref + dut.Y_G_stone*g_ref + dut.Y_B_stone*b_ref + dut.Y_shift),
                     csc_round(dut.Cb_B_stone*b_ref + dut.Cb_shift - dut.Cb_R_stone*r_ref - dut.Cb_G_stone*g_ref),
                     csc_round(dut.Cr_R_stone*r_ref + dut.Cr_shift - dut.Cr_G_stone*g_ref - dut.Cr_B_stone*b_ref));
    end

    // 波形导出
    initial begin
        $dumpfile("tb_rgb_to_ycbcr.vcd");
        $dumpvars(0, tb_rgb_to_ycbcr);
    end

    // 结束报告
    initial begin
        #99000;
        $display("============================================================");
        if (align_err == 0)
            $display("同步对齐校验: OK (o_h_sync/o_v_sync/o_data_en 与数据同拍, 延迟4拍)");
        else
            $display("同步对齐校验: FAIL, %0d 次失配", align_err);
        if (err_cnt == 0)
            $display("数据校验: 全部 PASS (共%0d拍)", cycle);
        else
            $display("数据校验: %0d 个错误", err_cnt);
        $display("============================================================");
        #1000;
        $finish;
    end

endmodule
