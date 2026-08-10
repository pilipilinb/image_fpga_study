//========================================================================
// coord_gen.v —— 定点累加坐标生成器（bilinear_v3 版）
// 功能：为双线性插值缩放生成源坐标 (src_x_int, src_y_int) 与权重 (u_frac, v_frac)
//       每输出像素一拍，累加式生成，运行期无乘除（除法只在编译期 localparam 完成）
//
// 来源：清洗 bilinear_v2/coord_gen.v，差异如下：
//   1. 保留：STEP_X/Y 编译期四舍五入、x/y 累加器、行末换行清零逻辑（算法零改动）
//   2. 修正：权重取小数低 FRAC_BITS 位（v2 取高 8 位丢精度，见 v2 L54-55）
//   3. 补充：start 帧启动、valid_out 逐拍有效（v2 只有帧末 frame_done，
//            上游无法知道"哪拍坐标有效"）
//   4. 收紧：src_x_int/src_y_int 位宽 = $clog2(IN)+1（v2 写死 16 位）
//
// 定点化：源坐标 = 累加值 / 2^FRAC_BITS
//   整数部分 = 源坐标，小数部分 = 插值权重
//   src = dst × (IN/OUT)，STEP = (IN << FRAC_BITS) / OUT（四舍五入）
//
// 适用：整数倍放大（OUT = IN × SCALE，由顶层代入 OUT_WIDTH/OUT_HEIGHT）
//   STEP ≈ (1<<FRAC_BITS)/SCALE < 2^FRAC_BITS，源坐标单调递增、不跳读
//
// 时序语义：pixel_en 有效拍，src_x_int/src_y_int/u_frac/v_frac 为组合直通
//   当前像素的坐标与权重（valid_out 同拍拉高）；该拍时钟沿后累加器推进到下一像素。
//   done 帧末组合标志；帧结束后 TB 应停 pixel_en 或拉 start 开始新帧。
//   帧内防御：frame_active 标志，最后一像素沿后清零且 y 不再推进；
//   此后即使上游误拉 pixel_en，valid_out 拉低、坐标冻结在界内 (0, IN_H-1)，不越界。
//========================================================================
`timescale 1ns/1ps

module coord_gen #(
    parameter IN_WIDTH   = 112,     // 输入图像宽
    parameter IN_HEIGHT  = 103,     // 输入图像高
    parameter OUT_WIDTH  = 224,     // 输出图像宽（= IN_WIDTH × SCALE，顶层代入）
    parameter OUT_HEIGHT = 206,     // 输出图像高（= IN_HEIGHT × SCALE）
    parameter FRAC_BITS  = 8,       // 定点小数位（与插值核位宽绑定，冻结 8）
    // 派生位宽（参数间可引用，供端口声明使用）
    parameter XW = $clog2(IN_WIDTH)  + 1,   // src_x_int 位宽：clog2(IN)+1，容纳累加溢出到 IN 的边界值
    parameter YW = $clog2(IN_HEIGHT) + 1    // src_y_int 位宽
)(
    input                       clk,
    input                       rst_n,       // 低电平复位（异步）
    input                       start,       // 帧启动：拉高一拍清零帧状态并开始
    input                       pixel_en,    // 逐拍推进：每输出像素一拍
    output [XW-1:0]             src_x_int,   // 源 x 整数部分（组合直通，与 pixel_en 同拍有效）
    output [YW-1:0]             src_y_int,   // 源 y 整数部分
    output [FRAC_BITS-1:0]      u_frac,      // x 方向权重（小数部分，0~1 对应 0~2^FB-1）
    output [FRAC_BITS-1:0]      v_frac,      // y 方向权重
    output                      valid_out,   // 坐标/权重有效（组合 = pixel_en && frame_active）
    output                      done         // 帧末标志（组合）
);

    //========================================================================
    // 内部位宽与步进
    //========================================================================
    // 累加器位宽 = 整数部分 XW 位 + 小数 FRAC_BITS 位
    // 最大累加值 ~ IN<<FRAC_BITS，需 clog2(IN)+FRAC_BITS 位，XW 多 1 位余量
    localparam ACC_W = FRAC_BITS + XW;
    // 输出计数器位宽（0..OUT-1）
    localparam CXW = $clog2(OUT_WIDTH);
    localparam CYW = $clog2(OUT_HEIGHT);

    // 步进值 = (输入尺寸 << FRAC_BITS) / 输出尺寸，+OUT/2 实现四舍五入
    localparam STEP_X = ((IN_WIDTH  << FRAC_BITS) + OUT_WIDTH/2)  / OUT_WIDTH;
    localparam STEP_Y = ((IN_HEIGHT << FRAC_BITS) + OUT_HEIGHT/2) / OUT_HEIGHT;

    //========================================================================
    // 累加器与计数器
    //========================================================================
    reg [ACC_W-1:0] x_accum, y_accum;//源域：表示当前输出的像素对应源图哪个位置（含小数权重），定点数累加
    reg [CXW-1:0]   x_cnt;//输出域，即当前该输出的是第几个像素,步长为1，整数累加
    reg [CYW-1:0]   y_cnt;
    reg             frame_active;   // 帧内标志：start 置 1，最后一像素沿后清 0（防御越界喂像素）

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_cnt        <= {CXW{1'b0}};
            y_cnt        <= {CYW{1'b0}};
            x_accum      <= {ACC_W{1'b0}};
            y_accum      <= {ACC_W{1'b0}};
            frame_active <= 1'b0;
        end
        else if (start) begin
            // 帧启动：清零帧状态（优先级高于 pixel_en，start 期间 pixel_en 应保持 0）
            x_cnt        <= {CXW{1'b0}};
            y_cnt        <= {CYW{1'b0}};
            x_accum      <= {ACC_W{1'b0}};
            y_accum      <= {ACC_W{1'b0}};
            frame_active <= 1'b1;
        end
        else if (pixel_en && frame_active) begin
            if (x_cnt == OUT_WIDTH - 1) begin
                // 行末：x 清零换行，y 累加 +STEP_Y（最后一行帧末不推进 y，避免源坐标越界）
                x_cnt   <= {CXW{1'b0}};
                x_accum <= {ACC_W{1'b0}};
                if (y_cnt == OUT_HEIGHT - 1) begin
                    // 帧末：本拍正是最后一像素，y 不再推进（避免源坐标越界），沿后关帧
                    frame_active <= 1'b0;
                end
                else begin
                    y_cnt   <= y_cnt + 1'b1;
                    y_accum <= y_accum + STEP_Y;
                end
            end
            else begin
                x_cnt   <= x_cnt + 1'b1;
                x_accum <= x_accum + STEP_X;
            end
        end
    end

    //========================================================================
    // 输出：坐标 = 累加值整数部分，权重 = 累加值小数部分（取低 FRAC_BITS 位）
    //========================================================================
    assign src_x_int = x_accum[ACC_W-1 : FRAC_BITS];
    assign src_y_int = y_accum[ACC_W-1 : FRAC_BITS];
    assign u_frac    = x_accum[FRAC_BITS-1 : 0];   // 全保留小数位（v2 取高 8 位丢精度）
    assign v_frac    = y_accum[FRAC_BITS-1 : 0];
    // valid_out 门控 frame_active：帧末沿后误拉的 pixel_en 不产生有效像素，
    // 上游读组合时看到 valid_out=0 即不会取数（坐标已冻结在尾像素）
    assign valid_out = pixel_en && frame_active;   // 组合直通，与坐标/权重同拍有效
    assign done      = (y_cnt == OUT_HEIGHT - 1) && (x_cnt == OUT_WIDTH - 1);

endmodule