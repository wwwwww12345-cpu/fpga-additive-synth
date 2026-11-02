//=============================================================================
// tb_partial_engine_bitref.v —— 钢琴引擎 "contrib→vsum 加一级流水" 逐位验收 (2026-11-01)
//
// 改动：rtl/partial_engine.v 把 contrib 打一拍（contrib_r），累加/ags 更新顺延一拍，
//       窗口结束条件 SLOTS+3 -> SLOTS+4。数值应**完全不变**（加法顺序/舍入点/32bit 截位不变）。
// 参考：tb/partial_engine_ref.v（git HEAD 冻结版，两级 b/c/d 流水，无 e 级）。
//
// 判据：两实例 audio_out 逐样本相同 —— 允许整体延迟 ≤ 2 个采样（本改动是 1 拍，远小于 1 采样），
//       因此对着同一拍比较；最后再打印 pass_clks / overrun 对照。
// 激励：4 个音分批按下（不同力度）、松手、重触发，并带一次 pitch_we 微调；
//       配置与正式固件一致（32 声部 × 16 分音、4 层力度、PN 表、ATK 噪声、REL_RATE=143）。
//
// 运行（ASCII 镜像根目录）：
//   vlog -sv rtl/partial_engine.v tb/partial_engine_ref.v tb/tb_partial_engine_bitref.v
//   vsim -c -quiet work.tb_partial_engine_bitref -do "run -all; quit -f"
//   -> 期望 "PENG: ALL PASS(bit-exact)"；耗时较长(4096 采样)。
//=============================================================================
`timescale 1ns/1ps
module tb_partial_engine_bitref;

    localparam integer NSAMP = 4096;      // 采样个数（>=4096）
    localparam integer DIV   = 1041;      // sample_req 周期（≈48828 Hz @50MHz）

    reg clk = 1'b0;
    always #10 clk = ~clk;                // 50 MHz
    reg rst_n = 1'b0;

    reg [11:0] div = 12'd0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) div <= 12'd0;
        else if (div == DIV-1) div <= 12'd0;
        else div <= div + 12'd1;
    end
    wire sample_req = (div == DIV-1);

    // ---- 事件口
    reg               param_we    = 1'b0;
    reg [4:0]         param_voice = 5'd0;
    reg [23:0]        param_ftw   = 24'd0;
    reg               param_on    = 1'b0;
    reg [6:0]         param_vel   = 7'd96;
    reg [6:0]         param_note  = 7'd60;
    reg               pitch_we    = 1'b0;
    reg [4:0]         pitch_voice = 5'd0;
    reg [23:0]        pitch_ftw   = 24'd0;

    wire signed [23:0] aud_new, aud_ref;
    wire [5:0]  act_new, act_ref;
    wire        ovr_new, ovr_ref, full_new, full_ref;
    wire [15:0] pc_new, pc_ref;

    localparam [15:0] A_INC = 16'd10923, D_INC = 16'd20, SUS = 16'h0800, R_INC = 16'd119;

    partial_engine #(
        .VOICES(32), .PARTIALS(16), .PHASE_W(24), .OUT_W(24),
        .SINE_FILE("rtl/rom/sine_full_1024_q23.hex"),
        .RATIO_FILE("rtl/rom/harm_ratio_C4.hex"),
        .AMP_FILE("rtl/rom/harm_amp_vel_pn4_v2.hex"),
        .PHA_FILE("rtl/rom/harm_phase_C4.hex"),
        .DEC_FILE("rtl/rom/harm_decay_ctrl_slow.hex"),
        .VEL_LAYERS(4), .VEL_SHIFT(5), .OCT_TABLES(0), .Q4_TABLES(0), .PN_TABLES(1),
        .PER_NOTE_CORR(0), .CORR_FILE("rtl/rom/note_corr.hex"),
        .REL_RATE(143), .ATK_NOISE(16'd42000), .ATK_DEC(16'd8192)
    ) u_new (
        .clk(clk), .rst_n(rst_n), .sample_req(sample_req),
        .param_we(param_we), .param_voice(param_voice), .param_ftw(param_ftw),
        .param_on(param_on), .param_vel(param_vel), .param_note(param_note),
        .adsr_a_inc(A_INC), .adsr_d_inc(D_INC), .adsr_sus(SUS), .adsr_r_inc(R_INC),
        .pitch_we(pitch_we), .pitch_voice(pitch_voice), .pitch_ftw(pitch_ftw),
        .audio_out(aud_new), .active_voices(act_new), .overrun(ovr_new),
        .pass_clks(pc_new), .evt_full(full_new));

    partial_engine_ref #(
        .VOICES(32), .PARTIALS(16), .PHASE_W(24), .OUT_W(24),
        .SINE_FILE("rtl/rom/sine_full_1024_q23.hex"),
        .RATIO_FILE("rtl/rom/harm_ratio_C4.hex"),
        .AMP_FILE("rtl/rom/harm_amp_vel_pn4_v2.hex"),
        .PHA_FILE("rtl/rom/harm_phase_C4.hex"),
        .DEC_FILE("rtl/rom/harm_decay_ctrl_slow.hex"),
        .VEL_LAYERS(4), .VEL_SHIFT(5), .OCT_TABLES(0), .Q4_TABLES(0), .PN_TABLES(1),
        .PER_NOTE_CORR(0), .CORR_FILE("rtl/rom/note_corr.hex"),
        .REL_RATE(143), .ATK_NOISE(16'd42000), .ATK_DEC(16'd8192)
    ) u_ref (
        .clk(clk), .rst_n(rst_n), .sample_req(sample_req),
        .param_we(param_we), .param_voice(param_voice), .param_ftw(param_ftw),
        .param_on(param_on), .param_vel(param_vel), .param_note(param_note),
        .adsr_a_inc(A_INC), .adsr_d_inc(D_INC), .adsr_sus(SUS), .adsr_r_inc(R_INC),
        .pitch_we(pitch_we), .pitch_voice(pitch_voice), .pitch_ftw(pitch_ftw),
        .audio_out(aud_ref), .active_voices(act_ref), .overrun(ovr_ref),
        .pass_clks(pc_ref), .evt_full(full_ref));

    // ---- 比对
    //   逐拍比会看到"1 个 clk 的相位差"（本改动让 audio_out 在窗口内晚一拍更新，
    //   但窗口结束仍远早于下个 sample_req，采样级的值不受影响）。所以按**采样对齐**比：
    //   在每个采样周期的固定相位（div==0，即 sample_req 之后一拍、上一采样已定稿）取一次，
    //   要求逐样本完全相等。另外仍统计逐拍差异用于说明相位差的大小。
    integer mism = 0, maxd = 0, d, dclk = 0;
    integer peak = 0, ncaps = 0;
    always @(posedge clk) begin
        if (rst_n) begin
            // 逐拍（仅统计，不作为判据）
            d = aud_new - aud_ref;
            if (d < 0) d = -d;
            if (d > 0) dclk = dclk + 1;
            // 采样对齐判据
            if (div == 12'd0) begin
                ncaps = ncaps + 1;
                if (aud_new !== aud_ref) begin
                    mism = mism + 1;
                    if (mism <= 5) $display("  MISMATCH samp#%0d new=%0d ref=%0d", ncaps, aud_new, aud_ref);
                end
                if (act_new !== act_ref) begin
                    mism = mism + 1;
                    if (mism <= 5) $display("  MISMATCH samp#%0d active new=%0d ref=%0d", ncaps, act_new, act_ref);
                end
            end
            if (aud_new > peak) peak = aud_new;
            if (-aud_new > peak) peak = -aud_new;
        end
    end

    // ---- 事件激励（用一个"采样计数"做时间轴）
    integer samp = 0;
    always @(posedge clk) if (sample_req) samp <= samp + 1;

    task note_on(input [4:0] v, input [6:0] n, input [6:0] vel, input [23:0] ftw);
        begin
            @(negedge clk);
            param_we <= 1'b1; param_voice <= v; param_note <= n;
            param_on <= 1'b1; param_vel <= vel; param_ftw <= ftw;
            @(negedge clk); param_we <= 1'b0;
            repeat (4) @(negedge clk);
        end
    endtask

    task note_off(input [4:0] v, input [6:0] n);
        begin
            @(negedge clk);
            param_we <= 1'b1; param_voice <= v; param_note <= n;
            param_on <= 1'b0; param_vel <= 7'd0; param_ftw <= 24'd0;
            @(negedge clk); param_we <= 1'b0;
            repeat (4) @(negedge clk);
        end
    endtask

    integer errs = 0;
    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (50) @(posedge clk);        // F_CLR 清零 BSRAM

        wait (samp >= 10);
        note_on(5'd0, 7'd60, 7'd96,  24'h0B6F00);
        wait (samp >= 60);
        note_on(5'd1, 7'd64, 7'd127, 24'h0D9E00);
        wait (samp >= 120);
        note_on(5'd2, 7'd67, 7'd40,  24'h0FE000);
        wait (samp >= 200);
        note_off(5'd0, 7'd60);
        wait (samp >= 260);
        note_on(5'd3, 7'd72, 7'd80,  24'h150000);
        wait (samp >= 400);
        // pitch 微调（走 pitch_we 直写口）
        @(negedge clk); pitch_we <= 1'b1; pitch_voice <= 5'd1; pitch_ftw <= 24'h0DA000;
        @(negedge clk); pitch_we <= 1'b0;
        wait (samp >= 700);
        note_off(5'd2, 7'd67);
        wait (samp >= 900);
        note_on(5'd0, 7'd60, 7'd120, 24'h0B6F00);   // 同音重触发
        wait (samp >= 1500);
        note_off(5'd1, 7'd64);
        wait (samp >= 2200);
        note_off(5'd3, 7'd72);

        wait (samp >= NSAMP);
        repeat (64) @(posedge clk);

        $display("  captured samples = %0d, mismatches = %0d, 逐拍有差异的 clk 数 = %0d, peak = %0d",
                 ncaps, mism, dclk, peak);
        $display("  pass_clks: new=%0d ref=%0d | overrun: new=%0d ref=%0d",
                 pc_new, pc_ref, ovr_new, ovr_ref);

        if (ncaps < NSAMP)         begin errs = errs + 1; $display("  FAIL 采样数不足"); end
        if (mism != 0)             begin errs = errs + 1; $display("  FAIL 有 %0d 拍不同", mism); end
        if (ncaps < NSAMP)         begin errs = errs + 1; $display("  FAIL 采样对齐点数不足 (%0d)", ncaps); end
        if (peak < 1000)           begin errs = errs + 1; $display("  FAIL 输出近乎静音(peak=%0d), 可能是假绿", peak); end
        if (ovr_new !== 1'b0)      begin errs = errs + 1; $display("  FAIL 出现 overrun"); end

        if (errs == 0) $display("PENG: ALL PASS (bit-exact, %0d samples, 0 mismatch)", samp);
        else           $display("PENG: FAIL (%0d)", errs);
        $finish;
    end

    initial begin
        #900_000_000;                       // 900ms 仿真时间上限
        $display("PENG: FAIL (watchdog)");
        $finish;
    end

endmodule
