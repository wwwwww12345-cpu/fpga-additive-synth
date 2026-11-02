// dc_block.v -- 吉他输出直流阻断 + 静音门（v29）
//
//   为什么需要：gtr_body 的三个 biquad 都是近直流极点（Q≈4、f0≈100/210/330Hz），
//   定点状态里任何一点 DC 都会被放大成持续的低频摆动；DAC 端一旦有直流，
//   PCM5102A 的 ΔΣ 就永远进不了零输入态（空闲音/静音门失效）。
//
//   实现：不直接用 y = x - x1 + a*y1 的反馈式（那条式子在 Verilog 里极易踩符号坑：
//   拼接是**无符号**，参数参与乘法时也可能被当无符号，结果右移变成逻辑右移、
//   负的 y1 会把 acc 抬到 +131041 → 直接饱和到 +32767，反而制造一个满幅 DC）。
//   这里改成"慢均值估计 + 相减"，全是有符号 32bit 加减和算术右移，没有乘法：
//
//       mean' = mean + ((x*256 - mean) >>> SHIFT)   // mean 存 Q15.8, 一阶低通 fc ≈ 15 Hz
//       y     = x - (mean' >>> 8)                   // 高通, 通带增益 1
//
//   mean 多留 8 位小数是必须的：直接对 16bit 均值做 >>9 会有 ±512 LSB 的死区
//   （|x-mean| < 512 时增量为 0，均值就停在那儿），实测残留 DC = +257 LSB；
//   多 8 位小数后死区降到 1 LSB（实测残留 +0.005 %FS）。
//
//   再接静音门：连续 GATE_HOLD 个采样都 |y| < GATE_THR 就把输出强制清零，
//   让 DAC 真正收到零输入、能进静音态。
module dc_block #(
    parameter        [4:0]  SHIFT     = 5'd9,        // 9 -> fc ≈ 15 Hz
    // v30: 门限从 256 降到 16。原值 256 是照交接文档抄的, 但那只适合"琴体输出接近满幅"的
    //      假设; 实际吉他单音在琴体输出上的峰值只有 ~1000 LSB, 256(-42dBFS) 相当于在
    //      **衰减 12 dB 处**就把尾音清零 -> 用户听到"C4 一拍半、B4/C5 超短、突然收尾"。
    //      16 LSB = -66 dBFS, 在音符峰值下 36 dB, 听不出来。
    parameter signed [15:0] GATE_THR  = 16'sd16,
    parameter        [15:0] GATE_HOLD = 16'd4096     // ≈84 ms
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_req,             // 48.8k 采样节拍
    input  wire signed [15:0] in_sample,
    output reg  signed [15:0] out_sample
);
    reg  signed [31:0] mean;                   // Q15.8 的直流估计
    reg  [15:0] quiet;

    wire signed [31:0] x32    = {{16{in_sample[15]}}, in_sample};
    wire signed [31:0] xtgt   = x32 <<< 8;                    // x * 256
    wire signed [31:0] dif    = xtgt - mean;
    wire signed [31:0] mean_n = mean + (dif >>> SHIFT);
    wire signed [31:0] mean16 = (mean_n + 32'sd128) >>> 8;    // 回到 Q15（四舍五入）
    wire signed [31:0] y32    = x32 - mean16;
    wire signed [15:0] ysat   = (y32 > 32'sd32767)  ? 16'sd32767 :
                                (y32 < -32'sd32768) ? -16'sd32768 :
                                                      y32[15:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mean <= 32'sd0; quiet <= 16'd0; out_sample <= 16'sd0;
        end else if (sample_req) begin
            mean <= mean_n;
            if ((ysat < GATE_THR) && (ysat > -GATE_THR)) begin
                if (quiet < GATE_HOLD) begin
                    quiet <= quiet + 16'd1;
                    out_sample <= ysat;
                end else begin
                    out_sample <= 16'sd0;
                end
            end else begin
                quiet <= 16'd0;
                out_sample <= ysat;
            end
        end
    end
endmodule
