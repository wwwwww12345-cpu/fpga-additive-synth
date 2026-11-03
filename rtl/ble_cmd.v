//=============================================================================
// ble_cmd.v —— 小程序二进制协议 v0 解析器（0x80~0x93）
//
// 帧格式: 1 命令字节(bit7=1) + 0~3 数据字节(bit7=0)
// 重新同步: 收数据期间遇到 bit7=1 → 上一帧作废, 以新命令字节重新开始
//           空闲态收到 bit7=0 → 丢弃(游离数据, 正是 ASCII "60+/-" 走的路)
//
// 输出:
//   range_off  : 音域偏移 -64..+63 (0x81/0x83)
//   chord_mode : 和弦 0=关 1=大三 2=小三 3=属七 (0x82)
//   曲谱写口   : 0x90/0x91/0x92 → song_ram (512 × 24bit = {note,vel,dur})
//   演奏脉冲   : play_go(0x84) / play_stop(0x85) / play_rst(0x93)
//
// 协议文档: 采样音色/docs/PROTOCOL.md ; 小程序侧唯一定义处 utils/protocol.js
//=============================================================================
`timescale 1ns/1ps

module ble_cmd (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        byte_valid,       // 单拍: 本拍 byte_data 有效(已与 uart_rx 握手)
    input  wire [7:0]  byte_data,

    output reg  signed [7:0] range_off,  // 半音, -64..+63
    output reg  [1:0]  chord_mode,       // 0=关 1=大三 2=小三 3=属七
    output reg         timbre,           // 0=钢琴 1=吉他 (0x86, 2026-10-21)
    output reg  [6:0]  rvb_mix,          // 混响湿度 0..127 (0x89, 2026-11-02), 复位 32
    output reg  [6:0]  glide_amt,        // 滑音量 0..127 (0x8B, 2026-11-02), 复位 0=关

    // 曲谱 RAM 写口
    output reg         ram_we,
    output reg  [8:0]  ram_waddr,
    output reg  [23:0] ram_wdata,        // {note[6:0], vel[6:0], dur[6:0], 2'b00}

    // 曲谱状态
    output reg         song_valid,       // 0x92 计数校验通过 → 1
    output reg  [9:0]  song_len,         // N (1..512)
    output wire        song_updating,    // 0x90..0x92 之间为 1

    // 演奏控制(单拍脉冲)
    output reg         play_go,
    output reg         play_stop,
    output reg         play_rst,

    // 指引弹奏(单拍脉冲, 2026-11-03)
    output reg         guide_start,      // 0x94: 用已下发曲谱开始灯带指引
    output reg         guide_stop,       // 0x95: 退出指引

    // 诊断
    output reg  [7:0]  err_cnt,          // 未知命令/计数不符/溢出/超 N 写入
    output reg  [7:0]  frame_cnt,        // 完整帧(含零数据帧)计数

    // 下行应答事件(2026-10-24): 每条真正执行完的命令给一拍, 供 ack_tx 组 A1/A2
    output reg         note_we,           // 单音事件(0x87/0x88), 单拍
    output reg         note_on,
    output reg  [6:0]  note_note,
    output reg  [6:0]  note_vel,
    output reg         evt_we,
    output reg  [7:0]  evt_cmd,
    output reg  [3:0]  evt_code          // 0=成功 1=条目数不符 2=N超范围 3=不在下发期
);
    //---------------------------------------------------------- 常量
    localparam C_PING  = 8'h80,
               C_RANGE = 8'h81,
               C_CHORD = 8'h82,
               C_RRST  = 8'h83,
               C_PLAY  = 8'h84,
               C_STOP  = 8'h85,
               C_TMBR  = 8'h86,
               C_VERB  = 8'h89,     // 混响湿度 0..127 (2026-11-02)
               C_GLID  = 8'h8B,     // 滑音量 0..127 (2026-11-02)
               C_SBEG  = 8'h90,
               C_SENT  = 8'h91,
               C_SEND  = 8'h92,
               C_SRST  = 8'h93,
               C_GSTR  = 8'h94,     // 指引弹奏开始 (2026-11-03)
               C_GSTP  = 8'h95,     // 指引弹奏停止 (2026-11-03)
               C_NON   = 8'h87,     // 单音按下: note, vel
               C_NOFF  = 8'h88;     // 单音松开: note

    localparam S_IDLE = 1'b0,
               S_DATA = 1'b1;

    //---------------------------------------------------------- 内部
    reg        st;
    reg [7:0]  cmd;
    reg [1:0]  need, got;
    reg [6:0]  d0, d1, d2;
    reg        exec_pend;

    reg [9:0]  wptr;                     // 已写入条数
    reg [9:0]  nlen;                     // 本曲目标条数 N
    reg        updating;

    assign song_updating = updating;

    // 命令 → 数据字节数
    function [1:0] datalen;
        input [7:0] c;
        begin
            case (c)
                C_RANGE, C_CHORD, C_TMBR, C_NOFF, C_VERB, C_GLID : datalen = 2'd1;
                C_NON            : datalen = 2'd2;
                C_SBEG           : datalen = 2'd2;
                C_SENT           : datalen = 2'd3;
                default          : datalen = 2'd0;
            endcase
        end
    endfunction

    //---------------------------------------------------------- 主状态机
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            cmd       <= 8'd0;
            need      <= 2'd0;
            got       <= 2'd0;
            d0        <= 7'd0; d1 <= 7'd0; d2 <= 7'd0;
            exec_pend <= 1'b0;
            wptr      <= 10'd0;
            nlen      <= 10'd0;
            updating  <= 1'b0;
            range_off <= 8'sd0;
            chord_mode<= 2'd0;
            timbre    <= 1'b0;
            rvb_mix   <= 7'd32;   // 默认 = 现有固定 25% 湿声
            glide_amt <= 7'd0;    // 默认滑音关
            ram_we    <= 1'b0;
            ram_waddr <= 9'd0;
            ram_wdata <= 24'd0;
            song_valid<= 1'b0;
            song_len  <= 10'd0;
            play_go   <= 1'b0;
            play_stop <= 1'b0;
            play_rst  <= 1'b0;
            guide_start <= 1'b0;
            guide_stop  <= 1'b0;
            err_cnt   <= 8'd0;
            frame_cnt <= 8'd0;
            evt_we    <= 1'b0;
            note_we   <= 1'b0; note_on <= 1'b0; note_note <= 7'd0; note_vel <= 7'd0;
            evt_cmd   <= 8'd0;
            evt_code  <= 4'd0;
        end else begin
            // 默认: 脉冲与写使能只保持一拍
            play_go   <= 1'b0;
            play_stop <= 1'b0;
            play_rst  <= 1'b0;
            guide_start <= 1'b0;
            guide_stop  <= 1'b0;
            ram_we    <= 1'b0;
            evt_we    <= 1'b0;
            note_we   <= 1'b0; note_on <= 1'b0; note_note <= 7'd0; note_vel <= 7'd0;

            //------------------------------------------------ 收字节
            if (byte_valid) begin
                if (byte_data[7]) begin
                    // 命令字节: 无论当前什么状态, 都重新开始一帧
                    cmd  <= byte_data;
                    got  <= 2'd0;
                    need <= datalen(byte_data);
                    if (datalen(byte_data) == 2'd0) begin
                        exec_pend <= 1'b1;   // 零数据帧: 下一拍执行
                        st        <= S_IDLE;
                    end else begin
                        st <= S_DATA;
                    end
                end else if (st == S_DATA) begin
                    // 数据字节: 按需存入
                    if (need == 2'd1) begin
                        d0 <= byte_data[6:0];
                    end else if (need == 2'd2) begin
                        if (got == 2'd0) d0 <= byte_data[6:0];
                        else             d1 <= byte_data[6:0];
                    end else begin
                        if      (got == 2'd0) d0 <= byte_data[6:0];
                        else if (got == 2'd1) d1 <= byte_data[6:0];
                        else                  d2 <= byte_data[6:0];
                    end
                    got <= got + 2'd1;
                    if (got + 2'd1 == need) begin
                        exec_pend <= 1'b1;   // 凑满: 下一拍执行
                        st        <= S_IDLE;
                    end
                end
                // st==S_IDLE 且 bit7=0 → 游离数据, 丢弃(不计数, 保持静默)
            end

            //------------------------------------------------ 执行
            if (exec_pend) begin
                exec_pend <= 1'b0;
                frame_cnt <= frame_cnt + 8'd1;
                // 应答事件: 默认成功(code=0), 出错的分支单独覆盖
                evt_we   <= 1'b1;
                evt_cmd  <= cmd;
                evt_code <= 4'd0;
                case (cmd)
                    C_PING : ;                                  // v0: 不崩/不误触发

                    C_RANGE: range_off <= $signed({1'b0, d0}) - 8'sd64;

                    C_CHORD: begin
                        if (d0 <= 7'd3) chord_mode <= d0[1:0];
                        else begin
                            chord_mode <= 2'd0;
                            err_cnt    <= err_cnt + 8'd1;
                        end
                    end

                    C_TMBR : timbre <= (d0 != 7'd0);   // 0=钢琴, 非0=吉他

                    C_VERB : rvb_mix <= d0;            // 0x89: 混响湿度 0..127 (d0 本身 7bit)

                    C_GLID : glide_amt <= d0;          // 0x8B: 滑音量 0..127

                    C_RRST : range_off <= 8'sd0;

                    C_NON  : begin                               // 0x87 单音按下
                        note_we   <= 1'b1;
                        note_on   <= (d1 != 7'd0);
                        note_note <= d0;
                        note_vel  <= (d1 > 7'd127) ? 7'd127 : d1;
                    end

                    C_NOFF : begin                               // 0x88 单音松开
                        note_we   <= 1'b1;
                        note_on   <= 1'b0;
                        note_note <= d0;
                        note_vel  <= 7'd0;
                    end

                    C_PLAY : play_go   <= 1'b1;                 // player 自己判 song_valid

                    C_STOP : play_stop <= 1'b1;

                    // 指引弹奏: 需要已下发并通过校验的曲谱(0x92 之后 song_valid=1)
                    C_GSTR : begin
                        if (song_valid) begin
                            guide_start <= 1'b1;
                        end else begin
                            evt_code <= 4'd4;                   // NACK: 未下发曲谱 / 曲谱无效
                            err_cnt  <= err_cnt + 8'd1;
                        end
                    end

                    C_GSTP : guide_stop <= 1'b1;

                    C_SBEG : begin
                        // N = d0 | (d1<<7), 上限 512; 期间禁止演奏, 曲谱暂不可用
                        nlen      <= {d1[2:0], d0[6:0]} ;
                        if ({d1[6:0], d0[6:0]} > 14'd512 || {d1[6:0], d0[6:0]} == 14'd0) begin
                            err_cnt   <= err_cnt + 8'd1;
                            song_valid<= 1'b0;
                            nlen      <= 10'd0;       // 2026-10-24 非法 N 不得被 0x92 洗白(见 docs/小程序协议复核_20261024.md)
                            evt_code  <= 4'd2;        // NACK: N 超范围
                        end else begin
                            song_valid<= 1'b0;                  // 0x92 校验通过前不可用
                        end
                        updating  <= 1'b1;
                        wptr      <= 10'd0;
                        play_stop <= 1'b1;                      // 防播放半截曲谱
                    end

                    C_SENT : begin
                        if (updating && wptr < nlen && wptr < 10'd512) begin
                            ram_we    <= 1'b1;
                            ram_waddr <= wptr[8:0];
                            ram_wdata <= {d0, d1, d2, 2'b00};
                            wptr      <= wptr + 10'd1;
                        end else begin
                            err_cnt <= err_cnt + 8'd1;          // 超 N / 超 512 / 非下发期: 丢弃
                        end
                    end

                    C_SEND : begin
                        updating <= 1'b0;
                        if (updating && wptr == nlen && nlen != 10'd0) begin
                            song_valid <= 1'b1;
                            song_len   <= nlen;
                        end else begin
                            song_valid <= 1'b0;                 // 计数不符 → 整曲丢弃
                            err_cnt    <= err_cnt + 8'd1;
                            // NACK: 不在下发期(3) / 条目数不符(1)
                            evt_code   <= updating ? 4'd1 : 4'd3;
                        end
                    end

                    C_SRST : begin
                        play_rst  <= 1'b1;
                        play_stop <= 1'b1;
                    end

                    default: err_cnt <= err_cnt + 8'd1;        // 未知命令
                endcase
            end
        end
    end
endmodule
