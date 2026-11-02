//=============================================================================
// top.v —— 整机顶层 (P0-1): 引擎 + 交互层 + I2S + LED 指引 + 测试图样
//
//   时钟    : 板载 50MHz 直驱 (E2), 无 PLL —— i2s_48k 的 BCLK_INC 与
//             ws2812_phy 的位时序常数都按 50MHz 算, 换时钟必须重算 (handoff 坑13/11)
//   复位    : 上电自动 ~21ms + 底板 USER_KEY(H11) 按住复位(高=按下, 消抖 2.6ms)
//   测试模式: btn_test 跳线拉高 -> test_pattern 依次按住 32 个音(现场数谱峰验收)
//   外部键事件: key_*_in 暴露在 PMOD(下拉, 浮空=不按), 是传感器层/BLE 的落点;
//             key_ready_out 引出 —— 上游必须看它(背压, 不看会丢事件)
//   LED     : viz_led + ws2812_phy 旁听键总线, 占 1 根 IO(G5)
//   音色    : 现为 C4 参考音钢琴一套表 (2026-10-12 由 A1 改为 C4, 见下方参数注释);
//             第二音色/表情口(bend/vib/glide)留待 P1
//=============================================================================
`timescale 1ns/1ps
module top #(
    parameter NPIX = 24,                      // WS2812 颗数
    // ---- 音色表(默认 = C4 参考音钢琴; 换音色只需覆盖这四个参数, 见 top_gtr.v) ----
    //   2026-10-12: 参考音由 A1 改为 C4 (K3 会诊: 单参考音架构下中音区外推误差最小,
    //   且 16 个分音间隔 261Hz 更利于"数独立谱峰"的赛题验收)
    parameter RATIO_FILE = "rtl/rom/harm_ratio_C4.hex",
    //   注意: 这里的 AMP_FILE 只在 VEL_LAYERS=1 时生效(单层表);
    //   实际出货的 top_vel8_int.v / top_auto_c4_v2.v 一律覆盖成 8 层表
    //   "rtl/rom/harm_amp_vel_C4.hex" (见下方 VEL_LAYERS 说明)。
    //   历史上还有过 harm_amp_C4_new/physical/mid/oldlaw 等对照表, 均非生产用表。
    parameter AMP_FILE   = "rtl/rom/harm_amp_C4.hex",
    parameter PHA_FILE   = "rtl/rom/harm_phase_C4.hex",
    parameter DEC_FILE   = "rtl/rom/harm_decay_ctrl_C4.hex",
    // ---- 输出电平衰减(2^OUT_ATT_SHIFT 分之一) ----
    //   为什么需要: 单音峰值 -4.2dBFS / 32 复音峰值 -1.7dBFS, 距 24bit 饱和只剩 1.7dB;
    //   若失真来自"电平过高"(DAC 输入或音响输入级过载), 用同一套表降 6/12dB 即可定性:
    //     降 6dB 后明显变干净 => 削波(电平问题); 一样沙哑 => 音响固有非线性。
    //   默认 0 = 与改动前逐位一致(可回滚/可对拍)。
    parameter        OUT_ATT_SHIFT = 0,
    // ---- 输出抖动(整机版) ----
    //   2026-10-12 上板实测: PCM5102A 模块在"输入序列特殊"(全 0 数据 / 非公度采样周期)
    //   时会**自生可听失真**(ΔΣ 空闲音/图案相关类); 给一点点听不见的抖动就恢复正常。
    //   DITHER_SHIFT = 16(默认) -> 关闭(逐位不变); 6 -> ±8LSB(-120dBFS);
    //                  3 -> ±64LSB(-108dBFS);      0 -> ±512LSB(-84dBFS)。
    //   幅度都远低于可闻阈值, 目的是让 DAC 的调制器不进入"坏图案"。
    parameter        DITHER_SHIFT = 16,
    // ---- 力度分层 (VEL_LAYERS) ----
    //   1 = 旧行为(单层幅度表, 所有力度都读 layer 0, 表值再乘 vel);
    //   8 = 分层(AMP_FILE 必须是 8 层 × 16 项 = 128 项的表, 如 harm_amp_vel_C4.hex),
    //       层号 = clamp(param_vel >> 4, 0, 7); 层表本身承载该力度的幅度, 不再乘 vel。
    //   注意取舍: 分层表以"ff 层占满刻度(-1dBFS)"为基准 -> mf 层比旧单层表轻约 14.5dB
    //   (力度动态是真的, 不是缩放)。见 tools/gen_vel_layers_C4.log 报告。
    parameter        VEL_LAYERS = 1,
    parameter        VEL_SHIFT  = 4,          // layer = vel >> VEL_SHIFT (8 layers -> 4, 4 layers -> 5)
    // OCT_TABLES=1: AMP_FILE 是 4 段八度表, 引擎按音高选段 (2026-10-21 高音修正)
    parameter        OCT_TABLES = 0,
    // Q4_TABLES=1: 32 段（每 4 半音一张）
    parameter        Q4_TABLES = 0,
    // PN_TABLES=1: 每音一张表（128 段，BSRAM）
    parameter        PN_TABLES = 0,
    // PER_NOTE_CORR=1: 读 note_corr.hex, note-on 乘 per-note 修正
    parameter        PER_NOTE_CORR = 0,
    parameter        CORR_FILE = "rtl/rom/note_corr.hex",
    // TIMBRE=0: 钢琴加法引擎; TIMBRE=1: 吉他 Karplus-Strong 引擎
    parameter        TIMBRE = 0,
    // ---- 调试测试音 (DEBUG_TONE) ----
    //   参数取 0/1/2:
    //     0 = 正常(引擎输出) -- 默认, 逐位不变
    //     1 = 用**内部 630Hz 纯正弦**替换引擎输出 (走同一份 sine_lut)
    //     2 = 用**每样本 +1 计数器**替换引擎输出 (轨迹最易判读)
    //   用途(判决实验): 同一固件、同样接线/时钟/串化器/握手, 只换样本源。
    parameter        DEBUG_TONE = 0,
    // ---- 调试旁路 (DEBUG_BYPASS) ----
    //   0 = 正常: audio_sel -> OUT_ATT_SHIFT -> 抖动 -> sat24 -> i2s
    //   1 = **旁路**后处理链: audio_sel 直连 i2s (与探针固件同构: 组合直连)
    //   用途: 判定"沙哑"是否由 top.v 的后处理链(mux/衰减/抖动/sat24)引入。
    //     旁路后干净 -> 问题在后处理链
    //     旁路后仍沙哑 -> 问题在别处(i2s 实例/复位/时钟域)
    parameter        DEBUG_BYPASS = 0,
    parameter [3:0]    RVB_SHIFT  = 4'd2,          // reverb wet = 1/2^RVB_SHIFT (2 = 25%)
    parameter            DISP_ON    = 1,           // 0 = 不综合 OLED 显示链（省布局压力，输出接 0）
    // ---- 音高表 (NOTE_FILE) ----
    //   表内容 = Q0.32, 按 fs=48000 算 (note_ctrl 取 [31:8] 得 24bit FTW)。
    //   若 I2S_INT_CLK=1 (采样率变 48828.125Hz), 必须换成 ×3072/3125 重算的表,
    //   否则整体音高会高 29.6 音分。
    parameter NOTE_FILE = "rtl/rom/note_ftw.hex",
    // ---- 串化器时钟 (I2S_INT_CLK) ----
    //   0 = 小数分频 (默认, 48.000kHz, BCLK 抖动图样周期 3 样点)
    //   1 = 整数分频 (48.828125kHz, BCLK 逐周期精确无抖动)
    //   实测依据: probe_630_clk_ab (同一 630.0000Hz @0dBFS 短/长段对照) ——
    //     小数分频段用户听感"像方波", 整数分频段方波感消失 => 抖动会造出强奇次谐波。
    parameter I2S_INT_CLK = 0,
    // ---- 2026-10-15 新增: 把 test_pattern 的参数透传出来 ----
    //   目的: 不改 test_pattern.v、不复制 top.v, 就能用一条顶层参数定制"自动敲哪个音/几个/多大力"。
    //   默认值与原硬编码完全一致 (N_NOTES=32, N0=45, STEP=2, VEL=127), 故对既有固件**零影响**。
    //   例: top_auto_c4.v 用 N_NOTES(1), N0(60), STEP(0), VEL(64) -> 只敲一个 C4、力度中等。
    parameter TP_N_NOTES = 32,
    parameter TP_N0      = 45,
    parameter TP_STEP    = 2,
    parameter TP_VEL     = 127,
    // ---- 2026-10-15 新增: ADSR 面板透传 (默认值 = 原硬编码值, 对既有固件零影响) ----
    //   控制率 = 采样率/2^CTRL_L2 ≈ 0.655ms (每个声部每周期更新一次)
    //   状态机语义(partial_engine.v:303-322):
    //     attack : g += a_inc 直到 16'h7FFF -> 进 decay
    //     decay  : g -= d_inc 直到 <= sus+d_inc -> 锁在 sus, 进 sustain
    //     sustain: 不动(等抬键)
    //     release: 抬键后 g -= r_inc 直到 0
    //   !! d_inc=0 且 sus=0x7FFF 的组合 = "按下后永不衰减, 只有抬键才开始掉",
    //      对钢琴是错的(击弦后应立刻开始衰减)。本参数化就是为了让顶层能改它。
    parameter [15:0] ADSR_A_INC = 16'd10923,   // (32767/10923)×0.655ms ≈ 4.6ms 起振
    parameter [15:0] ADSR_D_INC = 16'd0,       // 原值 0 = 不衰减(保持向后兼容)
    parameter [15:0] ADSR_SUS   = 16'h7FFF,    // 原值 = 满幅(保持向后兼容)
    parameter [15:0] ADSR_R_INC = 16'd109,     // (32767/109)×0.655ms ≈ 6s 释放
    // ---- 松键释放形状 (2026-10-19) ----
    //   0 = 旧行为(线性); >0 = 指数(定速率, 与电平无关), 实测 C4 tau≈0.15s -> 143
    parameter        REL_RATE   = 0,
    parameter [15:0] REL_FLOOR  = 16'd32,
    // ---- 音头噪声 (2026-10-20) ----
    //   ATK_NOISE=0 关闭; 峰值=(32767*ATK_NOISE)>>12; 每 0.655ms 减 ATK_DEC
    parameter [15:0] ATK_NOISE  = 16'd0,
    parameter [15:0] ATK_DEC    = 16'd0,
    // ---- FSR 键事件门控 (2026-10-31) ----
    //   1 = 原行为(FSR 的 AIN0~3 各自当 C4/D4/E4/F#4 键), 默认值 ⇒ 既有变体逐位不变。
    //   0 = 只保留 FSR 的**模拟读数**(o_fsr_ch/o_fsr_data, 给上层做力度), 键事件不进 mux。
    //       需要它是因为五选一里 fsr_we 优先级高于 key_*_in: 上层自己用 FSR 给力度时,
    //       FSR 自己的键事件会把手机/触摸按键顶掉(同拍撞车还会静默丢一个事件)。
    parameter        FSR_KEYS_EN = 1
)(
    input  wire        clk,
    input  wire        btn_rst,
    input  wire        btn_test,
    input  wire        key_we_in,
    input  wire [6:0]  key_note_in,
    input  wire        key_on_in,
    input  wire [6:0]  key_vel_in,
    input  wire        timbre_in,   // 0=钢琴 1=吉他（运行时，来自 0x86）
    input  wire [6:0]  rvb_mix,     // 混响湿度 0..127（0x89）；32 = 原来固定的 25% 湿声
    input  wire [6:0]  glide_amt,   // 滑音量 0..127（0x8B）；0 = 关，见下方 glide_q15
    input  wire        demo_we,     // 吉他自动演示触发（单拍）
    input  wire [6:0]  demo_note,
    input  wire        uart_pc_rx,    // B3: 板载调试器 USB 串口(官方 simple_uart 同款), PC 直调
    input  wire        uart_ble_rx,   // G2: 蓝牙模块 HC-04 TX(官方 40 脚表 pmod_io[22])
    inout  wire        i2c_sda,       // B2: ADS1115 SDA(开漏, 外部上拉) —— FSR402 力度
    output wire        oled_sck,
    output wire        oled_mosi,
    output wire        oled_dc,
    output wire        oled_cs,
    output wire        i2c_scl,       // F1: ADS1115 SCL(主机推挽直驱)
    output wire        key_ready_out,
    output wire        dac_sck,       // F5 -> PCM5102 SCK, 恒 0 = 内部 PLL 模式
    output wire        i2s_bclk,      // G7 -> PCM5102 BCK
    output wire        i2s_lrck,      // H5 -> PCM5102 LRCK
    output wire        i2s_sdata,     // H8 -> PCM5102 DIN
    output wire        led_din,
    // FSR/ADC 观测口（给上层的力度锁存用；不影响内部逻辑）
    output wire [1:0]  o_fsr_ch,
    output wire [15:0] o_fsr_data,
    output wire        dbg_eng_we,
    output wire        dbg_eng_on,
    output wire [6:0]  dbg_eng_note
);
    // PCM5102 模块直插 PMOD: SCK F5 / BCK G7 / DIN H8 / LRCK H5 / GND / 3V3(VIN)
    // SCK 恒 0 => PCM5102A 用内部 PLL 从 BCK 恢复主时钟 (模块无需外部主时钟)
    assign dac_sck = 1'b0;

    //------------------------------------------------ 上电复位(~21ms) + 按键消抖
    // pwr_cnt 无复位端: 初值靠 FF 上电态(Gowin 支持 initial 综合成 INIT 属性;
    // 仿真里不给初值会 X 传染, rst_n 永远起不来 —— 参见 handoff 坑14 的 X 教训)
    reg [19:0] pwr_cnt;
    initial pwr_cnt = 20'd0;
    always @(posedge clk) if (pwr_cnt != 20'hF_FFFF) pwr_cnt <= pwr_cnt + 20'd1;
    wire pwr_rst = (pwr_cnt != 20'hF_FFFF);
    wire rst_n0  = ~pwr_rst;                  // 消抖器自己的复位

    wire btn_rst_c, test_mode;
    debounce u_db_rst  (.clk(clk), .rst_n(rst_n0), .din(btn_rst),  .dout(btn_rst_c));
    debounce u_db_test (.clk(clk), .rst_n(rst_n0), .din(btn_test), .dout(test_mode));
    wire rst_n = ~(pwr_rst | btn_rst_c);

    //------------------------------------------------ 键事件总线信号声明（先声明后引用: 坑9 隐式网）
    wire sample_req;

    //---- 调试测试音源 (DEBUG_TONE=1 时启用; =0 时整块被裁掉, 不影响正常路径) ----
    wire signed [23:0] tone_a;
    generate
        if (DEBUG_TONE == 1) begin : g_tone
            reg [23:0] tone_phase;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) tone_phase <= 24'd0;
                else if (sample_req) tone_phase <= tone_phase + 24'd220201;   // 630.0000 Hz
            end
            // 2026-10-14 换表: 同 partial_engine, 改走整周期满表 sine_lut_full (已验证路径)
            wire signed [23:0] tone_s24;
            sine_lut_full #(.PHASE_W(24), .IDX_W(10), .FRAC_W(12), .OUT_W(24),
                            .QN(1024), .ROM_FILE("rtl/rom/sine_full_1024_q23.hex")) u_tone (
                .clk(clk), .rst_n(rst_n), .interp_en(1'b1),
                .phase(tone_phase), .sin_out(tone_s24));
            // 定标: 旧 16 位表时为 <<6; 满表 Q23 比旧表多 8 位 -> 移位量应**减** 8 = >>>2,
            //       保持同一电平(-12dBFS)。
            //       (2026-10-21 修: 曾误写成 <<<14。移位结果宽度=左操作数宽度(24bit),
            //        <<<14 截断后只剩正弦表值的低 10 位 -> 输出近满幅 LSB 噪声, 不是正弦)
            assign tone_a = tone_s24 >>> 2;
        end else if (DEBUG_TONE == 2) begin : g_cnt
            // 每样本 +1 的 16bit 计数器, 左移 8 位放到 24bit 的高位
            reg [15:0] dbg_counter;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) dbg_counter <= 16'd0;
                else if (sample_req) dbg_counter <= dbg_counter + 16'd1;
            end
            // 关键: 这里也是"组合直出", 与探针固件同构。
            // 若它干净 -> top.v 通路与握手无罪, 问题在引擎的流水线时序;
            // 若它也坏 -> top.v 的通路/握手有问题。
            assign tone_a = {{8{dbg_counter[15]}}, dbg_counter} <<< 8;
        end else begin : g_notone
            assign tone_a = 24'sd0;
        end
    endgenerate
    wire key_ready;
    wire tp_we, tp_on;
    wire [6:0] tp_note, tp_vel;
    wire       uk_pc_we, uk_pc_on, uk_ble_we, uk_ble_on;
    wire [6:0] uk_pc_note, uk_pc_vel, uk_ble_note, uk_ble_vel;

    //------------------------------------------------ UART/蓝牙 -> 键事件 (P0-3/P1-9)
    // 两条独立收路, 协议见 uart_key.v: "音号+'+'" 开 / "音号+'-'" 关 / 其他字节无害忽略
    uart_key u_uk_pc (
        .clk(clk), .rst_n(rst_n), .rx(uart_pc_rx), .key_ready(key_ready),
        .key_we(uk_pc_we), .key_note(uk_pc_note), .key_on(uk_pc_on), .key_vel(uk_pc_vel));
    uart_key u_uk_ble (
        .clk(clk), .rst_n(rst_n), .rx(uart_ble_rx), .key_ready(key_ready),
        .key_we(uk_ble_we), .key_note(uk_ble_note), .key_on(uk_ble_on), .key_vel(uk_ble_vel));

    //------------------------------------------------ FSR402 压力键 (经 ADS1115, I2C)
    // 4 通道轮询 ≈ 6ms/轮(400kHz I2C), 迟滞+连续确认消抖, 事件带力度。
    // 传感器层详见 fsr_key.v / ads1115_if.v, 交接记录见 docs/handoff.md
    wire       fsr_we;
    wire [6:0] fsr_note, fsr_vel;
    wire       fsr_on;
    fsr_key u_fsr (
        .clk(clk), .rst_n(rst_n), .key_ready(key_ready),
        .key_we(fsr_we), .key_note(fsr_note), .key_on(fsr_on), .key_vel(fsr_vel),
        .i2c_scl(i2c_scl), .i2c_sda(i2c_sda),
        .i2c_err(), .dbg_ch(o_fsr_ch), .dbg_data(o_fsr_data), .ev_drop());

    // 2026-10-31: FSR 键事件门控。FSR_KEYS_EN=1 时与原来逐位等价(常量折叠);
    //   注意 key_ready 仍接 fsr_key(它照常读 ADC 并自己出队), 只是事件不进下面的 mux。
    wire fsr_key_we = FSR_KEYS_EN ? fsr_we : 1'b0;

    //------------------------------------------------ 触后颤音（2026-11-02, 第 2 维表情）
    //   同一颗 FSR：击弦瞬间当力度（ble 那边取 AIN0 码值），按住后压力变化当颤音深度。
    //   o_fsr_ch/o_fsr_data 是 fsr_key 的观测口，FSR_KEYS_EN=0 时它照样读（只是键事件
    //   不进 mux），所以力度与这里都不受影响。
    //   vib_dep = fsr 高字节(码值[14:8]) × 4 → 0..~412，按 note_ctrl 的口径 1/32768 相对
    //   频率偏移 ≈ 0..21 音分；vib_rate=236 → 控制率 1526Hz 下约 5.5Hz。
    reg  [15:0] fsr_ch0_lat;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) fsr_ch0_lat <= 16'd0;
        else if (o_fsr_ch == 2'd0) fsr_ch0_lat <= o_fsr_data;
    end
    wire [15:0] vib_dep  = {9'd0, fsr_ch0_lat[14:8]} << 2;   // 0..~412 (≈0..21 音分)
    wire [15:0] vib_rate = 16'd236;                          // ≈5.5 Hz @控制率 1526Hz

    //------------------------------------------------ 滑音（2026-11-02, 第 3 维表情, 0x8B）
    //   0 = 关；1 → 1016（≈50ms 滑到）；127 → 8（≈1s 慢滑）
    wire [15:0] glide_q15 = (glide_amt == 7'd0) ? 16'd0
                                              : ((16'd128 - {9'd0, glide_amt}) << 3);

    //------------------------------------------------ 键事件总线: 测试图样/蓝牙/PC/FSR/外部 五选一
    // 优先级: 测试模式 > 蓝牙 > PC 调试口 > FSR 压力键 > 并行键总线(外部遗留口)
    test_pattern #(.N_NOTES(TP_N_NOTES), .N0(TP_N0), .STEP(TP_STEP), .VEL(TP_VEL)) u_tp (
        .clk(clk), .rst_n(rst_n), .test_en(test_mode),
        .key_we(tp_we), .key_note(tp_note), .key_on(tp_on), .key_vel(tp_vel),
        .key_ready(key_ready), .pressed_cnt());

    wire       key_we   = test_mode ? tp_we   :
                          uk_ble_we ? uk_ble_we :
                         (uk_pc_we ? uk_pc_we : (fsr_key_we ? fsr_key_we : key_we_in));
    wire [6:0] key_note = test_mode ? tp_note :
                          uk_ble_we ? uk_ble_note :
                         (uk_pc_we ? uk_pc_note : (fsr_key_we ? fsr_note : key_note_in));
    wire       key_on   = test_mode ? tp_on   :
                          uk_ble_we ? uk_ble_on :
                         (uk_pc_we ? uk_pc_on : (fsr_key_we ? fsr_on : key_on_in));
    wire [6:0] key_vel  = test_mode ? tp_vel  :
                          uk_ble_we ? uk_ble_vel :
                         (uk_pc_we ? uk_pc_vel : (fsr_key_we ? fsr_vel : key_vel_in));
    assign key_ready_out = key_ready;

    //------------------------------------------------ 交互层 -> 引擎
    wire eng_we, eng_on, eng_evt_full, pitch_we, steal_flag;
    wire [4:0]  eng_voice, pitch_voice;
    wire [23:0] eng_ftw, pitch_ftw;
    wire [6:0]  eng_vel;
    wire [6:0]  eng_note;
    // 2026-10-26 调试: 送给引擎的事件(给 LED 探针)
    assign dbg_eng_we   = eng_we;
    assign dbg_eng_on   = eng_on;
    assign dbg_eng_note = eng_note;
    wire        timbre_r = timbre_in | (TIMBRE != 0);   // 运行时音色 (0x86)
    wire [5:0]  busy_cnt;
    wire [7:0]  drop_cnt;
    note_ctrl #(
        .VOICES(32), .PHASE_W(24), .NOTE_FILE(NOTE_FILE)) u_nc (
        .clk(clk), .rst_n(rst_n), .sample_req(sample_req),
        .key_we(key_we), .key_note(key_note), .key_on(key_on), .key_vel(key_vel),
        .key_ready(key_ready),
        .bend_q15(16'd0), .vib_depth_q15(vib_dep), .vib_inc(vib_rate), .glide_q15(glide_q15),
        .adsr_a_inc(ADSR_A_INC), .adsr_d_inc(ADSR_D_INC), .adsr_sus(ADSR_SUS), .adsr_r_inc(ADSR_R_INC),
        .eng_we(eng_we), .eng_voice(eng_voice), .eng_ftw(eng_ftw),
        .eng_on(eng_on), .eng_vel(eng_vel), .eng_note(eng_note), .eng_evt_full(eng_evt_full),
        .pitch_we(pitch_we), .pitch_voice(pitch_voice), .pitch_ftw(pitch_ftw),
        .voice_busy(), .voice_rel(),
        .busy_cnt(busy_cnt), .steal_flag(steal_flag), .drop_cnt(drop_cnt));

    //------------------------------------------------ 引擎 -> I2S
    wire signed [23:0] audio;
    wire signed [23:0] piano_audio;
    wire signed [23:0] gtr_audio;
    wire [5:0]  gtr_act;
    wire [5:0]  active_voices;
    wire        overrun;
    wire [15:0] pass_clks;
    partial_engine #(
        .VOICES(32), .PARTIALS(16), .PHASE_W(24), .OUT_W(24),
        .SINE_FILE("rtl/rom/sine_full_1024_q23.hex"), .RATIO_FILE(RATIO_FILE),
        .AMP_FILE(AMP_FILE), .PHA_FILE(PHA_FILE),
        .DEC_FILE(DEC_FILE), .VEL_LAYERS(VEL_LAYERS), .VEL_SHIFT(VEL_SHIFT), .OCT_TABLES(OCT_TABLES),
        .PER_NOTE_CORR(PER_NOTE_CORR), .CORR_FILE(CORR_FILE), .Q4_TABLES(Q4_TABLES),
        .PN_TABLES(PN_TABLES),
        .REL_RATE(REL_RATE), .REL_FLOOR(REL_FLOOR),
        .ATK_NOISE(ATK_NOISE), .ATK_DEC(ATK_DEC)) u_eng (
        .clk(clk), .rst_n(rst_n), .sample_req(sample_req),
        .param_we(eng_we && ((timbre_r == 1'b0) || !eng_on)), .param_voice(eng_voice), .param_ftw(eng_ftw),
        .param_on(eng_on), .param_vel(eng_vel), .param_note(eng_note),
        .pitch_we(pitch_we), .pitch_voice(pitch_voice), .pitch_ftw(pitch_ftw),
        .adsr_a_inc(ADSR_A_INC), .adsr_d_inc(ADSR_D_INC), .adsr_sus(ADSR_SUS), .adsr_r_inc(ADSR_R_INC),
        .audio_out(piano_audio), .active_voices(active_voices),
        .overrun(overrun), .pass_clks(pass_clks), .evt_full(eng_evt_full));


    //---- 吉他 KS 引擎（16 弦）----
    //   2026-10-30 按队友 guitar-v30 定稿同步（她上板确认无"呼呼"）：
    //     TRI_SHIFT=4        三角/16，赋权给噪声 -> 全谐波（消除风琴音色）
    //     NZ_MODE=1/NZ_GAIN=16384  高通 LFSR 噪声 50% -> 近似白噪声（拨片感）
    //     EXC_BIPOLAR=1     三角居中到 ±16384，去掉每次拨弦灌进的 +16384 直流阶跃
    //     RELEASE_ON_OFF=0  松手不瞬断，弦自然余音
    gtr_ks_engine #(.VOICES(16), .MAXN(640),
                    .NZ_GAIN(16'd16384), .NZ_MODE(1),
                    .RELEASE_ON_OFF(0), .TRI_SHIFT(4)) u_gtr (
        .clk(clk), .rst_n(rst_n), .sample_req(sample_req),
        .note_we((eng_we && eng_on && timbre_r) || demo_we),
        .note(demo_we ? demo_note : eng_note),
        .note_off_we(eng_we && !eng_on && timbre_r), .off_note(eng_note),
        .audio_out(gtr_audio), .active_cnt(gtr_act));

    //---- 吉他琴体滤波（3 biquad，Q15）----
    wire signed [15:0] gtr_body_out;
    //   v30: 琴体滤波器换成 gtr_body_lead（16bit -> 24bit 状态，移回 Q15 四舍五入，
    //   48bit 累加）。原因：对称正确的 16bit 状态 + 向下取整，将 1LSB 截断偏差放大 ~5288 倍，
    //   把状态钉成每 band 约 -5442 LSB 的不动点 -> 输出恒定约 -5%FS 直流 + 随弹奏漂移，就是"呼呼"。
    gtr_body_lead u_gtr_body (
        .clk(clk), .rst_n(rst_n), .sample_req(sample_req),
        .in_sample(gtr_audio[19:4]), .out_sample(gtr_body_out));

    //---- 吉他输出直流阻断（2026-10-26）：琴体四舍五入留下 |y|<~2731 LSB 的直流死区，
    //     连弹低音会把直流推进去并驻留 -> DAC 进不了静音态、听成"呼呼"在音后延续。
    wire signed [15:0] gtr_dc_out;
    //   v30 她的 dc_block：均值 Q15.8、SHIFT=9（fc≈15Hz）、静音门 16 LSB / 保持 4096 样本（84ms）。
    //   1536 在她那里把尾音砍掉了（琴体峰值只有约1000LSB）；16 则是 -66dBFS，不影响听感。
    dc_block u_gtr_dc (
        .clk(clk), .rst_n(rst_n), .sample_req(sample_req),
        .in_sample(gtr_body_out), .out_sample(gtr_dc_out));

    //   只给吉他 +12dB（她 v30d 是全局 OUT_ATT_SHIFT 2->0，因为她那版是纯吉他固件；
    //   我们双引擎不能把钢琴也抬 +12dB，所以在 mux 前只对吉他乘 4。）
    wire signed [23:0] gtr24     = {gtr_dc_out, 8'd0};
    wire signed [25:0] gtr4      = $signed({{2{gtr24[23]}}, gtr24}) <<< 2;
    wire signed [23:0] gtr24_g12 = (gtr4 > 26'sd8388607)  ? 24'sd8388607  :
                                   (gtr4 < -26'sd8388608) ? -24'sd8388608 :
                                                            gtr4[23:0];
    assign audio = timbre_r ? gtr24_g12 : piano_audio;

    // 左右声道同源; 做李萨如演示时改成两个声部分别出 L/R
    // 输出衰减: 24bit 有符号算术右移(保留符号), OUT_ATT_SHIFT=0 时不改变任何位
    // DEBUG_TONE=1 时, audio 被换成内部测试音(见上方 g_tone)
    wire signed [23:0] audio_sel = (DEBUG_TONE != 0) ? tone_a : audio;
    wire signed [23:0] audio_out_att = audio_sel >>> OUT_ATT_SHIFT;

    // ---- Reverb insert: mono, 16-bit, shift-only gains (0 DSP) ----
    //   x = attenuated dry (top 16 bits); wet added back at 1/2^RVB_SHIFT.
    //   rvb_mono: 4 combs (0.75 feedback) + 2 allpasses (0.5), 6 BSRAM blocks.
    wire signed [15:0] rvb_x = audio_out_att[23:8];
    wire signed [15:0] rvb_y;
    rvb_mono #(.MIX_SHIFT(4'd1)) u_rvb (
        .clk(clk), .rst_n(rst_n), .sample_req(sample_req),
        .x(rvb_x), .y(rvb_y), .busy());

    // 2026-11-02: 湿声量改由 0x89 运行时给（rvb_mix 0..127）。
    // v33: rvb_y 已是**纯湿声**（rvb_mono 不再把干声包进输出），所以这里是干净的
    //   干湿混合 dry + wet*mix*2:
    //   mix=0   -> 全干
    //   mix=32  -> 约 12.5% 湿声（默认，轻微空间感）
    //   mix=127 -> 约 50% 湿声（明显拖尾）
    //   （旧写法把干声也乘进去，127 时干声 ×2 顶到饱和，混响旋钮等于失效）
    wire signed [23:0] rvb_wet24 = ($signed(rvb_y) * $signed({1'b0, rvb_mix})) <<< 1;
    wire signed [24:0] rvb_sum   = $signed({{1{audio_out_att[23]}}, audio_out_att})
                                 + $signed({{1{rvb_wet24[23]}}, rvb_wet24});
    wire signed [23:0] audio_dry = (rvb_sum > 25'sd8_388_607)  ? 24'sd8_388_607 :
                                   (rvb_sum < -25'sd8_388_608) ? -24'sd8_388_608 :
                                                                  rvb_sum[23:0];

    //---- 输出抖动: 15bit LFSR, 每个采样推进一次; 只在 DITHER_SHIFT<=10 时生效 ----
    reg [14:0] dith_lfsr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) dith_lfsr <= 15'h1234;
        else if (sample_req) dith_lfsr <= {dith_lfsr[13:0], dith_lfsr[14] ^ dith_lfsr[13]};
    end
    wire signed [23:0] dith_val = (DITHER_SHIFT <= 10)
                                  ? (($signed({14'b0, dith_lfsr[9:0]}) - 24'sd512) >>> DITHER_SHIFT)
                                  : 24'sd0;
    // 带饱和的相加(绝不允许回卷: 满幅+抖动若回卷会变成刺耳的咔哒)
    wire signed [24:0] audio_sum = audio_dry + dith_val;
    wire signed [23:0] audio_chained = (audio_sum > 25'sd8_388_607)  ? 24'sd8_388_607  :
                                        (audio_sum < -25'sd8_388_608) ? -24'sd8_388_608 :
                                                                        audio_sum[23:0];
    // DEBUG_BYPASS=1 时绕开整条后处理链, 与探针固件同构(组合直连)
    wire signed [23:0] audio_final = (DEBUG_BYPASS != 0) ? audio_sel : audio_chained;

    //------------------------------------------------ 串化器
    // I2S_INT_CLK = 0 : 小数分频 (BCLK 3.072MHz 平均, 抖动图样周期 3 个样点)
    // I2S_INT_CLK = 1 : 整数分频 (BCLK 3.125MHz 逐周期精确, 无抖动图样)
    //   实测(probe_630_clk_ab, 同一 630.0000Hz/0dBFS 短长对照):
    //     小数分频段 -> 用户听感"像方波"(强奇次谐波)
    //     整数分频段 -> 方波感消失, 只剩低频噪声
    //   代价: 采样率变成 48828.125Hz, 因此 NOTE_FILE 必须换成分母 3125 重算过的表
    //        (rtl/rom/note_ftw_48828.hex = 原表 × 3072/3125), 音高逐音不变。
    generate
    if (I2S_INT_CLK != 0) begin : g_i2s_int
        i2s_48k_int #(.DIV(8)) u_i2s (
            .clk(clk), .rst_n(rst_n),
            .audio_l(audio_final), .audio_r(audio_final),
            .bclk(i2s_bclk), .lrck(i2s_lrck), .sdata(i2s_sdata),
            .sample_req(sample_req));
    end else begin : g_i2s_frac
        i2s_48k u_i2s (
            .clk(clk), .rst_n(rst_n),
            .audio_l(audio_final), .audio_r(audio_final),
            .bclk(i2s_bclk), .lrck(i2s_lrck), .sdata(i2s_sdata),
            .sample_req(sample_req));
    end
    endgenerate

    //------------------------------------------------ LED 指引 (旁听键总线, 零侵入)
    wire px_we, frame_start;
    wire [4:0]  px_waddr;
    wire [23:0] px_wdata;
    viz_led #(.NPIX(NPIX), .NOTE_BASE(60)) u_viz (
        .clk(clk), .rst_n(rst_n),
        .key_we(key_we), .key_note(key_note), .key_on(key_on), .key_vel(key_vel),
        .alarm_lvl(overrun), .drop_cnt(drop_cnt),
        .px_we(px_we), .px_waddr(px_waddr), .px_wdata(px_wdata),
        .frame_start(frame_start));
    ws2812_phy #(.NPIX(NPIX)) u_phy (
        .clk(clk), .rst_n(rst_n), .din(led_din), .frame_start(frame_start),
        .px_we(px_we), .px_waddr(px_waddr), .px_wdata(px_wdata));


    generate
    if (DISP_ON != 0) begin : g_disp
    // =====================================================================
    // OLED 128x64 (SSD1306/SH1106) -- Lissajous X-Y scope
    //   viz_lissa -> fb_128x64 -> ssd1306 -> spi_master -> 4 pins
    //   RESET pin is not driven by FPGA (tie OLED RES to 3.3V or RC).
    //   Pins below are PLACEHOLDERS (L5/K5/J5/C2) until real wiring is fixed.
    // =====================================================================
    wire        d_we;
    wire [9:0]  d_waddr, d_raddr_a, d_raddr_b;
    wire [7:0]  d_wdata, d_rdata_a, d_rdata_b;
    wire        d_spi_start, d_spi_busy, d_spi_done, d_init_done;
    wire [7:0]  d_spi_data;
    wire        d_dc, d_cs_n;

    viz_lissa u_lissa (
        .clk(clk), .rst_n(rst_n), .sample_req(sample_req), .audio(audio),
        .we(d_we), .waddr(d_waddr), .wdata(d_wdata),
        .raddr_a(d_raddr_a), .rdata_a(d_rdata_a), .busy());

    fb_128x64 u_fb (
        .clk(clk), .we(d_we), .waddr(d_waddr), .wdata(d_wdata),
        .raddr_a(d_raddr_a), .rdata_a(d_rdata_a),
        .raddr_b(d_raddr_b), .rdata_b(d_rdata_b));

    ssd1306 #(.COL_OFF(2), .SH1106(1)) u_oled (
        .clk(clk), .rst_n(rst_n), .fb_rdata(d_rdata_b), .fb_raddr(d_raddr_b),
        .spi_start(d_spi_start), .spi_data(d_spi_data), .dc(d_dc), .cs_n(d_cs_n),
        .spi_busy(d_spi_busy), .spi_done(d_spi_done), .init_done(d_init_done));

    spi_master #(.DIV(16)) u_spi (
        .clk(clk), .rst_n(rst_n), .start(d_spi_start), .din(d_spi_data),
        .sck(oled_sck), .mosi(oled_mosi), .busy(d_spi_busy), .done(d_spi_done));

    assign oled_dc = d_dc;
    assign oled_cs = d_cs_n;
    end else begin : g_nodisp
        assign oled_sck  = 1'b0;
        assign oled_mosi = 1'b0;
        assign oled_dc   = 1'b0;
        assign oled_cs   = 1'b0;
    end
    endgenerate
    // 不显示时，内部信号名仍被引用，避免综合告警
endmodule

//-----------------------------------------------------------------------------
// debounce (内联): 2FF 同步 + 全 1 计数翻转判据, W=17 -> 2^17*20ns ≈ 2.6ms 稳定才认
//-----------------------------------------------------------------------------
module debounce #(
    parameter W = 17
)(
    input  wire clk,
    input  wire rst_n,
    input  wire din,
    output reg  dout
);
    reg [W-1:0] cnt;
    reg d0, d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d0 <= 1'b0; d1 <= 1'b0; cnt <= {W{1'b0}}; dout <= 1'b0;
        end else begin
            d0 <= din; d1 <= d0;
            if (d1 == dout) cnt <= {W{1'b0}};
            else begin
                cnt <= cnt + 1'b1;
                if (&cnt) dout <= d1;
            end
        end
    end
endmodule
