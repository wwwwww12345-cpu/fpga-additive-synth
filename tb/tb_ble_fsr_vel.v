//=============================================================================
// tb_ble_fsr_vel.v —— 小程序 0x87 → **FSR 实时力度** → keyhub 出口 回归 (2026-10-31)
//
// 被测 DUT = 真实的 rtl/top_ble_fsr.v（完整链路：字节注入 → ble_cmd →
//            [FSR-2] 力度选择 → keyhub → key_we/key_note/key_on/key_vel）。
//
//   字节注入: force dut.ble_data / dut.ble_take（uart_rx 之后的"已收字节"层面；
//   UART 物理层不在本 tb 范围，本轮也未改它），每个字节正好 1 拍 byte_valid。
//   fsr_code 注入: force dut.fsr_code（就是 top_ble_fsr 里那个锁存寄存器）。
//   复位加速: force 上电计数器（pwr_cnt/oled_rst_cnt/oled_post_cnt 与 u_top 内部
//   pwr_cnt），跳过 21ms+20ms+1ms 上电延时 —— 只影响仿真时长，不改任何逻辑。
//   （打印串用 ASCII: ModelSim ASE 在中文 Windows 控制台会把 UTF-8 打成乱码）
//
// 断言：
//   A1  87 3C 60, fsr_code=0x4E20  → note=60 on=1 vel=0x4E(78)   [FSR 生效]
//   A2  88 3C                      → note=60 on=0 vel=0          [松开不带上力度]
//   A3  87 3E 60, fsr_code=0x0000  → note=62 on=1 vel=96         [无 FSR 读数→退回帧值]
//   A4  87 40 60, fsr_code=0x8000  → note=64 on=1 vel=127        [高位越界→钳 127]
//   B1  FSR_KEYS_EN=1 的 top: 注入 fsr_we → key_* 被 FSR 事件占据（原行为）
//   B2  FSR_KEYS_EN=0 的 top: 注入 fsr_we → key_* 仍走 key_*_in（门控生效）
//   期望结尾: "BFSV: ALL PASS (10 checks)"
//=============================================================================
`timescale 1ns/1ps
module tb_ble_fsr_vel;

    reg clk = 1'b0;
    always #10 clk = ~clk;                  // 50 MHz

    integer errs = 0, checks = 0;

    //=====================================================================
    // DUT1: 真实 top_ble_fsr（小程序单音 + FSR 力度）
    //=====================================================================
    reg        btn_rst = 1'b0;
    reg        uart_ble_rx = 1'b1;
    wire       uart_ble_tx, led_din, key_ready_out;
    wire       dac_sck, i2s_bclk, i2s_lrck, i2s_sdata;
    wire       oled_sck, oled_mosi, oled_dc, oled_rst;
    wire       i2c_sda_d1, i2c_scl_d1;

    top_ble_fsr u_dut (
        .clk(clk), .btn_rst(btn_rst),
        .uart_ble_tx(uart_ble_tx), .uart_ble_rx(uart_ble_rx),
        .uart_pc_rx(1'b1), .led_din(led_din), .key_ready_out(key_ready_out),
        .dac_sck(dac_sck), .i2s_bclk(i2s_bclk), .i2s_lrck(i2s_lrck), .i2s_sdata(i2s_sdata),
        .btn_test(1'b0),
        .i2c_sda(i2c_sda_d1), .i2c_scl(i2c_scl_d1),
        .oled_sck(oled_sck), .oled_mosi(oled_mosi), .oled_dc(oled_dc), .oled_rst(oled_rst));

    pullup (i2c_sda_d1);                    // 板上 ADS1115 模块带 10k 上拉

    // ---- keyhub 出口事件捕获（这条就是喂给 top.key_* 的总线）
    reg [6:0] ev_note [0:15];
    reg       ev_on   [0:15];
    reg [6:0] ev_vel  [0:15];
    integer   ev_n = 0;
    always @(posedge clk) begin
        if (u_dut.key_we && ev_n < 16) begin
            ev_note[ev_n] <= u_dut.key_note;
            ev_on  [ev_n] <= u_dut.key_on;
            ev_vel [ev_n] <= u_dut.key_vel;
            $display("  [%0t] EVT#%0d note=%0d on=%b vel=%0d",
                     $time, ev_n, u_dut.key_note, u_dut.key_on, u_dut.key_vel);
            ev_n <= ev_n + 1;
        end
    end

    //=====================================================================
    // DUT2/DUT3: 裸 top，只为 FSR_KEYS_EN 门控 A/B
    //=====================================================================
    reg        a_kwe = 1'b0, a_kon = 1'b0;
    reg  [6:0] a_knote = 7'd69, a_kvel = 7'd64;
    wire       a_kready, b_kready;
    reg        b_kwe = 1'b0, b_kon = 1'b0;
    reg  [6:0] b_knote = 7'd69, b_kvel = 7'd64;
    wire       i2c_sda_a, i2c_sda_b;

    top #(.DISP_ON(0)) uA (                 // 默认 FSR_KEYS_EN=1（既有行为）
        .clk(clk), .btn_rst(1'b0), .btn_test(1'b0),
        .key_we_in(a_kwe), .key_note_in(a_knote), .key_on_in(a_kon), .key_vel_in(a_kvel),
        .timbre_in(1'b0), .demo_we(1'b0), .demo_note(7'd0),
        .uart_pc_rx(1'b1), .uart_ble_rx(1'b1),
        .i2c_sda(i2c_sda_a), .i2c_scl(), .key_ready_out(a_kready),
        .dac_sck(), .i2s_bclk(), .i2s_lrck(), .i2s_sdata(), .led_din(),
        .oled_sck(), .oled_mosi(), .oled_dc(), .oled_cs(),
        .o_fsr_ch(), .o_fsr_data(),
        .dbg_eng_we(), .dbg_eng_on(), .dbg_eng_note());

    top #(.DISP_ON(0), .FSR_KEYS_EN(0)) uB ( // 门控版
        .clk(clk), .btn_rst(1'b0), .btn_test(1'b0),
        .key_we_in(b_kwe), .key_note_in(b_knote), .key_on_in(b_kon), .key_vel_in(b_kvel),
        .timbre_in(1'b0), .demo_we(1'b0), .demo_note(7'd0),
        .uart_pc_rx(1'b1), .uart_ble_rx(1'b1),
        .i2c_sda(i2c_sda_b), .i2c_scl(), .key_ready_out(b_kready),
        .dac_sck(), .i2s_bclk(), .i2s_lrck(), .i2s_sdata(), .led_din(),
        .oled_sck(), .oled_mosi(), .oled_dc(), .oled_cs(),
        .o_fsr_ch(), .o_fsr_data(),
        .dbg_eng_we(), .dbg_eng_on(), .dbg_eng_note());

    pullup (i2c_sda_a);
    pullup (i2c_sda_b);

    // 打开方式: vlog +define+BFSV_DEBUG ... （只是诊断打印，不影响断言）
`ifdef BFSV_DEBUG
    always @(posedge clk) begin
        if (u_dut.ble_note_we)
            $display("  DBG note_we on=%b note=%0d vel=%0d acc=%b push_any=%b ncnt=%0d",
                     u_dut.ble_note_on, u_dut.ble_note_note, u_dut.ble_note_vel,
                     u_dut.ble_note_acc, u_dut.push_any, u_dut.ncnt);
        if (u_dut.a_take)
            $display("  DBG a_take ncnt=%0d hub_wcnt=%0d key_ready=%b",
                     u_dut.ncnt, u_dut.u_hub.wcount, u_dut.u_top.key_ready);
        if (u_dut.a_req)
            $display("  DBG a_req note=%0d on=%b | busy=%b ready=%b space=%0d ok=%b",
                     u_dut.nnote, u_dut.non, u_dut.u_hub.a_busy, u_dut.u_hub.a_ready,
                     u_dut.u_hub.space, u_dut.u_hub.a_ok);
    end
