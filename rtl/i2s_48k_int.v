//=============================================================================
// i2s_48k_int.v —— 与 i2s_48k.v 功能完全相同, 但 BCLK 用**整数分频**(无抖动)
//
// 动机(2026-10-14 A/B 判决后):
//   听感规律 = "干净 ⟺ 音的周期样点数 N 能被 3 整除"。3 正是小数分频抖动图样的周期:
//     BCLK_INC/2^32 = 527765581/2^32 ≈ 0.12288 = 384/3125
//     -> 每 3125 个 clk 恰好 384 次翻转 -> 每 3 个样点(3×1041.667clk=3125clk)完全重复
//   本模块改用固定 8 分频(半周期 8 clk): BCLK = 50MHz/16 = 3.125MHz **逐周期精确**,
//   LRCK = 3.125MHz/64 = 48828.125Hz **逐周期精确**, 抖动图样不存在。
//
// 代价: 采样率变成 48828.125Hz (= 50MHz/1024, 比 48k 高 1.725% = +29.6 音分)。
//   本模块只用于判决实验; 若要正式用, FTW 需按 48000/48828.125 重算(表乘 3072/3125)。
//
// 帧结构/严格 I2S/数据延迟/引脚语义与 i2s_48k.v 逐位一致。
//=============================================================================
`timescale 1ns/1ps

module i2s_48k_int #(
    parameter integer DIV = 8          // BCLK 半周期 = DIV 个 clk (8 -> BCLK 3.125MHz)
)(
    input [23:0] audio_l, input [23:0] audio_r,
    input clk, input rst_n,
    output reg bclk, output reg lrck, output wire sdata,
    output reg sample_req
);
    reg [3:0] hc;                      // 半周期计数 0..DIV-1
    reg [5:0] bclk_cnt;                // 0..63, 每帧 64 个 BCLK 翻转
    reg [23:0] shift, right_buf;
    reg        sdata_raw, sdata_d;

    wire bclk_fall = (hc == DIV[3:0] - 4'd1) && bclk;

    assign sdata = sdata_d;            // I2S_DELAY = 1

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hc   <= 4'd0;
            bclk <= 1'b0;
        end else begin
            if (hc == DIV[3:0] - 4'd1) begin
                hc   <= 4'd0;
                bclk <= ~bclk;
            end else hc <= hc + 4'd1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bclk_cnt   <= 6'd0;
            shift      <= 24'd0;
            right_buf  <= 24'd0;
            lrck       <= 1'b0;
            sdata_raw  <= 1'b0;
            sample_req <= 1'b0;
        end else begin
            sample_req <= 1'b0;
            if (bclk_fall) begin
                bclk_cnt <= bclk_cnt + 6'd1;
                case (bclk_cnt)
                    6'd63: begin
                        lrck       <= 1'b0;
                        right_buf  <= audio_r;
                        shift      <= {audio_l[22:0], 1'b0};   // 与 i2s_48k.v 相同(已复原)
                        sdata_raw  <= audio_l[23];
                        sample_req <= 1'b1;
                    end
                    6'd31: begin
                        lrck      <= 1'b1;
                        shift     <= {right_buf[22:0], 1'b0};
                        sdata_raw <= right_buf[23];
                    end
                    default: begin
                        shift     <= {shift[22:0], 1'b0};
                        sdata_raw <= shift[23];
                    end
                endcase
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sdata_d <= 1'b0;
        else if (bclk_fall) sdata_d <= sdata_raw;
    end

endmodule
