//=============================================================================
// song_player.v —— 曲谱演奏状态机
//
// 语义(按 docs/FPGA对接说明.md + 交接文档 §4.2):
//   IDLE --0x84(且 song_valid)--> 逐条播放
//   每条: note==0(休止)   → 只等 dur×10ms
//         note==cur_note 且 dur==127 → 连音线: 不重触发, 只等 dur×10ms (同音延长)
//         note==cur_note 且 dur<127  → 重复音: key_off + key_on 重触发 (v31, 原来被吞)
//         note!=cur_note → key_off(cur_note) + key_on(note,vel); 等 dur×10ms
//   ptr+1; 到 N → key_off(cur_note) 回 IDLE
//   0x85/0x93 → 立即 key_off(cur_note) 回 IDLE (0x93 另外 ptr←0)
//   0x90 到来 → ble_cmd 先给 play_stop (防播放半截曲谱)
//
// 定时: 50MHz, 1 个 dur 单位 = 10ms = 500_000 拍(精确整数, 不用采样时钟推)
// 键事件: ev_req/ev_take 握手, 由 keyhub 汇总后统一受 top 的 key_ready 背压
//=============================================================================
`timescale 1ns/1ps

module song_player #(
    parameter CLK_PER_TICK = 500_000,   // 10ms @50MHz
    parameter APPLY_RANGE  = 1         // 音域偏移是否作用于曲谱(待定项, 默认生效)
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        go,             // 0x84 单拍
    input  wire        stop,           // 0x85 / 0x93 / 0x90 单拍
    input  wire        reset,          // 0x93 单拍(指针归零)

    input  wire        song_valid,
    input  wire [9:0]  song_len,

    output reg  [8:0]  raddr,
    input  wire [23:0] rdata,          // {note,vel,dur,2'b00}

    input  wire signed [7:0] range_off,

    output reg         ev_req,
    output reg  [6:0]  ev_note,
    output reg         ev_on,
    output reg  [6:0]  ev_vel,
    input  wire        ev_take,

    output reg         playing,
    output reg  [9:0]  ptr
);
    localparam S_IDLE = 3'd0,
               S_LOAD = 3'd1,
               S_RD   = 3'd2,
               S_DEC  = 3'd3,
               S_OFF  = 3'd4,
               S_ON   = 3'd5,
               S_WAIT = 3'd6,
               S_KILL = 3'd7;      // 停止/复位时补 key_off
    // S_IDLE 还会承担"收尾 key_off", 用 flag_end 区分

    reg [2:0]  st;
    reg [6:0]  cur;                    // 当前按着的音(0 = 无)
    reg [6:0]  nxt;
    reg [6:0]  nxt_vel;
    reg [26:0] load_cnt;               // 本条 dur × CLK_PER_TICK - 1
    reg [26:0] cnt;
    reg        off_rest;               // S_OFF 之后是"休止"(→WAIT) 还是"换音"(→ON)
    reg        stop_pend;
    reg        end_pend;               // 全曲结束, 补 key_off

    //--------------------------------------------- 音域偏移 + clamp
    wire signed [8:0] adj = $signed({1'b0, nxt}) + (APPLY_RANGE ? $signed(range_off) : 9'sd0);
    wire [6:0] note_adj = (adj < 9'sd0)   ? 7'd0   :
                          (adj > 9'sd127) ? 7'd127 : adj[6:0];

    //--------------------------------------------- RAM 读出字段
    wire [6:0] dec_note = rdata[22:16];
    wire [6:0] dec_vel  = (rdata[15:9] == 7'd0) ? 7'd1 : rdata[15:9];
    wire [6:0] dec_dur  = (rdata[8:2]  == 7'd0) ? 7'd1 : rdata[8:2];

    // 移调后的"本条音号", 与 cur 同口径(cur 存的是移调后正在发声的音号)。
    // 必须由 dec_note 组合直接算 —— 不能改用 note_adj: 它由寄存器 nxt 推出,
    // 比本条滞后一条, 拿来做同音比较会把之后每条都误判成"同音延长"
    // (实测 60,60,62 @ range+1: 只出 on61, 后面的 60/62 全部不弹)。2026-10-21 修。
    wire signed [8:0] adj_dec = $signed({1'b0, dec_note}) + (APPLY_RANGE ? $signed(range_off) : 9'sd0);
    wire [6:0] dec_adj = (adj_dec < 9'sd0)   ? 7'd0   :
                         (adj_dec > 9'sd127) ? 7'd127 : adj_dec[6:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            cur       <= 7'd0;
            nxt       <= 7'd0;
            nxt_vel   <= 7'd0;
            load_cnt  <= 27'd0;
            cnt       <= 27'd0;
            raddr     <= 9'd0;
            ev_req    <= 1'b0;
            ev_note   <= 7'd0;
            ev_on     <= 1'b0;
            ev_vel    <= 7'd0;
            playing   <= 1'b0;
            ptr       <= 10'd0;
            off_rest  <= 1'b0;
            stop_pend <= 1'b0;
            end_pend  <= 1'b0;
        end else begin
            //--------------------------------------- 停止/复位请求
            if (reset) begin
                ptr       <= 10'd0;
                stop_pend <= 1'b1;
                end_pend  <= 1'b0;
            end else if (stop) begin
                stop_pend <= 1'b1;
                end_pend  <= 1'b0;
            end

            case (st)
                //================================================== 空闲
                S_IDLE: begin
                    ev_req  <= 1'b0;
                    playing <= 1'b0;
                    if (stop_pend) begin
                        stop_pend <= 1'b0;
                        if (cur != 7'd0) begin
                            nxt <= cur;
                            st  <= S_KILL;
                        end
                    end else if (go && song_valid) begin
                        ptr     <= 10'd0;
                        playing <= 1'b1;
                        st      <= S_LOAD;
                    end
                end

                //================================================== 取指
                S_LOAD: begin
                    if (stop_pend) begin
                        stop_pend <= 1'b0;
                        if (cur != 7'd0) begin nxt <= cur; st <= S_KILL; end
                    end else begin
                        raddr <= ptr[8:0];
                        st    <= S_RD;
                    end
                end

                S_RD: st <= S_DEC;                       // 等 RAM 输出一拍

                //================================================== 决策
                S_DEC: begin
                    if (stop_pend) begin
                        stop_pend <= 1'b0;
                        if (cur != 7'd0) begin nxt <= cur; st <= S_KILL; end
                    end else begin
                        nxt      <= dec_note;
                        nxt_vel  <= dec_vel;
                        load_cnt <= (dec_dur * CLK_PER_TICK) - 27'd1;
                        if (dec_note == 7'd0) begin
                            if (cur != 7'd0) begin
                                off_rest <= 1'b1;            // 休止: 先抬当前音
                                nxt      <= cur;
                                st       <= S_OFF;
                            end else begin
                                cnt <= (dec_dur * CLK_PER_TICK) - 27'd1;
                                st  <= S_WAIT;
                            end
                        end else if ((dec_adj == cur) &&
                                     ((dec_dur == 7'd127) || (dec_adj == 7'd0))) begin
                            // v31: 只有"真连音线"才延长。谱面把 >1270ms 的长音拆成多条同音
                            //   条目(dur 封顶 127), 这些必须并成一条; 而 dur<127 的同音是
                            //   "同一音高弹两次", 必须走下面的 S_OFF→S_ON 重触发, 否则会被
                            //   吞成一个长音(小星星 6 处 / 两只老虎 1 处 / Love Song 26 处)。
                            cnt <= (dec_dur * CLK_PER_TICK) - 27'd1;
                            st  <= S_WAIT;
                        end else if (cur != 7'd0) begin
                            off_rest <= 1'b0;            // 换音: 先抬旧音
                            st       <= S_OFF;
                        end else begin
                            st <= S_ON;
                        end
                    end
                end

                //================================================== 抬键
                S_OFF: begin
                    ev_req  <= 1'b1;
                    ev_note <= cur;                  // 要抬的是"当前按着的音"
                    ev_on   <= 1'b0;
                    ev_vel  <= 7'd0;
                    if (ev_take) begin
                        ev_req <= 1'b0;
                        cur    <= 7'd0;
                        if (stop_pend) begin
                            stop_pend <= 1'b0;
                            playing   <= 1'b0;
                            st        <= S_IDLE;
                        end else if (off_rest) begin
                            cnt <= load_cnt;
                            st  <= S_WAIT;
                        end else begin
                            st <= S_ON;              // 换音: 接着发新音
                        end
                    end
                end

                //================================================== 按键
                S_ON: begin
                    ev_req  <= 1'b1;
                    ev_note <= note_adj;
                    ev_on   <= 1'b1;
                    ev_vel  <= nxt_vel;
                    if (ev_take) begin
                        ev_req <= 1'b0;
                        cur    <= note_adj;
                        if (stop_pend) begin
                            stop_pend <= 1'b0;
                            st        <= S_KILL;     // 按下去就被叫停: 立刻抬
                        end else begin
                            cnt <= load_cnt;
                            st  <= S_WAIT;
                        end
                    end
                end

                //================================================== 计时
                S_WAIT: begin
                    if (stop_pend) begin
                        stop_pend <= 1'b0;
                        if (cur != 7'd0) begin nxt <= cur; st <= S_KILL; end
                        else begin playing <= 1'b0; st <= S_IDLE; end
                    end else if (cnt == 27'd0) begin
                        if (ptr + 10'd1 >= song_len) begin
                            if (cur != 7'd0) begin nxt <= cur; st <= S_KILL; end
                            else begin playing <= 1'b0; st <= S_IDLE; end
                        end else begin
                            ptr <= ptr + 10'd1;
                            st  <= S_LOAD;
                        end
                    end else begin
                        cnt <= cnt - 27'd1;
                    end
                end

                //================================================== 补抬键
                S_KILL: begin
                    ev_req  <= 1'b1;
                    ev_note <= nxt;
                    ev_on   <= 1'b0;
                    ev_vel  <= 7'd0;
                    if (ev_take) begin
                        ev_req  <= 1'b0;
                        cur     <= 7'd0;
                        playing <= 1'b0;
                        st      <= S_IDLE;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
