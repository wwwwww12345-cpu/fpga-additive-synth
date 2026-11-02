//=============================================================================
// keyhub.v —— 键事件汇聚
//
// 三个事件源汇到同一个 top.key_* 出口:
//   1) 单键(ASCII "60+/-" / 小程序 0x87/0x88)      ← 受音域偏移作用
//   2) 和弦展开(单键按下时按 chord_mode 叠 1~4 个音) ← 只作用于单键, 不作用于曲谱
//   3) 曲谱播放(song_player)
//
// 事件字(16 bit): {on, note[6:0], 1'b0, vel[6:0]}
//
// 2026-10-26 修复记录:
//   R1 每键一份和弦记忆(现在 16 行): 原来只有一份 held[], 后按的键会覆盖前一个键,
//      导致"松开放错一组、前一组永远挂着"。
//   R2 **出口改组合**: 原来 key_we/数据打一拍, 而 note_ctrl 是在下一拍用
//      `if (key_we) if (key_ready) 存 else drop_cnt++` 重新检查 key_ready 的 ——
//      拍间不一致时正好丢一个字(表现为和弦松开"少放一个音")。现在 key_* 直接组合来自
//      fifo[rp], 与 key_ready 同一拍对齐, 不再有"在途"事件。
//   R3 组大小门槛: a_ready 只要求 space >= 本组事件数(原来一刀切 >=4)。
//   R4 写口轮转: 曲谱 s_req 长期为高时单键组抢不到写口(a_busy 长挂); 现在 s/a 轮流写。
//   R5 ch_n 必须 3bit(属七要 4)
//
// 已知限制: 两个和弦共用的音, 松开其中一个键会把共用音也放掉(需要每音引用计数)。
//=============================================================================
`timescale 1ns/1ps

module keyhub (
    input  wire        clk,
    input  wire        rst_n,

    input  wire signed [7:0] range_off,   // 半音偏移(作用于单键)
    input  wire [1:0]  chord_mode,        // 0关 1大三 2小三 3属七

    // ---- 单键源 ----
    input  wire        a_req,
    input  wire [6:0]  a_note,
    input  wire        a_on,
    input  wire [6:0]  a_vel,
    output reg         a_take,

    // ---- 曲谱源 ----
    input  wire        s_req,
    input  wire [6:0]  s_note,
    input  wire        s_on,
    input  wire [6:0]  s_vel,
    output reg         s_take,

    // ---- 到 top (R2: 组合输出, 与 key_ready 同拍) ----
    output wire        key_we,
    output wire [6:0]  key_note,
    output wire        key_on,
    output wire [6:0]  key_vel,
    input  wire        key_ready
);
    localparam DEPTH = 16;
    localparam NH    = 8;                    // 同时记住的"按下的键"行数

    //---------------------------------------------------------- FIFO
    reg  [15:0] fifo [0:DEPTH-1];
    reg  [3:0]  wp, rp;
    reg  [4:0]  wcount;                       // 0..16
    wire [4:0]  space = 5'd16 - wcount;
    wire [15:0] rd_word = fifo[rp];

    // R2: 组合输出
    assign key_we   = (wcount != 5'd0) && key_ready;
    assign key_note = rd_word[14:8];
    assign key_on   = rd_word[15];
    assign key_vel  = rd_word[6:0];

    //---------------------------------------------------------- 单键展开
    reg        a_busy;
    reg [2:0]  a_idx;                         // 0..3
    reg [2:0]  a_cnt;                         // 1..4
    reg [15:0] a_ev [0:3];

    // 每个按下的键一行: 原始音号 + 这一组实际发的音(已加音域偏移) + 个数
    reg [6:0]  h_root [0:NH-1];
    reg [6:0]  h_n0 [0:NH-1], h_n1 [0:NH-1], h_n2 [0:NH-1], h_n3 [0:NH-1];
    reg [2:0]  h_cnt  [0:NH-1];
    reg        h_val  [0:NH-1];

    // 音域偏移 + clamp
    wire signed [8:0] root_s = $signed({1'b0, a_note}) + $signed(range_off);
    wire [6:0] root = (root_s < 9'sd0)   ? 7'd0   :
                      (root_s > 9'sd127) ? 7'd127 : root_s[6:0];

    function [6:0] clampp;
        input [8:0] v;
        begin
            clampp = (v > 9'd127) ? 7'd127 : v[6:0];
        end
    endfunction

    wire [6:0] c_maj3 = clampp({2'b00, root} + 9'd4);
    wire [6:0] c_min3 = clampp({2'b00, root} + 9'd3);
    wire [6:0] c_5    = clampp({2'b00, root} + 9'd7);
    wire [6:0] c_7    = clampp({2'b00, root} + 9'd10);

    // 本次按下要叠的音(按 chord_mode); R5: ch_n 3bit
    reg  [2:0] ch_n;
    reg  [6:0] ch_0, ch_1, ch_2, ch_3;
    always @* begin
        ch_0 = root; ch_1 = c_maj3; ch_2 = c_5; ch_3 = c_7;
        case (chord_mode)
            2'd1:    begin ch_1 = c_maj3; ch_n = 3'd3; end   // 大三: 根 +4 +7
            2'd2:    begin ch_1 = c_min3; ch_n = 3'd3; end   // 小三: 根 +3 +7
            2'd3:    ch_n = 3'd4;                            // 属七: 根 +4 +7 +10
            default: ch_n = 3'd1;                            // 关: 单音
        endcase
    end

    //---------------------------------------------------------- 表内查找(最小编号优先)
    integer hi;
    reg        has_free, has_rel, is_dup;
    reg [3:0]  free_i, rel_i;
    always @* begin
        has_free = 1'b0; free_i = 4'd0;
        has_rel  = 1'b0; rel_i  = 4'd0;
        is_dup   = 1'b0;
        for (hi = NH - 1; hi >= 0; hi = hi - 1) begin
            if (!h_val[hi]) begin
                has_free = 1'b1; free_i = hi[3:0];
            end else if (h_root[hi] == a_note) begin
                has_rel  = 1'b1; rel_i  = hi[3:0]; is_dup = 1'b1;
            end
        end
    end

    wire [3:0] sto_i = is_dup ? rel_i : free_i;

    //---------------------------------------------------------- 入队选择
    reg  s_ack;
    reg  s_prio;                              // R4: 写口轮转
    wire s_want   = s_req && !s_ack;
    wire a_want   = a_busy;
    wire s_push   = s_want && (space != 5'd0) && ( s_prio || !a_want);
    wire a_push   = a_want && (space != 5'd0) && (!s_prio || !s_want);
    wire a_ok     = a_on ? (has_free || is_dup) : has_rel;
    // R3: 只要求放得下本组
    wire [4:0] need_slots = a_on ? {2'b00, ch_n} : {2'b00, h_cnt[rel_i]};
    wire a_ready  = !a_busy && (space >= need_slots);
    wire a_accept = a_req && a_ready &&  a_ok;
    wire a_drop   = a_req && a_ready && !a_ok;

    wire [15:0] s_word = {s_on, s_note, 1'b0, s_vel};
    wire [15:0] a_word = a_ev[a_idx];

    wire push_any = s_push || a_push;
    wire pop_any  = (wcount != 5'd0) && key_ready;

    always @(posedge clk) begin
        if (s_push)      fifo[wp] <= s_word;
        else if (a_push) fifo[wp] <= a_word;
    end

    //---------------------------------------------------------- 主逻辑
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wp <= 4'd0; rp <= 4'd0; wcount <= 5'd0;
            a_busy <= 1'b0; a_idx <= 3'd0; a_cnt <= 3'd0;
            a_take <= 1'b0; s_take <= 1'b0; s_ack <= 1'b0; s_prio <= 1'b0;
            for (hi = 0; hi < NH; hi = hi + 1) begin
                h_root[hi] <= 7'd0; h_cnt[hi] <= 3'd0;
                h_n0[hi] <= 7'd0; h_n1[hi] <= 7'd0; h_n2[hi] <= 7'd0; h_n3[hi] <= 7'd0;
                h_val[hi] <= 1'b0;
            end
        end else begin
            a_take <= 1'b0;
            s_take <= 1'b0;

            if (s_push)      s_ack <= 1'b1;
            else if (!s_req) s_ack <= 1'b0;

            if (push_any) s_prio <= ~s_prio;         // R4

            // 空组抬键 / 表满按下: 直接丢弃
            if (a_drop) a_take <= 1'b1;

            //--------------------------------------------- 单键接收
            if (a_accept) begin
                a_take <= 1'b1;
                a_idx  <= 3'd0;
                a_busy <= 1'b1;
                if (a_on) begin
                    h_val [sto_i] <= 1'b1;
                    h_root[sto_i] <= a_note;
                    h_cnt [sto_i] <= ch_n;
                    h_n0  [sto_i] <= ch_0;
                    h_n1  [sto_i] <= ch_1;
                    h_n2  [sto_i] <= ch_2;
                    h_n3  [sto_i] <= ch_3;
                    a_ev[0] <= {1'b1, ch_0, 1'b0, a_vel};
                    a_ev[1] <= (ch_n >= 3'd2) ? {1'b1, ch_1, 1'b0, a_vel} : 16'd0;
                    a_ev[2] <= (ch_n >= 3'd3) ? {1'b1, ch_2, 1'b0, a_vel} : 16'd0;
                    a_ev[3] <= (ch_n >= 3'd4) ? {1'b1, ch_3, 1'b0, a_vel} : 16'd0;
                    a_cnt   <= ch_n;
                end else begin
                    h_val[rel_i] <= 1'b0;
                    a_ev[0] <= {1'b0, h_n0[rel_i], 1'b0, a_vel};
                    a_ev[1] <= (h_cnt[rel_i] >= 3'd2) ? {1'b0, h_n1[rel_i], 1'b0, a_vel} : 16'd0;
                    a_ev[2] <= (h_cnt[rel_i] >= 3'd3) ? {1'b0, h_n2[rel_i], 1'b0, a_vel} : 16'd0;
                    a_ev[3] <= (h_cnt[rel_i] >= 3'd4) ? {1'b0, h_n3[rel_i], 1'b0, a_vel} : 16'd0;
                    a_cnt   <= h_cnt[rel_i];
                end
            end

            //--------------------------------------------- 入队推进
            if (s_push) begin
                s_take <= 1'b1;
                wp     <= wp + 4'd1;
            end else if (a_push) begin
                wp     <= wp + 4'd1;
                a_idx  <= a_idx + 3'd1;
                if (a_idx + 3'd1 == a_cnt) a_busy <= 1'b0;
            end

            //--------------------------------------------- 出队计数(R2: key_we 已组合输出)
            if (pop_any) rp <= rp + 4'd1;

            wcount <= wcount + (push_any ? 5'd1 : 5'd0) - (pop_any ? 5'd1 : 5'd0);
        end
    end
endmodule