`endif

    //=====================================================================
    // 工具
    //=====================================================================
    task send8(input [7:0] b);
        begin
            @(negedge clk);
            force u_dut.ble_data = b;
            force u_dut.ble_take = 1'b1;    // 正好 1 拍 byte_valid
            @(negedge clk);
            force u_dut.ble_take = 1'b0;
            @(negedge clk);
        end
    endtask

    task chk_ev(input [255:0] name, input integer idx,
                input integer enote, input integer eon, input integer evel);
        begin
            checks = checks + 1;
            if (ev_n <= idx) begin
                errs = errs + 1;
                $display("  FAIL %0s : no event (ev_n=%0d)", name, ev_n);
            end else if ((ev_note[idx] !== enote[6:0]) || (ev_on[idx] !== eon[0]) ||
                         (ev_vel[idx]  !== evel[6:0])) begin
                errs = errs + 1;
                $display("  FAIL %0s : got note=%0d on=%0d vel=%0d, exp %0d/%0d/%0d",
                         name, ev_note[idx], ev_on[idx], ev_vel[idx], enote, eon, evel);
            end else
                $display("  ok   %0s : note=%0d on=%0d vel=%0d", name, enote, eon, evel);
        end
    endtask

    task chk_cnt(input [255:0] name, input integer e);
        begin
            checks = checks + 1;
            if (ev_n !== e) begin
                errs = errs + 1;
                $display("  FAIL %0s : event count %0d, exp %0d", name, ev_n, e);
            end else $display("  ok   %0s : event count %0d", name, e);
        end
    endtask

    //=====================================================================
    // 主流程
    //=====================================================================
    initial begin
        // ---- 加速上电复位（不改逻辑，只跳过 21ms+20ms+1ms 的计数器）
        #1;
        force u_dut.pwr_cnt        = 20'hF_FFFF;
        force u_dut.oled_rst_cnt   = 20'd999_999;
        force u_dut.oled_post_cnt  = 17'd49_999;
        force u_dut.u_top.pwr_cnt  = 20'hF_FFFF;
        force uA.pwr_cnt           = 20'hF_FFFF;
        force uB.pwr_cnt           = 20'hF_FFFF;
        repeat (40) @(posedge clk);
        if (u_dut.rst_n !== 1'b1) begin
            errs = errs + 1; $display("  FAIL reset not released (rst_n=%b)", u_dut.rst_n);
        end else $display("  ok   reset released (rst_n=1)");

        //---- A1: 0x87 + FSR 有读数 -> 力度取 FSR
        $display("\n[A1] 87 3C 60, fsr_code=0x4E20 -> note 60 / vel 78");
        force u_dut.fsr_code = 16'h4E20;
        send8(8'h87); send8(8'h3C); send8(8'h60);
        repeat (20) @(posedge clk);
        chk_ev("A1 0x87 uses FSR velocity", 0, 60, 1, 78);
        chk_cnt("A1 exactly 1 event", 1);

        //---- A2: 0x88 松开 -> vel 必须是 0（不带上力度）
        $display("\n[A2] 88 3C -> note 60 / off / vel 0");
        send8(8'h88); send8(8'h3C);
        repeat (20) @(posedge clk);
        chk_ev("A2 0x88 note-off", 1, 60, 0, 0);
        chk_cnt("A2 event count", 2);

        //---- A3: FSR 无读数(高字节=0) -> 退回帧里的 vel 字节
        $display("\n[A3] 87 3E 60, fsr_code=0 -> note 62 / vel 96 (frame byte)");
        force u_dut.fsr_code = 16'h0000;
        send8(8'h87); send8(8'h3E); send8(8'h60);
        repeat (20) @(posedge clk);
        chk_ev("A3 fallback to frame vel", 2, 62, 1, 96);
        chk_cnt("A3 event count", 3);

        //---- A4: 码值 bit15=1 -> 钳到 127
        $display("\n[A4] 87 40 60, fsr_code=0x8000 -> note 64 / vel 127");
        force u_dut.fsr_code = 16'h8000;
        send8(8'h87); send8(8'h40); send8(8'h60);
        repeat (20) @(posedge clk);
        chk_ev("A4 clamp to 127", 3, 64, 1, 127);
        chk_cnt("A4 event count", 4);

        //---- B1: FSR_KEYS_EN=1 -> 注入的 fsr_we 抢到 key_*（原行为）
        $display("\n[B1] FSR_KEYS_EN=1: force fsr_we=1 note=60 vel=127 -> key_* takes FSR");
        force uA.u_fsr.key_we   = 1'b1;
        force uA.u_fsr.key_note = 7'd60;
        force uA.u_fsr.key_on   = 1'b1;
        force uA.u_fsr.key_vel  = 7'd127;
        a_kwe = 1'b1; a_knote = 7'd69; a_kon = 1'b1; a_kvel = 7'd64;   // 同时给外部键
        repeat (6) @(posedge clk);
        checks = checks + 1;
        if ((uA.key_we !== 1'b1) || (uA.key_note !== 7'd60) || (uA.key_vel !== 7'd127)) begin
            errs = errs + 1;
            $display("  FAIL B1 : got we=%b note=%0d vel=%0d, exp 1/60/127",
                     uA.key_we, uA.key_note, uA.key_vel);
        end else $display("  ok   B1 : FSR event wins (note=60 vel=127)");

        //---- B2: FSR_KEYS_EN=0 -> fsr_we 被门控，key_* 仍走外部键
        $display("\n[B2] FSR_KEYS_EN=0: same fsr_we injection -> key_* must use key_*_in(69/64)");
        force uB.u_fsr.key_we   = 1'b1;
        force uB.u_fsr.key_note = 7'd60;
        force uB.u_fsr.key_on   = 1'b1;
        force uB.u_fsr.key_vel  = 7'd127;
        b_kwe = 1'b1; b_knote = 7'd69; b_kon = 1'b1; b_kvel = 7'd64;
        repeat (6) @(posedge clk);
        checks = checks + 1;
        if ((uB.key_we !== 1'b1) || (uB.key_note !== 7'd69) || (uB.key_vel !== 7'd64)) begin
            errs = errs + 1;
            $display("  FAIL B2 : got we=%b note=%0d vel=%0d, exp 1/69/64 (FSR should be gated)",
                     uB.key_we, uB.key_note, uB.key_vel);
        end else $display("  ok   B2 : FSR event gated, external key passes");

        a_kwe = 1'b0; b_kwe = 1'b0;

        // ---- 收尾
        $display("\n----------------------------------------");
        if (errs == 0) $display("=== BFSV: ALL PASS (%0d checks) ===", checks);
        else           $display("=== BFSV: FAIL (%0d/%0d) ===", errs, checks);
        $display("----------------------------------------");
        $finish;
    end

    // 看门狗（防挂死）
    initial begin
        #5_000_000;                     // 5ms 仿真时间上限（本 tb 应在 ~50us 内结束）
        $display("=== BFSV: FAIL (watchdog timeout) ===");
        $finish;
    end

endmodule
