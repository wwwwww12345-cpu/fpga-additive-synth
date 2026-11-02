//=============================================================================
// gtr_body_lead_v29_ref.v —— **冻结的参考模型**（= 2026-10-30 的 gtr_body_lead.v 原文）
//   只改了一处：模块名 -> gtr_body_lead_ref。
//   用途：tb/tb_gtr_body_lead_bitref.v 把新版的 out_sample 与它逐样本比对，
//         要求 max|diff| = 0（逐位不变）。**不要改这个文件**；要改琴体请改
//         rtl/gtr_body_lead.v，然后重跑那个 tb。
//=============================================================================// gtr_body_lead.v -- 吉他琴体：3 个并联 biquad（Q14，共用 1 个乘法器）
//
// v29 (2026-10-26) 修 "呼呼"：
//   旧版状态只有 16bit，且 y = acc >>> 14 是**向下取整**。因为三个 band 都是
//   近直流极点（denominator 在 z=1 处只剩 3/16384），一个 LSB 的截断偏差会被
//   放大约 5288 倍，把状态死死钉在一个不动点上（实测每 band -5442 LSB，
//   合成输出恒定 -16326 LSB ≈ -5 %FS 的直流，且随弹奏漂移 → 耦合电容把它变成
//   "跟音一起出现的呼呼声"）。
//   修法：状态多保留 FRAC=8 位小数（24bit）并在移回 Q15 时**四舍五入**
//        → 量化误差降到 1/256 LSB，不动点消失（实测直流 -5 %FS → -0.006 %FS）。
//
//   位宽：系数 16bit(Q14)，状态 24bit(Q15 + 8 位小数)，累加器 48bit。
//         x 项先左移 8 位对齐到"Q15.8"，y 反馈项本身就是 Q15.8。
//   时序：sample_req 1 拍脉冲触发，串行乘加 ~23 拍完成（采样间隔 1024 拍）
module gtr_body_lead_ref (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_req,
    input  wire signed [15:0] in_sample,
    output reg  signed [15:0] out_sample
);
    localparam FRAC = 8;                       // 状态额外小数位

    reg [15:0] coef [0:14];
    initial $readmemh("rtl/rom/gtr_body_coef.hex", coef);

    reg signed [15:0] x1 [0:2], x2 [0:2];      // 输入历史（Q15）
    reg signed [23:0] y1 [0:2], y2 [0:2];      // 输出历史（Q15.8），v29 由 16bit 加宽
    reg signed [15:0] xs;
    reg signed [47:0] acc, ysum;
    reg signed [15:0] ysum16;
    reg [1:0] band;
    reg [3:0] st;
    integer k;

    // 系数按 band 取（signed 重解释）
    wire signed [15:0] c0 = coef[band*5+0];
    wire signed [15:0] c1 = coef[band*5+1];
    wire signed [15:0] c2 = coef[band*5+2];
    wire signed [15:0] c3 = coef[band*5+3];
    wire signed [15:0] c4 = coef[band*5+4];

    // 乘积：LHS 48bit 决定上下文宽度，16x16 / 16x24 都精确
    wire signed [47:0] p0 = c0 * xs;
    wire signed [47:0] p1 = c1 * x1[band];
    wire signed [47:0] p2 = c2 * x2[band];
    wire signed [47:0] p3 = c3 * y1[band];
    wire signed [47:0] p4 = c4 * y2[band];

    // v29: 四舍五入后再取状态（+8192 = 2^14 / 2）
    wire signed [47:0] ynew_w = (acc + 48'sd8192) >>> 14;
    wire signed [23:0] ynew24 = ynew_w[23:0];          // Q15.8，喂回状态
    wire signed [15:0] ynew16 = ynew_w[23:8];          // Q15，用于输出求和

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= 0; band <= 0; xs <= 0; acc <= 0; ysum <= 0; ysum16 <= 0;
            out_sample <= 0;
            for (k = 0; k < 3; k = k + 1) begin
                x1[k] <= 0; x2[k] <= 0; y1[k] <= 0; y2[k] <= 0;
            end
        end else begin
            case (st)
            4'd0: if (sample_req) begin xs <= in_sample; ysum <= 0; band <= 0; st <= 4'd1; end
            4'd1: begin acc <= p0 <<< FRAC;               st <= 4'd2; end
            4'd2: begin acc <= acc + (p1 <<< FRAC);       st <= 4'd3; end
            4'd3: begin acc <= acc + (p2 <<< FRAC);       st <= 4'd4; end
            4'd4: begin acc <= acc + p3;                  st <= 4'd5; end
            4'd5: begin acc <= acc + p4;                  st <= 4'd6; end
            4'd6: begin
                x2[band] <= x1[band]; x1[band] <= xs;
                y2[band] <= y1[band]; y1[band] <= ynew24;
                ysum <= ysum + ynew16;
                if (band == 2'd2) st <= 4'd7;
                else begin band <= band + 2'd1; st <= 4'd1; end
            end
            4'd7: begin out_sample <= xs + ysum[15:0]; st <= 4'd0; end
            default: st <= 4'd0;
            endcase
        end
    end
endmodule
