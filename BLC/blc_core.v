// ============================================================================
// 模块：blc_core —— 黑电平校正核（简流，纯逐像素点运算，零行缓存）
//
// 算法：p_out = max(p_in - OB[ch], 0)
//   OB[ch] 按 Bayer 相位 (row&1, col&1) 从四个可配偏置 OB_00/OB_01/OB_10/OB_11 中选。
//
// 【为什么要 BLC】CMOS 像素在无光照（遮光/OB 区）时也有暗电流导致的非零底电平；
//   不减掉它，后级增益/AWB/伽马会被这个底抬灰。四个通道的暗电流并不相同
//   （R/Gr/Gb/B 的响应与工艺偏差不同），共用一个值会让暗部偏色 → 分别标定。
//
// 【减法为什么必须饱和（不能环绕）】in - offset 若用无符号 8/10bit 直接减，
//   in < offset 时会环绕成大数（如 3-5=1021），暗点变亮点。两种等价 RTL 写法：
//     写法甲：扩 1 位有符号减：diff = {1'b0,in} - {1'b0,offset}（9/11bit）；
//             out = diff[MSB] ? 0 : diff[DW-1:0] —— 需要 DW+1 位减法通路
//     写法乙（本模块采用）：out = (in < offset) ? 0 : (in - offset)
//             —— 一个 DW 位比较器 + 一个 DW 位减法器 + 一个 mux，
//             没有 DW+1 位通路，减法器输入恒有 in >= offset，天然不借位。
//   两写法资源相当（比较器本来就要有），写法乙少一截进位链且可读性好。
//
// 【相位与流水对齐（本模块唯一的"对齐"难点）】
//   相位 = {row[0], col[0]}，由输入侧计数器生成，与 in_data 同拍；OB 选择用
//   "当前拍"的相位（此时像素和相位在同一个拍上）→ 选择结果与像素一起打 1 拍
//   寄存 → out_data 与 out_phase 天然同拍对齐。sof 清零计数器（显式帧同步，
//   替代"帧末回绕"——计数器回绕是本项目踩过的相位错位坑）；eol 拍列归零、行 +1，
//   并顺带强对齐（eol 到拍若列计数不在 W-1，以 eol 为准，等于免费的一致性保险）。
//
// 【反压（1 级流水）】下游 out_ready=0 且输出寄存器有字（stall）→ in_ready=0
//   冻结输入与计数器；输出寄存器保持（简流稳定性：valid 未 ready 时字段不变）。
//   减法是纯组合 + 1 级寄存，冻结零成本。
// ============================================================================
`timescale 1ns/1ps

module blc_core #(
    parameter DW      = 10,        // 像素位宽（RAW10；8bit sensor 场景传 8）
    parameter IMG_W   = 640,       // 行宽（列计数回绕兜底：eol 偶发丢失时 1 行内自愈）
    parameter IMG_H   = 480,       // 帧高（行计数位宽由此推导）
    parameter BAYER_PATTERN = 2'b00 // 语义标注（RGGB 默认）：OB_00=R、OB_01=Gr、
                                       //   OB_10=Gb、OB_11=B。不同 pattern 时由软件把
                                       //   标定值写进对应相位的槽位，硬件逻辑不依赖此参数
)(
    input  wire          clk,
    input  wire          rst_n,        // 低有效
    // ---- 入侧简流 ----
    input  wire          in_valid,
    output wire          in_ready,     // 输出寄存器被下游占住时为 0（反压冻结）
    input  wire [DW-1:0] in_data,
    input  wire          in_sof,       // 帧首（=tuser）
    input  wire          in_eol,       // 行末（=tlast）
    // ---- 黑电平偏置（寄存器可配：集成时接 AXI-Lite 寄存器，随增益分档由软件重写）----
    input  wire [DW-1:0] ob_00,        // (row&1,col&1)=(0,0)：RGGB 下 = R
    input  wire [DW-1:0] ob_01,        // (0,1)：RGGB 下 = Gr
    input  wire [DW-1:0] ob_10,        // (1,0)：RGGB 下 = Gb
    input  wire [DW-1:0] ob_11,        // (1,1)：RGGB 下 = B
    // ---- 出侧简流 ----
    output wire          out_valid,
    input  wire          out_ready, //下游模块提供
    output wire [DW-1:0] out_data,     // max(p - OB, 0)，饱和只 clamp 低边（减法无上溢）
    output wire          out_sof,
    output wire          out_eol,
    output wire [1:0]    out_phase     // 输出像素的 Bayer 相位 {row&1, col&1}，供 DPC/Demosaic 直接用
);

    // ---- 输入侧相位计数器（完整行列计数，DPC/top_dpc.v 同构风格）----
    // 【计数器语义（不变式）】fire 拍读到的 {row_cnt[0], col_cnt[0]} == 当前正在消费
    //   像素的 Bayer 相位；拍末推进到"下一像素"的坐标。三处容易写错的地方（都踩过）：
    //   ① sof 拍不能把 col 清零了事——本拍消费的就是 (0,0)，拍末必须推进到 1，
    //     否则下一拍 (0,1) 读到 0，整帧相位斜一列（首帧全错位的根因）。
    //   ② 跨帧行奇偶残留：上帧末 row_cnt=H，若 H 为奇，下一帧 sof 拍读到 1。
    //     解法：sof 拍的 OB 选择与 out_phase 强制 00（sof 拍像素恒为 (0,0)），
    //     同时 row_cnt 拍末清零——从下一拍起整帧相位严格对齐。
    //   ③ 与 DPC 老写法的关键差别：不靠 IMG_H/IMG_W 盲数数感知边界（丢 1 拍就永久
    //     错位无自愈），而是 sof/eol 显式同步——上游任何丢拍最多错到下一个 eol/sof。
    //     col 回绕仅作 eol 偶发丢失的兜底，正常流两者一致。
    localparam AW = $clog2(IMG_W);
    localparam RW = $clog2(IMG_H + 2);      // row_cnt 一帧内最大到 H（最后 eol 拍 +1）
    reg [RW-1:0] row_cnt;                   // 行计数：相位只取 [0]，sof 每帧清零
    reg [AW-1:0] col_cnt;                   // 列计数：相位取 [0]

    wire fire = in_valid && in_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_cnt <= {RW{1'b0}};
            col_cnt <= {AW{1'b0}};
        end
        else if (fire) begin
            if (in_sof) begin
                row_cnt <= {RW{1'b0}};              // 新帧从行 0 开始
                col_cnt <= {{(AW-1){1'b0}}, 1'b1};  // `col_cnt <= 1` 不是“当前拍是第 1 列”，而是“ 下一拍 是第 1 列”
            end
            else if (in_eol) begin
                col_cnt <= {AW{1'b0}};              // 行末：下一拍是新行第 0 列
                row_cnt <= row_cnt + 1'b1;
            end
            else begin
                col_cnt <= (col_cnt == IMG_W - 1) ? {AW{1'b0}} : (col_cnt + 1'b1);
            end
        end
    end

    // ---- OB 通道选择（用当前拍相位；与像素同拍，无对齐问题）----
    // sof 拍强制 00：该像素恒为 (0,0)，同时抹掉跨帧行奇偶残留（见上②）
    // 写法乙：先比较再减，省掉 DW+1 位减法通路（见头部说明）
    reg [DW-1:0] ob_sel;
    reg [1:0]    ph_cur;
    always @(*) begin
        ph_cur = in_sof ? 2'b00 : {row_cnt[0], col_cnt[0]};
        case (ph_cur)
            2'b00: ob_sel = ob_00;
            2'b01: ob_sel = ob_01;
            2'b10: ob_sel = ob_10;
            default: ob_sel = ob_11;
        endcase
    end

    wire [DW-1:0] diff = in_data - ob_sel;                 // 仅在 in_data >= ob_sel 时被采用（不借位）
    wire [DW-1:0] sub_res = (in_data < ob_sel) ? {DW{1'b0}} : diff;

    // ---- 1 级流水输出寄存器 + 反压冻结 ----
    reg          out_valid_r;
    reg [DW-1:0] out_data_r;
    reg          out_sof_r, out_eol_r;
    reg [1:0]    out_phase_r;

    wire stall = out_valid_r && !out_ready;    // 下游占住输出寄存器
    assign in_ready = !stall;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid_r <= 1'b0;
            out_data_r  <= {DW{1'b0}};
            out_sof_r   <= 1'b0;
            out_eol_r   <= 1'b0;
            out_phase_r <= 2'b00;
        end
        else if (!stall) begin
            out_valid_r <= fire;
            if (fire) begin
                out_data_r  <= sub_res;
                out_sof_r   <= in_sof;
                out_eol_r   <= in_eol;
                out_phase_r <= ph_cur;             // 与像素同拍锁存 → 天然对齐
            end
        end
        // stall：保持全部输出字段（简流稳定性）
    end

    assign out_valid = out_valid_r;
    assign out_data  = out_data_r;
    assign out_sof   = out_sof_r;
    assign out_eol   = out_eol_r;
    assign out_phase = out_phase_r;

endmodule
