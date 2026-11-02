// rvb_mono.v -- 单声道混响（Schroeder / Freeverb 精简版）
//
//   4 个并联梳状滤波器 + 2 个串联全通，16 位定点，单样本 12 拍（预算 516）。
//
//   为什么要这么写：
//   - 反馈系数取 3/4 与 1/2（二进制分数），乘法退化成移位+加法 => **0 个 DSP**
//     comb:  y[n] = x[n] + (3/4)·y[n-D]
//     allpass: v[n] = x[n] + (1/2)·v[n-D];  y[n] = -(1/2)·v[n] + v[n-D]
//   - 每条延迟线一个独立 RAM（深度取 2 的幂，工具各映射 1 块 BSRAM）
//     comb 深 1024（实际用 787/857/941/1003），allpass 深 256 / 1024（用 225 / 556）
//     => 6 块 BSRAM，总延迟约 4.4k 样本（~90 ms），够"听出混响"
//   - v33: 本模块只输出湿声 y = a1y >>> MIX_SHIFT；干湿混合在顶层做（dry + y*mix）
//
//   接口：每 sample_req 采一次，12 拍后 y 有效（y 比输入晚约 2 个样本，混响本身几十 ms，无所谓）
module rvb_mono #(
    parameter [9:0] D0 = 10'd787,
    parameter [9:0] D1 = 10'd857,
    parameter [9:0] D2 = 10'd941,
    parameter [9:0] D3 = 10'd1003,
    parameter [8:0] D4 = 9'd225,
    parameter [9:0] D5 = 10'd556,
    parameter [3:0] MIX_SHIFT = 4'd1        // 湿声按 1/2 混入；0 = 全湿叠加，2 = 1/4
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_req,
    input  wire signed [15:0] x,
    output reg  signed [15:0] y,
    output wire               busy
);
    // ---------------------------------------------------------------- 延迟线
    reg signed [15:0] m0 [0:1023];
    reg signed [15:0] m1 [0:1023];
    reg signed [15:0] m2 [0:1023];
    reg signed [15:0] m3 [0:1023];
    reg signed [15:0] m4 [0:255];
    reg signed [15:0] m5 [0:1023];

