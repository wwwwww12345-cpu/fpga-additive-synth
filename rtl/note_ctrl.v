//=============================================================================
// note_ctrl.v —— 键事件层 与 合成引擎 之间的参考实现 (声部分配 + 音高换算 + 表情)
//
// 分工边界(这是给别人对接的"契约"):
//   ┌──────────────┐  键事件   ┌───────────┐  音符事件  ┌──────────────┐
//   │ 交互/传感器层 │ ────────▶ │ note_ctrl │ ─────────▶ │ partial_engine│
//   │ (触摸/光电/   │ key_we    │ (本模块)  │ param_*    │ 32×16 分量    │
//   │  压力/手势)   │ key_note  │ 声部分配   │ pitch_*    │              │
//   │  ← 不是我负责 │ key_on    │ 音高换算   │ (连续调制)  │              │
//   └──────────────┘ key_vel   │ 表情调制   └──────────────┘
//                              └───────────┘
//   交互层只需要回答三个问题: 哪个键(MIDI 音号)? 按下还是抬起? 力度多少?
//   连续量(弯音/颤音深度/颤音速率/滑音速率)可以给, 不给就保持 0 => 无表情。
//
// 职责:
//   1) 键事件 FIFO(深 4) + key_ready 背压, 保证不丢事件
//   2) 32 声部分配: 优先空闲 -> 其次正在释放的 -> 都没有就抢占(round-robin)
//   3) 音高: note_ftw 表(Q0.32, fs=48k) >> 8 得到 24bit FTW
//   4) 表情(控制率 1500Hz 更新):
//        滑音 glide:  当前 FTW 按 glide_inc 逼近目标
//        弯音 bend:   FTW × (1 + bend×BEND_SEMI 半音的比值)
//        颤音 vibrato: 三角 LFO × vib_depth 调制 FTW
//      三个都作用在同一处, 最后经 pitch_we 口写进引擎
//   5) note_on/off 经 param_we 口送进引擎(引擎有 4 深 FIFO, 尊重 evt_full 背压)
//
// 时序: 事件从 key_we 到引擎生效 ≤ 2 个样本周期(≈42us), 远优于赛题 ≤5ms
//=============================================================================
`timescale 1ns/1ps

module note_ctrl #(
    parameter VOICES     = 32,
    parameter PHASE_W    = 24,
    parameter CTRL_L2    = 5,                       // 控制率 = fs / 2^CTRL_L2
    parameter BEND_Q15   = 16'd4014,                // ±32767 弯音对应的频率比例(Q1.15) = 0.1225 ≈ ±2 半音
    parameter NOTE_FILE  = "rtl/rom/note_ftw.hex"
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   sample_req,       // I2S 的样本脉冲(用来对齐控制率)

    //---------------- 键事件接口 (交互层的边界) ----------------
    input  wire                   key_we,
    input  wire [6:0]             key_note,         // MIDI 音号 0..127
    input  wire                   key_on,           // 1=按下 0=抬起
    input  wire [6:0]             key_vel,          // 力度 0..127
    output wire                   key_ready,        // 0 = FIFO 满, 上层必须停一拍

    //---------------- 连续表情量 (可选项, 不给就全 0) ----------------
    input  wire signed [15:0]     bend_q15,         // 弯音: ±32767 ≈ ±BEND 半音
    input  wire [15:0]            vib_depth_q15,    // 颤音深度: 相对频率偏移(Q1.15), 0=无
    input  wire [15:0]            vib_inc,          // 颤音速率: LFO 每控制率的相位增量
    input  wire [15:0]            glide_q15,        // 滑音速率: 每控制率逼近目标的比例, 0=立即到音

    //---------------- ADSR 面板 (透传给引擎) ----------------
    input  wire [15:0]            adsr_a_inc,
    input  wire [15:0]            adsr_d_inc,
    input  wire [15:0]            adsr_sus,
    input  wire [15:0]            adsr_r_inc,

    //---------------- 引擎: 音符事件口 ----------------
    output reg                    eng_we,
    output reg  [4:0]             eng_voice,
    output reg  [PHASE_W-1:0]     eng_ftw,
    output reg                    eng_on,
    output reg  [6:0]             eng_vel,
    output reg  [6:0]             eng_note,
    input  wire                   eng_evt_full,

    //---------------- 引擎: 连续音高调制口 ----------------
    output reg                    pitch_we,
    output reg  [4:0]             pitch_voice,
    output reg  [PHASE_W-1:0]     pitch_ftw,

    //---------------- 调试/可视化 ----------------
    output reg  [VOICES-1:0]      voice_busy,       // 正在发声(不含释放)
    output reg  [VOICES-1:0]      voice_rel,        // 正在释放
    output reg  [5:0]             busy_cnt,
    output reg                    steal_flag,       // 发生过抢占
    output reg  [7:0]             drop_cnt          // 事件被丢次数(应恒 0)
);

    localparam VW    = 5;
    localparam FF    = 4;                           // 键事件 FIFO 深度

    //---------------------------------------------------------------- 音高表
    reg [31:0] ftw_tab [0:127];
    initial $readmemh(NOTE_FILE, ftw_tab);

    //---------------------------------------------------------------- 键事件 FIFO
    reg [6:0] k_note [0:FF-1];
    reg       k_on   [0:FF-1];
    reg [6:0] k_vel  [0:FF-1];
    reg [1:0] k_wp, k_rp;
    reg [2:0] k_cnt;
    assign key_ready = (k_cnt != FF[2:0]);
    wire k_empty = (k_cnt == 3'd0);
    // 2026-11-01 修复：k_cnt 原来在同一个 always 块里出现两次非阻塞赋值
    //   （入队 :196 `k_cnt <= k_cnt + 1`、出队 :248 `k_cnt <= k_cnt - 1`），
    //   同拍既入队又出队时后写的 -1 生效，计数少 1 → k_empty 提前置 1 →
    //   事件卡在 FIFO 里，直到下一次 push 才被顶出来（整体滞后一个事件）。
    //   症状：大三和弦"按下正常 / 松开冒出一个三度音 / 第二次按下没声 /
    //   第二次松开才响和弦"（和弦一次 3 个事件连发，push+pop 同拍几乎必现）。
    //   改法与 keyhub 的 wcount 一致：整块里只对一个 net 结果赋值一次。
    wire k_push = key_we && key_ready;

    //---------------------------------------------------------------- 声部状态
    reg [6:0]        v_note [0:VOICES-1];
    reg [PHASE_W-1:0] v_ftw_cur [0:VOICES-1];       // 滑音用: 当前 FTW
    reg [PHASE_W-1:0] v_ftw_tgt [0:VOICES-1];       // 目标 FTW(表值)
    reg [VW-1:0]     steal_ptr;

    //---------------------------------------------------------------- 控制率
    reg [CTRL_L2-1:0] samp_cnt;
    reg               ctrl_tick;
    // 2026-11-02 表情扫描 —— 三级流水（每声部 3 拍）
    //   第1拍: 只做选择 —— 把 v_ftw_cur/v_ftw_tgt/忙闲按 vsel 选出来寄存（这一拍不做乘法）
    //   第2拍: 滑音 —— dcur=|tgt_r-cur_r|, stepq=(dcur>>8)*glide_q15>>7, glided 寄存
    //   第3拍: 调制 —— modulated = glided_r + ((glided_r*dev_r)>>>15), 发 pitch_we, 写回 v_ftw_cur
    //   dev 在第1拍寄存 => 同一声部三拍内 LFO 不漂移，数值与旧版逐位相同。
    reg               sweep;                         // 1 = 一轮扫描进行中
    reg [1:0]         ph;                            // 0/1/2 = 三级
    reg [VW-1:0]      vsel;                          // 当前声部
    reg [PHASE_W-1:0] cur_r, tgt_r;                  // 第1拍选出的操作数
    reg [PHASE_W-1:0] glided_r;
    reg signed [31:0] dev_r;
    reg [VW-1:0]      gv_r;
    reg               gbusy_r;

    //---------------------------------------------------------------- 三角波 LFO
    // 量程 ±32767: 这样 vib_depth_q15/32768 就是"相对频率偏移"的直观含义
    // (踩过的坑: 一开始只摆到 ±16384, 深度实际只有设定值的一半)
    reg signed [16:0] lfo;                           // -32768 .. +32767
    reg               lfo_dir;                       // 1=上升

    integer i;

    // 空闲声部选择(优先最低号)
    reg [VW-1:0] free_idx;
    reg          has_free, has_rel;
    reg [VW-1:0] rel_idx;
    always @* begin
        free_idx = 0; has_free = 0; rel_idx = 0; has_rel = 0;
        for (i = 0; i < VOICES; i = i + 1) begin
            if (!voice_busy[i] && !voice_rel[i]) begin
                if (!has_free) begin free_idx = i[VW-1:0]; has_free = 1; end
            end else if (voice_rel[i]) begin
                if (!has_rel) begin rel_idx = i[VW-1:0]; has_rel = 1; end
            end
        end
    end

    // 找某个正在发声的声部(用于 note off): 从高号往低号找, **找到即停**
    // (放最近加入的同音声部。2026-10-21 修: 旧写法漏了"找到即停", 循环无脑
    //  覆盖到结束, 实际放掉的是最低号匹配声部; 同音占两声部时另一个会挂住)
    reg [VW-1:0] off_idx;
    reg          has_off;
    reg [6:0]    off_note;
    always @* begin
        off_idx = 0; has_off = 0;
        for (i = VOICES-1; i >= 0; i = i - 1)
            if (!has_off && voice_busy[i] && v_note[i] == off_note) begin
                off_idx = i[VW-1:0]; has_off = 1;
            end
    end

    //---------------------------------------------------------------- 事件分派状态机
    localparam E_IDLE = 2'd0, E_SEND = 2'd1;
    reg [1:0] est;
    reg [6:0] e_note, e_vel;
    reg       e_on;
    // 本拍真的会出队一个事件（与 E_IDLE 分支里的条件逐字一致）
    wire k_pop = (est == E_IDLE) && !k_empty && !eng_evt_full;

    // 表情计算(组合): dev = 弯音 + 颤音, 单位 Q1.15 频率比例
    wire signed [31:0] bend_dev = ($signed(bend_q15) * $signed({1'b0, BEND_Q15})) >>> 15;
    wire signed [31:0] vib_dev  = ($signed(vib_depth_q15) * lfo) >>> 15;
    wire signed [31:0] dev      = bend_dev + vib_dev;

    // 扫描第2拍: 滑音用第1拍选出来寄存的 cur_r/tgt_r —— 组合链里没有 32 选 1 mux 了
    wire [PHASE_W-1:0] dcur   = (tgt_r > cur_r) ? (tgt_r - cur_r) : (cur_r - tgt_r);
    wire [PHASE_W-1:0] stepq  = (dcur >> 8) * glide_q15 >> 7;   // 近似: 差值 × glide_q15 / 32768
    wire [PHASE_W-1:0] glided = (glide_q15 == 0) ? tgt_r :
                                (tgt_r > cur_r) ? (cur_r + (stepq == 0 ? 1'b1 : stepq)) :
                                (cur_r - (stepq == 0 ? 1'b1 : stepq));
    // 第3拍: 表情作用在滑音后的音高上（glided_r / dev_r 都是寄存值）
    wire signed [PHASE_W+15:0] modulated_r = $signed({1'b0, glided_r})
                                           + (($signed({1'b0, glided_r}) * dev_r) >>> 15);
    wire [PHASE_W-1:0] ftw_out_r = modulated_r[PHASE_W-1:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            k_wp <= 0; k_rp <= 0; k_cnt <= 0;
            est <= E_IDLE; eng_we <= 0; eng_voice <= 0; eng_ftw <= 0; eng_on <= 0; eng_vel <= 0;
            eng_note <= 0;
            pitch_we <= 0; pitch_voice <= 0; pitch_ftw <= 0;
            voice_busy <= 0; voice_rel <= 0; busy_cnt <= 0;
            steal_flag <= 0; drop_cnt <= 0; steal_ptr <= 0;
            samp_cnt <= 0; ctrl_tick <= 0; sweep <= 1'b0; ph <= 2'd0; vsel <= {VW{1'b0}};
            cur_r <= 0; tgt_r <= 0;
            lfo <= 0; lfo_dir <= 1'b1;
            glided_r <= 0; dev_r <= 0; gv_r <= 0; gbusy_r <= 1'b0;
            e_note <= 0; e_vel <= 0; e_on <= 0; off_note <= 0;
            for (i = 0; i < VOICES; i = i + 1) begin
                v_note[i] <= 0; v_ftw_cur[i] <= 0; v_ftw_tgt[i] <= 0;
            end
        end else begin
            eng_we   <= 1'b0;
            pitch_we <= 1'b0;

            //========================================== 1) 键事件入队
            if (key_we) begin
                if (key_ready) begin
                    k_note[k_wp] <= key_note;
                    k_on[k_wp]   <= key_on;
                    k_vel[k_wp]  <= key_vel;
                    k_wp  <= k_wp + 1'b1;
                end else begin
                    drop_cnt <= drop_cnt + 8'd1;      // 上层没看 key_ready, 记一笔
                end
            end
            // k_cnt 统一在这里加减一次（见上方 2026-11-01 修复说明）
            k_cnt <= k_cnt + (k_push ? 3'd1 : 3'd0) - (k_pop ? 3'd1 : 3'd0);

            //========================================== 2) 控制率节拍 + LFO
            if (sample_req) begin
                if (samp_cnt == {CTRL_L2{1'b1}}) begin
                    samp_cnt  <= 0;
                    ctrl_tick <= 1'b1;
                    // 三角波 LFO: 每控制率走 vib_inc
                    if (lfo_dir) begin
                        if (lfo + $signed({1'b0, vib_inc}) >= 32767) begin
                            lfo <= 32767; lfo_dir <= 1'b0;
                        end else lfo <= lfo + $signed({1'b0, vib_inc});
                    end else begin
                        if (lfo - $signed({1'b0, vib_inc}) <= -32768) begin
                            lfo <= -32768; lfo_dir <= 1'b1;
                        end else lfo <= lfo - $signed({1'b0, vib_inc});
                    end
                end else begin
                    samp_cnt  <= samp_cnt + 1'b1;
                    ctrl_tick <= 1'b0;
                end
            end

            //========================================== 3) 表情扫描 (每控制率扫 32 个音, 每音 3 拍)
            //   2026-11-02 三级流水（SETUP −6.43 → 目标 ≥0.5）:
            //     第1拍: 只做选择 cur_r/tgt_r/gv/busy + 寄存 dev（dev 必须在这一拍抓，
            //            因为 voice0 的第1拍正好落在 ctrl_tick 当拍，LFO 还是旧值，
            //            与旧实现"voice0 用旧 LFO、其余用新 LFO"完全一致）
            //     第2拍: 滑音 (dcur/stepq/glided)
            //     第3拍: 调制 (modulated_r) + 发 pitch_we + 写回 v_ftw_cur
            if (ctrl_tick || sweep) begin
                if (ctrl_tick) begin           // 新的一轮: 复位到第1拍，当拍就选 voice0
                    sweep <= 1'b1;
                    vsel  <= {VW{1'b0}};
                    ph    <= 2'd1;
                    cur_r <= v_ftw_cur[{VW{1'b0}}];
                    tgt_r <= v_ftw_tgt[{VW{1'b0}}];
                    gv_r  <= {VW{1'b0}};
                    gbusy_r <= (voice_busy[{VW{1'b0}}] || voice_rel[{VW{1'b0}}]);
                    dev_r <= dev;
                end else begin
                    case (ph)
                    2'd1: begin            // 第2拍: 滑音
                        glided_r <= glided;
                        ph       <= 2'd2;
                    end
                    2'd2: begin            // 第3拍: 调制 + 发出
                        if (gbusy_r) begin
                            v_ftw_cur[gv_r] <= glided_r;
                            pitch_we        <= 1'b1;
                            pitch_voice     <= gv_r;
                            pitch_ftw       <= ftw_out_r;
                        end
                        if (vsel == (VOICES-1)) begin
                            sweep <= 1'b0; vsel <= {VW{1'b0}}; ph <= 2'd0;
                        end else begin
                            vsel  <= vsel + 1'b1;
                            ph    <= 2'd0;
                        end
                    end
                    default: begin         // 第1拍: 只做选择
                        cur_r   <= v_ftw_cur[vsel];
                        tgt_r   <= v_ftw_tgt[vsel];
                        gv_r    <= vsel;
                        gbusy_r <= (voice_busy[vsel] || voice_rel[vsel]);
                        dev_r   <= dev;
                        ph      <= 2'd1;
                    end
                    endcase
                end
            end else begin
                sweep <= 1'b0; vsel <= {VW{1'b0}}; ph <= 2'd0;
            end

            //========================================== 4) 音符事件分派
            case (est)
            E_IDLE: begin
                if (!k_empty && !eng_evt_full) begin
                    e_note <= k_note[k_rp];
                    e_on   <= k_on[k_rp];
                    e_vel  <= k_vel[k_rp];
                    off_note <= k_note[k_rp];
                    k_rp  <= k_rp + 1'b1;
                    // k_cnt 的减法在上面统一做，这里不再重复赋值
                    est   <= E_SEND;
                end
            end

            E_SEND: begin
                // 分派: 分配声部 / 发送给引擎 (组合选出的 free_idx/has_off 已经稳定)
                if (!eng_evt_full) begin
                    eng_we <= 1'b1;
                    eng_on <= e_on;
                    eng_vel <= e_vel;
                    eng_note <= e_note;
                    if (e_on) begin
                        if (has_free) begin
                            eng_voice <= free_idx;
                            v_note[free_idx]    <= e_note;
                            v_ftw_tgt[free_idx] <= ftw_tab[e_note][PHASE_W+7:8];
                            v_ftw_cur[free_idx] <= ftw_tab[e_note][PHASE_W+7:8];
                            voice_busy[free_idx] <= 1'b1;
                            voice_rel[free_idx]  <= 1'b0;
                            eng_ftw <= ftw_tab[e_note][PHASE_W+7:8];
                            busy_cnt <= busy_cnt + 6'd1;
                        end else if (has_rel) begin
                            eng_voice <= rel_idx;
                            v_note[rel_idx]    <= e_note;
                            v_ftw_tgt[rel_idx] <= ftw_tab[e_note][PHASE_W+7:8];
                            v_ftw_cur[rel_idx] <= ftw_tab[e_note][PHASE_W+7:8];
                            voice_busy[rel_idx] <= 1'b1;
                            voice_rel[rel_idx]  <= 1'b0;
                            eng_ftw <= ftw_tab[e_note][PHASE_W+7:8];
                            busy_cnt <= busy_cnt + 6'd1;
                        end else begin                      // 抢占
                            eng_voice <= steal_ptr;
                            v_note[steal_ptr]    <= e_note;
                            v_ftw_tgt[steal_ptr] <= ftw_tab[e_note][PHASE_W+7:8];
                            v_ftw_cur[steal_ptr] <= ftw_tab[e_note][PHASE_W+7:8];
                            voice_busy[steal_ptr] <= 1'b1;
                            eng_ftw <= ftw_tab[e_note][PHASE_W+7:8];
                            steal_ptr <= steal_ptr + 1'b1;
                            steal_flag <= 1'b1;
                        end
                    end else begin
                        if (has_off) begin
                            eng_voice <= off_idx;
                            eng_ftw   <= v_ftw_cur[off_idx];
                            voice_busy[off_idx] <= 1'b0;
                            voice_rel[off_idx]  <= 1'b1;    // 交给引擎走 release
                            if (busy_cnt != 0) busy_cnt <= busy_cnt - 6'd1;
                        end else begin
                            eng_we <= 1'b0;                 // 没有对应声部, 丢弃
                        end
                    end
                    est <= E_IDLE;
                end
            end
            default: est <= E_IDLE;
            endcase
        end
    end

endmodule