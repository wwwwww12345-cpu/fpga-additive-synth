`timescale 1ns/1ps
//=============================================================================
// fsr_key.v —— FSR402 x4 (经 ADS1115 I2C) -> 键事件层, 接口对齐 note_ctrl 键总线
//
// 数据流: ads1115_if 转换 4 通道码值 -> 每通道迟滞比较(TH_ON/TH_OFF) ->
//         连续 CONFIRM 次一致才跳变(消抖) -> 事件进 FIFO -> key_ready=1 当拍发单拍 key_we
//
// 接线: FSR402 一端接 3.3V, 另一端接 AINx + 10k 下拉到 GND
// 音号: 通道 0..3 = NOTE0 + k*NOTE_STEP, 默认 60/62/64/66 (C4 D4 E4 F#4)
// 力度: 见 VEL_DELAY (2026-10-23 新增)
//
//   2026-10-23 板上实测结论: 原实现 vel = 确认拍码值>>8, 而确认发生在压力刚过
//   TH_ON(6000=0.75V) 的上升沿, 实测 9 次按压 vel 全部落在 24~34, 与真实峰值
//   (0.36~1.82V) 几乎不相关 -> 4 层力度表实际只用到底层。
//   修法: VEL_DELAY = N (本通道有效采样个数, 每次≈8.5ms)。
//     N = 0 -> 老行为(立即发, 用确认拍码值), 逐位不变
//     N >= 1 -> 越阈确认后先不发, 继续采 N 个样本取**窗口峰值**再发 note-on
//   VEL_DELAY=3 ≈ 25ms -> 按下到发声 ≈40ms
//
// 坑X: 全部 FF 带复位端 + FIFO 状态位归零 —— ModelSim 直接可跑。
//=============================================================================
module fsr_key #(
    parameter integer TQ         = 31,
    parameter [15:0]  CONV_WAIT  = 16'd65000,
    parameter         I2C_ADDR   = 7'h48,
    parameter [15:0]  TH_ON      = 16'd6000,  // ~0.75V: 触发迟滞上位
    parameter [15:0]  TH_OFF     = 16'd3000,  // ~0.37V: 释放迟滞下位
    parameter integer CONFIRM     = 2,         // 连续 N 次采样越阈才跳变
    parameter [6:0]   NOTE0      = 7'd60,     // 通道 0 音号 (C4)
    parameter [6:0]   NOTE_STEP  = 7'd2,
    parameter integer VEL_DELAY   = 0          // 0=老行为; N=越阈后等 N 个采样取峰值
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        key_ready,   // note_ctrl 键 FIFO 背压(必须接 H7 连线)
    output reg         key_we,      // 1 拍有效
    output reg  [6:0]  key_note,
    output reg         key_on,
    output reg  [6:0]  key_vel,
    output wire        i2c_scl,
    inout  wire        i2c_sda,
    output wire        i2c_err,     // 调试: I2C NACK 错误标志
    output reg  [1:0]  dbg_ch,      // 调试: 最近采样通道
    output reg  [15:0] dbg_data,    // 调试: 最近采样码值
    output reg  [7:0]  ev_drop      // 调试: FIFO 满丢弃计数器(不该发生)
);

    //---------------------------------------------------------------- ADC 转换
    wire        ch_valid;
    wire [1:0]  ch;
    wire [15:0] ch_data;
    wire        bus_bad;      // 上层读数非法(0xFFFF / >0x7FFF)

    ads1115_if #(
        .TQ(TQ), .CONV_WAIT(CONV_WAIT), .I2C_ADDR(I2C_ADDR)
    ) u_adc (
        .clk(clk), .rst_n(rst_n),
        .ch_valid(ch_valid), .ch(ch), .ch_data(ch_data),
        .i2c_err(i2c_err), .bus_bad(bus_bad),
        .i2c_scl(i2c_scl), .i2c_sda(i2c_sda));

    // ------------------------------------------------------------------------
    // 2026-10-15 修正 —— 幻影四音案。
    //   上层保证: **非法读数不发 ch_valid、ch_data 保持 0**。
    //   这里再加一道独立的**物理量程**闸线(即使上层失效也拦得住):
    //   ADS1115 单端 + PGA=±4.096V, 合法码值只有 0..0x7FFF。
    // ------------------------------------------------------------------------
    wire [15:0] code_in   = bus_bad ? 16'd0 : ch_data;
    wire        code_bad  = (code_in == 16'hFFFF) || (code_in > 16'h7FFF);
    wire [15:0] code_ok   = code_bad ? 16'd0 : code_in;   // 非法 -> 当 0(无压力)
    wire        valid_ok  = ch_valid && !code_bad;

    wire        _unused_i2c_err = i2c_err;

    //---------------------------------------------------------------- 音号映射
    function [6:0] ch2note(input [1:0] c);
        begin
            case (c)
                2'd0:    ch2note = NOTE0;
                2'd1:    ch2note = NOTE0 + NOTE_STEP;
                2'd2:    ch2note = NOTE0 + 2*NOTE_STEP;
                default: ch2note = NOTE0 + 3*NOTE_STEP;
            endcase
        end
    endfunction

    // 力度: 码值 >>8, 下限 1 上限 127
    function [6:0] vel_of(input [15:0] code);
        reg [7:0] v8;
        begin
            v8 = code[15:8];
            vel_of = (v8 == 8'd0) ? 7'd1 : (v8[7]) ? 7'd127 : v8[6:0];
        end
    endfunction

    wire [6:0] vel_now = vel_of(code_ok);

    //---------------------------------------------------------------- 状态
    reg [3:0] pressed;                    // 每通道键状态
    reg [7:0] on_cnt  [0:3];
    reg [7:0] off_cnt [0:3];

    // VEL_DELAY 窗口: armed=等待凑样本, peak=窗口内峰值, vwait=已等样本数
    reg [3:0]  armed;
    reg [15:0] peak   [0:3];
    reg [7:0]  vwait  [0:3];

    // 事件缓存(单槽): 事件最小间隔 = 轮询周期
    reg       ev_pend;
    reg [6:0] ev_note;
    reg       ev_on;
    reg [6:0] ev_vel;
    // 极短叩击: 窗口未结束就松开 -> 先补 note-on, 下一拍再补 note-off
    reg       off_q;
    reg [6:0] off_q_note;

    // 事件 FIFO 深度 8: {vel[6:0], note[6:0], on}
    reg [14:0] fifo [0:7];
    reg [2:0]  wr_ptr, rd_ptr, cnt;

    wire pop_now  = (cnt != 3'd0) && key_ready;
    wire push_now = ev_pend && ((cnt != 3'd7) || pop_now);

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pressed <= 4'h0; ev_pend <= 1'b0; ev_note <= 7'd0; ev_on <= 1'b0;
            ev_vel <= 7'd0; key_we <= 1'b0; key_note <= 7'd0; key_on <= 1'b0;
            key_vel <= 7'd0; dbg_ch <= 2'd0; dbg_data <= 16'd0; ev_drop <= 8'd0;
            wr_ptr <= 3'd0; rd_ptr <= 3'd0; cnt <= 3'd0;
            armed <= 4'h0; off_q <= 1'b0; off_q_note <= 7'd0;
            for (i = 0; i < 4; i = i + 1) begin
                on_cnt[i] <= 8'd0; off_cnt[i] <= 8'd0;
                peak[i] <= 16'd0;  vwait[i] <= 8'd0;
            end
            for (i = 0; i < 8; i = i + 1) fifo[i] <= 15'd0;
        end else begin
            key_we <= 1'b0;

            // 1) 发送: FIFO 深 + 背压, 单拍 key_we, 当拍数据稳定
            if (pop_now) begin
                key_we   <= 1'b1;
                key_note <= fifo[rd_ptr][7:1];
                key_vel  <= fifo[rd_ptr][14:8];
                key_on   <= fifo[rd_ptr][0];
                rd_ptr   <= rd_ptr + 3'd1;
            end

            // 2) 阈值判定 + 连续确认 + 力度窗口
            if (valid_ok) begin
                dbg_ch   <= ch;
                dbg_data <= code_ok;
                if (!pressed[ch]) begin
                    if (code_ok >= TH_ON) begin
                        if (on_cnt[ch] >= CONFIRM-1) begin
                            pressed[ch] <= 1'b1;
                            on_cnt[ch]  <= 8'd0;
                            off_cnt[ch] <= 8'd0;
                            if (VEL_DELAY == 0) begin
                                ev_pend <= 1'b1;
                                ev_note <= ch2note(ch);
                                ev_on   <= 1'b1;
                                ev_vel  <= vel_now;
                            end else begin
                                armed[ch]  <= 1'b1;
                                peak[ch]   <= code_ok;
                                vwait[ch]  <= 8'd0;
                            end
                        end else on_cnt[ch] <= on_cnt[ch] + 8'd1;
                    end else on_cnt[ch] <= 8'd0;
                end else begin
                    // 已按下: 先看力度窗口是否到点
                    if (VEL_DELAY != 0 && armed[ch]) begin
                        if (code_ok > peak[ch]) peak[ch] <= code_ok;
                        if (vwait[ch] >= VEL_DELAY-1) begin
                            armed[ch] <= 1'b0;
                            ev_pend   <= 1'b1;
                            ev_note   <= ch2note(ch);
                            ev_on     <= 1'b1;
                            ev_vel    <= (code_ok > peak[ch]) ? vel_of(code_ok) : vel_of(peak[ch]);
                        end else vwait[ch] <= vwait[ch] + 8'd1;
                    end
                    // 再看是否松开
                    if (code_ok < TH_OFF) begin
                        if (off_cnt[ch] >= CONFIRM-1) begin
                            pressed[ch] <= 1'b0;
                            on_cnt[ch]  <= 8'd0;
                            off_cnt[ch] <= 8'd0;
                            if (VEL_DELAY != 0 && armed[ch]) begin
                                // 窗口没结束就松开: 用当前峰值补 note-on, 下一拍补 note-off
                                armed[ch]  <= 1'b0;
                                ev_pend    <= 1'b1;
                                ev_note    <= ch2note(ch);
                                ev_on      <= 1'b1;
                                ev_vel     <= (code_ok > peak[ch]) ? vel_of(code_ok) : vel_of(peak[ch]);
                                off_q      <= 1'b1;
                                off_q_note <= ch2note(ch);
                            end else begin
                                ev_pend <= 1'b1;
                                ev_note <= ch2note(ch);
                                ev_on   <= 1'b0;
                                ev_vel  <= 7'd0;
                            end
                        end else off_cnt[ch] <= off_cnt[ch] + 8'd1;
                    end else off_cnt[ch] <= 8'd0;
                end
            end

            // 3) 缓存事件 -> FIFO (同拍压入+弹出 = 无延传递)
            if (push_now) begin
                fifo[wr_ptr] <= {ev_vel, ev_note, ev_on};
                wr_ptr  <= wr_ptr + 3'd1;
                ev_pend <= 1'b0;
                if (off_q) begin                 // 同一槽紧接着排 note-off
                    ev_pend    <= 1'b1;
                    ev_note    <= off_q_note;
                    ev_on      <= 1'b0;
                    ev_vel     <= 7'd0;
                    off_q      <= 1'b0;
                end
            end else if (ev_pend) begin
                ev_drop <= ev_drop + 8'd1;      // FIFO 满 丢弃并计数(不该发生)
                ev_pend <= 1'b0;
            end

            case ({push_now, pop_now})
                2'b10:   cnt <= cnt + 3'd1;
                2'b01:   cnt <= cnt - 3'd1;
                default: ;
            endcase
        end
    end

endmodule
