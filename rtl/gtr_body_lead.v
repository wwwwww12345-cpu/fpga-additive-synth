// gtr_body_lead.v -- 吉他琴体：3 个并联 biquad（Q14，共用 1 个乘法器）
//
// 2026-11-01 资源优化（**逐位不变**，验收见 tb/tb_gtr_body_lead_bitref.v）：
//   旧版把 p0..p4 五条乘法并排写成 wire，综合器实例化 ~6 个 DSP（16x16 x3 + 16x24 x2）；
//   其实 FSM 每个状态只消费 1 个乘积。现在只写一个 16x24 有符号乘法：
//     st1..st3 的 x 项把 16bit 样本符号扩展到 24bit，数学上与旧版 16x16 完全等价；
//     st4/st5 的 y 反馈项本身就是 24bit。乘积 40bit 再符号扩展到 48bit 当作旧的 p0..p4。
//   16x24 在 GW5A 上占 2 个 18x18 切片 => DSP 6 -> 2，其余（累加顺序、+8192>>>14
//   四舍五入、状态更新）一字未改。
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
module gtr_body_lead (
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

    // 2026-11-02 二级优化（**逐位不变**，验收 tb/tb_gtr_body_lead_bitref.v）:
    //   上一版把 5 个乘法并成 1 个之后，乘法器的操作数是 "band*5+cidx → ROM → mux" 现取的，
    //   实测这条链 24.5 ns（SETUP −1.9）。现在每个 band 开始时把**该 band 的 5 个系数和
    //   4 个状态值一次锁存**（st0 锁 band0，st6 锁 band+1），乘法器只吃寄存器 + 5:1 小 mux。
    //   数值不变：这些量在 st1~st5 内本来就不变，锁存点取的也正是旧版同一拍会读到的值。
    reg signed [15:0] bc0, bc1, bc2, bc3, bc4;   // 本 band 的 c0..c4 (Q14)
    reg signed [15:0] bx1, bx2;                  // 本 band 的输入历史 (Q15)
    reg signed [23:0] by1, by2;                  // 本 band 的输出历史 (Q15.8)

    // 共享乘法器: 每个状态选一对**寄存**操作数，一周期只算一个乘积。
    //   宽度统一 16bit(系数 Q14) x 24bit(样本/状态); x 项先符号扩展 24bit（与旧 16x16 等价）。
    reg  signed [15:0] mul_a;
    reg  signed [23:0] mul_b;
    always @(*) begin
        case (st)
            4'd1:    begin mul_a = bc0; mul_b = {{8{xs[15]}},  xs};   end
            4'd2:    begin mul_a = bc1; mul_b = {{8{bx1[15]}}, bx1};  end
            4'd3:    begin mul_a = bc2; mul_b = {{8{bx2[15]}}, bx2};  end
            4'd4:    begin mul_a = bc3; mul_b = by1;                  end
            default: begin mul_a = bc4; mul_b = by2;                  end
        endcase
    end
    wire signed [39:0] prod40 = mul_a * mul_b;
    // 符号扩展到旧的 48bit 宽度（16x16 的结果因此与旧 p0..p2 逐位一致）
    wire signed [47:0] prod   = {{8{prod40[39]}}, prod40};

    // v29: 四舍五入后再取状态（+8192 = 2^14 / 2）
    wire signed [47:0] ynew_w = (acc + 48'sd8192) >>> 14;
    wire signed [23:0] ynew24 = ynew_w[23:0];          // Q15.8，喂回状态
    wire signed [15:0] ynew16 = ynew_w[23:8];          // Q15，用于输出求和

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= 0; band <= 0; xs <= 0; acc <= 0; ysum <= 0; ysum16 <= 0;
            bc0 <= 0; bc1 <= 0; bc2 <= 0; bc3 <= 0; bc4 <= 0;
            bx1 <= 0; bx2 <= 0; by1 <= 0; by2 <= 0;
            out_sample <= 0;
            for (k = 0; k < 3; k = k + 1) begin
                x1[k] <= 0; x2[k] <= 0; y1[k] <= 0; y2[k] <= 0;
            end
        end else begin
            case (st)
            4'd0: if (sample_req) begin
                xs <= in_sample; ysum <= 0; band <= 0; st <= 4'd1;
                // 锁存 band0 的系数/操作数
                bc0 <= coef[0]; bc1 <= coef[1]; bc2 <= coef[2]; bc3 <= coef[3]; bc4 <= coef[4];
                bx1 <= x1[0]; bx2 <= x2[0]; by1 <= y1[0]; by2 <= y2[0];
            end
            4'd1: begin acc <= prod <<< FRAC;             st <= 4'd2; end
            4'd2: begin acc <= acc + (prod <<< FRAC);     st <= 4'd3; end
            4'd3: begin acc <= acc + (prod <<< FRAC);     st <= 4'd4; end
            4'd4: begin acc <= acc + prod;                st <= 4'd5; end
            4'd5: begin acc <= acc + prod;                st <= 4'd6; end
            4'd6: begin
                x2[band] <= x1[band]; x1[band] <= xs;
                y2[band] <= y1[band]; y1[band] <= ynew24;
                ysum <= ysum + ynew16;
                if (band == 2'd2) st <= 4'd7;
                else begin
                    band <= band + 2'd1; st <= 4'd1;
                    // 锁存下一个 band 的系数/操作数（本拍不写那一组，取值与旧版一致）
                    bc0 <= coef[(band + 2'd1)*5 + 0];
                    bc1 <= coef[(band + 2'd1)*5 + 1];
                    bc2 <= coef[(band + 2'd1)*5 + 2];
                    bc3 <= coef[(band + 2'd1)*5 + 3];
                    bc4 <= coef[(band + 2'd1)*5 + 4];
                    bx1 <= x1[band + 2'd1]; bx2 <= x2[band + 2'd1];
                    by1 <= y1[band + 2'd1]; by2 <= y2[band + 2'd1];
                end
            end
            4'd7: begin out_sample <= xs + ysum[15:0]; st <= 4'd0; end
            default: st <= 4'd0;
            endcase
        end
    end
endmodule
