`timescale 1ns/1ps
// guide_ctrl 单元测试：黄→绿→下一音 / 按错红→黄 / 休止跳过 / 停止
module tb_guide;
    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    reg start = 0, stop = 0, song_valid = 1;
    reg [9:0] song_len = 10'd4;
    wire [8:0] raddr;
    reg [23:0] rdata;
    reg key_we = 0, key_on = 0;
    reg [6:0] key_note = 0;
    wire active, in_range;
    wire [6:0] target;
    wire [1:0] state;
    wire [9:0] ptr;

    // 简易 song_ram 模型：60, 62, 休止, 64
    reg [23:0] mem [0:511];
    always @(posedge clk) rdata <= mem[raddr];

    initial begin
        mem[0] = {7'd60, 7'd96, 7'd10, 2'b00};
        mem[1] = {7'd62, 7'd96, 7'd10, 2'b00};
        mem[2] = {7'd0,  7'd96, 7'd10, 2'b00};
        mem[3] = {7'd64, 7'd96, 7'd10, 2'b00};
    end

    guide_ctrl #(.RED_CLKS(5), .BASE_NOTE(7'd60), .NPIX(24)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .stop(stop),
        .song_valid(song_valid), .song_len(song_len),
        .raddr(raddr), .rdata(rdata),
        .key_we(key_we), .key_note(key_note), .key_on(key_on),
        .active(active), .target_note(target), .state(state), .ptr(ptr),
        .target_in_range(in_range)
    );

    task press(input [6:0] n);
        begin
            @(negedge clk); key_note = n; key_on = 1; key_we = 1;
            @(negedge clk); key_we = 0;
        end
    endtask
    task lift(input [6:0] n);
        begin
            @(negedge clk); key_note = n; key_on = 0; key_we = 1;
            @(negedge clk); key_we = 0;
        end
    endtask

    integer errors = 0;
    task chk(input cond, input [255:0] msg);
        begin
            if (!cond) begin errors = errors + 1; $display("FAIL: %0s", msg); end
            else $display("ok: %0s", msg);
        end
    endtask

    initial begin
        #100 rst_n = 1;
        #100;
        start <= 1; #20 start <= 0;
        #100;
        chk(active === 1'b1, "active after start");
        chk(target == 7'd60, "target=60 yellow");
        chk(state == 2'd0, "state yellow");

        // 按错 61 -> 红
        press(7'd61);
        #100;
        chk(state == 2'd2, "wrong key -> red");
        #200;                       // RED_CLKS=5, 100ns 足够
        chk(state == 2'd0, "red back to yellow");

        // 按对 60 -> 绿
        press(7'd60);
        #100;
        chk(state == 2'd1, "correct -> green");
        lift(7'd60);
        #200;
        chk(target == 7'd62, "next target=62 after release");
        chk(state == 2'd0, "yellow for next");

        // 按对 62 -> 松开 -> 应跳过休止到 64
        press(7'd62); #100; lift(7'd62); #300;
        chk(target == 7'd64, "rest skipped, target=64");

        // 结束
        press(7'd64); #100; lift(7'd64); #300;
        chk(active === 1'b0, "done after last note");

        // stop 复位
        start <= 1; #20 start <= 0; #100;
        stop <= 1; #20 stop <= 0; #100;
        chk(active === 1'b0, "stop clears active");

        $display(errors == 0 ? "ALL PASS" : "ERRORS=%0d", errors);
        $stop;
    end
endmodule
