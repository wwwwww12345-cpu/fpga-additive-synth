//=============================================================================
// tb_ble_cmd_proto.v — ble_cmd.v protocol parser unit test (2026-10-24)
//
// Purpose: turn the review verdicts into a reproducible experiment.
//   Key case B (P0): an ILLEGAL N is truncated into nlen; does 0x92 then
//   "certify" the illegal song as valid?
//
// Run in an ASCII-only dir (ModelSim ASE cannot handle CJK paths):
//   vlib work && vlog rtl/ble_cmd.v tb/tb_ble_cmd_proto.v
//   vsim -c work.tb_ble_cmd_proto -do "run -all; quit -f"
// Verdict: prints "=== ALL CHECK PASSED ===" or "--- FAIL --- n/m".
// NOTE: check labels are ASCII only on purpose (ModelSim console cyrillic/CJK
//       mangling); Chinese rationale lives in the comments.
//=============================================================================
`timescale 1ns/1ps

module tb_ble_cmd_proto;

    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    reg         byte_valid = 1'b0;
    reg  [7:0]  byte_data  = 8'h00;

    wire signed [7:0] range_off;
    wire [1:0]  chord_mode;
    wire        timbre;
    wire        ram_we;
    wire [8:0]  ram_waddr;
    wire [23:0] ram_wdata;
    wire        song_valid;
    wire [9:0]  song_len;
    wire        song_updating;
    wire        play_go, play_stop, play_rst;
    wire [7:0]  err_cnt, frame_cnt;

    integer fails    = 0;
    integer checks   = 0;
    integer ram_wr   = 0;     // ram_we pulse count
    integer both_cnt = 0;     // play_rst & play_stop same cycle
    integer go_cnt   = 0;
    integer stop_cnt = 0;
    integer rst_cnt  = 0;
    integer err0;

    ble_cmd dut (
        .clk(clk), .rst_n(rst_n),
        .byte_valid(byte_valid), .byte_data(byte_data),
        .range_off(range_off), .chord_mode(chord_mode), .timbre(timbre),
        .ram_we(ram_we), .ram_waddr(ram_waddr), .ram_wdata(ram_wdata),
        .song_valid(song_valid), .song_len(song_len), .song_updating(song_updating),
        .play_go(play_go), .play_stop(play_stop), .play_rst(play_rst),
        .err_cnt(err_cnt), .frame_cnt(frame_cnt)
    );

    always #10 clk = ~clk;                  // 50 MHz

    always @(posedge clk) begin
        if (ram_we)                ram_wr   <= ram_wr + 1;
        if (play_rst)              rst_cnt  <= rst_cnt + 1;
        if (play_stop)             stop_cnt <= stop_cnt + 1;
        if (play_go)               go_cnt   <= go_cnt + 1;
        if (play_rst && play_stop) both_cnt <= both_cnt + 1;
    end

    //------------------------------------------------------------ checks
    task chk(input [255:0] name, input integer got, input integer exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                fails = fails + 1;
                $display("  FAIL %0s : got=%0d exp=%0d", name, got, exp);
            end else begin
                $display("  ok   %0s : %0d", name, got);
            end
        end
    endtask

    task reset_dut;
        begin
            @(negedge clk); rst_n = 1'b0;
            repeat (3) @(negedge clk);
            rst_n = 1'b1;
            repeat (3) @(negedge clk);
            ram_wr = 0; both_cnt = 0; go_cnt = 0; stop_cnt = 0; rst_cnt = 0;
        end
    endtask

    // One byte: valid high for exactly one clock, then settle long enough for
    // the registered exec stage AND the pulse counters ($display reads them).
    task send(input [7:0] b);
        begin
            @(negedge clk); byte_valid = 1'b1; byte_data = b;
            @(negedge clk); byte_valid = 1'b0; byte_data = 8'h00;
            repeat (4) @(negedge clk);
        end
    endtask

    //------------------------------------------------------------ main
    integer i;

    initial begin : main

        //===== A. legal song N=2 : harness self-check (must be green)
        $display("\n[A] legal song N=2");
        reset_dut;
        send(8'h90); send(8'h02); send(8'h00);
        chk("A updating after 0x90", song_updating, 1);
        chk("A valid before 0x92",   song_valid,    0);
        send(8'h91); send(8'h3C); send(8'h60); send(8'h32);
        send(8'h91); send(8'h3C); send(8'h60); send(8'h32);
        chk("A ram writes", ram_wr, 2);
        send(8'h92);
        chk("A song_valid", song_valid, 1);
        chk("A song_len",   song_len,   2);
        chk("A err_cnt",    err_cnt,    0);

        //===== B. P0: illegal N=1025 -> nlen truncated to 1 -> does 0x92 certify it?
        $display("\n[B] P0: illegal N=1025 (d1=8, d0=1)");
        reset_dut;
        send(8'h90); send(8'h01); send(8'h08);
        $display("  after 0x90: song_valid=%0d err_cnt=%0d updating=%0d",
                 song_valid, err_cnt, song_updating);
        chk("B rejected -> song_valid", song_valid, 0);
        chk("B rejected -> err_cnt",    err_cnt,    1);
        err0 = err_cnt;
        send(8'h91); send(8'h3C); send(8'h60); send(8'h32);
        // Observation only: broken RTL writes 1 polluted entry here; fixed RTL
        // rejects it. Both are acceptable -- the semantic assertion is below.
        $display("  observed ram writes for stray 0x91 = %0d", ram_wr);
        send(8'h92);
        $display("  after 0x92: song_valid=%0d song_len=%0d err_cnt=%0d",
                 song_valid, song_len, err_cnt);
        chk("B 0x92 must NOT revive illegal song", song_valid, 0);
        // err_cnt after 0x92: broken RTL keeps 1 (it thought it succeeded);
        // fixed RTL reports 3 (0x90 + 0x91 + 0x92 all rejected). Observation only.
        $display("  observed err_cnt after 0x92 = %0d (broken=1, fixed=3)", err_cnt);

        //===== B2. contrast: illegal N=513 -> nlen=513, cannot be reached
        $display("\n[B2] contrast: illegal N=513 (d1=4, d0=1)");
        reset_dut;
        send(8'h90); send(8'h01); send(8'h04);
        chk("B2 rejected -> err_cnt", err_cnt, 1);
        send(8'h92);
        chk("B2 stays invalid", song_valid, 0);

        //===== C. count mismatch: N=2 but only 1 entry
        $display("\n[C] count mismatch: N=2 but 1 entry");
        reset_dut;
        send(8'h90); send(8'h02); send(8'h00);
        send(8'h91); send(8'h3C); send(8'h60); send(8'h32);
        send(8'h92);
        chk("C song_valid", song_valid, 0);
        chk("C err_cnt",    err_cnt,    1);

        //===== D. stray 0x91 / 0x92 without 0x90
        $display("\n[D] stray 0x91 / 0x92 without 0x90");
        reset_dut;
        send(8'h91); send(8'h3C); send(8'h60); send(8'h32);
        chk("D stray 0x91 -> no ram write", ram_wr,  0);
        chk("D stray 0x91 -> err_cnt",      err_cnt, 1);
        send(8'h92);
        chk("D stray 0x92 -> song_valid", song_valid, 0);

        //===== E. single-byte commands
        $display("\n[E] single-byte commands");
        reset_dut;
        send(8'h81); send(8'h4C);
        chk("E range_off +12", range_off, 12);
        send(8'h81); send(8'h00);
        chk("E range_off -64", range_off, -64);
        send(8'h83);
        chk("E range reset", range_off, 0);
        send(8'h82); send(8'h02);
        chk("E chord minor", chord_mode, 2);
        send(8'h82); send(8'h05);
        chk("E illegal chord -> 0",       chord_mode, 0);
        chk("E illegal chord -> err_cnt", err_cnt,    1);
        send(8'h86); send(8'h01);
        chk("E timbre=1", timbre, 1);
        send(8'h86); send(8'h00);
        chk("E timbre=0", timbre, 0);
        send(8'h86); send(8'h7F);
        chk("E timbre=127 -> 1", timbre, 1);

        //===== F. play pulses
        $display("\n[F] play pulses");
        reset_dut;
        send(8'h84);
        chk("F play_go pulses", go_cnt, 1);
        send(8'h85);
        chk("F play_stop pulses", stop_cnt, 1);
        chk("F play_rst untouched", rst_cnt, 0);
        send(8'h93);
        chk("F 0x93 play_rst", rst_cnt, 1);
        chk("F 0x93 rst+stop same cycle", both_cnt, 1);

        //===== G. PING / unknown command
        $display("\n[G] PING & unknown");
        reset_dut;
        err0 = err_cnt;
        send(8'h80);
        chk("G PING changes nothing", {timbre, chord_mode, range_off[7:0]}, 0);
        chk("G PING no error", err_cnt, err0);
        // 0xA1 0x92 are both bit7=1 -> two independent unknown 0-data frames
        // -> err_cnt += 2 (this is exactly why a phase-2 ACK cannot be parsed today)
        send(8'hA1); send(8'h92);
        chk("G 0xA1 + 0x92 -> err_cnt +2", err_cnt, err0 + 2);

        //===== H. N=512 upper boundary (documented max, 9-bit RAM address limit)
        $display("\n[H] N=512 upper boundary");
        reset_dut;
        send(8'h90); send(8'h00); send(8'h04);          // N = 4*128 + 0 = 512
        for (i = 0; i < 512; i = i + 1)
            begin send(8'h91); send(8'h30); send(8'h40); send(8'h10); end
        chk("H ram writes", ram_wr, 512);
        send(8'h92);
        chk("H song_valid", song_valid, 1);
        chk("H song_len",   song_len,   512);

        //===== verdict
        $display("\n----------------------------------------");
        if (fails == 0) $display("=== ALL CHECK PASSED === (%0d checks)", checks);
        else            $display("--- FAIL --- %0d/%0d checks failed", fails, checks);
        $display("----------------------------------------\n");
        $finish;
    end
endmodule
