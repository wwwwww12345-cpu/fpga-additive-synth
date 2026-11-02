//=============================================================================
// partial_engine_ref.v —— **冻结参考模型**（git HEAD 的 rtl/partial_engine.v 原文）
//   只改了模块名 -> partial_engine_ref。
//   用途：tb/tb_partial_engine_bitref.v 逐样本比对 audio_out（要求对齐后 0 差异）。
//   **不要改这个文件**。
//=============================================================================//=============================================================================
// partial_engine.v —— 加法合成引擎核心 (TDM 时分复用)
//
// 结构:
//   32 复音 × 16 分量 = 512 个"时隙(slot)", 每个时隙 = 一个完整振荡器:
//     独立相位累加器(24bit, 存 BSRAM) + 独立频率字 FTW_k = FTW_voice × k√(1+Bk²)
//     + 独立包络(每分量自己的 τ 衰减量) + 独立起始相位(实测相位表)
//   -> 对上赛题口径"独立发声单元 = 独立相位累加器 + 频率调控 + 包络控制"
//
// 状态为什么放 BSRAM:
//   512×(24bit 相位 + 24bit 包络) = 24Kbit -> 2 个 BSRAM(共 56);
//   用寄存器堆要 24576 个 FF(超过 23280), 而且动态索引的寄存器堆要 512:1
//   多路选择器, 会吃掉上万 LUT —— 不可行。
//
// 时序预算 (50MHz / 48kHz): 512 时隙, 1 时隙/时钟 = 512 clk, 占 1041.7 的 49.2%。
//   sine_lut 是双读口(插值要读相邻两点), 两个口正好服务 1 个时隙/时钟。
//
// 流水 (1 时隙/时钟):
//   a 段: 组合出 BSRAM 读地址 -> st_rd (下一拍有效)
//   b 段: 由 st_rd 算 FTW_k、phase_next、包络衰减 -> 同拍写回 BSRAM + 驱动 sine_lut
//   c 段: sine_lut 内部第 1 级
//   d 段: sin_out 有效 -> 累加到本音; 跨到下个音时乘 ADSR 再进混音
//
// 音符事件: param_we 进 4 深 FIFO, 在"一趟结束"时执行
//   (避免初始化那 16 次写和正在跑的趟互相覆盖; 延迟 = 1 个样本周期 20.8us)
//
// 包络省乘法: 每分量包络每 2^CTRL_L2 个样本更新一次(系数表已按
//   1-exp(-2^CTRL_L2/(τ·fs)) 生成), 控制率 1500Hz 听不出台阶, 乘法省 32 倍。
//
// 力度分层 (VEL_LAYERS=8):
//   真钢琴弹得越重, 音色越亮(高次分音占比上升), 不只是更响。做法:
//   幅度表从 16 项扩成 8 层 × 16 项(256B, 仍是一块小 ROM),
//     地址 = {layer, k} (layer 3bit 在高位, k 4bit 在低位 -> 步长 16);
//   每声部一个 layer_v[3bit] 寄存器(共 96 FF), 在音符事件的 F_INIT 第一拍由
//     layer = clamp(param_vel >> 4, 0, 7) 写入;
//   F_INIT 的 16 次时隙初始化按 (layer_v, k) 取该层幅度。
//   **逐声部 vel 乘法删除** —— 层表已经承载"该力度下的幅度", 再乘 vel 会是
//   层内二次压缩(层边界跳变)且与实测电平不符。
//   层间数据由 tools/gen_vel_layers.py 从 pp/mf/ff 三层实测在 dB 域插值得到;
//   归一化基准: ff 层峰值 = 现行 mf 表的峰值, mf/pp 依次更轻。
//   趟长不变: 分层只改了"初始化时从哪个地址取值", 一趟仍是 512 时隙 + 4 拍排空。
//=============================================================================
`timescale 1ns/1ps

module partial_engine_ref #(
    parameter VOICES     = 32,
    parameter PARTIALS   = 16,
    parameter PHASE_W    = 24,
    parameter GAIN_W     = 24,          // 包络位宽: 必须够宽, 否则小 τ 的每步衰减会被截断成 0
    parameter OUT_W      = 24,
    parameter SINE_W     = 24,          // 满表 24 位 (Q23); 16 = 旧 1/4 波 16 位表
    parameter ACC_W      = 32,
    parameter CTRL_L2    = 5,
    parameter SINE_FILE  = "rtl/rom/sine_full_1024_q23.hex",
    // 下面四张表的默认值是**历史遗留**(最早参考音是 A1)。所有顶层都会覆盖成 C4:
    //   top.v / top_vel8_int.v / top_auto_c4_v2.v -> harm_*_C4.hex
    // 单独例化本模块(老 tb/探针)若不传参, 仍会去读 A1 那四张表 —— 改动前请确认参考音。
    parameter RATIO_FILE = "rtl/rom/harm_ratio_A1.hex",
    parameter AMP_FILE   = "rtl/rom/harm_amp_A1.hex",
    parameter PHA_FILE   = "rtl/rom/harm_phase_A1.hex",
    parameter DEC_FILE   = "rtl/rom/harm_decay_ctrl_A1.hex",
    //-------------------------------------------------------------- 力度分层
    // VEL_LAYERS = 1: 旧行为, AMP_FILE 是 16 项单层表, 所有声部都读 layer 0
    // VEL_LAYERS = 8: 分层行为, AMP_FILE 是 8×PARTIALS 项的力度分层表
    //                 (tools/gen_vel_layers.py 产出), 层号 = clamp(param_vel>>4,0,7)
    // 用参数而不是改文件名: 老 tb/探针不传这个参数时行为**逐位不变**(可回滚、可对拍)
    parameter VEL_LAYERS  = 1,
    //---------------------------------------------------------- 八度多参考表 (2026-10-21)
    //   OCT_TABLES = 0: 旧行为, AMP_FILE = VEL_LAYERS×PARTIALS 项
    //   OCT_TABLES = 1: AMP_FILE = 4×(VEL_LAYERS×PARTIALS) 项, 段序 = 八度 4/5/6/7
    //                   按事件 ftw 选段 (C5/C6/C7 的频率字阈值), 修高音谐波过亮
    //   老 tb / 老顶层不传这个参数 -> 0, 行为逐位不变
    parameter OCT_TABLES  = 0,
    //---------------------------------------------------------- 4 半音一段表 (2026-10-21)
    //   Q4_TABLES = 1: AMP_FILE = 32×VEL_LAYERS×PARTIALS 项, 段号 = note[6:2]
    //   比按音修正省一个乘法器；比八度表细 3 倍
    parameter Q4_TABLES   = 0,
    //---------------------------------------------------------- 每音一张表 (2026-10-21)
    //   PN_TABLES = 1: AMP_FILE = 128×VEL_LAYERS×PARTIALS 项, 地址 {note,layer,k}
    //   放 BSRAM（同步读），F_INIT 多一拍 warm-up
    parameter PN_TABLES    = 0,
    //---------------------------------------------------------- 按音修正 (2026-10-21)
    //   PER_NOTE_CORR = 1: 读 note_corr.hex (128×16×8bit), note-on 时
    //   gain = amp × corr[note,k] >> 8；不传这个参数 -> 0，逐位不变
    parameter PER_NOTE_CORR = 0,
    parameter CORR_FILE   = "rtl/rom/note_corr.hex",
    parameter VEL_SHIFT   = 4,
    //---------------------------------------------------------- 松键释放形状 (2026-10-19)
    //   REL_RATE = 0  : 旧行为 —— 从当前 adsr_g 按 adsr_r_inc 线性降到 0
    //   REL_RATE > 0  : 指数释放 —— adsr_g -= (adsr_g*REL_RATE)>>15,
    //                   adsr_g <= REL_FLOOR 时归零。tau = 0.655ms*32768/REL_RATE
    parameter REL_RATE    = 0,
    parameter REL_FLOOR   = 16'd32,
    //---------------------------------------------------------- 音头噪声 (2026-10-20)
    //   ATK_NOISE = 0 关闭; >0 = note-on 时的噪声包络初值(Q15)
    //   噪声峰值 = (32767*ATK_NOISE)>>12; 每 0.655ms 减 ATK_DEC; 按 vel/128 缩放
    parameter [15:0] ATK_NOISE = 16'd0,
    parameter [15:0] ATK_DEC   = 16'd0
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   sample_req,

    input  wire                   param_we,
    input  wire [4:0]             param_voice,
    input  wire [PHASE_W-1:0]     param_ftw,
    input  wire                   param_on,
    input  wire [6:0]             param_vel,
    input  wire [6:0]             param_note,

    input  wire [15:0]            adsr_a_inc,
    input  wire [15:0]            adsr_d_inc,
    input  wire [15:0]            adsr_sus,
    input  wire [15:0]            adsr_r_inc,

    // ---- 连续音高调制口 (弯音/滑音/颤音): 控制率更新, 直写每音的 FTW 寄存器 ----
    // 为什么不走音符事件口: 颤音每控制率要更新所有音的 FTW, 而事件 FIFO 每个样本
    // 只能消化 1 个事件 —— 用事件口做颤音必然把 FIFO 冲爆。
    input  wire                   pitch_we,
    input  wire [4:0]             pitch_voice,
    input  wire [PHASE_W-1:0]     pitch_ftw,

    output reg signed [OUT_W-1:0] audio_out,
    output reg  [5:0]             active_voices,
    output reg                    overrun,
    output reg  [15:0]            pass_clks,
    output wire                   evt_full         // 事件 FIFO 满(上一层要停一拍)
);

    localparam PW    = 4;
    localparam SLOTS = VOICES * PARTIALS;
    localparam SW    = 9;
    localparam VW    = 5;
    localparam KMSK  = PARTIALS - 1;
    localparam LW    = (VEL_LAYERS > 1) ? $clog2(VEL_LAYERS) : 1;   // 层号位宽 (8 层 -> 3)
    localparam ABW   = PW + LW;                                     // 幅度 ROM 地址位宽 (4+3=7)

    //---------------------------------------------------------------- 系数 ROM
    reg [31:0] kratio[0:PARTIALS-1];
    reg [31:0] pha_t [0:PARTIALS-1];
    reg [31:0] dec_t [0:PARTIALS-1];
    // 幅度表: 单层 16 项 / 分层 VEL_LAYERS×PARTIALS 项。
    // 拼接索引 addr = {layer[LW-1:0], k[PW-1:0]}, 步长 = 2^PW = PARTIALS (handoff 坑 14:
    // 步长由**字段位宽**决定, 不是"我以为是几层" —— 这里 layer 在高位, 所以
    // layer*PARTIALS + k 正好落在 [0, VEL_LAYERS*PARTIALS-1] 内)
    reg [15:0] amp_t [0:(((PN_TABLES != 0) ? 128 : ((Q4_TABLES != 0) ? 32 : ((OCT_TABLES != 0) ? 8 : 1)))*VEL_LAYERS*PARTIALS)-1];
    // 按音修正表: 128 音 × 16 分音, 8bit (255≈1.0)
    reg [7:0]  corr_t [0:128*PARTIALS-1];
    initial begin
        $readmemh(RATIO_FILE, kratio);
        $readmemh(AMP_FILE,   amp_t);
        $readmemh(PHA_FILE,   pha_t);
        $readmemh(DEC_FILE,   dec_t);
        if (PER_NOTE_CORR != 0) $readmemh(CORR_FILE, corr_t);
    end

    //---------------------------------------------------------------- 时隙状态 BSRAM
    // {phase[PHASE_W-1:0], gain[GAIN_W-1:0]}
    // 读: 同步(一个读口); 写: 组合控制, 同拍生效(避免"晚一拍"导致清零/初始化漏写)
    reg [PHASE_W+GAIN_W-1:0] st [0:SLOTS-1];
    reg [PHASE_W+GAIN_W-1:0] st_rd;
    // (读/写口的 always 块放在下面, 因为 rd_addr/wr_* 要先声明)
    // always @(posedge clk) st_rd <= st[rd_addr];
    // always @(posedge clk) if (wr_en) st[wr_addr] <= wr_data;

    //---------------------------------------------------------------- 每音寄存器
    reg [PHASE_W-1:0] ftw_v   [0:VOICES-1];
    reg [15:0]        adsr_g  [0:VOICES-1];
    // 样本级 ADSR 平滑: ags 每样本逼近 adsr_g (一阶, tau=8 样本≈0.17ms),
    // 消除控制率台阶(起振/释放的"刺")
    reg signed [16:0] ags_v   [0:VOICES-1];
    reg [1:0]         adsr_st [0:VOICES-1];    // 0=off 1=attack 2=decay 3=sustain
    reg               rel_v   [0:VOICES-1];
    // 力度层寄存器: 3bit × 32 = 96 FF (VEL_LAYERS=1 时综合掉)
    reg [LW-1:0]      layer_v [0:VOICES-1];

    //---------------------------------------------------------------- 正弦表
    // 2026-10-14 换表: sine_lut(1/4波+象限镜像+取负, 257深) -> sine_lut_full(整周期满表, 1024深)
    //   理由: 满表路径已在硅片上逐位验证 (probe_630_interp_ab 长段 1312/1312, 0 LSB 偏差);
    //         1/4波路径在同等验证下炸音。满表把 镜像寻址 / 取负 / 257深ROM 三者一次性绕开。
    //   端口延迟已实测: 两模块**相同**, 均为 2 拍 (见 D:\piano_sim\tb_latency.v) -> 流水不用调。
    //   定标: SINE_W 16->24 使 sine_out 数值大 2^8 倍, 故 contrib 右移多 8 位 (SINE_SHR)。
    reg  [PHASE_W-1:0]       sine_phase;
    wire signed [SINE_W-1:0] sine_out;
    localparam integer SINE_SHR = (SINE_W > 16) ? (SINE_W - 16) : 0;   // 24位表 -> 8
    sine_lut_full #(.PHASE_W(PHASE_W), .IDX_W(10), .FRAC_W(12), .OUT_W(SINE_W),
                    .QN(1024), .ROM_FILE(SINE_FILE)) u_sine (
        .clk(clk), .rst_n(rst_n), .interp_en(1'b1),
        .phase(sine_phase), .sin_out(sine_out)
    );

    //---------------------------------------------------------------- 控制状态
    localparam F_IDLE = 3'd0, F_RUN = 3'd1, F_FIN = 3'd2, F_CLR = 3'd3, F_INIT = 3'd4,
                   F_RMP = 3'd5;   // 2026-10-26: 输出增益斜坡的第二拍(乘法/钳位), 拆开关键路径
    reg [2:0]  fsm;
    reg [SW:0] slot;
    reg [SW:0] clk_cnt;
    reg [CTRL_L2-1:0] samp_cnt;
    reg        decay_en;
    reg [5:0]  adsr_cyc;
    reg        adsr_sweep;
    // ADSR 扫描两级流水：A 拍寄存式读出，B 拍运算写回。
    //   目的: 切断 "32 选 1 mux -> 释放乘法 -> 写回" 的组合长链（V3 的最差路径）。
    //   逐位等价: 公式不变、每声部每采样更新一次、写回顺序不变；只多 1 拍（每采样 1024 拍，引擎用 516，余量充足）。
    reg [15:0] sg_q;
    reg [1:0]  sst_q;
    reg        srel_q;
    reg [VW-1:0] sidx_q;
    reg        sval_q;

    reg                b_v, c_v, d_v;
    reg [SW-1:0]       b_slot;
    reg [VW-1:0]       b_voice, c_voice, d_voice;
    reg                b_klast, c_klast, d_klast;
    reg [GAIN_W-1:0]   b_gain, c_gain, d_gain;

    wire [SW-1:0] cur = slot[SW-1:0] - 1'b1;    // b 段正在处理的时隙
    wire [PW-1:0] k_idx = cur[PW-1:0];
    wire [VW-1:0] v_idx = cur[PW +: VW];
    wire [PHASE_W-1:0] ph_now = st_rd[PHASE_W+GAIN_W-1:GAIN_W];
    wire [GAIN_W-1:0]  gn_now = st_rd[GAIN_W-1:0];

    wire [63:0]        ftw_prod = ftw_v[v_idx] * kratio[k_idx];
    wire [PHASE_W-1:0] ftw_k    = ftw_prod[PHASE_W+15:16];
    wire [PHASE_W-1:0] ph_next  = ph_now + ftw_k;
    wire [63:0]        dprod    = gn_now * dec_t[k_idx];
    wire [GAIN_W-1:0]  gn_dec   = gn_now - dprod[GAIN_W+31:32];
    wire [GAIN_W-1:0]  gn_next  = decay_en ? gn_dec : gn_now;

    reg signed [ACC_W-1:0] acc_voice, acc_mix;
    // 定标: 旧式 (SINE_W=16) 为 (sine_out * d_gain) >>> 23。
    //       满表 24 位时 sine_out 大 2^8 倍 -> 先 >>> SINE_SHR 再乘, 与旧式**数值等价**
    //       (右移在定点乘法前做, 不改变结果, 因为乘数 d_gain 是整数)。
    wire signed [47:0] contrib = (($signed(sine_out) >>> SINE_SHR) * $signed({1'b0, d_gain})) >>> 23;
    wire signed [47:0] vsum    = acc_voice + contrib;
    wire signed [47:0] vscaled = ($signed(vsum) * $signed(ags_v[d_voice])) >>> 15;

    //---------------------------------------------------------------- 音符事件 FIFO (深度 4)
    reg [4:0]         q_voice [0:3];
    reg               q_on    [0:3];
    reg [6:0]         q_vel   [0:3];
    reg [6:0]         q_note  [0:3];
    reg [PHASE_W-1:0] q_ftw   [0:3];
    reg [1:0]         q_wp, q_rp;
    reg [2:0]         q_cnt;
    assign evt_full = (q_cnt == 3'd4);
    wire   evt_empty = (q_cnt == 3'd0);

    // 当前正在执行的事件
    reg [VW-1:0]      i_voice;
    reg               evt_on;
    reg [7:0]         i_vel;
    reg [6:0]         i_note;
    reg [PHASE_W-1:0] i_ftw;
    reg [PW:0]        i_k;
    reg [1:0]         i_phase;                  // 0=setup, 1=warm(仅PN), 2=写时隙

    //---------------------------------------------------------------- 组合写口
    // 读地址必须组合(打一拍会让整趟状态挪一格); 写口也组合->同拍生效,
    // 否则"晚一拍"会把清零的最后一格和 note 初始化漏掉(踩过的坑)
    wire [SW-1:0] rd_addr = slot[SW-1:0];
    wire b_active = (fsm == F_RUN) && (slot >= 1) && (slot <= SLOTS);
    wire i_active = (fsm == F_INIT) && evt_on && (i_phase == 2'd1);
    // 幅度表地址 = {layer, k}  (VEL_LAYERS=1 时 layer 恒 0 -> 退化成原来的 amp_t[k])
    wire [LW-1:0]       amp_layer = (VEL_LAYERS > 1) ? layer_v[i_voice] : {LW{1'b0}};
    // 八度段号: ftw 阈值 = C3/C4/C5/C6/C7 的频率字 (note_ftw_48828[48/60/72/84/96]>>8)
    //   段序 0..5 = 八度 2/3/4/5/6/7；6/7 段在表里是 C7 的重复（C7 以上沿用）
    wire [2:0]          amp_oct   = (OCT_TABLES != 0) ?
                                    ((i_ftw >= 24'd719150) ? 3'd5 :
                                     (i_ftw >= 24'd359575) ? 3'd4 :
                                     (i_ftw >= 24'd179787) ? 3'd3 :
                                     (i_ftw >= 24'd89893)  ? 3'd2 :
                                     (i_ftw >= 24'd44946)  ? 3'd1 : 3'd0) : 3'd0;
    // 4 半音一段: 段号 = i_note[6:2] (32 段, 0..127 音全覆盖)
    wire [4:0]          amp_q4    = (Q4_TABLES != 0) ? i_note[6:2] : 5'd0;
    wire [ABW+4:0]      amp_addr  = (Q4_TABLES != 0)
                                    ? {amp_q4, amp_layer, i_k[PW-1:0]}
                                    : {2'b00, amp_oct, amp_layer, i_k[PW-1:0]};
    // 每音一张表: BSRAM 同步读（地址 {note, layer, k}）
    reg  [13:0]         amp_rd;
    reg  [15:0]         amp_q;
    always @(posedge clk) if (PN_TABLES != 0) amp_q <= amp_t[amp_rd];
    wire [15:0]         amp_val = (PN_TABLES != 0) ? amp_q : amp_t[amp_addr];
    // gain_init 按配置二选一:
    //   VEL_LAYERS=1 (旧行为/默认): gain = amp * vel * 2 —— 与改动前公式逐位一致。
    //     评审教训: 曾把 vel 缩放在默认路径也删掉, 导致 vel=96 比旧固件响 2.5dB、
    //     vel=64 响 6dB、vel=0 不再静音 —— "板上无回归"的声明是错的, 已修回。
    //   VEL_LAYERS>1 (分层): 层级本身承载该力度的幅度(含实测频谱形状), 不再乘 vel
    //     —— 再乘会把层内二次压缩, 层边界(vel 79->80)出现跳变且与实测电平不符。
    //     gain 从 Q1.15 <<8 成 Q1.23, 与旧行为同一量纲 (纯移位, 不花资源)。
    // 按音修正: gain = amp × corr[note,k] >> 8（PER_NOTE_CORR=0 时逐位不变）
    wire [15:0] amp_raw = amp_val;
    wire [7:0]  corr_v  = (PER_NOTE_CORR != 0) ? corr_t[{i_note, i_k[PW-1:0]}] : 8'hFF;
    wire [31:0] amp_c   = (PER_NOTE_CORR != 0) ? (({16'b0, amp_raw} * corr_v) >> 8)
                                               : {16'b0, amp_raw};
    wire [31:0] gain_init = (VEL_LAYERS > 1) ? (amp_c << 8)
                                             : ((amp_raw * i_vel) << 1);
    wire        wr_en   = (fsm == F_CLR) || b_active || i_active;
    wire [SW-1:0] wr_addr = (fsm == F_CLR)   ? slot[SW-1:0] :
                            (fsm == F_INIT)  ? ((i_voice * PARTIALS) + i_k[PW-1:0]) :
                                               cur;
    wire [PHASE_W-1:0] pha_init = pha_t[i_k[PW-1:0]][PHASE_W+7:8];
    wire [PHASE_W+GAIN_W-1:0] wr_data =
                            (fsm == F_CLR)  ? {(PHASE_W+GAIN_W){1'b0}} :
                            (fsm == F_INIT) ? {pha_init, gain_init[GAIN_W-1:0]} :
                                              {ph_next, gn_next};

    // 状态 BSRAM 的读(同步) / 写(组合控制, 同拍生效)
    always @(posedge clk) st_rd <= st[rd_addr];
    always @(posedge clk) if (wr_en) st[wr_addr] <= wr_data;

    integer i;
    //------------------------------------------------------------ 饱和到 24bit
    localparam signed [ACC_W-1:0] SAT_MAX =  (1 <<< (OUT_W-1)) - 1;
    localparam signed [ACC_W-1:0] SAT_MIN = -(1 <<< (OUT_W-1));
    function signed [OUT_W-1:0] sat24;
        input signed [ACC_W-1:0] v;
        input integer sh;
        reg signed [ACC_W-1:0] s;
        begin
            s = v <<< sh;
            if (s > SAT_MAX)      sat24 = SAT_MAX[OUT_W-1:0];
            else if (s < SAT_MIN) sat24 = SAT_MIN[OUT_W-1:0];
            else                  sat24 = s[OUT_W-1:0];
        end
    endfunction

    //---------------------------------------------------------- 输出增益斜坡 (2026-10-26)
    // 病根: fin_sh 按 active_voices 分档 (1->8, 2~3->7, 4~7->6...)，第二个音按下时
    //   正在响的音整体乘 0.5 = -6.02dB 的**台阶**，台阶正好落在新音的音头上，
    //   听感就是"音头爆音/咔一下"。量化见 docs/分析_音头与吉他_20261026.md，
    //   听感样本 evidence/183_attack_vel/c4_then_e4_shiftstep.wav。
    // 做法: 声部数跨档时不让 fin_sh 立刻生效，实际使用的移位 sh_use 一次只走一档，
    //   并在 RAMP_LEN 个样本内用 1 个乘法器把增益线性搬到新档（16bit 域，低 8 位本来
    //   就被下游丢弃）。不分档时与旧实现逐位一致: out = sat24(acc_mix, fin_sh)，低 8 位=0。
    // 输出级移位: 按 active_voices 选(1 声部 8 -> 每翻倍少 1)
    wire [3:0] fin_sh = (active_voices <= 6'd1)  ? 4'd8 :
                        (active_voices <= 6'd3)  ? 4'd7 :
                        (active_voices <= 6'd7)  ? 4'd6 :
                        (active_voices <= 6'd15) ? 4'd5 :
                        (active_voices <= 6'd31) ? 4'd4 : 4'd3;
    localparam RAMP_LEN = 9'd255;              // 每档 256 样本 ≈ 5.2ms @48.8ksps
    reg  [3:0]  sh_use;                        // 当前实际使用的移位 (8..3)
    reg  [8:0]  rmp_k;                         // 斜坡进度 0..511
    reg         rmp_act;
    wire        rmp_attn = (fin_sh < sh_use);  // 声部变多 -> fin_sh 变小 -> 增益要衰减
    // a16 = (acc_mix <<< sh_use) >>> 8 = acc_mix >>> (8 - sh_use)
    wire signed [ACC_W-1:0] a16_ext = acc_mix >>> (4'd8 - sh_use);
    wire signed [15:0] a16 = (a16_ext > 32'sd32767)  ? 16'sd32767 :
                             (a16_ext < -32'sd32768) ? -16'sd32768 : a16_ext[15:0];
    // 下坡(增益变小)时按 |a16| 的一半起步: out = a16 - (a16 - a16/2)*k/4096 -> 收敛到 a16/2
    //   注意符号: 必须用 (a16 - (a16>>>1)) 而不是 (a16>>>1)，否则负数会越减越大(撞饱和)
    wire signed [15:0] rmul_in = rmp_attn ? (a16 - (a16 >>> 1)) : a16;
    wire [11:0]        rmp_kq  = {rmp_k, 3'b000};            // 0..4088 ≈ 0..4096
    // 时序(2026-10-26): F_FIN 只算到 rmul_in 并打一拍，乘法/加/钳位放到 F_RMP 的下一拍
    reg  signed [15:0] a16_r, rmul_r;
    reg  [11:0]        kq_r;
    reg                attn_r, act_r;
    wire signed [27:0] rprod_r = rmul_r * $signed({1'b0, kq_r});   // 16b x 12b -> 1 DSP
    wire signed [15:0] rterm_r = rprod_r >>> 12;                   // ≈ a16 * k/4096
    wire signed [16:0] a16_ramp_r = act_r
                                  ? (attn_r ? ($signed({a16_r[15], a16_r}) - rterm_r)
                                            : ($signed({a16_r[15], a16_r}) + rterm_r))
                                  : $signed({a16_r[15], a16_r});
    wire signed [23:0] out24_ramp = (a16_ramp_r >  17'sd32767) ? 24'sh7FFFFF :
                                    (a16_ramp_r < -17'sd32768) ? 24'sh800000 :
                                    {a16_ramp_r[15:0], 8'h00};

    //---------------------------------------------------------- 音头噪声 ROM (2026-10-21)
    // 用一张 256 点的"低通噪声脉冲"表, note-on 时顺序读出; 无滤波状态, 模型可逐位复刻
    reg signed [15:0] atk_rom [0:255];
    initial $readmemh("rtl/rom/atk_noise_rom.hex", atk_rom);
    reg  [7:0]  atk_pos;
    reg         atk_act;
    reg  [14:0] atk_scale;
    wire signed [15:0] atk_smp  = atk_rom[atk_pos];
    wire signed [30:0] atk_prod = atk_smp * $signed({1'b0, atk_scale});
    wire signed [23:0] atk_n    = atk_prod >>> 12;
    wire [15:0] atk_scale_c = (({16'd0, ATK_NOISE} * {24'd0, i_vel}) >> 7 > 16'd32767)
                             ? 16'd32767 : (({16'd0, ATK_NOISE} * {24'd0, i_vel}) >> 7);

    // 输出级: 按 active_voices 选移位, 叠加音头噪声后饱和到 24bit
    // 输出级: 移位 fin_sh 已上移到"输出增益斜坡"一节声明(2026-10-26)
    function signed [OUT_W-1:0] sat_add;
        input signed [OUT_W-1:0] a;
        input signed [23:0]      b;
        reg   signed [24:0]      s;
        begin
            s = $signed(a) + $signed(b);
            if (s > 25'sd8388607)       sat_add = 24'sh7FFFFF;
            else if (s < -25'sd8388608) sat_add = 24'sh800000;
            else                        sat_add = s[OUT_W-1:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fsm <= F_CLR; slot <= 0; clk_cnt <= 0; samp_cnt <= 0;
            audio_out <= 0; acc_voice <= 0; acc_mix <= 0;
            overrun <= 0; pass_clks <= 0;
            sine_phase <= 0; decay_en <= 0;
            b_v <= 0; c_v <= 0; d_v <= 0;
            b_slot <= 0; b_voice <= 0; c_voice <= 0; d_voice <= 0;
            b_klast <= 0; c_klast <= 0; d_klast <= 0;
            b_gain <= 0; c_gain <= 0; d_gain <= 0;
            active_voices <= 0; adsr_cyc <= 0; adsr_sweep <= 0; sval_q <= 1'b0; sg_q <= 16'd0; sst_q <= 2'd0; srel_q <= 1'b0; sidx_q <= {VW{1'b0}};
            q_wp <= 0; q_rp <= 0; q_cnt <= 0;
            i_voice <= 0; evt_on <= 0; i_vel <= 0; i_ftw <= 0; i_k <= 0; i_phase <= 0;
            i_note <= 0;
            atk_pos <= 8'd0; atk_act <= 1'b0; atk_scale <= 15'd0;
            sh_use <= 4'd8; rmp_k <= 9'd0; rmp_act <= 1'b0;
            a16_r <= 16'sd0; rmul_r <= 16'sd0; kq_r <= 12'd0; attn_r <= 1'b0; act_r <= 1'b0;
            for (i = 0; i < VOICES; i = i + 1) begin
                ftw_v[i] <= 0; adsr_g[i] <= 0; adsr_st[i] <= 0; rel_v[i] <= 0;
                ags_v[i] <= 0;
                layer_v[i] <= 0;
            end
        end else begin

            // 音头噪声: 每样本推进一次; note-on 时在 F_INIT 重置
            // 2026-10-26: 2 倍速读出(5.24ms -> 2.62ms, 频谱上移) + 每 32 样本按 ATK_DEC 衰减
            //   (ATK_DEC 原来只在注释里存在, 代码里根本没接 -> 恒幅 5ms 的低频 thump,
            //    就是用户听到的"开头那一下不对劲")。ATK_NOISE 幅度不动。
            if (sample_req && atk_act) begin
                if (atk_pos >= 8'd254) atk_act <= 1'b0;
                else                   atk_pos <= atk_pos + 8'd2;
            end
            if (atk_act && (samp_cnt == 6'd0)) begin
                atk_scale <= (atk_scale > ATK_DEC) ? (atk_scale - ATK_DEC) : 15'd0;
            end

            //================================================== 1) 音符事件入队
            //   连续音高调制(弯音/滑音/颤音)走独立口, 直接写 FTW 寄存器:
            //   放在事件之后, 保证"最新算出来的音高"赢
            if (pitch_we) ftw_v[pitch_voice] <= pitch_ftw;
            if (param_we && !evt_full) begin
                q_voice[q_wp] <= param_voice;
                q_on[q_wp]    <= param_on;
                q_vel[q_wp]   <= param_vel;
                q_note[q_wp]  <= param_note;
                q_ftw[q_wp]   <= param_ftw;
                q_wp  <= q_wp + 1'b1;
                q_cnt <= q_cnt + 1'b1;
            end

            //================================================== 2) 每分量包络的控制率节拍
            if (fsm == F_IDLE && sample_req) begin
                decay_en <= (samp_cnt == 0);
                samp_cnt <= samp_cnt + 1'b1;
                if (samp_cnt == 0) begin          // 启动一次 ADSR 扫描(每拍一个音, 32 拍)
                    adsr_sweep <= 1'b1;
                    adsr_cyc   <= 6'd0;
                end
            end
            if (fsm == F_FIN) decay_en <= 1'b0;

            //================================================== 3) ADSR 扫描（两级流水）
            if (adsr_sweep) begin
                adsr_cyc <= adsr_cyc + 1'b1;
                if (adsr_cyc > VOICES) adsr_sweep <= 1'b0;      // 多一拍排空
                sg_q   <= adsr_g[(adsr_cyc < VOICES) ? adsr_cyc[VW-1:0] : {VW{1'b0}}];
                sst_q  <= adsr_st[(adsr_cyc < VOICES) ? adsr_cyc[VW-1:0] : {VW{1'b0}}];
                srel_q <= rel_v[(adsr_cyc < VOICES) ? adsr_cyc[VW-1:0] : {VW{1'b0}}];
                sidx_q <= adsr_cyc[VW-1:0];
                sval_q <= (adsr_cyc < VOICES);
            end

            if (sval_q) begin
                if (sst_q == 2'd1) begin
                    if (sg_q + adsr_a_inc >= 16'h7FFF) begin
                        adsr_g[sidx_q]  <= 16'h7FFF;
                        adsr_st[sidx_q] <= 2'd2;
                    end else
                        adsr_g[sidx_q] <= sg_q + adsr_a_inc;
                end else if (sst_q == 2'd2) begin
                    if (sg_q <= adsr_sus + adsr_d_inc) begin
                        adsr_g[sidx_q]  <= adsr_sus;
                        adsr_st[sidx_q] <= 2'd3;
                    end else
                        adsr_g[sidx_q] <= sg_q - adsr_d_inc;
                end else if (srel_q) begin
                    // REL_RATE=0: 线性(旧行为); >0: 指数释放(定速率, 与当前电平无关)
                    if ((REL_RATE != 0) ? (sg_q <= REL_FLOOR) : (sg_q <= adsr_r_inc)) begin
                        adsr_g[sidx_q]  <= 16'd0;
                        rel_v[sidx_q]   <= 1'b0;
                        adsr_st[sidx_q] <= 2'd0;
                        if (active_voices != 0) active_voices <= active_voices - 6'd1;
                    end else if (REL_RATE != 0)
                        adsr_g[sidx_q] <= sg_q - ((sg_q * REL_RATE) >> 15);
                    else
                        adsr_g[sidx_q] <= sg_q - adsr_r_inc;
                end
            end

            //================================================== 4) 主状态机
            case (fsm)
            //---- 上电清零: BSRAM 内容上电不确定, 必须全部写 0
            F_CLR: begin
                b_v <= 0; c_v <= 0; d_v <= 0;
                if (slot == SLOTS - 1) begin fsm <= F_IDLE; slot <= 0; end
                else                          slot <= slot + 1'b1;
            end

            F_IDLE: begin
                b_v <= 0; c_v <= 0; d_v <= 0;
                if (sample_req) begin
                    fsm <= F_RUN; slot <= 0; clk_cnt <= 0;
                    acc_voice <= 0; acc_mix <= 0; overrun <= 0;
                end
            end

            F_RUN: begin
                clk_cnt <= clk_cnt + 1'b1;
                b_v <= b_active;
                if (b_active) begin
                    b_slot     <= cur;
                    b_voice    <= v_idx;
                    b_klast    <= (cur[PW-1:0] == KMSK[PW-1:0]);
                    b_gain     <= gn_next;
                    sine_phase <= ph_next;
                end
                c_v <= b_v;  c_gain <= b_gain;  c_klast <= b_klast;  c_voice <= b_voice;
                d_v <= c_v;  d_gain <= c_gain;  d_klast <= c_klast;  d_voice <= c_voice;
                if (d_v) begin
                    if (d_klast) begin
                    acc_mix <= acc_mix + vscaled;
                    acc_voice <= 0;
                    // 样本级包络: 每个声部每样本逼近一次 (一阶, tau=8 样本)
                    ags_v[d_voice] <= ags_v[d_voice]
                                    + (($signed({1'b0, adsr_g[d_voice]}) - ags_v[d_voice]) >>> 3);
                end
                    else               acc_voice <= vsum[ACC_W-1:0];
                end
                if (slot == SLOTS + 3) fsm <= F_FIN;
                else                   slot <= slot + 1'b1;
            end

            F_FIN: begin
                b_v <= 0; c_v <= 0; d_v <= 0;
                // 噪声先并入 acc_mix, 再统一按声部数移位/饱和(修复复音噪信比)
                // 2026-10-26: 移位经增益斜坡(out24_ramp), 消除声部数跨档的 -6dB 台阶
                //   为了关键路径, 移位/饱和打一拍, 乘法+钳位放到 F_RMP
                a16_r  <= a16;
                rmul_r <= rmul_in;
                kq_r   <= rmp_kq;
                attn_r <= rmp_attn;
                act_r  <= rmp_act;
                pass_clks <= clk_cnt;
                if (clk_cnt > 1041) overrun <= 1'b1;
                fsm <= F_RMP;
            end

            // 输出增益斜坡第二拍: 乘法/加法/钳位 + 音头噪声; 同时推进斜坡状态机、取下一个事件
            F_RMP: begin
                audio_out <= sat_add(out24_ramp, atk_n);
                // 斜坡状态机: 一次搬一档, 搬完再把 sh_use 落到目标
                if (rmp_act) begin
                    if (rmp_k >= RAMP_LEN) begin
                        rmp_act <= 1'b0; rmp_k <= 9'd0;
                        sh_use  <= rmp_attn ? (sh_use - 1'b1) : (sh_use + 1'b1);
                    end else rmp_k <= rmp_k + 1'b1;
                end else if (fin_sh != sh_use) begin
                    rmp_act <= 1'b1; rmp_k <= 9'd0;
                end
                // 一趟结束 -> 若有音符事件, 先执行(此时写口空闲, 不会和趟互相覆盖)
                if (!evt_empty) begin
                    fsm      <= F_INIT;
                    i_voice  <= q_voice[q_rp];
                    evt_on   <= q_on[q_rp];
                    i_vel    <= q_vel[q_rp];
                    i_note   <= q_note[q_rp];
                    i_ftw    <= q_ftw[q_rp];
                    i_k      <= 0;
                    i_phase  <= 2'd0;
                    if (PN_TABLES != 0)
                        amp_rd <= {q_note[q_rp], q_vel[q_rp][VEL_SHIFT +: LW], 4'd0};
                    q_rp     <= q_rp + 1'b1;
                    q_cnt    <= q_cnt - 1'b1;
                end else begin
                    fsm <= F_IDLE;
                end
            end

            //---- 执行一个音符事件: 第一拍应用 FTW/ADSR, 之后 16 拍写时隙
            F_INIT: begin
                b_v <= 0; c_v <= 0; d_v <= 0;
                if (i_phase == 2'd0) begin
                    ftw_v[i_voice] <= i_ftw;
                    // 力度 -> 层号, 在本音的 16 次时隙写之前定下来
                    layer_v[i_voice] <= i_vel[VEL_SHIFT +: LW];
                    if (evt_on) begin
                        adsr_g[i_voice]  <= 16'd0;
                        ags_v[i_voice]   <= 17'sd0;
                        adsr_st[i_voice] <= 2'd1;
                        rel_v[i_voice]   <= 1'b0;
                        atk_pos   <= 8'd0;
                        atk_act   <= 1'b1;
                        atk_scale <= atk_scale_c[14:0];
                        if (adsr_st[i_voice] == 2'd0 && !rel_v[i_voice])
                            active_voices <= active_voices + 6'd1;
                    end else begin
                        rel_v[i_voice]   <= 1'b1;
                        adsr_st[i_voice] <= 2'd3;
                    end
                    i_phase <= 2'd1;
                    i_k <= 0;
                    if (PN_TABLES != 0) amp_rd <= {i_note, i_vel[VEL_SHIFT +: LW], 4'd1};
                end else if (evt_on) begin
                    if (i_k == PARTIALS - 1) begin fsm <= F_IDLE; i_k <= 0; i_phase <= 2'd0; end
                    else begin
                        i_k <= i_k + 1'b1;
                        if (PN_TABLES != 0)
                            amp_rd <= {i_note, i_vel[VEL_SHIFT +: LW],
                                       (i_k < PARTIALS - 2) ? (i_k[3:0] + 4'd2) : 4'd15};
                    end
                end else begin
                    fsm <= F_IDLE; i_phase <= 2'd0;
                end
            end

            default: fsm <= F_IDLE;
            endcase
        end
    end

endmodule