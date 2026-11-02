// gtr_demo.v -- 吉他自动演示：每 10 s 扫一次（默认 C4-E4-G4-B3），无需任何输入，上电就响
//   50 MHz: PERIOD = 500_000_000 (10 s)，扫弦间隔 30 ms (1_500_000)
//   2026-10-22: 音符与个数提为参数（默认值 = 原行为，逐位不变），
//   以便编"单音判定"固件（NNOTES=1，只弹 N1）来区分"引擎抖"与"和弦拍频"。
module gtr_demo #(
    parameter PERIOD = 500_000_000,
    parameter STEP   = 1_500_000,
    parameter [6:0] N1 = 7'd60,     // C4
    parameter [6:0] N2 = 7'd64,     // E4
    parameter [6:0] N3 = 7'd67,     // G4
    parameter [6:0] N4 = 7'd59,     // B3
    parameter       NNOTES = 4      // 1 = 只弹 N1（单音判定版），2..4 = 依次弹前几个
)(
    input  wire       clk,
    input  wire       rst_n,
    output reg        we,
    output reg  [6:0] note
);
    reg [28:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= 0; we <= 0; note <= N1;
        end else begin
            we <= 1'b0;
            cnt <= (cnt == PERIOD - 1) ? 29'd0 : (cnt + 1'b1);
            if (cnt == 29'd0) begin we <= 1'b1; note <= N1; end
            else if ((NNOTES >= 2) && (cnt == STEP[28:0])) begin we <= 1'b1; note <= N2; end
            else if ((NNOTES >= 3) && (cnt == (STEP * 2))) begin we <= 1'b1; note <= N3; end
            else if ((NNOTES >= 4) && (cnt == (STEP * 3))) begin we <= 1'b1; note <= N4; end
        end
    end
endmodule
