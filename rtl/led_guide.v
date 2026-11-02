//=============================================================================
// led_guide.v —— 音符 → 灯位指引（2026-10-24）
//
// 24 颗 WS2812 = 半音一格：第 0 颗 = BASE_NOTE（默认 60 = C4），向上连续 NPIX 个半音。
// 正在发声的音符点亮自己那一格，抬键熄灭。事件源直接用 keyhub 的出口
// （单键 / 和弦 / 曲谱三路已经合并成一条事件流），所以曲谱播放时灯会跟着走。
//
// 设计取舍：
//   * 超出 [BASE, BASE+NPIX-1] 的音符 → 钳到两端（保证"永远有反应"，
//     而不是静默；代价是低/高音区都挤在边缘一颗灯上）。
//   * 整条灯带只有一个全局颜色（ws2812_mono 的限制），所以指引用颜色区分
//     "有人在弹"（顶层给橙色），具体哪个音靠 mask 的位。
//   * 同一音高被"和弦 + 曲谱"同时触发时，先来的 off 会把它熄灭——可接受，
//     因为本工程里曲谱播放与手动单键不会同时进行。
//=============================================================================
`timescale 1ns/1ps

module led_guide #(
    parameter [6:0] BASE_NOTE = 7'd60,
    parameter       NPIX      = 24
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        ev_we,       // 单拍: 本拍 ev_note/ev_on 有效
    input  wire [6:0]  ev_note,
    input  wire        ev_on,
    output reg  [31:0] mask,        // bit i = 第 i 颗亮
    output wire        active       // 至少一个音符在响
);

    // n - BASE, 下溢时 t[8]=1
    function [5:0] idx_of;
        input [6:0] n;
        reg   [8:0] t;
        begin
            t = {2'b00, n} - {2'b00, BASE_NOTE};
            if (t[8])                 idx_of = 6'd0;            // 低于音域 → 第 0 颗
            else if (t > (NPIX-1))    idx_of = NPIX[5:0] - 6'd1; // 高于音域 → 最后一颗
            else                      idx_of = t[5:0];
        end
    endfunction

    wire [5:0]  idx = idx_of(ev_note);
    wire [31:0] sel = 32'd1 << idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)        mask <= 32'd0;
        else if (ev_we) begin
            if (ev_on) mask <= mask |  sel;
            else       mask <= mask & ~sel;
        end
    end

    assign active = (mask != 32'd0);

endmodule
