// ============================================================================
// gamma_core.v —— Gamma 伽马校正核（线性 RGB 10bit → RGB888，LAT=1）
//
// 算法（与 make_gamma_data.py 的 gamma_ref 位级同构）：
//   LUT[x] = clamp(floor(255·(x/1023)^(1/2.2) + 0.5), 0, 255)      x ∈ [0,1023]
//   out    = { LUT[R], LUT[G], LUT[B] }                            （三通道同拍并行查表）
//
// 【本模块 = 全链位宽缩减的唯一出口】★ 架构要点
//   线性 RGB 域全程 10bit（降噪/CCM 都不降位宽），位宽缩减统一在 Gamma 出口完成：
//     · LUT 内容离线预存 round 后的值 ⇒ 折算零硬件成本、零偏置（不用在数据通路上加东西）
//     · 与"感知域才是 8bit 显示域"的分域语义对齐；下游 VDMA 的 tdata[23:0] 契约由此给出
//   （对比：若在 Demosaic 出口就地 >>2 截断，会有 −0.375LSB 直流偏置，多级链上累积）
//
// 【为什么用 LUT 不算幂函数】
//   x^2.2 无硬件原语（要 exp/log 或 CORDIC）；而查表 1 拍出结果，且顺手把 10→8 办了
//
// 【资源换算（伪代码漏了"三通道三个读口"这一点）】
//   每通道 1024×8 = 8192 bit ≈ 半个 BRAM18（18Kb=18432bit 的 44%）
//   但 RGB 要**同拍**各查一次，而一个 BRAM18 只有 2 个读口 → 必须 **3 份副本**
//   ⇒ 3×8192 = 24576 bit ≈ 1 个 BRAM36（或占 2 个 BRAM18）
//   （伪代码的 "8bit 地址 → 2048bit → 半个 BRAM18" 也是错的：2048/18432 ≈ 11%）
//
// 【LAT = 1 与反压】
//   BRAM 自带输出寄存器：`dout <= {LUT_R[..], LUT_G[..], LUT_B[..]}` 一拍出结果。
//   run_en 直接当 **BRAM 读使能**（BRAM 的 EN 端口）→ 冻结时输出原地保持。
//   ⇒ 这就是"LAT=1 核直接当输出寄存器"的正确做法：**用使能门控**，
//     不需要额外 hold 寄存器（对比 M3 的 DPC：那里没有 BRAM 使能可用，才要 hold_in）
//
// 【复位】BRAM 阵列不可复位（物理无该管脚）；dout/dout_valid 用同步复位给定义值，
//   上电脏数据靠 valid 门控屏蔽（项目铁律）
// ============================================================================
`timescale 1ns/1ps

`ifndef GAMMA_CORE_V_INC
`define GAMMA_CORE_V_INC

module gamma_core #(
    parameter DW = 10,     // 输入单通道位宽（线性 RGB 域）
    parameter OW = 8       // 输出单通道位宽（RGB888）
)(
    input  wire            clk,
    input  wire            rst_n,
    input  wire [3*DW-1:0] din,        // {r,g,b}
    input  wire            din_valid,
    input  wire            run_en,     // = !stall：兼作 BRAM 读使能（冻结门控）
    output reg  [3*OW-1:0] dout,       // {r,g,b} 各 8bit
    output reg             dout_valid
);

    // ------------------------------------------------------------------------
    // 三份并行 LUT（同源同内容；为什么必须 3 份：见文件头"资源换算"）
    //   $readmemh 与 Python golden 同源生成 → 天然消除曲线/舍入不一致
    // ------------------------------------------------------------------------
    (* ram_style = "block" *) reg [OW-1:0] lutR [0:(1<<DW)-1];
    (* ram_style = "block" *) reg [OW-1:0] lutG [0:(1<<DW)-1];
    (* ram_style = "block" *) reg [OW-1:0] lutB [0:(1<<DW)-1];
    initial begin
        $readmemh("gamma_lut.coe", lutR);
        $readmemh("gamma_lut.coe", lutG);
        $readmemh("gamma_lut.coe", lutB);
    end

    // ------------------------------------------------------------------------
    // 拆分地址（"in 就是地址"——三通道各自的 10bit 值直接当查表地址）
    // ------------------------------------------------------------------------
    wire [DW-1:0] aR = din[3*DW-1 -: DW];
    wire [DW-1:0] aG = din[2*DW-1 -: DW];
    wire [DW-1:0] aB = din[   DW-1:   0];

    // ------------------------------------------------------------------------
    // 同步读（1 拍潜伏）+ 输出寄存 + 冻结保持
    // ------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout       <= {3*OW{1'b0}};
            dout_valid <= 1'b0;
        end else if (run_en) begin
            dout       <= {lutR[aR], lutG[aG], lutB[aB]};
            dout_valid <= din_valid;
        end
        // run_en=0（stall）：BRAM 读停 + 输出整组保持
    end

endmodule

`endif  // GAMMA_CORE_V_INC
