//=============================================================================
// test_pattern.v —— 现场验收用测试图样发生器
//
// 赛题要求: "支持测试模式下输出多路不同频率音频, 频谱可观测对应数量独立谱峰,
//            同时可通过 RTL 代码佐证纯硬件实时合成通路"
// 做法: test_en 拉高 -> 依次按下 N_NOTES 个音(音号间隔 STEP 个半音, 便于频谱分辨),
//       全部按住不放; test_en 拉低 -> 全部释放。
// 按键节奏: 每个音之间等 key_ready(不丢事件), 并留 T_GAP 个时钟的间隔。
//=============================================================================
`timescale 1ns/1ps

module test_pattern #(
    parameter N_NOTES = 32,
    parameter N0      = 45,          // 起始 MIDI 音号 (45 = A2 110Hz)
    parameter STEP    = 2,           // 每 2 个半音一个音, 频谱上隔得开
    parameter T_GAP   = 2000,        // 按键间隔(时钟数), 50MHz 下 2000 = 40us
    parameter VEL     = 127
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       test_en,
    output reg        key_we,
    output reg [6:0]  key_note,
    output reg        key_on,
    output reg [6:0]  key_vel,
    input  wire       key_ready,
    output wire [7:0] pressed_cnt    // 已按下的音数(给 LED/数码管显示)
);

    localparam S_IDLE = 2'd0, S_PRESS = 2'd1, S_HOLD = 2'd2, S_REL = 2'd3;
    reg [1:0]  st;
    reg [1:0]  st_d;
    reg [7:0]  idx;
    reg [15:0] gap;
    reg        was_en;

    assign pressed_cnt = idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; st_d <= S_IDLE; idx <= 0; gap <= 0; was_en <= 0;
            key_we <= 0; key_note <= 0; key_on <= 0; key_vel <= VEL[6:0];
        end else begin
            key_we <= 1'b0;
            was_en <= test_en;

            case (st)
            S_IDLE: begin
                idx <= 0;
                if (test_en && !was_en) begin        // 上升沿开始
                    st  <= S_PRESS;
                    gap <= T_GAP[15:0];
                end
            end

            S_PRESS: begin
                if (gap != 0) gap <= gap - 1'b1;
                else if (key_ready) begin
                    key_we   <= 1'b1;
                    key_note <= N0[6:0] + idx[6:0] * STEP[6:0];
                    key_on   <= 1'b1;
                    key_vel  <= VEL[6:0];
                    idx      <= idx + 8'd1;
                    gap      <= T_GAP[15:0];
                    if (idx == N_NOTES[7:0] - 1) st <= S_HOLD;
                end
                if (!test_en) st <= S_REL;
            end

            S_HOLD: begin                        // 全部按住, 等 test_en 拉低
                if (!test_en) st <= S_REL;
            end

            S_REL: begin
                if (gap != 0) gap <= gap - 1'b1;
                else if (key_ready && idx != 0) begin
                    idx      <= idx - 8'd1;
                    key_we   <= 1'b1;
                    key_note <= N0[6:0] + (idx - 8'd1) * STEP[6:0];
                    key_on   <= 1'b0;
                    key_vel  <= VEL[6:0];
                    gap      <= T_GAP[15:0];
                end else if (idx == 0) begin
                    st <= S_IDLE;
                end
            end

            default: st <= S_IDLE;
            endcase
        end
    end

endmodule