`ifndef SYNTHESIS
    // 仅仿真：存储器清零（板上 BSRAM 由配置初值，综合时这段被排除）
    integer ii;
    initial begin
        for (ii = 0; ii < 1024; ii = ii + 1) begin
            m0[ii] = 16'sd0; m1[ii] = 16'sd0; m2[ii] = 16'sd0;
            m3[ii] = 16'sd0; m5[ii] = 16'sd0;
        end
        for (ii = 0; ii < 256; ii = ii + 1) m4[ii] = 16'sd0;
    end
`endif

    reg [9:0] p0, p1, p2, p3, p5;
    reg [7:0] p4;

    function [9:0] nxt(input [9:0] p, input [9:0] d);
        nxt = (p == d - 10'd1) ? 10'd0 : (p + 10'd1);
    endfunction
    function [7:0] nxt4(input [7:0] p, input [8:0] d);
        nxt4 = (p == d[7:0] - 8'd1) ? 8'd0 : (p + 8'd1);
    endfunction

    function signed [15:0] sat16(input signed [17:0] v);
        sat16 = (v > 18'sd32767) ? 16'sd32767 : (v < -18'sd32768) ? -16'sd32768 : v[15:0];
    endfunction

    // ---------------------------------------------------------------- 流水
    reg        run;
    reg [3:0]  st;
    reg signed [15:0] xin;
    reg signed [15:0] d0r, d1r, d2r, d3r, d4r, d5r;
    reg signed [17:0] csum;                      // 4 路求和需要 18 位，避免回绕
    reg signed [15:0] v0, v1, v2, v3, w1;
    wire signed [15:0] ws  = sat16(csum >>> 2);       // 4 个梳状取平均
    // v34: 反馈 0.75 -> 0.875 (7/8 = 1/2+1/4+1/8)。
    //   原来 RT60 只有约 80ms, 比钢琴自身的衰减(0.7s+)还短, 混响被完全掩蔽,
    //   现场只能听到一点点电平变化、听不出空间感。0.875 后尾巴约 3 倍长。
    wire signed [16:0] c0m = (xin + (d0r >>> 1) + (d0r >>> 2) + (d0r >>> 3));   // x + 0.875*d
    wire signed [16:0] c1m = (xin + (d1r >>> 1) + (d1r >>> 2) + (d1r >>> 3));
    wire signed [16:0] c2m = (xin + (d2r >>> 1) + (d2r >>> 2) + (d2r >>> 3));
    wire signed [16:0] c3m = (xin + (d3r >>> 1) + (d3r >>> 2) + (d3r >>> 3));
    wire signed [17:0] a0v = (ws + (d4r >>> 1));                  // v = x + 0.5*d
    wire signed [17:0] a0y = (d4r - (a0v >>> 1));                 // y = d - 0.5*v
    wire signed [17:0] a1v = (w1 + (d5r >>> 1));
    wire signed [17:0] a1y = (d5r - (a1v >>> 1));

    assign busy = run;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= 4'd0; run <= 1'b0;
            xin <= 0; d0r<=0; d1r<=0; d2r<=0; d3r<=0; d4r<=0; d5r<=0;
            csum <= 0; v0<=0; v1<=0; v2<=0; v3<=0; w1<=0; y <= 0;
            p0<=0; p1<=0; p2<=0; p3<=0; p4<=0; p5<=0;
        end else begin
            if (sample_req && !run) begin
                xin <= x;
                run <= 1'b1;
                st  <= 4'd0;
                csum <= 18'sd0;
            end

            if (run) begin
                case (st)
                // ---- comb 0
                4'd0: begin d0r <= m0[p0]; st <= 4'd1; end
                4'd1: begin
                    v0 <= sat16(c0m); m0[p0] <= sat16(c0m);
                    csum <= sat16(c0m);
                    p0 <= nxt(p0, D0); st <= 4'd2;
                end
                // ---- comb 1
                4'd2: begin d1r <= m1[p1]; st <= 4'd3; end
                4'd3: begin
                    v1 <= sat16(c1m); m1[p1] <= sat16(c1m);
                    csum <= csum + sat16(c1m);
                    p1 <= nxt(p1, D1); st <= 4'd4;
                end
                // ---- comb 2
                4'd4: begin d2r <= m2[p2]; st <= 4'd5; end
                4'd5: begin
                    v2 <= sat16(c2m); m2[p2] <= sat16(c2m);
                    csum <= csum + sat16(c2m);
                    p2 <= nxt(p2, D2); st <= 4'd6;
                end
                // ---- comb 3
                4'd6: begin d3r <= m3[p3]; st <= 4'd7; end
                4'd7: begin
                    v3 <= sat16(c3m); m3[p3] <= sat16(c3m);
                    csum <= csum + sat16(c3m);
                    p3 <= nxt(p3, D3); st <= 4'd8;
                end
                // ---- allpass 0（csum 已含全部 4 个梳状）
                4'd8:  begin d4r <= m4[p4]; st <= 4'd9; end
                4'd9:  begin
                    m4[p4] <= sat16(a0v);
                    w1 <= sat16(a0y);
                    p4 <= nxt4(p4, D4); st <= 4'd10;
                end
                // ---- allpass 1
                4'd10: begin d5r <= m5[p5]; st <= 4'd11; end
                4'd11: begin
                    m5[p5] <= sat16(a1v);
                    // v33: 只输出**湿声**。原来这里写成 xin + (a1y>>>MIX_SHIFT),
                    //   把干声也包进了 y; 而顶层又加一次干声(audio_out_att + y*mix),
                    //   于是 0x89 实际变成"干声增益旋钮": mix=127 时干声被放大 2 倍、
                    //   顶到饱和, 湿声被淹没 -> 现场测不出混响差别。
                    y <= sat16(sat16(a1y) >>> MIX_SHIFT);
                    p5 <= nxt(p5, D5); st <= 4'd0; run <= 1'b0;
                end
                default: begin st <= 4'd0; run <= 1'b0; end
                endcase
            end
        end
    end
endmodule
