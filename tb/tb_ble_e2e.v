//=============================================================================
// tb_ble_e2e.v —— 主页功能端到端验证（2026-10-24）
//
// 串起来的链路：mcu 字节 → ble_cmd → (曲谱写口/音域/和弦/音色) → keyhub → 事件流
//              曲谱 = ble_cmd RAM 写口 → song RAM → song_player → keyhub
//
// 每个场景都用**小程序页面实际会发的字节**驱动，断言最终落到 key 事件流上的音符：
//   A 单键基线           (a_req 60)                     → 60 on/off
//   B 音域「升八度」      81 4C (+12)                     → 72
//   C 和弦「大三」        82 01                           → 60,64,67
//   D 和弦「属七」+升八度 81 4C + 82 03                   → 72,76,79,82
//   E 音色「吉他/钢琴」   86 01 / 86 00                   → timbre 输出
//   F 曲谱下发+演奏       90 02 00 / 91 .. / 92 / 84      → 60 on → 62 on
//   G 演奏停止/复位       85 / 93                         → play_stop / play_rst
//   H 非法 N             90 01 08 (N=1025) + 92           → song_valid 保持 0
//=============================================================================
`timescale 1ns/1ps

module tb_ble_e2e;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;                       // 50 MHz

    //------------------------------------------------------------ ble_cmd
    reg        byte_valid = 1'b0;
    reg  [7:0] byte_data  = 8'h00;
    wire signed [7:0] range_off;
    wire [1:0] chord_mode;
    wire       timbre;
    wire       ram_we;
    wire [8:0] ram_waddr;
    wire [23:0] ram_wdata;
    wire       song_valid;
    wire [9:0] song_len;
    wire       song_updating;
    wire       play_go, play_stop, play_rst;
    wire [7:0] err_cnt, frame_cnt;
    wire        evt_we;
    wire [7:0]  evt_cmd;
    wire [3:0]  evt_code;

    ble_cmd u_cmd (
        .clk(clk), .rst_n(rst_n),
        .byte_valid(byte_valid), .byte_data(byte_data),
        .range_off(range_off), .chord_mode(chord_mode), .timbre(timbre),
        .ram_we(ram_we), .ram_waddr(ram_waddr), .ram_wdata(ram_wdata),
        .song_valid(song_valid), .song_len(song_len), .song_updating(song_updating),
        .play_go(play_go), .play_stop(play_stop), .play_rst(play_rst),
        .err_cnt(err_cnt), .frame_cnt(frame_cnt),
        .evt_we(evt_we), .evt_cmd(evt_cmd), .evt_code(evt_code));

    //------------------------------------------------------------ 下行应答
    wire       ack_valid;
    wire [7:0] ack_data;

    ack_tx u_ack (
        .clk(clk), .rst_n(rst_n),
        .evt_we(evt_we), .evt_cmd(evt_cmd), .evt_code(evt_code),
        .tx_ready(1'b1), .tx_data(ack_data), .tx_valid(ack_valid));

    reg  [7:0] txb [0:31];
    integer    tx_n = 0;
    reg        tx_clr = 1'b0;

    always @(posedge clk) begin
        if (tx_clr) tx_n <= 0;
        else if (ack_valid && tx_n < 32) begin
            txb[tx_n] <= ack_data;
            tx_n      <= tx_n + 1;
        end
    end

    // 等应答发完，再同步清零（避免与上面的自增抢同一拍）
    task clr_tx;
        begin
            wait (!ack_valid);
            repeat (4) @(negedge clk);
            tx_clr = 1'b1;
            @(negedge clk);
            tx_clr = 1'b0;
            repeat (4) @(negedge clk);
        end
    endtask

    //------------------------------------------------------------ song RAM
    reg  [23:0] mem [0:511];
    wire [8:0]  raddr;
    reg  [23:0] rdata;
    integer k;

    always @(posedge clk) begin
        if (ram_we) mem[ram_waddr] <= ram_wdata;
        rdata <= mem[raddr];
    end

    //------------------------------------------------------------ song_player
    wire       s_req, s_on, s_take;
    wire [6:0] s_note, s_vel;
    wire       playing;
    wire [9:0] ptr;

    song_player #(.CLK_PER_TICK(10), .APPLY_RANGE(1)) u_pl (
        .clk(clk), .rst_n(rst_n),
        .go(play_go), .stop(play_stop), .reset(play_rst),
        .song_valid(song_valid), .song_len(song_len),
        .raddr(raddr), .rdata(rdata), .range_off(range_off),
        .ev_req(s_req), .ev_note(s_note), .ev_on(s_on), .ev_vel(s_vel),
        .ev_take(s_take), .playing(playing), .ptr(ptr));

    //------------------------------------------------------------ keyhub
    reg        a_req = 1'b0;
    reg  [6:0] a_note = 7'd0;
    reg        a_on = 1'b0;
    reg  [6:0] a_vel = 7'd96;
    wire       a_take;
    wire       key_we, key_on;
    wire [6:0] key_note, key_vel;

    keyhub u_hub (
        .clk(clk), .rst_n(rst_n),
        .range_off(range_off), .chord_mode(chord_mode),
        .a_req(a_req), .a_note(a_note), .a_on(a_on), .a_vel(a_vel), .a_take(a_take),
        .s_req(s_req), .s_note(s_note), .s_on(s_on), .s_vel(s_vel), .s_take(s_take),
        .key_we(key_we), .key_note(key_note), .key_on(key_on), .key_vel(key_vel),
        .key_ready(1'b1));

    //------------------------------------------------------------ 事件捕获
    reg  [6:0] evn [0:63];
    reg        evo [0:63];
    integer    ev_n = 0;

    always @(posedge clk) begin
        if (key_we && ev_n < 64) begin
            evn[ev_n] <= key_note;
            evo[ev_n] <= key_on;
            ev_n      <= ev_n + 1;
        end
    end

    integer fails = 0, checks = 0;

    task chk(input [255:0] name, input integer got, input integer exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                fails = fails + 1;
                $display("  FAIL %0s : got=%0d exp=%0d", name, got, exp);
            end else $display("  ok   %0s : %0d", name, got);
        end
    endtask

    task chk_ev(input [255:0] name, input integer idx, input integer note, input integer onbit);
        begin
            checks = checks + 1;
            if (idx >= ev_n) begin
                fails = fails + 1;
                $display("  FAIL %0s : 事件不足(共 %0d 个)", name, ev_n);
            end else if ((evn[idx] !== note[6:0]) || (evo[idx] !== onbit[0])) begin
                fails = fails + 1;
                $display("  FAIL %0s : got note=%0d on=%0d, exp %0d/%0d",
                         name, evn[idx], evo[idx], note, onbit);
            end else $display("  ok   %0s : note=%0d on=%0d", name, evn[idx], evo[idx]);
        end
    endtask

    task send(input [7:0] b);
        begin
            @(negedge clk); byte_valid = 1'b1; byte_data = b;
            @(negedge clk); byte_valid = 1'b0; byte_data = 8'h00;
            repeat (10) @(negedge clk);
        end
    endtask

    task press(input [6:0] n);
        begin
            @(negedge clk); a_req = 1'b1; a_note = n; a_on = 1'b1; a_vel = 7'd96;
            wait (a_take); @(negedge clk); a_req = 1'b0;
            repeat (6) @(negedge clk);
        end
    endtask

    task lift(input [6:0] n);
        begin
            @(negedge clk); a_req = 1'b1; a_note = n; a_on = 1'b0; a_vel = 7'd0;
            wait (a_take); @(negedge clk); a_req = 1'b0;
            repeat (6) @(negedge clk);
        end
    endtask

    task do_reset;
        begin
            @(negedge clk); rst_n = 1'b0;
            repeat (10) @(negedge clk);
            rst_n = 1'b1;
            repeat (10) @(negedge clk);
            ev_n = 0;
        end
    endtask

    //------------------------------------------------------------ 主流程
    initial begin : main

        //===== A 单键基线
        $display("\n[A] 单键 60（无移调/无和弦）");
        do_reset;
        press(7'd60);
        chk("A 事件数", ev_n, 1);
        chk_ev("A note=60 on", 0, 60, 1);
        lift(7'd60);
        chk_ev("A note=60 off", 1, 60, 0);

        //===== B 音域升八度
        $display("\n[B] 音域「升八度」81 4C → 单键 60 应发 72");
        do_reset;
        send(8'h81); send(8'h4C);                 // +12
        chk("B range_off", range_off, 12);
        press(7'd60);
        chk_ev("B note=72 on", 0, 72, 1);
        lift(7'd60);

        //===== C 和弦大三
        $display("\n[C] 和弦「大三」82 01 → 单键 60 应发 60/64/67");
        do_reset;
        send(8'h82); send(8'h01);
        chk("C chord_mode", chord_mode, 1);
        press(7'd60);
        chk("C 事件数(3 音)", ev_n, 3);
        chk_ev("C 根音", 0, 60, 1);
        chk_ev("C 大三度", 1, 64, 1);
        chk_ev("C 纯五度", 2, 67, 1);
        lift(7'd60);

        //===== D 属七 + 升八度
        $display("\n[D] 属七 82 03 + 升八度 81 4C → 72/76/79/82");
        do_reset;
        send(8'h81); send(8'h4C);
        send(8'h82); send(8'h03);
        press(7'd60);
        chk("D 事件数(4 音)", ev_n, 4);
        chk_ev("D 根音", 0, 72, 1);
        chk_ev("D 大三度", 1, 76, 1);
        chk_ev("D 纯五度", 2, 79, 1);
        chk_ev("D 小七度", 3, 82, 1);
        lift(7'd60);

        //===== E 音色
        $display("\n[E] 音色 86 01 / 86 00");
        do_reset;
        send(8'h86); send(8'h01);
        chk("E timbre=吉他", timbre, 1);
        send(8'h86); send(8'h00);
        chk("E timbre=钢琴", timbre, 0);

        //===== F 曲谱下发 + 演奏
        $display("\n[F] 曲谱 90/91/92 + 84");
        do_reset;
        send(8'h90); send(8'h02); send(8'h00);            // N=2
        send(8'h91); send(8'h3C); send(8'h60); send(8'h32);  // 60 vel96 dur50
        send(8'h91); send(8'h3E); send(8'h64); send(8'h0A);  // 62 vel100 dur10
        send(8'h92);
        chk("F song_valid", song_valid, 1);
        chk("F song_len",   song_len,   2);
        chk("F RAM[0] note", mem[0][22:16], 60);
        chk("F RAM[0] vel",  mem[0][15:9],  96);
        chk("F RAM[0] dur",  mem[0][8:2],   50);
        chk("F RAM[1] note", mem[1][22:16], 62);
        ev_n = 0;
        send(8'h84);                                       // 开始演奏
        repeat (200) @(negedge clk);                       // 60 的 500 拍还没走完
        chk("F 演奏中 note=60 on", ev_n >= 1, 1);
        chk_ev("F 第一个音", 0, 60, 1);
        repeat (1200) @(negedge clk);                      // 让两条都过完
        chk_ev("F 第二音前先抬 60", 1, 60, 0);
        chk_ev("F 第二个音 62",     2, 62, 1);
        chk("F 播完停止(playing)", playing, 0);

        //===== G 停止 / 复位
        $display("\n[G] 85 停止 / 93 复位");
        do_reset;
        send(8'h90); send(8'h01); send(8'h00);              // N=1
        send(8'h91); send(8'h3C); send(8'h60); send(8'h7F);  // 60, vel96, dur127(长音)
        send(8'h92);
        ev_n = 0;
        send(8'h84);
        repeat (100) @(negedge clk);
        chk("G 播放中", playing, 1);
        chk_ev("G 有音在响", 0, 60, 1);
        send(8'h85);
        repeat (80) @(negedge clk);
        chk("G 85 后 playing=0", playing, 0);
        chk("G 85 后最后一个事件是抬键", evo[ev_n-1], 0);

        // 复位：重新下发后播放，0x93 必须停且指针归零
        send(8'h90); send(8'h01); send(8'h00);
        send(8'h91); send(8'h3C); send(8'h60); send(8'h7F);
        send(8'h92);
        send(8'h84); repeat (100) @(negedge clk);
        send(8'h93); repeat (80) @(negedge clk);
        chk("G 93 后 playing=0", playing, 0);
        chk("G 93 后 ptr 归零",  ptr,    0);

        //===== H 非法 N 不得被 92 洗白（今日修复的回归项）
        $display("\n[H] 非法 N=1025 + 0x92 → 仍不可播");
        do_reset;
        send(8'h90); send(8'h01); send(8'h08);
        chk("H 0x90 报错", err_cnt, 1);
        send(8'h91); send(8'h3C); send(8'h60); send(8'h32);
        send(8'h92);
        chk("H song_valid 保持 0", song_valid, 0);

        //===== I 下行应答 A1/A2
        $display("\n[I] ACK: PING / 曲谱成功 / 非法N / 未下发就结束");
        do_reset;
        clr_tx;
        send(8'h80);                                    // PING
        chk("I PING 回 2 字节", tx_n, 2);
        chk("I PING byte0=A1", txb[0], 8'hA1);
        chk("I PING byte1=00(低7位)", txb[1], 8'h00);

        clr_tx;
        send(8'h90); send(8'h01); send(8'h00);          // N=1
        chk("I 0x90 成功不回包", tx_n, 0);
        send(8'h91); send(8'h3C); send(8'h60); send(8'h32);
        chk("I 0x91 不回包", tx_n, 0);
        send(8'h92);
        chk("I 成功只回 2 字节", tx_n, 2);
        chk("I ACK byte0=A1", txb[0], 8'hA1);
        chk("I ACK byte1=12(低7位)", txb[1], 8'h12);

        clr_tx;
        send(8'h90); send(8'h01); send(8'h08);          // 非法 N=1025
        chk("I 非法N 回 3 字节", tx_n, 3);
        chk("I NACK byte0=A2", txb[0], 8'hA2);
        chk("I NACK byte1=10(低7位)", txb[1], 8'h10);
        chk("I NACK 错误码=2", txb[2], 8'h02);

        // 干净复位后直接发 0x92 → 不在下发期，错误码 3
        do_reset;
        clr_tx;
        send(8'h92);
        chk("I 未下发就结束 回 3 字节", tx_n, 3);
        chk("I NACK byte1=12(低7位)", txb[1], 8'h12);
        chk("I 错误码=3", txb[2], 8'h03);

        clr_tx;
        send(8'h81); send(8'h4C);                       // 音域：不应答
        send(8'h82); send(8'h01);
        send(8'h86); send(8'h01);
        send(8'h83);
        chk("I 其它命令静默", tx_n, 0);

        $display("\n----------------------------------------");
        if (fails == 0) $display("=== ALL CHECK PASSED === (%0d checks)", checks);
        else            $display("--- FAIL --- %0d/%0d", fails, checks);
        $display("----------------------------------------\n");
        $finish;
    end
endmodule
