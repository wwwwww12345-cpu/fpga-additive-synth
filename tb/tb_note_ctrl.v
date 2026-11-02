//=============================================================================
// tb_note_ctrl.v —— 交互层 -> note_ctrl -> 引擎 的端到端验收
//
// 场景(一条 testbench 跑完, 输出三段音频给 tools/verify_note_ctrl.py 验):
//   seg1: 按 8 个音(110..369Hz, 隔 3 个半音), 无表情   -> 8 个基频都在, 音高准
//   seg2: 弯音 +32767 (≈+2 半音)                      -> 基频整体上移 200 音分
//   seg3: 颤音 vib_depth=3000, vib_inc=655(≈15Hz)     -> 基频随时间摆动
//   最后: 再按 40 个音(超过 32 复音)                  -> 抢占生效, 事件不丢
//
// 用法: vsim -c -do "run -all; quit -f" work.tb_note_ctrl
//=============================================================================
`timescale 1ns/1ps

module tb_note_ctrl;

    parameter VOICES  = 32;
    parameter PHASE_W = 24;
    parameter DIV     = 1041;              // sample_req 周期 -> fs = 50MHz/1041

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    reg [11:0] div = 0;
    always @(posedge clk) if (div == DIV-1) div <= 0; else div <= div + 1'b1;
    wire sample_req = (div == DIV-1);

    //---------------- 键事件(本 TB 直接当"交互层"来喂) ----------------
    reg        key_we = 0;
    reg [6:0]  key_note = 0;
    reg        key_on = 0;
    reg [6:0]  key_vel = 0;
    wire       key_ready;

    //---------------- 表情量 ----------------
    reg signed [15:0] bend_q15 = 0;
    reg [15:0]        vib_depth_q15 = 0;
    reg [15:0]        vib_inc = 0;
    reg [15:0]        glide_q15 = 0;

    //---------------- ADSR: A=2ms, S=1.0(便于和幅度表直接比对), R=200ms ----------------
    wire [15:0] A_INC = 16'd10923, D_INC = 16'd0, SUS = 16'h7FFF, R_INC = 16'd109;

    wire        eng_we, eng_on, eng_evt_full;
    wire [4:0]  eng_voice;
    wire [PHASE_W-1:0] eng_ftw;
    wire [6:0]  eng_vel;
    wire        pitch_we;
    wire [4:0]  pitch_voice;
    wire [PHASE_W-1:0] pitch_ftw;
    wire [VOICES-1:0]  voice_busy, voice_rel;
    wire [5:0]  busy_cnt;
    wire        steal_flag;
    wire [7:0]  drop_cnt;

    wire signed [23:0] audio_out;
    wire [5:0]  active_voices;
    wire        overrun;
    wire [15:0] pass_clks;

    note_ctrl #(.VOICES(VOICES), .PHASE_W(PHASE_W),
                .NOTE_FILE("rtl/rom/note_ftw.hex")) u_nc (
        .clk(clk), .rst_n(rst_n), .sample_req(sample_req),
        .key_we(key_we), .key_note(key_note), .key_on(key_on), .key_vel(key_vel),
        .key_ready(key_ready),
        .bend_q15(bend_q15), .vib_depth_q15(vib_depth_q15), .vib_inc(vib_inc), .glide_q15(glide_q15),
        .adsr_a_inc(A_INC), .adsr_d_inc(D_INC), .adsr_sus(SUS), .adsr_r_inc(R_INC),
        .eng_we(eng_we), .eng_voice(eng_voice), .eng_ftw(eng_ftw),
        .eng_on(eng_on), .eng_vel(eng_vel), .eng_evt_full(eng_evt_full),
        .pitch_we(pitch_we), .pitch_voice(pitch_voice), .pitch_ftw(pitch_ftw),
        .voice_busy(voice_busy), .voice_rel(voice_rel),
        .busy_cnt(busy_cnt), .steal_flag(steal_flag), .drop_cnt(drop_cnt)
    );

    partial_engine #(
        .VOICES(VOICES), .PARTIALS(16), .PHASE_W(PHASE_W), .OUT_W(24),
        .SINE_FILE("rtl/rom/sine_q16.hex"), .RATIO_FILE("rtl/rom/harm_ratio_A1.hex"),
        .AMP_FILE("rtl/rom/harm_amp_A1.hex"), .PHA_FILE("rtl/rom/harm_phase_A1.hex"),
        .DEC_FILE("rtl/rom/harm_decay_ctrl_A1.hex")
    ) u_eng (
        .clk(clk), .rst_n(rst_n), .sample_req(sample_req),
        .param_we(eng_we), .param_voice(eng_voice), .param_ftw(eng_ftw),
        .param_on(eng_on), .param_vel(eng_vel),
        .pitch_we(pitch_we), .pitch_voice(pitch_voice), .pitch_ftw(pitch_ftw),
        .adsr_a_inc(A_INC), .adsr_d_inc(D_INC), .adsr_sus(SUS), .adsr_r_inc(R_INC),
        .audio_out(audio_out), .active_voices(active_voices),
        .overrun(overrun), .pass_clks(pass_clks), .evt_full(eng_evt_full)
    );

    integer fd, i;
    integer max_pass = 0, ovr = 0;
    integer ftw_min = 99999999, ftw_max = 0, ftw_tgt0 = 0;
    always @(posedge clk) if (pitch_we && pitch_voice == 5'd2) begin
        if (pitch_ftw < ftw_min) ftw_min = pitch_ftw;
        if (pitch_ftw > ftw_max) ftw_max = pitch_ftw;
    end

    task press;
        input [6:0] note;
        input       on;
        begin
            while (!key_ready) @(posedge clk);      // 尊重背压, 不丢事件
            @(negedge clk);
            key_we = 1; key_note = note; key_on = on; key_vel = 7'd127;
            @(negedge clk);
            key_we = 0;
        end
    endtask

    task dump;
        input [1023:0] fn;
        input integer n;
        begin
            fd = $fopen(fn, "w");
            for (i = 0; i < n; i = i + 1) begin
                @(posedge clk);
                while (!sample_req) @(posedge clk);
                $fwrite(fd, "%0d\n", audio_out);
                if (pass_clks > max_pass) max_pass = pass_clks;
                if (overrun) ovr = ovr + 1;
            end
            $fclose(fd);
        end
    endtask

    task wait_samples;
        input integer n;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(posedge clk);
                while (!sample_req) @(posedge clk);
            end
        end
    endtask

    initial begin
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (700) @(posedge clk);          // 等引擎上电清零

        //---- 按 8 个音: MIDI 45,48,51,54,57,60,63,66 (110..369Hz) ----
        press(7'd45, 1'b1);  press(7'd50, 1'b1);  press(7'd55, 1'b1);  press(7'd60, 1'b1);
        press(7'd65, 1'b1);  press(7'd70, 1'b1);  press(7'd75, 1'b1);  press(7'd80, 1'b1);
        wait_samples(800);
        $display("== seg1 无表情: busy_cnt=%0d active_voices=%0d", busy_cnt, active_voices);
        dump("nc_seg1.txt", 4096);

        //---- 弯音 +2 半音 ----
        bend_q15 = 16'sh7FFF;
        wait_samples(200);
        $display("== seg2 弯音 +32767 (期望 +200 音分)");
        dump("nc_seg2.txt", 4096);
        bend_q15 = 16'sh0000;
        wait_samples(200);

        //---- 颤音: 深度 3000 (≈9.2% ≈ ±152 音分), LFO ≈15Hz ----
        ftw_min = 99999999; ftw_max = 0;      // 只在颤音段统计(否则会把抢占后的重分配也算进来)
        // 颤音段只留一个音(55), 否则密集谐波谱里测不出基频摆动
        press(7'd45, 1'b0); press(7'd50, 1'b0); press(7'd60, 1'b0); press(7'd65, 1'b0);
        press(7'd70, 1'b0); press(7'd75, 1'b0); press(7'd80, 1'b0);
        wait_samples(300);
        vib_depth_q15 = 16'd3000;
        vib_inc = 16'd655;                     // 2*32768/(1500/15) ≈ 655
        wait_samples(200);
        $display("== seg3 颤音 depth=%0d inc=%0d", vib_depth_q15, vib_inc);
        dump("nc_seg3.txt", 4096);
        vib_depth_q15 = 0; vib_inc = 0;
        wait_samples(200);

        //---- 放开 8 个音, 再按 40 个音(超过 32 复音) 测抢占 ----
        press(7'd45, 1'b0); press(7'd50, 1'b0); press(7'd55, 1'b0); press(7'd60, 1'b0);
        press(7'd65, 1'b0); press(7'd70, 1'b0); press(7'd75, 1'b0); press(7'd80, 1'b0);
        wait_samples(100);
        for (i = 0; i < 40; i = i + 1) press(7'd36 + i[6:0], 1'b1);
        wait_samples(200);
        $display("== 40 音抢占: busy_cnt=%0d steal=%b drop_cnt=%0d active_voices=%0d",
                 busy_cnt, steal_flag, drop_cnt, active_voices);

        $display("== 时序: pass_clks 最大=%0d/%0d, overrun=%0d", max_pass, DIV, ovr);
        $display("== 声部2 FTW 调制: min=%0d max=%0d base=%0d (峰峰 %0.2f%%)",
                 ftw_min, ftw_max, u_nc.v_ftw_tgt[2],
                 100.0 * (ftw_max - ftw_min) / u_nc.v_ftw_tgt[2]);
        $finish;
    end

endmodule