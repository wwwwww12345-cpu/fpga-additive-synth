//=============================================================================
// ack_tx.v —— 下行应答发生器（2026-10-24，协议 v0.2）
//
// 只对"结果对用户有意义"的三种命令回包，避免上一条命令回一串字节：
//   0x80 PING        → A1 80                      （连通性探测的回应）
//   0x90 曲谱开始     → 只有出错才回 A2 90 <code>   （成功不回，省带宽）
//   0x92 曲谱结束     → 成功 A1 92; 失败 A2 92 <code>
// 其余命令（0x81/0x82/0x83/0x84/0x85/0x86/0x91/0x93/未知）一律静默，
// 因为它们是幂等/即时的，回包只会把上行日志刷满。
//
// 错误码（与 ble_cmd 的 evt_code 一致）：
//   1 = 条目数不符（0x92 时 wptr != nlen）
//   2 = N 超范围（0x90 时 N>512 或 N==0）
//   3 = 不在下发期就发了 0x92
//
// 时序：evt_we 是单拍；本模块立刻把 2~3 个字节装进小缓冲，之后在 tx_ready
// 时逐字节送出。命令间隔远大于 3 字节发送时间（115200 下每字节约 87µs），
// 所以"忙时来了新应答"会丢弃——这是刻意的取舍，不做 FIFO 队列。
//=============================================================================
`timescale 1ns/1ps

module ack_tx (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        evt_we,
    input  wire [7:0]  evt_cmd,
    input  wire [3:0]  evt_code,

    input  wire        tx_ready,
    output wire [7:0]  tx_data,
    output wire        tx_valid
);
    localparam [7:0] A_ACK  = 8'hA1,
                     A_NACK = 8'hA2;

    reg [7:0]  b0, b1, b2;
    reg [1:0]  len;            // 2 或 3
    reg [1:0]  idx;
    reg        busy;

    wire is_ping = (evt_cmd == 8'h80);
    wire is_sbeg = (evt_cmd == 8'h90);
    wire is_send = (evt_cmd == 8'h92);
    wire failed  = (evt_code != 4'd0);

    assign tx_valid = busy;
    assign tx_data  = (idx == 2'd0) ? b0 :
                      (idx == 2'd1) ? b1 : b2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0;
            idx  <= 2'd0;
            len  <= 2'd2;
            b0   <= 8'd0; b1 <= 8'd0; b2 <= 8'd0;
        end else begin
            // ---- 装填 ----
            if (evt_we && !busy) begin
                if (is_ping) begin
                    b0  <= A_ACK;  b1 <= {1'b0, evt_cmd[6:0]};  len <= 2'd2;
                    idx <= 2'd0;   busy <= 1'b1;
                end else if (is_sbeg && failed) begin
                    b0  <= A_NACK; b1 <= {1'b0, evt_cmd[6:0]}; b2 <= {4'd0, evt_code}; len <= 2'd3;
                    idx <= 2'd0;   busy <= 1'b1;
                end else if (is_send) begin
                    if (failed) begin
                        b0  <= A_NACK; b1 <= {1'b0, evt_cmd[6:0]}; b2 <= {4'd0, evt_code}; len <= 2'd3;
                    end else begin
                        b0  <= A_ACK;  b1 <= {1'b0, evt_cmd[6:0]}; len <= 2'd2;
                    end
                    idx <= 2'd0; busy <= 1'b1;
                end
            end

            // ---- 逐字节送出 ----
            if (busy && tx_ready) begin
                if (idx == len - 2'd1) busy <= 1'b0;
                idx <= idx + 2'd1;
            end
        end
    end
endmodule
