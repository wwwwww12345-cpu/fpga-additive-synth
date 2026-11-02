//=============================================================================
// tb_gtr_body_lead_bitref.v —— 吉他琴体"逐位不变"验收 (2026-11-01)
//
// 目的：把 rtl/gtr_body_lead.v（共享 1 个 16x24 乘法器的新版）
//      与 tb/gtr_body_lead_v29_ref.v（2026-10-30 冻结的参考模型 = 5 条并排乘法）
//      喂**同一串** in_sample / sample_req，逐样本比较 out_sample。
//
// 判据（硬）：max|diff| == 0 且 mismatch == 0（不是"误差很小"，是逐位相同）。
// 激励：前 12 个样本是边界值（0 / ±满幅 / ±1 / ±16384 / ±30000），之后是 16bit LFSR 随机。
// 节奏：sample_req 每 1024 拍一次（与真实 48828Hz 采样间隔同量级），共 NSAMP 个样本。
//
// 运行（在 ASCII 镜像根目录，如 D:\bfsv_sim）：
//   vlog -sv rtl/gtr_body_lead.v tb/gtr_body_lead_v29_ref.v tb/tb_gtr_body_lead_bitref.v
//   vsim -c -quiet work.tb_gtr_body_lead_bitref -do "run -all; quit -f"
//   -> 期望末行 "GTRBODY: ALL PASS"
//=============================================================================
`timescale 1ns/1ps
module tb_gtr_body_lead_bitref;

    localparam integer NSAMP = 2048;        // 样本数（每样本 1024 拍）

    reg clk = 1'b0;
    always #10 clk = ~clk;                  // 50 MHz

    reg rst_n = 1'b0;
    reg sample_req = 1'b0;

    reg [15:0] lfsr = 16'hACE1;
    reg [3:0]  beat = 4'd0;

    function signed [15:0] edgeval(input [3:0] i);
        begin
            case (i)
                4'd0:  edgeval = 16'sd0;
                4'd1:  edgeval = 16'sd32767;
                4'd2:  edgeval = -16'sd32768;
                4'd3:  edgeval = 16'sd1;
                4'd4:  edgeval = -16'sd1;
                4'd5:  edgeval = 16'sd16384;
                4'd6:  edgeval = -16'sd16384;
                4'd7:  edgeval = 16'sd12345;
                4'd8:  edgeval = -16'sd23456;
                4'd9:  edgeval = 16'sd0;
                4'd10: edgeval = 16'sd30000;
                default: edgeval = -16'sd30000;
            endcase
        end
    endfunction

    wire signed [15:0] in_sample = (beat < 4'd12) ? edgeval(beat) : $signed(lfsr);

    // ---- 采样节拍：每 1024 拍一个 1 拍宽的 sample_req
    reg [10:0] sr_cnt = 11'd0;
    integer    nsent  = 0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_req <= 1'b0; sr_cnt <= 11'd0; lfsr <= 16'hACE1; beat <= 4'd0;
        end else begin
            sample_req <= 1'b0;
            if (sr_cnt == 11'd1023) begin
                sr_cnt     <= 11'd0;
                sample_req <= 1'b1;
                nsent      <= nsent + 1;
                if (beat < 4'd12) beat <= beat + 4'd1;
                lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            end else sr_cnt <= sr_cnt + 11'd1;
        end
    end

    // ---- DUT（新版）与 REF（冻结的 v30 参考）
    wire signed [15:0] out_dut, out_ref;

    gtr_body_lead u_dut (
        .clk(clk), .rst_n(rst_n), .sample_req(sample_req),
        .in_sample(in_sample), .out_sample(out_dut));

    gtr_body_lead_ref u_ref (
        .clk(clk), .rst_n(rst_n), .sample_req(sample_req),
        .in_sample(in_sample), .out_sample(out_ref));

    // ---- 逐拍比对
    integer mism = 0;
    integer maxd = 0;
    integer d;
    always @(posedge clk) begin
        if (rst_n) begin
            d = out_dut - out_ref;              // 16bit 有符号 -> integer
            if (d < 0) d = -d;
            if (d > maxd) maxd = d;
            if (out_dut !== out_ref) begin
                mism = mism + 1;
                if (mism <= 5)
                    $display("  MISMATCH t=%0t dut=%0d ref=%0d", $time, out_dut, out_ref);
            end
        end
    end

    integer errs = 0;
    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        // 等 NSAMP+2 个采样节拍（多给 2 个让最后几个样本走完 st7）
        wait (nsent >= NSAMP + 2);
        repeat (64) @(posedge clk);

        $display("  samples sent = %0d, mismatches = %0d, max|diff| = %0d", nsent, mism, maxd);

        if (nsent < NSAMP) begin
            errs = errs + 1; $display("  FAIL 样本数不足 (%0d)", nsent);
        end
        if (mism != 0) begin
            errs = errs + 1; $display("  FAIL 有 %0d 拍输出不同（要求 0）", mism);
        end
        if (maxd != 0) begin
            errs = errs + 1; $display("  FAIL max|diff| = %0d（要求 0）", maxd);
        end
        // 顺带确认不是"两边都是常数 0"的假绿
        if (maxd == 0 && mism == 0 && out_ref === 16'sd0 && nsent > 100) begin
            $display("  note: 参考输出当前为 0（末样本静音），仅代表末拍相同");
        end

        if (errs == 0) $display("GTRBODY: ALL PASS (bit-exact, %0d samples)", nsent);
        else           $display("GTRBODY: FAIL (%0d)", errs);
        $finish;
    end

    // 看门狗
    initial begin
        #200_000_000;                       // 200ms 仿真时间上限
        $display("GTRBODY: FAIL (watchdog)");
        $finish;
    end

endmodule
