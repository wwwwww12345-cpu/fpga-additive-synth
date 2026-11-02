//=============================================================================
// tb_partial_engine.v —— 引擎验收
//   +NVOICE=<n>  同时按下的音数 (1 = 单音, 32 = 满复音)
//   +N0=<midi>   起始音号 (第 v 个音 = N0 + 2v, 隔两个半音便于分辨)
//   +NSAMP=<n>   导出样本数
//   +OUT=<file>  样本文件 (每行一个 24bit 有符号数)
//   +DIV=<n>     sample_req 周期 (默认 1041 -> fs = 50MHz/1041 = 48030.7Hz)
//   另外打印: 每个样本实际用的时钟数 pass_clks 的最大值、overrun 次数
//=============================================================================
`timescale 1ns/1ps

module tb_partial_engine;

    parameter VOICES   = 32;
    parameter PARTIALS = 16;
    parameter PHASE_W  = 24;

    localparam real FCLK = 50.0e6;

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    integer DIV_V, NVOICE_V, N0_V, NSAMP_V;
    integer fd, i, v, n;
    reg [1023:0] out_file;
    real  fnote, fs;
    integer ftw_val;

    reg [11:0] div = 0;
    always @(posedge clk) if (div == DIV_V-1) div <= 0; else div <= div + 1'b1;
    wire sample_req = (div == DIV_V-1);

    reg              param_we = 0;
    reg [4:0]        param_voice = 0;
    reg [PHASE_W-1:0] param_ftw = 0;
    reg              param_on = 1;
    reg [6:0]        param_vel = 127;

    // ADSR: A=2ms, D=0(直接到 S), S=1.0(满载, 便于和幅度表直接比对), R=200ms
    wire [15:0] A_INC = 16'd10923;    // 1/(0.002*1500) = 0.333 -> Q15
    wire [15:0] D_INC = 16'd0;
    wire [15:0] SUS   = 16'h7FFF;
    wire [15:0] R_INC = 16'd109;      // 1.0/(0.2*1500) = 0.00333 -> Q15

    wire signed [23:0] audio_out;
    wire [5:0]  active_voices;
    wire        overrun;
    wire [15:0] pass_clks;
    wire        evt_full;                        // 声明必须在实例化之前(否则隐式网+显式声明冲突)
    integer ovf_cnt = 0, max_pass = 0, ovr_cnt = 0, clip_cnt = 0, peak = 0;
    integer init_cnt = 0, init_max = 0;

    always @(posedge clk) if (evt_full) ovf_cnt = ovf_cnt + 1;
    always @(posedge clk) if (dut.fsm == 3'd4 && !dut.i_phase) begin
        init_cnt = init_cnt + 1;
        if (dut.i_voice > init_max) init_max = dut.i_voice;
    end

    partial_engine #(
        .VOICES(VOICES), .PARTIALS(PARTIALS), .PHASE_W(PHASE_W), .OUT_W(24),
        .SINE_FILE("rtl/rom/sine_q16.hex"), .RATIO_FILE("rtl/rom/harm_ratio_A1.hex"),
        .AMP_FILE("rtl/rom/harm_amp_A1.hex"), .PHA_FILE("rtl/rom/harm_phase_A1.hex"),
        .DEC_FILE("rtl/rom/harm_decay_ctrl_A1.hex")
    ) dut (
        .clk(clk), .rst_n(rst_n), .sample_req(sample_req),
        .param_we(param_we), .param_voice(param_voice), .param_ftw(param_ftw),
        .param_on(param_on), .param_vel(param_vel),
        .adsr_a_inc(A_INC), .adsr_d_inc(D_INC), .adsr_sus(SUS), .adsr_r_inc(R_INC),
        .audio_out(audio_out), .active_voices(active_voices),
        .overrun(overrun), .pass_clks(pass_clks), .evt_full(evt_full)
    );


    function integer midi2ftw;
        input integer note;
        begin
            fnote = 440.0 * $pow(2.0, (note - 69) / 12.0);
            midi2ftw = $rtoi(fnote / fs * 16777216.0 + 0.5);
        end
    endfunction

    initial begin
        if (!$value$plusargs("NVOICE=%d", NVOICE_V)) NVOICE_V = 1;
        if (!$value$plusargs("N0=%d",     N0_V))     N0_V = 69;
        if (!$value$plusargs("NSAMP=%d",  NSAMP_V))  NSAMP_V = 4096;
        if (!$value$plusargs("DIV=%d",    DIV_V))    DIV_V = 1041;
        if (!$value$plusargs("OUT=%s",    out_file)) out_file = "engine_out.txt";
        fs = FCLK / DIV_V;

        $display("=== partial_engine 验收: %0d 音 × %0d 分量, fs = %0.1f Hz",
                 NVOICE_V, PARTIALS, fs);

        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (20) @(posedge clk);

        //---- 按下 NVOICE_V 个音 ----
        for (v = 0; v < NVOICE_V; v = v + 1) begin
            @(negedge clk);
            param_we    = 1'b1;
            param_voice = v[4:0];
            param_ftw   = midi2ftw(N0_V + 2*v);
            param_on    = 1'b1;
            param_vel   = 7'd127;
            @(negedge clk);
            param_we    = 1'b0;
            repeat (2*DIV_V) @(posedge clk);      // 每个音隔两个样本, 给 4 深事件 FIFO 足够余量
        end
        $display("  active_voices = %0d (应为 %0d), FIFO 溢出拍数 = %0d", active_voices, NVOICE_V, ovf_cnt);

        repeat (500) @(posedge clk);          // 等所有音都起振
        //---- 导出 ----
        fd = $fopen(out_file, "w");
        if (fd == 0) begin $display("!! 打不开 %0s", out_file); $finish; end
        for (i = 0; i < NSAMP_V; i = i + 1) begin
            @(posedge clk);
            while (!sample_req) @(posedge clk);       // 等到本样本已算完
            $fwrite(fd, "%0d\n", audio_out);
            if (pass_clks > max_pass) max_pass = pass_clks;
            if (audio_out == 24'sh7FFFFF || audio_out == -24'sh800000) clip_cnt = clip_cnt + 1;
            n = (audio_out < 0) ? -audio_out : audio_out;
            if (n > peak) peak = n;
            if (overrun) ovr_cnt = ovr_cnt + 1;
        end
        $fclose(fd);

        $display("  pass_clks 最大 = %0d  (一个样本周期 %0d clk, 余量 %0.1f%%)",
                 max_pass, DIV_V, 100.0*(DIV_V-max_pass)/DIV_V);
        $display("  overrun 次数 = %0d (应为 0)", ovr_cnt);
        $display("  输出峰值 = %0d / 8388607  (饱和次数 %0d)", peak, clip_cnt);
        $display("  样本已写入 %0s", out_file);
        $finish;
    end

endmodule