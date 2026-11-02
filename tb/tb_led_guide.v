//=============================================================================
// tb_led_guide.v —— led_guide 单元测试（2026-10-24）
// 覆盖: 单音点亮/熄灭、多音共存、低音钳位、高音钳位、active 标志、复位。
// 运行(ASCII 目录): vlib work; vlog rtl/led_guide.v tb/tb_led_guide.v;
//                   vsim -c work.tb_led_guide -do "run -all; quit -f"
//=============================================================================
`timescale 1ns/1ps

module tb_led_guide;
    reg        clk = 1'b0;
    reg        rst_n = 1'b0;
    reg        ev_we = 1'b0;
    reg  [6:0] ev_note = 7'd0;
    reg        ev_on = 1'b0;
    wire [31:0] mask;
    wire        active;

    integer fails = 0, checks = 0;

    always #10 clk = ~clk;                     // 50 MHz

    led_guide #(.BASE_NOTE(7'd60), .NPIX(24)) dut (
        .clk(clk), .rst_n(rst_n),
        .ev_we(ev_we), .ev_note(ev_note), .ev_on(ev_on),
        .mask(mask), .active(active));

    task ev(input [6:0] n, input on);
        begin
            @(negedge clk); ev_we = 1'b1; ev_note = n; ev_on = on;
            @(negedge clk); ev_we = 1'b0;
            @(negedge clk);
        end
    endtask

    task chk(input [255:0] name, input [31:0] got, input [31:0] exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                fails = fails + 1;
                $display("  FAIL %0s : got=%08h exp=%08h", name, got, exp);
            end else begin
                $display("  ok   %0s : %08h", name, got);
            end
        end
    endtask

    initial begin
        $display("=== tb_led_guide ===");
        repeat (4) @(posedge clk);
        rst_n = 1; @(posedge clk);

        chk("reset mask", mask, 32'h0);

        ev(7'd60, 1'b1);   chk("C4 on  -> bit0",  mask, 32'h0000_0001);
        chk("active = 1",  {31'd0, active}, 32'd1);
        ev(7'd60, 1'b0);   chk("C4 off -> 0",     mask, 32'h0000_0000);
        chk("active = 0",  {31'd0, active}, 32'd0);

        ev(7'd67, 1'b1);   chk("G4 on  -> bit7",  mask, 32'h0000_0080);
        ev(7'd71, 1'b1);   chk("B4 on  -> bit11", mask, 32'h0000_0880);
        ev(7'd64, 1'b1);   chk("E4 on  -> bit4",  mask, 32'h0000_0890);

        ev(7'd67, 1'b0);   chk("G4 off keeps rest", mask, 32'h0000_0810);
        ev(7'd64, 1'b0);
        ev(7'd71, 1'b0);   chk("all off",         mask, 32'h0000_0000);

        ev(7'd36, 1'b1);   chk("C2 -> clamp bit0", mask, 32'h0000_0001);
        ev(7'd36, 1'b0);
        ev(7'd96, 1'b1);   chk("C7 -> clamp bit23", mask, 32'h0080_0000);
        ev(7'd96, 1'b0);
        chk("final 0", mask, 32'h0000_0000);

        $display("----------------------------------------");
        if (fails == 0) $display("=== ALL CHECK PASSED === (%0d checks)", checks);
        else            $display("--- FAIL --- %0d/%0d", fails, checks);
        $display("----------------------------------------");
        $finish;
    end
endmodule
