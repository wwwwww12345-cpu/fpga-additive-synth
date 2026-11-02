//=============================================================================
// keymatrix.v —— 4x4 矩阵键盘扫描（2026-11-02, lowlat 演示用）
//
//   行: 4 根输出，**逐行拉低**（低有效），每行 1000 拍 = 20 µs @50MHz，整轮 ≈80 µs。
//   列: 4 根输入，内部 PD / 外部 10k 上拉到 3V3，**读到低 = 按下**。
//
//   延迟策略: 按下在**本次扫描到该行的那一帧**就发 note-on（不去抖）；
//             释放要连续 DEB_MS 毫秒都被读到高才发 note-off（默认 3 ms）。
//             同一个键重复触发由上层 keyhub/note_ctrl 去重挡掉。
//
//   力度: 按下那一刻取外部给的 fsr_code，code>>8 钳 1..127；高字节=0 时回退 96。
//   事件: 4 深 FIFO + ev_take 握手；计数器只在块里赋值一次（同块二次赋值会丢计数）。
//
//   KEYMAP_V: 16 个 7bit 音号拼成 112bit（Verilog-2001 没有数组参数）。
//     行0: C4  D4  E4  F4   (60 62 64 65)
//     行1: G4  A4  B4  C5   (67 69 71 72)
//     行2: C#4 D#4 F#4 G#4  (61 63 66 68)
//     行3: A#4 C#5 D#5 D#5  (70 73 75 75) ← 第 16 键先占位"换音域"，音号暂用 D#5
//=============================================================================
`timescale 1ns/1ps
module keymatrix #(
    parameter integer DEB_MS   = 3,            // 释放去抖（毫秒）
    parameter integer CLK_MHZ  = 50,
    // 2026-11-02 定稿（只用自然音；第 8 / 第 16 键空置 = 7'h7F，直接忽略）:
    //   行0(1..4)  : C4  D4  E4  F4    (60 62 64 65)
    //   行1(5..8)  : G4  A4  B4  空    (67 69 71 7F)
    //   行2(9..12) : C5  D5  E5  F5    (72 74 76 77)
    //   行3(13..16): G5  A5  B5  空    (79 81 83 7F)
    parameter [111:0] KEYMAP_V = {
        7'd127, 7'd83, 7'd81, 7'd79,
        7'd77,  7'd76, 7'd74, 7'd72,
        7'd127, 7'd71, 7'd69, 7'd67,
        7'd65,  7'd64, 7'd62, 7'd60
    }
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [15:0] fsr_code,               // AIN0 码值（按下那一刻的力度）
    output reg  [3:0]  row_n,                  // 行驱动，低=选中
    input  wire [3:0]  col,                    // 列输入，低=按下
    output wire        ev_valid,               // FIFO 非空（= keyhub.a_req）
    output wire [6:0]  ev_note,                // 队头（稳定，直到被取走）
    output wire        ev_on,
    output wire [6:0]  ev_vel,
    input  wire        ev_take                 // keyhub.a_take
);
    localparam integer ROW_CLKS = 1000;                        // 20 µs
    localparam integer DEB_CLKS = DEB_MS * CLK_MHZ * 1000;     // 3 ms = 150000 clk
    // 每个键每轮只被看一次(4 行 x ROW_CLKS)，所以释放去抖按"被看到的次数"计:
    //   3 ms / (4 x 20 us) = 37.5 -> 38 次
    localparam integer REL_VISITS = ((DEB_MS*CLK_MHZ*1000) + (4*ROW_CLKS) - 1) / (4*ROW_CLKS);

    function [6:0] vel_of(input [15:0] c);
        reg [7:0] v8;
        begin
            v8 = c[15:8];
            if (v8 == 8'd0)       vel_of = 7'd96;
            else if (v8 > 8'd127) vel_of = 7'd127;
            else                  vel_of = v8[6:0];
        end
    endfunction

    //---------------------------------------------------------------- 行扫描
    reg [1:0]  row;
    reg [1:0]  row_s;                          // 采样那一拍的行号（row 同时会自增，必须锁存）
    reg [9:0]  row_cnt;
    reg [3:0]  c1, c2;                          // 列输入两级同步
    reg [3:0]  keys_lat;                        // 本行采样结果（1=按下）
    reg        proc;                            // 1 = 正在逐键处理
    reg [1:0]  pj;                              // 处理到第几列

    wire [3:0] cidx = {2'b00, row_s} * 4'd4 + {2'b00, pj};   // 键序号 0..15（4bit! 3bit 会把 8..15 折回 0..7）

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row <= 2'd0; row_cnt <= 10'd0; c1 <= 4'hF; c2 <= 4'hF;
            row_n <= 4'b1110; proc <= 1'b0; pj <= 2'd0; keys_lat <= 4'hF;
        end else begin
            c1 <= col;  c2 <= c1;
            if (!proc) begin
                if (row_cnt == ROW_CLKS-1) begin
                    row_cnt  <= 10'd0;
                    keys_lat <= ~c2;                 // 低=按下，取反存
                    row_s    <= row;                 // 锁存本行行号（next 行已经同时切换）
                    proc     <= 1'b1;
                    pj       <= 2'd0;
                    row      <= row + 2'd1;
                    case (row + 2'd1)
                        2'd0:    row_n <= 4'b1110;
                        2'd1:    row_n <= 4'b1101;
                        2'd2:    row_n <= 4'b1011;
                        default: row_n <= 4'b0111;
                    endcase
                end else row_cnt <= row_cnt + 10'd1;
            end else begin
                if (pj == 2'd3) proc <= 1'b0;
                else            pj   <= pj + 2'd1;
            end
        end
    end

    //---------------------------------------------------------------- 键状态 + 释放去抖 + FIFO
    reg [15:0] pressed;
    reg [19:0] rel_cnt [0:15];
    reg [14:0] fifo [0:3];                       // {on, note[6:0], vel[6:0]} = 15bit
    reg [1:0]  wr, rd;
    reg [2:0]  cnt;
    wire       full  = (cnt == 3'd4);
    wire       empty = (cnt == 3'd0);
    wire       pop   = !empty && ev_take;

    // 本拍要处理的键
    wire        k_cur   = pressed[cidx];
    wire        k_seen  = keys_lat[pj];          // 1 = 读到按下
    wire [6:0]  k_note_v   = KEYMAP_V[cidx*7 +: 7];
    wire        k_used     = (k_note_v < 7'h7E);          // 0x7F = 空键，忽略
    wire        k_push_on  = proc && !k_cur &&  k_seen && !full && k_used;
    wire        k_push_off = proc &&  k_cur && !k_seen && !full &&
                             (rel_cnt[cidx] >= REL_VISITS-1);
    wire        k_push  = k_push_on | k_push_off;
    wire        k_hold  = proc && k_cur && !k_seen && !k_push_off;   // 还在去抖窗口里

    assign ev_valid = !empty;
    assign ev_on    = fifo[rd][14];
    assign ev_note  = fifo[rd][13:7];
    assign ev_vel   = fifo[rd][6:0];

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pressed <= 16'd0; wr <= 2'd0; rd <= 2'd0; cnt <= 3'd0;

            for (k = 0; k < 16; k = k + 1) rel_cnt[k] <= 20'd0;
        end else begin
            if (k_push_on) begin
                pressed[cidx]  <= 1'b1;
                rel_cnt[cidx]  <= 20'd0;
                fifo[wr]       <= {1'b1, KEYMAP_V[cidx*7 +: 7], vel_of(fsr_code)};
                wr             <= wr + 2'd1;
            end else if (k_push_off) begin
                pressed[cidx]  <= 1'b0;
                rel_cnt[cidx]  <= 20'd0;
                fifo[wr]       <= {1'b0, KEYMAP_V[cidx*7 +: 7], 7'd0};
                wr             <= wr + 2'd1;
            end else if (k_hold) begin
                if (rel_cnt[cidx] != 20'hF_FFFF) rel_cnt[cidx] <= rel_cnt[cidx] + 20'd1;
            end else if (proc && k_cur && k_seen) begin
                rel_cnt[cidx] <= 20'd0;          // 又读到按下了 -> 计时清零
            end

            if (pop) rd <= rd + 2'd1;

            // 计数只在这一处赋值（同块二次赋值会丢计数 —— 2026-11-01 的教训）
            cnt <= cnt + (k_push ? 3'd1 : 3'd0) - (pop ? 3'd1 : 3'd0);
        end
    end
endmodule
