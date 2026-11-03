//=============================================================================
// guide_ctrl.v —— 曲谱灯带「指引弹奏」控制器 (2026-11-03)
//
// 功能（对应小程序「指引弹奏」按钮，命令 0x94 / 0x95）：
//   开始后：第 1 个音的灯亮黄；
//           按对（key_on 且音号==target）→ 该灯变绿，保持到松开；
//           松开 → 指针 +1，下一个音的灯变黄；
//           按错（key_on 且音号!=target）→ 该灯变红 RED_CLKS 后变回黄；
//           休止符(note==0)直接跳过；
//           走到 song_len 之后自动结束（active=0，全灭）。
//   说明：本模块只产生「目标音 + 颜色状态」，三色由顶层按单色灯带实现
//         （yellow/green/red 三种全局颜色 + 单点 mask）。
//
// 曲谱来源：song_ram 的读口（与 song_player 分时复用：指引模式下 player 必须停）。
// 字格式：{note[22:16], vel[15:9], dur[8:2], 2'b00}
//=============================================================================
`timescale 1ns/1ps

module guide_ctrl #(
    parameter RED_CLKS = 25_000_000,     // 按错后红灯时长: 0.5 s @50MHz
    parameter BASE_NOTE = 7'd60,         // 灯带第 0 颗对应 MIDI 音号（仅用于顶层 mask）
    parameter NPIX      = 24
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,            // 单拍: 0x94
    input  wire        stop,             // 单拍: 0x95 / 自动演奏开始 / 复位

    input  wire        song_valid,       // 0x92 校验通过
    input  wire [9:0]  song_len,         // 条目数 N (1..512)
    output reg  [8:0]  raddr,            // 曲谱读地址
    input  wire [23:0] rdata,            // 同步读回

    input  wire        key_we,
    input  wire [6:0]  key_note,
    input  wire        key_on,

    output reg         active,           // 指引进行中
    output reg  [6:0]  target_note,      // 当前目标音
    output reg  [1:0]  state,            // 0=黄(等待) 1=绿(按对) 2=红(按错)
    output reg  [9:0]  ptr,              // 当前条目号
    output wire        target_in_range   // 目标音是否落在灯带范围（给顶层 mask 用）
);
    localparam S_IDLE  = 3'd0,
               S_LATCH = 3'd1,          // 等同步读回
               S_WAIT  = 3'd2,          // 黄：等按
               S_HIT   = 3'd3,          // 绿：已按对，等松开
               S_RED   = 3'd4,          // 红：按错冷却
               S_ADDR  = 3'd5;          // 发读地址，等 RAM 同步读回

    reg [2:0]  fsm;
    reg [31:0] red_cnt;

    wire [6:0] w_note = rdata[22:16];
    wire [6:0] w_dur  = rdata[8:2];

    // 高级条件（组合，便于阅读）
    wire key_hit  = key_we &&  key_on && (key_note == target_note);
    wire key_miss = key_we &&  key_on && (key_note != target_note);
    wire key_rel  = key_we && !key_on && (key_note == target_note);

    assign target_in_range = (target_note >= BASE_NOTE) &&
                             (target_note <  BASE_NOTE + NPIX);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fsm         <= S_IDLE;
            active      <= 1'b0;
            target_note <= 7'd0;
            state       <= 2'd0;
            ptr         <= 10'd0;
            raddr       <= 9'd0;
            red_cnt     <= 32'd0;
        end else begin
            // 停止优先于一切；曲谱失效（重新下发 0x90 会让 song_valid=0）也退出
            if (stop || !song_valid) begin
                fsm         <= S_IDLE;
                active      <= 1'b0;
                target_note <= 7'd0;
                state       <= 2'd0;
                ptr         <= 10'd0;
                red_cnt     <= 32'd0;
            end else begin
                case (fsm)
                S_IDLE: begin
                    active <= 1'b0;
                    state  <= 2'd0;
                    if (start && song_valid && (song_len != 10'd0)) begin
                        active <= 1'b1;
                        ptr    <= 10'd0;
                        raddr  <= 9'd0;
                        fsm    <= S_ADDR;
                    end
                end

                S_ADDR: begin
                    // 地址已在上一拍发出；本拍让 RAM 采样，下一拍 LATCH 取数
                    fsm <= S_LATCH;
                end

                S_LATCH: begin
                    // 同步读回当前条目
                    if (w_note == 7'd0) begin
                        // 休止符: 直接跳过（不点灯）
                        if (ptr + 10'd1 >= song_len) begin
                            active <= 1'b0;
                            fsm    <= S_IDLE;
                            state  <= 2'd0;
                        end else begin
                            ptr   <= ptr + 10'd1;
                            raddr <= (ptr + 10'd1);
                            fsm   <= S_ADDR;
                        end
                    end else begin
                        target_note <= w_note;
                        state       <= 2'd0;        // 黄
                        fsm         <= S_WAIT;
                    end
                end

                S_WAIT: begin
                    if (key_hit) begin
                        state <= 2'd1;              // 绿
                        fsm   <= S_HIT;
                    end else if (key_miss) begin
                        state   <= 2'd2;            // 红
                        red_cnt <= RED_CLKS;
                        fsm     <= S_RED;
                    end
                end

                S_HIT: begin
                    if (key_rel) begin
                        // 松开: 下一个音
                        if (ptr + 10'd1 >= song_len) begin
                            active <= 1'b0;
                            fsm    <= S_IDLE;
                            state  <= 2'd0;
                        end else begin
                            ptr   <= ptr + 10'd1;
                            raddr <= (ptr + 10'd1);
                            fsm   <= S_ADDR;
                            state <= 2'd0;
                        end
                    end
                end

                S_RED: begin
                    if (key_hit) begin
                        // 红期间又按对: 直接转绿（更宽容）
                        state <= 2'd1;
                        fsm   <= S_HIT;
                    end else if (red_cnt != 32'd0) begin
                        red_cnt <= red_cnt - 32'd1;
                    end else begin
                        state <= 2'd0;              // 变回黄
                        fsm   <= S_WAIT;
                    end
                end

                default: fsm <= S_IDLE;
                endcase
            end
        end
    end

    // 未用信号（保留给将来按 dur 计时）
    wire _unused = &{1'b0, w_dur, 1'b0};

endmodule
