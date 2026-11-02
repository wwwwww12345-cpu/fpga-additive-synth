// gtr_body.v -- 独立吉他琴体滤波（与 tools/gtr_body_int_model.py 逐位一致）
//
//   3 个并联 biquad (Direct Form I)，系数 Q14 有符号，来自 rtl/rom/gtr_body_coef.hex
//   排列: band0(b0,b1,b2,c3,c4), band1(...), band2(...)，其中 c3=-a1, c4=-a2
//   每 band: y = (c0*x + c1*x1 + c2*x2 + c3*y1 + c4*y2 + 2^13) >>> 14，结果取低 16 位回绕
//           **必须是四舍五入**（2026-10-22 修）：向下取整会让负的直流模态卡成不动点，
//           输出被钉在一个负直流上，v27 "后半段呼呼风声" 就是这条引起的，详见 yacc_rnd 注释
//   输出: body = x + y1 + y2 + y3（16 位回绕）
//   时序: sample_req 1 拍脉冲触发，串行乘加状态机 ~20 拍完成（采样间隔 1024 拍）
module gtr_body (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_req,
    input  wire signed [15:0] in_sample,
    output reg  signed [15:0] out_sample
);
    reg [15:0] coef [0:14];
    initial $readmemh("rtl/rom/gtr_body_coef.hex", coef);

    // 每 band 的 x/y 状态（16 位有符号）
    reg signed [15:0] bx1 [0:2], bx2 [0:2], by1 [0:2], by2 [0:2];
    reg signed [15:0] x_reg, yv_reg;
    reg signed [31:0] yacc, ytot;
    reg [1:0] band;
    reg [2:0] bs;
    integer bi;

    wire [2:0] cidx = (bs >= 3'd1 && bs <= 3'd5) ? (bs - 3'd1) : 3'd0;
    wire signed [15:0] c_sel = coef[band * 5 + cidx];
    wire signed [15:0] v_sel = (bs == 3'd1) ? x_reg :
                               (bs == 3'd2) ? bx1[band] :
                               (bs == 3'd3) ? bx2[band] :
                               (bs == 3'd4) ? by1[band] : by2[band];
    wire signed [31:0] c32 = {{16{c_sel[15]}}, c_sel};
    wire signed [31:0] v32 = {{16{v_sel[15]}}, v_sel};

    // ---- 状态截断 = 四舍五入，不是向下取整 ----
    //   病根(2026-10-22 定位/量化): 本节 DC 方向环路增益 = c3+c4 = 16381/16384 = 0.999817,
    //   每样本只损耗 0.000183*|y| 个 LSB。用 >>14(向下取整) 时 floor(0.999817*y) == y，
    //   损耗被整位丢掉 => 任何负的直流模态都成为**不动点**，永远回不到 0。
    //   证据(位精确模型, 60s demo): 静默段内部状态 y1=(-5063,-1358,-490) 整秒不变,
    //   输出挂在 -6765/-6647/-2140/-1726 LSB(约 -21% 满幅) 且每轮扫弦跳到新值;
    //   PCM5102A 因此永远进不了静音态 => ΔΣ 空闲音/图案噪声(听感=后半段"呼呼")。
    //   改为 +2^13 后取 [29:14] 后: 静默段恒为 +4 LSB(-78dBFS, 即静音), 且不累积。
    //   等价式 wrap16((yacc + 2^13) >> 14)，与两个整数模型逐位一致。
    //   代价: 1 个 32 位加法器, 0 DSP / 0 BSRAM。
    wire signed [31:0] yacc_rnd = yacc + 32'sd8192;
    wire signed [15:0] yv_q14   = yacc_rnd[29:14];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_sample <= 0;
            x_reg <= 0; yv_reg <= 0; yacc <= 0; ytot <= 0;
            band <= 0; bs <= 0;
            for (bi = 0; bi < 3; bi = bi + 1) begin
                bx1[bi] <= 0; bx2[bi] <= 0; by1[bi] <= 0; by2[bi] <= 0;
            end
        end else begin
            case (bs)
            3'd0: begin
                if (sample_req) begin
                    x_reg <= in_sample;
                    ytot <= 0; band <= 2'd0; bs <= 3'd1;
                end
            end
            3'd1: begin yacc <= c32 * v32;        bs <= 3'd2; end
            3'd2: begin yacc <= yacc + c32 * v32; bs <= 3'd3; end
            3'd3: begin yacc <= yacc + c32 * v32; bs <= 3'd4; end
            3'd4: begin yacc <= yacc + c32 * v32; bs <= 3'd5; end
            3'd5: begin yacc <= yacc + c32 * v32; bs <= 3'd6; end
            3'd6: begin
                // y = wrap16((yacc + 2^13) >>> 14)；移位状态寄存器
                yv_reg <= yv_q14;
                bx2[band] <= bx1[band]; bx1[band] <= x_reg;
                by2[band] <= by1[band]; by1[band] <= yv_q14;
                if (band == 2'd2) begin
                    // body = x + y1 + y2 + y3（赋给 16 位寄存器即回绕）
                    out_sample <= x_reg + ytot + yv_q14;
                    bs <= 3'd0;
                end else begin
                    ytot <= ytot + yv_q14;
                    band <= band + 2'd1;
                    bs <= 3'd1;
                end
            end
            default: bs <= 3'd0;
            endcase
        end
    end
endmodule
