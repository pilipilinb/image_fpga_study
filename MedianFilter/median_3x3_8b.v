//========================================================================
// median_3x3_8b.v —— 8bit 3×3 中值滤波核（MedianFilter 工程，W4 非线性滤波）
//
// 功能：输入 3×3 窗口 9 个像素，输出其中值（第 5 大/小）：
//   out = median(w00..w22)
//
// 【为什么中值滤波（非线性）】
//   均值/高斯是线性滤波（加权平均），对椒盐噪声（脉冲 0/255）会把极值
//   抹开成灰斑；中值滤波把窗口排序取中间——窗口内椒盐极值点少于 5 个时，
//   中值必为真实像素，脉冲被直接剔除。
//
// 【行排序三部曲（19 比较器，用户校正版）】
//   找 9 个数的中值 ≠ 全排序（要几十个比较器），只需 19 个：
//   ① 每行 sort3（3 比较器/行 ×3 = 9）→ r_max, r_mid, r_min
//   ② 提取 3 候选（7 比较器）：
//        cand1 = max(三行 min)   ← 行最小值中的最大值（2 比较）
//        cand2 = mid(三行 mid)   ← 行中间值的中间值（3 比较）
//        cand3 = min(三行 max)   ← 行最大值中的最小值（2 比较）
//   ③ 中值 = mid(cand1, cand2, cand3)（3 比较）
//   总 9 + 7 + 3 = 19 比较器
//
// 【反例（为什么 cand2 必须是三行 mid 的中值，不能省成中行 mid）】
//   窗口 {{5,2,8},{4,9,1},{7,3,6}}：行 min 列 {2,1,3}、mid 列 {5,4,6}、
//   max 列 {8,9,7}，真中值 5。若 cand2 取"中行的 mid"=4 → mid(3,4,7)=4 ❌；
//   取三行 mid 的中值 = 5 → mid(3,5,7)=5 ✅。省 3 个比较器的"16 比较器
//   版本"是错误简化（本工程踩过的坑，见计划反例记录）。
//
// 【sort3 网络（3 输入全排序 → hi/mid/lo，3 比较器）】
//   cmp1: a vs b → ab_min, ab_max
//   cmp2: ab_max vs c → t_max, t_min   （hi = t_max）
//   cmp3: ab_min vs t_min → 小=lo, 大=mid
//
// 【流水】级1 三行排序（9 比较器）→ 级2 候选提取+取中（10 比较器）+输出
//   valid 链 LAT=2 与数据通路严格对齐（工程铁律：级数-LAT 一一对应）
// 复位：纯组合比较网络，仅输出寄存器异步复位
//========================================================================
`timescale 1ns/1ps

module median_3x3_8b (
    input               clk,
    input               rst_n,       // 低电平复位（异步）

    // 3×3 窗口，9 个 8bit 像素（p00=左上，p22=右下，行×列）
    input  [7:0]        p00, p01, p02,
    input  [7:0]        p10, p11, p12,
    input  [7:0]        p20, p21, p22,
    input               valid_in,    // 窗口有效（接行缓存 matrix_valid）

    output reg  [7:0]   dout,        // 中值（与 valid_out 同拍）
    output              valid_out
);

    localparam LAT = 2;              // 流水级数（valid 链对齐）

    //========================================================================
    // 级1：三行 sort3（每行 3 比较器，共 9）
    //   第0行 = (p00,p01,p02)，第1行 = (p10,p11,p12)，第2行 = (p20,p21,p22)
    //========================================================================
    wire [7:0] r0_hi, r0_mid, r0_lo;
    wire [7:0] r1_hi, r1_mid, r1_lo;
    wire [7:0] r2_hi, r2_mid, r2_lo;

    // sort3 展开：ab_min/ab_max（cmp1）→ t_min/t_max（cmp2）→ lo/mid（cmp3）
    // 行0
    wire [7:0] r0_abmin = (p00 <= p01) ? p00 : p01;
    wire [7:0] r0_abmax = (p00 <= p01) ? p01 : p00; //以上两个共用一个比较器
    wire [7:0] r0_tmax  = (r0_abmax >= p02) ? r0_abmax : p02;
    wire [7:0] r0_tmin  = (r0_abmax >= p02) ? p02 : r0_abmax;//以上两个共用一个比较器
    assign r0_hi  = r0_tmax;                                     // hi = 最大值
    assign r0_mid = (r0_abmin >= r0_tmin) ? r0_abmin : r0_tmin;
    assign r0_lo  = (r0_abmin >= r0_tmin) ? r0_tmin : r0_abmin;//以上两个共用一个比较器

    // 行1
    wire [7:0] r1_abmin = (p10 <= p11) ? p10 : p11;
    wire [7:0] r1_abmax = (p10 <= p11) ? p11 : p10;
    wire [7:0] r1_tmax  = (r1_abmax >= p12) ? r1_abmax : p12;
    wire [7:0] r1_tmin  = (r1_abmax >= p12) ? p12 : r1_abmax;
    assign r1_hi  = r1_tmax;
    assign r1_mid = (r1_abmin >= r1_tmin) ? r1_abmin : r1_tmin;
    assign r1_lo  = (r1_abmin >= r1_tmin) ? r1_tmin : r1_abmin;
    // 行2
    wire [7:0] r2_abmin = (p20 <= p21) ? p20 : p21;
    wire [7:0] r2_abmax = (p20 <= p21) ? p21 : p20;
    wire [7:0] r2_tmax  = (r2_abmax >= p22) ? r2_abmax : p22;
    wire [7:0] r2_tmin  = (r2_abmax >= p22) ? p22 : r2_abmax;
    assign r2_hi  = r2_tmax;
    assign r2_mid = (r2_abmin >= r2_tmin) ? r2_abmin : r2_tmin;
    assign r2_lo  = (r2_abmin >= r2_tmin) ? r2_tmin : r2_abmin;

    //========================================================================
    // 级2a（组合）：
    //   候选提取（7 比较器：max3 用 2、mid3 用 3、min3 用 2）
    //   cand1 = max(r0_lo, r1_lo, r2_lo)
    //   cand2 = mid(r0_mid, r1_mid, r2_mid)
    //   cand3 = min(r0_hi, r1_hi, r2_hi)
    //========================================================================
    wire [7:0] c1_ab = (r0_lo >= r1_lo) ? r0_lo : r1_lo;
    wire [7:0] cand1 = (c1_ab >= r2_lo) ? c1_ab : r2_lo;          // 2 比较器

    // cand2：三行 mid 用 sort3 网络取 mid（3 比较器，与行排序同结构）
    wire [7:0] c2_abmin = (r0_mid <= r1_mid) ? r0_mid : r1_mid;
    wire [7:0] c2_abmax = (r0_mid <= r1_mid) ? r1_mid : r0_mid;
    wire [7:0] c2_tmax  = (c2_abmax >= r2_mid) ? c2_abmax : r2_mid;
    wire [7:0] c2_tmin  = (c2_abmax >= r2_mid) ? r2_mid : c2_abmax;
    wire [7:0] cand2    = (c2_abmin >= c2_tmin) ? c2_abmin : c2_tmin; // 3 比较器

    wire [7:0] c3_ab = (r0_hi <= r1_hi) ? r0_hi : r1_hi;
    wire [7:0] cand3 = (c3_ab <= r2_hi) ? c3_ab : r2_hi;          // 2 比较器

    //========================================================================
    // 级2b（组合）：最终中值 = mid(cand1, cand2, cand3)（3 比较器）
    //   与 cand2 同一 sort3 网络取 mid
    //========================================================================
    wire [7:0] f_abmin = (cand1 <= cand2) ? cand1 : cand2;
    wire [7:0] f_abmax = (cand1 <= cand2) ? cand2 : cand1;
    wire [7:0] f_tmax  = (f_abmax >= cand3) ? f_abmax : cand3;
    wire [7:0] f_tmin  = (f_abmax >= cand3) ? cand3 : f_abmax;
    wire [7:0] median  = (f_abmin >= f_tmin) ? f_abmin : f_tmin;  // 3 比较器

    //========================================================================
    // 输出寄存 + valid 链（级1 行排序 → 级2 提取+取中：LAT=2）
    // 【对齐关键（本工程踩过的坑）】median 是组合结果，若只打 1 级寄存，
    // 输出会比 valid 链早 1 拍——valid_out 拉高时 dout 已被刷新成下一个窗口。
    // 必须打 2 级（median → d1 → dout）与 LAT=2 链严格同步：
    //   沿 T 前 valid_in=1（窗口 Wᵀ）→ d1<=median(Wᵀ)、chain0<=1
    //   沿 T+1 → dout<=median(Wᵀ)、chain1<=chain0=1 → valid_out=1 与 dout 同拍
    //========================================================================
    reg [7:0] d1;
    reg [LAT-1:0] valid_chain;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d1 <= 8'd0;
            dout <= 8'd0;
            valid_chain <= {LAT{1'b0}};
        end else begin
            d1   <= median;
            dout <= d1;
            valid_chain <= {valid_chain[LAT-2:0], valid_in};
        end
    end

    assign valid_out = valid_chain[LAT-1];

endmodule