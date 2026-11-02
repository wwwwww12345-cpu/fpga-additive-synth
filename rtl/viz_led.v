// =============================================================================
// viz_led.v -- LED 演奏指引 + 脱机曲目指引 (赛题加分3"LED演奏指引" + 加分4"脱机演奏LED曲目指引")
//
//   与 note_ctrl 并联旁听同一条键事件总线 (key_we/note/on/vel), 不改任何现有模块;
//   报警也走旁听 (引擎 overrun 电平 + 交互层 drop_cnt 变化)。
//   输出 24bit {G,R,B} 像素流给 ws2812_phy -> NPIX 颗 WS2812 (NPIX=24: C4..B5 两个八度)。
//
//   每像素显示优先级:
//     报警红闪(全条) > 按对绿闪 > 下一音蓝呼吸(每拍一次, 辅助规范节奏) > 超时红 > 正在响白(亮度=力度) > 灭
//   全部颜色 <= 85/255 (1/3 亮度): 24 颗最坏 <0.6A, 可从底板 5V 取电 (必须共地)。
//
//   曲谱: rtl/rom/song_demo.hex, 每行 16bit = {gate, note[6:0], dur[7:0]}
//     gate=1 发声 / 0 休止; dur 单位=拍; 0x0000=曲终(停在非指引态, 只显示活跃音)
//   由 tools/gen_song.py 生成。SONG_LOOP=1 时曲终回卷循环。
// =============================================================================
module viz_led #(
    parameter NPIX        = 24,                        // 灯数 (NOTE_BASE+NPIX 必须 <= 128)
    parameter NOTE_BASE   = 60,                        // 像素0 对应 MIDI 音号 (C4)
    parameter BEAT_CLKS   = 25_000_000,                // 一拍 = 0.5s (120BPM) @50MHz, 改时钟/BPM 重算
    parameter FLASH_CLKS  = 15_000_000,                // 按对绿闪时长 0.3s
    parameter MISS_CLKS   = 50_000_000,                // 超时红时长 1.0s
    parameter ALARM_CLKS  = 100_000_000,               // 报警时长 2.0s
    parameter SONG_LOOP   = 1'b0,                      // 1=曲终回卷循环
    parameter SONG_HEX    = "rtl/rom/song_demo.hex",
    parameter SONG_MAX    = 64                         // 曲谱条目上限(固定 64, 含曲终符)
)(
    input  wire        clk,
    input  wire        rst_n,
    // ---- 键事件总线 (与 note_ctrl 同源旁听, 顶层直接并联) ----
    input  wire        key_we,
    input  wire [6:0]  key_note,     // MIDI 音号 0..127
    input  wire        key_on,       // 1=按下 0=抬起
    input  wire [6:0]  key_vel,      // 力度 0..127
    // ---- 报警旁听 (只读, 不改现有模块) ----
    input  wire        alarm_lvl,    // 接 partial_engine 的 overrun
    input  wire [7:0]  drop_cnt,     // 接 note_ctrl 的 drop_cnt (变化即报警)
    // ---- 像素流 -> ws2812_phy ----
    output reg         px_we,
    output reg  [4:0]  px_waddr,
    output reg [23:0]  px_wdata,     // {G,R,B}
    input  wire        frame_start   // phy 复位相开始的 1 拍脉冲
);

    // ================= 键事件旁听: 活跃音位图 + 窗口力度 =================
    reg [127:0] note_on;                              // MIDI 音号 -> 是否正在按
    reg  [6:0]  vel_win [0:NPIX-1];                   // 窗口内每音的最后力度
    wire        in_win = (key_note >= NOTE_BASE) && (key_note < NOTE_BASE + NPIX);
    wire [4:0]  ev_idx = key_note - NOTE_BASE;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) note_on <= 128'd0;
        else if (key_we) note_on[key_note] <= key_on;
    end
    always @(posedge clk) begin
        if (key_we && key_on && in_win) vel_win[ev_idx] <= key_vel;
    end

    // ================= 报警: overrun 电平 / drop_cnt 变化 =================
    // blink_cnt 复位值 = 2^21: 保证上电后第一段就是"亮"相, 报警立刻可见
    reg [7:0]  drop_q;
    reg [31:0] alarm_cnt;
    reg [23:0] blink_cnt;                             // [21] -> ~12Hz 闪
    wire alarm_set = alarm_lvl || (drop_cnt != drop_q);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) blink_cnt <= 24'h20_0000;
        else        blink_cnt <= blink_cnt + 24'd1;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            drop_q <= 8'd0; alarm_cnt <= 32'd0;
        end else begin
            drop_q <= drop_cnt;
            if (alarm_set)              alarm_cnt <= ALARM_CLKS;
            else if (alarm_cnt != 0)    alarm_cnt <= alarm_cnt - 32'd1;
        end
    end

    // ================= 曲谱 RAM 与播放指针 =================
    // 注意: 清零与 $readmemh 必须在同一个 initial 块内(块内语句有序, 跨块无序)
    reg [15:0] song [0:SONG_MAX-1];
    reg [5:0]  ptr;                                   // SONG_MAX 固定 64
    reg [7:0]  entry_beats;                           // 当前条目已过拍数
    reg [31:0] beat_div;
    reg [31:0] step_div;
    reg [2:0]  breath_step;                           // 蓝灯呼吸: 每拍 8 步三角
    integer i;
    initial begin
        for (i = 0; i < SONG_MAX; i = i + 1) song[i]   = 16'h0000;
        for (i = 0; i < NPIX;     i = i + 1) vel_win[i] = 7'd0;
        $readmemh(SONG_HEX, song);                    // 文件缺失/曲终 -> guide_en=0, 只显示活跃音
    end

    wire [15:0] cur_word  = song[ptr];
    wire        cur_gate  = cur_word[15];
    wire [6:0]  cur_note  = cur_word[14:8];
    wire [7:0]  cur_dur   = cur_word[7:0];
    wire        guide_en  = (cur_word != 16'h0000);
    wire [5:0]  next_ptr  = ptr + 6'd1;                // 64 深自然回卷
    wire [15:0] next_word = song[next_ptr];

    // 拍脉冲 (节奏/呼吸的时间基准)
    reg beat_pulse;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          begin beat_div <= 32'd0; beat_pulse <= 1'b0; end
        else if (beat_div >= BEAT_CLKS - 1) begin beat_div <= 32'd0; beat_pulse <= 1'b1; end
        else                 begin beat_div <= beat_div + 32'd1; beat_pulse <= 1'b0; end
    end
    // 呼吸步进: 每拍 8 步
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                           begin step_div <= 32'd0; breath_step <= 3'd0; end
        else if (step_div >= BEAT_CLKS/8 - 1) begin
            step_div <= 32'd0; breath_step <= breath_step + 3'd1;
        end else step_div <= step_div + 32'd1;
    end

    // 指针推进: 按对(match) 或 该条目拍数走满(timeout)
    wire ev_match = key_we && key_on && guide_en && cur_gate && (key_note == cur_note);
    wire timeout  = beat_pulse && guide_en && (entry_beats >= cur_dur - 8'd1);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ptr <= 6'd0; entry_beats <= 8'd0;
        end else if (ev_match || timeout) begin
            if (SONG_LOOP && (next_word == 16'h0000)) begin
                ptr <= 6'd0;                          // 循环模式: 回曲首
            end else begin
                ptr <= next_ptr;                      // 曲终格 word=0 -> guide_en 自动落 0
            end
            entry_beats <= 8'd0;
        end else if (beat_pulse && guide_en) begin
            entry_beats <= entry_beats + 8'd1;
        end
    end

    // ================= 绿闪 (按对) / 红 (超时) =================
    reg [NPIX-1:0] flash_map;
    reg [31:0]     flash_cnt;
    wire flash_set = ev_match && in_win;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flash_map <= {(NPIX){1'b0}}; flash_cnt <= 32'd0;
        end else if (flash_set) begin
            flash_map[ev_idx] <= 1'b1; flash_cnt <= FLASH_CLKS;
        end else if (flash_cnt != 32'd0) begin
            flash_cnt <= flash_cnt - 32'd1;
            if (flash_cnt == 32'd1) flash_map <= {(NPIX){1'b0}};
        end
    end

    reg [4:0]  miss_pix;
    reg        miss_valid;
    reg [31:0] miss_cnt;
    wire miss_set = timeout && cur_gate;              // 休止符不算 miss
    wire mis_in_win = (cur_note >= NOTE_BASE) && (cur_note < NOTE_BASE + NPIX);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            miss_cnt <= 32'd0; miss_pix <= 5'd0; miss_valid <= 1'b0;
        end else if (miss_set) begin
            miss_cnt <= MISS_CLKS; miss_pix <= cur_note - NOTE_BASE; miss_valid <= mis_in_win;
        end else if (miss_cnt != 32'd0) begin
            miss_cnt <= miss_cnt - 32'd1;
        end
    end

    // ================= 全帧重画 (每帧快照, 无脏标记) =================
    // 每帧都重画 => 两块缓冲交替刷新, 不存在"陈旧块"被发送 (也顺带杜绝任何
    // 未初始化存储被读出); 颜色仲裁是组合逻辑, 快照天然是最新状态。
    // 代价 24 写/0.8ms, 可忽略。
    reg       sw_st;                                  // 0=IDLE 1=RUN
    reg [4:0] sw_idx;
    wire sweep_last  = (sw_st == 1'b1) && (sw_idx == NPIX - 1);

    // ================= 颜色仲裁 (组合, 每像素独立) =================
    // 全部 <= 85 (1/3 亮度)。GRB 打包: [23:16]=G [15:8]=R [7:0]=B
    function [6:0] breath_lut(input [2:0] s);         // 10->85->10 三角
        case (s)
            3'd1: breath_lut = 7'd35;
            3'd2: breath_lut = 7'd60;
            3'd3: breath_lut = 7'd85;
            3'd4: breath_lut = 7'd60;
            3'd5: breath_lut = 7'd35;
            default: breath_lut = 7'd10;
        endcase
    endfunction

    function [23:0] color_of(input [4:0] idx);
        reg [6:0] wv;
        reg [13:0] prod;                          // 显式 14 位乘积: 若依赖表达式上下文,
        begin                                     // (a*b)>>7 会把乘积先截到 7 位再移位,
            prod = vel_win[idx] * 8'd40;          // 结果恒 0 (Gowin EX3041 就是这个坑)
            wv   = 7'd16 + prod[13:7];            // 力度 0..127 -> 亮度 16..55
            if (alarm_cnt != 32'd0)
                color_of = blink_cnt[21] ? {8'd0, 8'd85, 8'd0} : 24'd0;      // 全条红闪
            else if (flash_map[idx])
                color_of = {8'd85, 8'd0, 8'd0};                               // 绿闪=按对
            else if (guide_en && cur_gate && (cur_note == NOTE_BASE + idx))
                color_of = {8'd0, 8'd0, {1'b0, breath_lut(breath_step)}};     // 蓝=下一音
            else if (miss_valid && (miss_cnt != 32'd0) && (miss_pix == idx))
                color_of = {8'd0, 8'd40, 8'd0};                               // 红=超时没按
            else if (note_on[NOTE_BASE + idx])
                color_of = {wv, wv, wv};                                      // 白=正在响
            else
                color_of = 24'd0;
        end
    endfunction

    // sweep: frame_start 后 24 拍内把整帧快照写进 phy 的空闲缓冲
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sw_st <= 1'b0; sw_idx <= 5'd0;
            px_we <= 1'b0; px_waddr <= 5'd0; px_wdata <= 24'd0;
        end else begin
            px_we <= 1'b0;
            case (sw_st)
                1'b0: if (frame_start) begin
                    sw_st <= 1'b1; sw_idx <= 5'd0;
                end
                1'b1: begin
                    px_we    <= 1'b1;
                    px_waddr <= sw_idx;
                    px_wdata <= color_of(sw_idx);
                    if (sw_idx == NPIX - 1) sw_st <= 1'b0;
                    sw_idx <= sw_idx + 5'd1;
                end
            endcase
        end
    end
endmodule
