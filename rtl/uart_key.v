//=============================================================================
// uart_key.v —— UART/蓝牙 -> 键事件桥 (handoff P0-3 / P1-9 落点)
//
// 复用根目录现成的 UART_Receiver.v（8N1, 50MHz/115200, 已拷入 rtl/）收字节,
// 按 ASCII 行协议解码成 note_ctrl 的键事件:
//   '0'..'9'  累积音号（>24 再进位直接标记 0xFF 无效, 触发时丢弃）
//   '+'       音号开: key_on=1, vel=VEL
//   '-'       音号关: key_on=0
//   其他      （\n / 字母 / 空白等）累积复位, 不产生事件
//             —— 小程序 ble.write() 每条自动补 \n; 原小车按键 F/B/S/L/R/H/1/2/3
//             全部被无害忽略。注意 '\n' 千万不能当触发符, 否则 "60+" 会立刻断音。
//   示例: 发 "60+" -> C4 发音; 发 "60-" -> C4 停止
//
// 背压契约: key_ready=0 时事件挂起不发（handoff 坑: 不看 ready 会丢事件,
// drop_cnt 会涨）。挂起期间新触发丢弃（保 FIFO 序）; 115200 字节率 ~11.5KB/s,
// note_ctrl 每样本(20.8us)至少消化 1 事件, 挂起实际不可能发生。
//
// 踩坑对照: 乘积上下文截断（handoff 坑16）——acc*10 用 16bit 线网 acc_next
// 显式开宽, 不在 8bit LHS 上下文里直接乘。
//=============================================================================
`timescale 1ns/1ps

module uart_key #(
    parameter VEL = 7'd96
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,          // HC-04 TX / 板载调试器 USB 串口 -> FPGA
    input  wire       key_ready,   // note_ctrl 键 FIFO 背压
    output reg        key_we,      // 1 拍有效
    output reg  [6:0] key_note,    // MIDI 音号
    output reg        key_on,      // 1=按下 0=抬起
    output reg  [6:0] key_vel
);

    //---------------------------------------------------------------- UART 收件
    wire       rx_done;
    wire [7:0] rx_data;
    UART_Receiver u_rx (
        .rx(rx), .clk(clk), .rst_n(rst_n),
        .receive_data(rx_data), .rx_done(rx_done));

    //---------------------------------------------------------------- 解码
    reg [7:0] acc;                 // 音号累积; 8'hFF = 已溢出无效
    reg       pend;                // 事件挂起中
    reg [6:0] pend_note;
    reg       pend_on;

    // 16bit 开宽中间量, 避开乘积截断坑; 仅在 acc<=24 时取低 8 位（<=249 不溢出）
    wire [15:0] acc_next = acc * 16'd10 + (rx_data - 8'h30);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc <= 8'd0; pend <= 1'b0; pend_note <= 7'd0; pend_on <= 1'b0;
            key_we <= 1'b0; key_note <= 7'd0; key_on <= 1'b0; key_vel <= 7'd0;
        end else begin
            key_we <= 1'b0;

            // 1) 发射挂起事件（受背压）
            if (pend && key_ready) begin
                key_we   <= 1'b1;
                key_note <= pend_note;
                key_on   <= pend_on;
                key_vel  <= VEL;
                pend     <= 1'b0;
            end

            // 2) 字节解码（与发射同拍时, 本块的 pend 最后写胜出 -> 新事件排队）
            if (rx_done) begin
                if (rx_data >= 8'h30 && rx_data <= 8'h39) begin
                    acc <= (acc > 8'd24) ? 8'hFF : acc_next[7:0];
                end else if (rx_data == 8'h2B) begin          // '+'
                    if (!pend && acc >= 8'd1 && acc <= 8'd127) begin
                        pend_note <= acc[6:0];
                        pend_on   <= 1'b1;
                        pend      <= 1'b1;
                    end
                    acc <= 8'd0;
                end else if (rx_data == 8'h2D) begin          // '-'
                    if (!pend && acc >= 8'd1 && acc <= 8'd127) begin
                        pend_note <= acc[6:0];
                        pend_on   <= 1'b0;
                        pend      <= 1'b1;
                    end
                    acc <= 8'd0;
                end else begin                                // \n/字母/空白: 无效
                    acc <= 8'd0;
                end
            end
        end
    end

endmodule
