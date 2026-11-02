//=============================================================================
// sine_lut_full.v —— 整周期满表 + 线性插值（**只改表结构，不改插值这件事**）
//
// 变量分解（2026-10-14 判决后）：
//   ① 表几何: 257 点 1/4 波 + 象限镜像   vs   1024 点整周期
//   ② 插值:   线性插值                   vs   不插值(直接查表)
//   已知(实听, 整数分频时钟):
//     quarter + interp + 16bit = 不纯   (probe_630_level 系列)
//     quarter + interp + 24bit = 不纯   (probe_630_vs_lut24b 长段)
//     full    + no-int + 24bit = 纯     (probe_630_vs_classmate_i 长段, 对照版)
//   本模块补上第四格: full + interp + 24bit
//     -> 若"纯"  => 元凶是**1/4 波几何/镜像**
//     -> 若"不纯" => 元凶是**插值这件事本身**
//
// 表: rtl/rom/sine_full_1024_q23.hex (1024 项 × 24 位, 与对照表一致)
// 相位切位: ifull = phase[23:14] (1024 点), frac = phase[13:2] (12 位)
// idx_lo 在表尾回卷到 0（正弦周期, index 1024 == index 0）
//=============================================================================
`timescale 1ns/1ps

module sine_lut_full #(
    parameter PHASE_W  = 24,
    parameter IDX_W    = 10,
    parameter FRAC_W   = 12,
    parameter OUT_W    = 24,
    parameter QN       = 1024,
    parameter ROM_FILE = "rtl/rom/sine_full_1024_q23.hex"
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   interp_en,
    input  wire [PHASE_W-1:0]     phase,
    output reg signed [OUT_W-1:0] sin_out
);
    reg signed [OUT_W-1:0] rom [0:QN-1];
    initial $readmemh(ROM_FILE, rom);

    wire [IDX_W-1:0] ifull = phase[PHASE_W-1 -: IDX_W];
    wire [IDX_W-1:0] idx_lo_n = ifull + {{(IDX_W-1){1'b0}}, 1'b1};   // 自然回卷 (2^IDX_W)
    wire [FRAC_W-1:0] frac = phase[PHASE_W-IDX_W-1 -: FRAC_W];

    reg signed [OUT_W-1:0] r_hi, r_lo;
    reg [FRAC_W-1:0] f_d;
    reg              ie_d;

    always @(posedge clk) begin
        r_hi <= rom[ifull];
        r_lo <= rom[idx_lo_n];
        f_d  <= frac;
        ie_d <= interp_en;
    end

    wire signed [OUT_W:0]        diff = r_lo - r_hi;
    wire signed [OUT_W+FRAC_W:0] prod = diff * $signed({1'b0, f_d});
    wire signed [OUT_W+FRAC_W:0] base = r_hi <<< FRAC_W;
    wire signed [OUT_W+FRAC_W:0] rnd  = (base + prod) + ({{(OUT_W+FRAC_W){1'b0}}, 1'b1} <<< (FRAC_W-1));
    wire signed [OUT_W+FRAC_W:0] ival = rnd >>> FRAC_W;
    wire signed [OUT_W-1:0]      vsel = ie_d ? ival[OUT_W-1:0] : r_hi;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sin_out <= {OUT_W{1'b0}};
        else        sin_out <= vsel;
    end
endmodule
