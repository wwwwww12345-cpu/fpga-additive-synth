//=============================================================================
// top_ble_fsr.v —— 蓝牙回显 + 手机弹奏 + 二进制协议 v0 + **FSR 实时力度**
//
// 2026-10-31: 本文件 = top_ble_echo.v 的**完整副本** + 3 处改动（搜 [FSR-1..3] 定位）：
//   [FSR-1] 锁存 top 的 o_fsr_ch/o_fsr_data（只锁 AIN0）得到 fsr_code；
//   [FSR-2] push_vel 改为"有 FSR 读数用 FSR，无读数(高字节==0)退回帧里的 vel 字节"，
//           0x87 到达那一拍取的就是当时最新的 FSR 值 → keyhub → note_ctrl → 引擎 → DAC；
//   [FSR-3] top 传 FSR_KEYS_EN(0)：关掉 FSR 自己的 C4/D4/E4/F#4 键事件。否则 top.v
//           五选一里 fsr_we 高于 key_*_in，会顶掉手机按键（同拍撞车时 keyhub 的事件
//           已被认走 → 静默丢音，见 keyhub.v:65 / note_ctrl.v:190-191）。
//   GTR_DEMO 默认改 0：本版是纯 BLE 单音，不要上电每 10s 自动扫弦/强制吉他。
//
// 引脚见 rtl/top_ble_fsr.cst（照抄 top_ble_echo.cst，I2C 已在 F1/A1）
// 综合: gw_sh rtl/syn_ble_fsr.tcl    仿真: tb/tb_ble_fsr_vel.v
//
//-----------------------------------------------------------------------------
// 以下为 top_ble_echo.v 的原有说明（未改动，供对照）
// v3: 在 v2 基础上把**小程序协议 v0 (0x80~0x93)** 接进来
//   * 新增 rtl/ble_cmd.v      帧解析 + 音域/和弦/曲谱写口/演奏控制
//   * 新增 rtl/song_ram.v     512×24bit 曲谱 RAM (note/vel/dur)
//   * 新增 rtl/song_player.v  演奏状态机 (dur×10ms, 同音延长, 休止, 停止补抬键)
//   * 新增 rtl/keyhub.v       三源汇聚(ASCII单键/和弦展开/曲谱) + 统一 key_ready 背压
//   * 键事件全部经 keyhub 出, top.key_* 不再被 ASCII 解析器独占
//   * 抽出 ble_take = ble_valid & ble_ready, 回显/ASCII/协议三方共用同一份"已收字节"
//   * 补 assign key_ready_out (v2 漏驱动, 仿真为 z; 该脚不接, 仅防悬空)
//
// v2 相对 v1 的两处改动:
//   1. **关掉每 10 秒自动敲一次 C4**（用户要求: 那一轮周期的 C4 音关掉）——
//      删掉整套自动敲击状态机, 引擎不再被自动喂事件。
//   2. **把"手机弹奏"这条路接上**: 让 top 内部的 uart_key 去听 G2, 于是
//      demo 页按住 C4 发 ASCII "60+"/"60-" 时, 板子**会出声**。
//      (v1 里 top 内部两个串口收路的 rx 都被钉成 1'b1, 所以只能听见那声 C4,
//       手机弹奏不会出声 —— 本次一并修正。)
//
// 保留不变的部分:
//   * **回显通路逐字取自板级已验证的 probe_ble_led**: uart_rx -> uart_tx 直连 +
//     rx_data_ready = tx_data_ready 背压; 新增的只有"回到顶层必需"的 2 选 1 仲裁。
//   * 按键复位修正: rst_n = ~(pwr_rst | btn_rst_c), 与 top.v 行为一致
//     (v1 曾漏接 btn_rst, 板上按复位键没反应)。
//   * 输出电平 OUT_ATT_SHIFT=2 (-12dB, 用户已确认"很合适")、ADSR(d_inc=9/sus=0/r_inc=119)、
//     满表 sine_lut_full.v、8 层表 harm_amp_vel_C4.hex —— 与用户已验收的 v2c_q 逐字同档。
//
// 引脚见 rtl/top_ble_echo.cst（专用最小约束, 接线清单写在该文件头）
//
// 灯条状态: 绿=收到字节(1s) / 黄=上电自检 3s / 蓝=空闲脉冲 / 灭
// 综合: gw_sh rtl/syn_ble_proto.tcl
// 仿真: tb_proto.v (协议自检) / tb_final.v (回显回归)
//=============================================================================
`timescale 1ns/1ps

module top_ble_fsr #(
    parameter NPIX       = 24,
    parameter GTR_DEMO   = 0,               // 0=纯 BLE 单音(本版默认); 1=上电每 10s 自动扫弦（吉他）
    parameter GTR_NNOTES = 4,               // 自动演示每次扫几个音（1=只弹 C4，单音判定用）
    //   LED_DBG=1: 灯带改成"最近 3 个 key 事件"探针 —— 24 颗 = 3 个事件 × 8 bit，
    //              每个事件 = {on, note[6:0]}，绿=1 灭=0；第 1 颗是事件的 bit0。
    //              用来在板上直接看 keyhub 到底发出了哪些 on/note（诊断和弦问题）。
    parameter LED_DBG    = 0,
    parameter ACT_CLKS   = 50_000_000,      // 收到字节后绿灯时长 (1s @50MHz)
    parameter BOOT_CLKS  = 150_000_000,     // 上电黄灯自检 (3s)
    parameter PULSE_CLKS = 50_000_000,      // 空闲脉冲周期 (1s)
    parameter PULSE_ON   = 10_000_000       // 脉冲点亮 (0.2s)
)(
    input  wire        clk,           // E2, 50MHz
    input  wire        btn_rst,       // H11, 高=按下
    output wire        uart_ble_tx,   // G1 -> HC-04 RX  (回显发)
    input  wire        uart_ble_rx,   // G2 <- HC-04 TX  (收: 回显 + 弹奏共用)
    input  wire        uart_pc_rx,    // B3 板载串口(保留端口, 本次不用)
    output wire        led_din,       // G5 -> WS2812 DIN
    output wire        key_ready_out, // 保留端口(不接)
    output wire        dac_sck,       // F5 -> PCM5102 SCK (恒 0 = 内部 PLL)
    output wire        i2s_bclk,      // G7 -> BCK
    output wire        i2s_lrck,      // H5 -> LRCK
    output wire        i2s_sdata,     // H8 -> DIN
    input  wire        btn_test,      // 保留端口(不接)
    inout  wire        i2c_sda,       // A1: ADS1115 SDA (open-drain, external 10k pull-up)
    output wire        oled_sck,
    output wire        oled_mosi,
    output wire        oled_dc,
    output wire        oled_rst,      // K11: OLED RES (FPGA drives the reset pulse)
    output wire        i2c_scl        // F1: ADS1115 SCL (driven by fsr_key)
);
    //---------------------------------------------------------------- 复位
    // 上电自复位(21ms) **或** 按键复位, 与 top.v 一致。
    // (v1 曾只接上电复位, btn_rst 完全没用 -> 板上按复位键无反应)
    reg [19:0] pwr_cnt;
    initial pwr_cnt = 20'd0;
    always @(posedge clk) if (pwr_cnt != 20'hF_FFFF) pwr_cnt <= pwr_cnt + 20'd1;
    wire pwr_rst = (pwr_cnt != 20'hF_FFFF);
    wire rst_n0  = ~pwr_rst;                    // 消抖器自己的复位

    wire btn_rst_c;
    debounce u_db_rst (.clk(clk), .rst_n(rst_n0), .din(btn_rst), .dout(btn_rst_c));
    wire rst_n   = ~(pwr_rst | btn_rst_c);

    // ---- OLED RES: 上电拉低 20ms 再放高，之后多等 1ms 才允许显示链初始化 ----
    //   6 脚 SPI 模块的 RES 不能死接 3.3V，否则芯片不进初始化（整屏黑，四根信号却都正常）
    reg [19:0] oled_rst_cnt = 20'd0;
    wire       oled_rst_hold = (oled_rst_cnt != 20'd999_999);
    always @(posedge clk) begin
        if (pwr_rst)            oled_rst_cnt <= 20'd0;
        else if (oled_rst_hold) oled_rst_cnt <= oled_rst_cnt + 20'd1;
    end
    assign oled_rst = ~oled_rst_hold;

    reg [16:0] oled_post_cnt = 17'd0;
    wire       oled_post_done = (oled_post_cnt == 17'd49_999);
    always @(posedge clk) if (!oled_rst_hold && !oled_post_done) oled_post_cnt <= oled_post_cnt + 17'd1;

    // 给 top 的复位：RES 脉冲期间 + 放高后 1ms 都保持复位
    wire top_rst = btn_rst_c | oled_rst_hold | ~oled_post_done;

    assign dac_sck = 1'b0;                      // PCM5102A 用内部 PLL
        // 注意: key_ready_out 由 u_top 的键 FIFO 背压驱动(见下方端口连接),
    //       这里**不能**再 assign 常量, 否则该网有两个驱动(综合报 EX2000 并整模块黑盒)。
    wire _unused = &{1'b0, btn_test, uart_pc_rx, 1'b0};

    //================================================================
    // 0. [FSR-1] FSR 力度观测口（2026-10-31 新增，本文件独有）
    //    top 内部 fsr_key 每轮把最近一个通道的码值送到 o_fsr_ch/o_fsr_data
    //    （top.v:229 `.dbg_ch(o_fsr_ch), .dbg_data(o_fsr_data)`）。
    //    这里只锁 AIN0（fsr_ch==0）—— 本系统只有一块 FSR。
    //    取值口径 = 现有 vel_of()：code[15:8]，>=0x80 钳 127（fsr_key.v:88-94）。
    //    注：一轮 4 通道 ≈6.05ms（ads1115_if.v:23 CONV_WAIT 1.30ms + 总线 ≈0.21ms，
    //    每通道 ≈1.51ms），所以 fsr_code 的龄期 0~6.05ms。
    //================================================================
    wire [1:0]  fsr_ch;
    wire [15:0] fsr_data;
    reg  [15:0] fsr_code;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) fsr_code <= 16'd0;
        else if (fsr_ch == 2'd0) fsr_code <= fsr_data;
    end
    wire [7:0] fsr_vel8 = fsr_code[15:8];

    //================================================================
    // 1. 回显通路: uart_rx -> 2 选 1 仲裁 -> uart_tx
    //    （结构逐字取自板级已验证的 probe_ble_led, 只多了 PC 口的轮转仲裁）
    //================================================================
    wire [7:0] pc_data, ble_data;
    wire       pc_valid, ble_valid;

    reg        grant_ble;               // 1 = 本次应答蓝牙口
    reg        rr;                      // 轮转位

    wire       granted = pc_valid | ble_valid;
    wire [7:0] g_data  = ble_valid ? ble_data : pc_data;
    wire       tx_ready;

    // 下行应答(2026-10-24): ACK/NACK 优先占蓝牙 TX，回显让它一拍（不丢字节）
    wire        ack_valid;
    wire [7:0]  ack_data;
    wire        evt_we;
    wire [7:0]  evt_cmd;
    wire [3:0]  evt_code;

    wire       accepted = granted & tx_ready & ~ack_valid;

    uart_rx u_rx_pc (
        .clk(clk), .rst_n(rst_n),
        .rx_data(pc_data), .rx_data_valid(pc_valid),
        .rx_data_ready(accepted & ~grant_ble), .rx_pin(uart_pc_rx));

    wire       ble_ready = accepted & grant_ble;      // 蓝牙口本拍被消费
    wire       ble_take  = ble_valid & ble_ready;     // 单拍: 本拍字节已收下

    uart_rx u_rx_ble (
        .clk(clk), .rst_n(rst_n),
        .rx_data(ble_data), .rx_data_valid(ble_valid),
        .rx_data_ready(ble_ready), .rx_pin(uart_ble_rx));

    uart_tx u_tx (
        .clk(clk), .rst_n(rst_n),
        .tx_data(ack_valid ? ack_data : g_data),
        .tx_data_valid(ack_valid | accepted),
        .tx_data_ready(tx_ready), .tx_pin(uart_ble_tx));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grant_ble <= 1'b1;          // 上电默认偏蓝牙(本项目主用口)
            rr        <= 1'b0;
        end else if (accepted) begin
            grant_ble <= ble_valid;
            if (pc_valid && ble_valid) rr <= ~rr;
        end else if (pc_valid && ble_valid) begin
            grant_ble <= rr;
        end
    end

    //================================================================
    // 2. **手机弹奏**: 在本模块里自己解析 ASCII "音号+"/"音号-"
    //
    //    为什么不用 top 内部的 uart_key:
    //      v1 的自动敲击走的是 top 的 key_* 口, 而那个口**板上实测能出声**;
    //      top 内部那份 uart_key(另一份 UART_Receiver)在真机上的行为我们没验过。
    //      为把"弹奏不响"的变量压到最少, 这里**复用回显那一路已经收到的字节**
    //      (ble_valid/ble_data —— 板上已证明能收到 "60+"), 自己解析成键事件,
    //      直接喂 top 的 key_* 口: 与 v1 自动敲击**完全相同**的那条通路。
    //
    //    解析规则: 数字累积音号; '+' 开 / '-' 关; 其他字节(\n 等)复位累积。
    //    背压: 用 top 引出的 key_ready_out; 不 ready 就挂起(pend), 不丢事件。
    //================================================================
    //----------------------------------------------------------------
    // 2. 键事件汇聚: ASCII 单键 / 二进制协议(音域·和弦·曲谱) → top.key_*
    //    ASCII 与二进制天然共存: ASCII 全 bit7=0 → 协议解析器视为游离数据丢弃;
    //    协议命令字节 bit7=1 → ASCII 解析器复位累积。两边互不干扰。
    //----------------------------------------------------------------
    wire        timbre_w;
    wire [6:0]  p_rvb_mix;               // 0x89 混响湿度
    wire [6:0]  p_glide;                 // 0x8B 滑音量
    wire        demo_we_raw;
    wire [6:0]  demo_note;
    wire        demo_we = demo_we_raw & (GTR_DEMO != 0);
    wire        u_top_ready;            // top 键 FIFO 背压(由 u_top 输出驱动)
    wire        d_eng_we, d_eng_on;
    wire [6:0]  d_eng_note;

    //------------------------------------------------ 2a. 单键源: ASCII "音号+/-" + 小程序 0x87/0x88
    wire        a_take;
    reg  [8:0]  nacc;                   // ASCII 音号累积
    // 2026-10-26 R6: 原来是**单槽** npend, 新事件会直接覆盖还没被 keyhub 取走的那个
    //   (松手覆盖按下 -> 按下消失; 之后同一音被 note_on_map 去重挡住 -> "按下没反应")。
    //   现在改成 2 深小队列, 绝不覆盖。
    reg  [1:0]  nwp, nrp;
    reg  [2:0]  ncnt;
    // [BUG-1] 2026-10-31 本文件顺手修掉的既有缺陷（top_ble_echo.v 同病，未改动）：
    //   nwp/nrp 是 2bit 指针，却直接索引深度 2 的数组 q_*[0:1] —— 第 3 个事件起指针
    //   走到 2/3，仿真读到越界 → 读出 X（a_ok=1'bx → keyhub 永不 a_accept → 之后
    //   所有单音事件卡死在队列里）。这里一律用指针 LSB 索引（深度=2，LSB 本来就是
    //   唯一有效位，硬件综合结果不变），把仿真确定化。
    reg  [6:0]  q_nnote [0:1];
    reg         q_non   [0:1];
    reg  [6:0]  q_nvel  [0:1];
    wire        nfull = (ncnt == 3'd2);
    wire        a_req = (ncnt != 3'd0);
    wire [6:0]  nnote = q_nnote[nrp[0]];
    wire        non   = q_non[nrp[0]];
    wire [6:0]  nvel  = q_nvel[nrp[0]];

    // 小程序单音事件(0x87/0x88): 优先级高于 ASCII
    wire        ble_note_we, ble_note_on;
    wire [6:0]  ble_note_note, ble_note_vel;

    // 去重: 同一个音重复 note-on 直接忽略, 避免连续弹奏时重复重触发造成音头爆音
    reg  [127:0] note_on_map;
    wire         ble_note_acc = ble_note_we &&
                                (ble_note_on ? ~note_on_map[ble_note_note]
                                             :  note_on_map[ble_note_note]);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) note_on_map <= 128'd0;
        else if (ble_note_we) begin
            if (ble_note_on) note_on_map[ble_note_note] <= 1'b1;
            else             note_on_map[ble_note_note] <= 1'b0;
        end
    end

    // ASCII 通路: '+'/'-' 且音号合法时, 产生一个入队请求
    wire        ascii_push = ble_take && !nfull &&
                             (ble_data == 8'h2B || ble_data == 8'h2D) &&
                             (nacc >= 9'd1 && nacc <= 9'd127);
    wire        push_any   = (ble_note_acc || ascii_push) && !nfull;
    wire [6:0]  push_note  = ble_note_acc ? ble_note_note : nacc[6:0];
    wire        push_on    = ble_note_acc ? ble_note_on   : (ble_data == 8'h2B);
    // [FSR-2] 力度选择（放在 ble_note_vel 声明之后：有读数用 FSR，
    //   无读数(高字节==0: 没人按 / I2C 死)退回帧里的 vel 字节）
    wire [6:0]  fsr_vel    = (fsr_vel8 == 8'd0) ? ble_note_vel
                                                : (fsr_code[15] ? 7'd127 : fsr_code[14:8]);
    //   松开事件(0x88)仍发 vel=0 —— 与改动前逐位一致，note_ctrl 松开时也不看 vel。
    wire [6:0]  push_vel   = ble_note_acc ? (ble_note_on ? fsr_vel : 7'd0) : 7'd96;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            nacc <= 9'd0; nwp <= 2'd0; nrp <= 2'd0; ncnt <= 3'd0;
            q_nnote[0] <= 7'd0; q_nnote[1] <= 7'd0;
            q_non[0] <= 1'b0;   q_non[1] <= 1'b0;
            q_nvel[0] <= 7'd96; q_nvel[1] <= 7'd96;
        end else begin
            if (push_any) begin
                q_nnote[nwp[0]] <= push_note;
                q_non[nwp[0]]   <= push_on;
                q_nvel[nwp[0]]  <= push_vel;
                nwp <= nwp + 2'd1;
            end
            if (a_take) nrp <= nrp + 2'd1;
            ncnt <= ncnt + (push_any ? 3'd1 : 3'd0) - (a_take ? 3'd1 : 3'd0);
            // ASCII 音号累积
            if (ble_take) begin
                if (ble_data >= 8'h30 && ble_data <= 8'h39) begin       // '0'..'9'
                    if (nacc > 9'd24) nacc <= 9'd255;                   // 溢出标记(触发时丢弃)
                    else              nacc <= nacc * 9'd10 + (ble_data - 8'h30);
                end else if (ble_data == 8'h2B || ble_data == 8'h2D) begin // '+' / '-'
                    nacc <= 9'd0;
                end else begin
                    nacc <= 9'd0;                                       // '\n'/命令字节等: 复位
                end
            end
        end
    end

    //------------------------------------------------ 2b. 二进制协议 v0
    wire signed [7:0] p_range_off;
    wire [1:0]        p_chord_mode;
    wire              p_ram_we;
    wire [8:0]        p_ram_waddr;
    wire [23:0]       p_ram_wdata;
    wire              p_song_valid;
    wire [9:0]        p_song_len;
    wire              p_play_go, p_play_stop, p_play_rst;
    wire [7:0]        p_err_cnt, p_frame_cnt;

    ble_cmd u_cmd (
        .clk(clk), .rst_n(rst_n),
        .byte_valid(ble_take), .byte_data(ble_data),
        .range_off(p_range_off), .chord_mode(p_chord_mode), .timbre(timbre_w),
        .rvb_mix(p_rvb_mix), .glide_amt(p_glide),
        .ram_we(p_ram_we), .ram_waddr(p_ram_waddr), .ram_wdata(p_ram_wdata),
        .song_valid(p_song_valid), .song_len(p_song_len), .song_updating(),
        .play_go(p_play_go), .play_stop(p_play_stop), .play_rst(p_play_rst),
        .err_cnt(p_err_cnt), .frame_cnt(p_frame_cnt),
        .evt_we(evt_we), .evt_cmd(evt_cmd), .evt_code(evt_code),
        .note_we(ble_note_we), .note_on(ble_note_on),
        .note_note(ble_note_note), .note_vel(ble_note_vel)
    );

    //------------------------------------------------ 2a2. 下行应答 A1/A2
    ack_tx u_ack (
        .clk(clk), .rst_n(rst_n),
        .evt_we(evt_we), .evt_cmd(evt_cmd), .evt_code(evt_code),
        .tx_ready(tx_ready), .tx_data(ack_data), .tx_valid(ack_valid));

    wire [8:0]  p_song_raddr;
    wire [23:0] p_song_rdata;

    song_ram u_song_ram (
        .clk(clk),
        .we(p_ram_we), .waddr(p_ram_waddr), .wdata(p_ram_wdata),
        .raddr(p_song_raddr), .rdata(p_song_rdata)
    );

    wire       p_ev_req, p_ev_on, p_ev_take;
    wire [6:0] p_ev_note, p_ev_vel;

    song_player #(
        .CLK_PER_TICK (500_000),
        .APPLY_RANGE  (1)          // 音域作用于曲谱: 默认生效(可用参数关掉)
    ) u_player (
        .clk(clk), .rst_n(rst_n),
        .go(p_play_go), .stop(p_play_stop), .reset(p_play_rst),
        .song_valid(p_song_valid), .song_len(p_song_len),
        .raddr(p_song_raddr), .rdata(p_song_rdata),
        .range_off(p_range_off),
        .ev_req(p_ev_req), .ev_note(p_ev_note), .ev_on(p_ev_on), .ev_vel(p_ev_vel),
        .ev_take(p_ev_take),
        .playing(), .ptr()
    );

    //------------------------------------------------ 2c. 汇聚出口
    wire        key_we, key_on;
    wire [6:0]  key_note, key_vel;

    keyhub u_hub (
        .clk(clk), .rst_n(rst_n),
        .range_off(p_range_off), .chord_mode(p_chord_mode),
        .a_req(a_req), .a_note(nnote), .a_on(non), .a_vel(nvel), .a_take(a_take),
        .s_req(p_ev_req), .s_note(p_ev_note), .s_on(p_ev_on), .s_vel(p_ev_vel), .s_take(p_ev_take),
        .key_we(key_we), .key_note(key_note), .key_on(key_on), .key_vel(key_vel),
        .key_ready(u_top_ready)
    );

    assign key_ready_out = u_top_ready;     // 原版漏了驱动(仿真里是 z); 该脚不接, 补上防悬空

    top #(
        .NPIX         (NPIX),
        .RATIO_FILE   ("rtl/rom/harm_ratio_C4.hex"),
        .AMP_FILE     ("rtl/rom/harm_amp_vel_pn4_v2.hex"),
        .PHA_FILE     ("rtl/rom/harm_phase_C4.hex"),
        .DEC_FILE     ("rtl/rom/harm_decay_ctrl_slow.hex"),   // v17: 平滑单调 + 拉长余音
        .VEL_LAYERS   (4),
        .OCT_TABLES   (0),           // 改用每音一张表
        .Q4_TABLES    (0),
        .VEL_SHIFT    (5),
        .PN_TABLES    (1),           // per-note table (BSRAM)
        .TIMBRE       (0),           // 0=钢琴（运行时由 0x86 切换；两引擎共存）
        .PER_NOTE_CORR (0),          // 按音修正关闭（时序余量不足）
        .CORR_FILE    ("rtl/rom/note_corr.hex"),
        .NOTE_FILE    ("rtl/rom/note_ftw_48828.hex"),
        .I2S_INT_CLK  (1),
        // 抖动: ±8LSB(-120dBFS, 听不见)。2026-10-22: v27 "后半段风声" 的第二个必要条件。
        //   PCM5102A 在输入序列特殊(全 0 / 恒定值)时会自生可听失真(见 top.v:34-40 的实测记录),
        //   给一点点抖动就恢复正常。资源增量 0 —— LFSR 本来就在 top.v 里，只是被参数关掉了。
        //   若要 A/B: 删掉这一行即回到关闭状态(逐位与旧固件一致)。
        .DITHER_SHIFT (6),
        .DEBUG_TONE   (0),
        .DEBUG_BYPASS (0),
        .TP_N_NOTES   (1),
        .TP_N0        (60),
        .TP_STEP      (0),
        .TP_VEL       (64),
        .ADSR_A_INC   (16'd10923),   // ≈4.6ms 起振
        .ADSR_D_INC   (16'd20),      // v17: 衰减到 sustain 电平 ~0.7s
        .ADSR_SUS     (16'h0800),    // v18: -24dB 保持（中等前衰 + 长尾）
        .ADSR_R_INC   (16'd119),     // ≈0.18s 抬键收尾
        .REL_RATE     (143),          // exponential key-up release, tau~0.15s (measured)
        .ATK_NOISE    (16'd42000),      // hammer noise (peak ~-42dBFS, ~3ms)
        .ATK_DEC      (16'd8192),
        .OUT_ATT_SHIFT (2),          // **-12dB**: 与用户已确认"很合适"的那版同档
        .FSR_KEYS_EN   (0)           // [FSR-3] 关掉 top 内部 AIN0~3 自己的键事件
    ) u_top (
        .clk(clk), .btn_rst(top_rst),
        .btn_test(1'b0),             // 强制 test_mode=0, 接 K4 也不参与
        // <<< 键事件: 由 keyhub 汇总(ASCII 单键 / 和弦 / 曲谱播放)后从这里喂进去
        .key_we_in(key_we), .key_note_in(key_note), .key_on_in(key_on), .key_vel_in(key_vel),
        .timbre_in(timbre_w | (GTR_DEMO != 0)),   // 演示固件强制吉他
        .rvb_mix(p_rvb_mix),          // 0x89 混响湿度（默认 32 = 原 25%）
        .glide_amt(p_glide),         // 0x8B 滑音量（默认 0 = 关）
        .demo_we(demo_we), .demo_note(demo_note),
        .uart_pc_rx(1'b1),           // PC 口与本固件无关
        .uart_ble_rx(1'b1),          // top 内部那份 uart_key 不用(避免两份接收器并存)
        .i2c_sda(i2c_sda), .i2c_scl(i2c_scl),
        .key_ready_out(u_top_ready), // 键 FIFO 背压, 给上面的解析器用
        .o_fsr_ch(fsr_ch), .o_fsr_data(fsr_data),   // [FSR-1] FSR 码值观测口
        .dbg_eng_we   (d_eng_we),
        .dbg_eng_on   (d_eng_on),
        .dbg_eng_note (d_eng_note),
        .dac_sck(), .i2s_bclk(i2s_bclk), .i2s_lrck(i2s_lrck),
        .i2s_sdata(i2s_sdata), .led_din(),
        .oled_sck(oled_sck), .oled_mosi(oled_mosi), .oled_dc(oled_dc), .oled_cs()
    );

    //---- 吉他自动演示：上电每 10s 扫 C4/E4/G4/B3（GTR_DEMO=1 时生效）----
    //     GTR_NNOTES=1 时只弹 C4（单音判定版，见 top_ble_echo_solo.v）
    gtr_demo #(.NNOTES(GTR_NNOTES)) u_demo (
        .clk(clk), .rst_n(rst_n), .we(demo_we_raw), .note(demo_note));

    //================================================================
    // 3. 灯条状态显示（像素流写法取自 probe_ble_led.v）
    //================================================================
    reg [26:0] act_cnt;
    reg [27:0] boot_cnt;
    reg [27:0] pulse_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            act_cnt <= 27'd0; boot_cnt <= 28'd0; pulse_cnt <= 28'd0;
        end else begin
            if (granted && tx_ready) act_cnt <= ACT_CLKS[26:0];
            else if (act_cnt != 27'd0) act_cnt <= act_cnt - 27'd1;

            if (boot_cnt < BOOT_CLKS[27:0]) boot_cnt <= boot_cnt + 28'd1;

            if (pulse_cnt >= PULSE_CLKS[27:0] - 28'd1) pulse_cnt <= 28'd0;
            else pulse_cnt <= pulse_cnt + 28'd1;
        end
    end

    wire boot_phase = (boot_cnt < BOOT_CLKS[27:0]);
    wire pulse_on   = (pulse_cnt < PULSE_ON[27:0]);

    //------------------------------------------------ 2d. LED 音符指引 (2026-10-24)
    //   24 颗 = C4..B5 半音一格；正在发声的音符点亮自己那一格（抬键熄灭）。
    //   事件源 key_we/key_note/key_on 已由 keyhub 合并了 单键 + 和弦 + 曲谱三路。
    wire [31:0] guide_mask;
    wire        guide_active;

    led_guide #(.BASE_NOTE(7'd60), .NPIX(NPIX)) u_guide (
        .clk(clk), .rst_n(rst_n),
        .ev_we(key_we), .ev_note(key_note), .ev_on(key_on),
        .mask(guide_mask), .active(guide_active));

    // LED: mono status driver -- ONE colour, but each of the 32 positions can be
    //      on/off independently (32-bit mask).
    //      Cost ~100 LUT / ~80 FF, vs 1190 LUT / 682 FF for the old 24-bit-per-pixel
    //      double-buffered ws2812_phy driver.
    //      2026-10-24: 指引优先 —— 有音符在响时，只点亮那些音符的位置（琥珀色）；
    //      静音时回到原有状态语义：绿 = 有字节活动，黄 = 启动 3s（仅第 0 颗），
    //      蓝 = 空闲呼吸，否则全灭。
    // 2026-10-26 LED 探针: 最近 3 个 key 事件
    reg [7:0] ev_h1, ev_h2, ev_h3;           // ev_h1 最旧, ev_h3 最新
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin ev_h1 <= 8'd0; ev_h2 <= 8'd0; ev_h3 <= 8'd0; end
        else if ((LED_DBG == 2) ? d_eng_we : key_we) begin
            ev_h1 <= ev_h2;
            ev_h2 <= ev_h3;
            ev_h3 <= (LED_DBG == 2) ? {d_eng_on, d_eng_note} : {key_on, key_note};
        end
    end
    wire [31:0] ev_mask = {8'h00, ev_h3, ev_h2, ev_h1};

    wire [23:0] led_color = (LED_DBG != 0)    ? 24'h00_FF_00 :   // 探针: 纯绿
                            guide_active      ? 24'h60_FF_00 :   // {G,R,B} 琥珀
                            (act_cnt != 27'd0) ? 24'h55_00_00 :
                            boot_phase         ? 24'h55_55_00 :
                            pulse_on           ? 24'h00_00_28 :
                                                 24'h00_00_00;
    wire [31:0] led_mask  = (LED_DBG != 0)    ? ev_mask      :
                            boot_phase   ? 32'h0000_0001 :
                            guide_active ? guide_mask    : 32'hFFFF_FFFF;

    ws2812_mono #(.NPIX(NPIX)) u_led (
        .clk(clk), .rst_n(rst_n), .color(led_color), .mask(led_mask), .din(led_din));

endmodule