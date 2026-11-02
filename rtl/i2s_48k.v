//=============================================================================
// i2s_48k.v —— I2S 发送器(修正版): 让实际采样率精确等于 48.000kHz + 格式可选
//
// 采样率: 原版用 clk_cnt/16 得 BCLK=3.125MHz -> LRCK=48.828kHz(+29.6音分)。
//   修正: 32bit 相位累加器做小数分频, 期望 BCLK=48k*64=3.072MHz, 翻转率 6.144MHz
//   (16/17 拍交替, 抖动 ±20ns; LRCK/sample_req 精确 48.000kHz)
//
// !! 2026-10-13 上板判决: 本模块配的是**严格 Philips I2S**, 不是左对齐(LJ) !!
//   证据(用户盲听 probe_fmt_ab.bin, 同一固件内交替切换对齐方式):
//     段1/3 = LJ(数据与 LRCK 同沿) -> 用户听到"像噪声"、纯音不清晰
//     段2/4 = I2S(数据延后 1 个 BCLK) -> "纯音挺清晰"
//   机制: DAC 若按 I2S 在 LRCK 沿后第 2 个 BCLK 起采字, 而我们提前一位发,
//         它读到的字 = 我们的字 << 1:
//           |x| < 2^22 (-6dBFS 以下) -> 只是 +6dB 增益, 听不出失真
//           |x| >= 2^22(-6dBFS 以上) -> 符号位被挤出窗口 -> **符号翻转 + 回卷**
//         我们的探针都在 -12dBFS(躲过), 而钢琴峰值 -1dBFS -> 每个音头都被翻转回卷,
//         这就是"钢琴沙哑/颗粒"的一大来源。
//   所以默认改成 **I2S_DELAY = 1(严格 I2S)**; 置 0 可回到旧的 LJ 行为做对照。
//
// 实现: 只把**数据线**整体延后 1 个 BCLK(LRCK 不动) —— 两种格式的差别正在于此。
//   24bit 数据落在时隙 #2..#25, 剩余 #26..#32 全 0(8 个空位足够容纳这 1 拍延迟)。
//
// 接口与原版一致(多一个 parameter), 可直接替换。
//=============================================================================
`timescale 1ns/1ps

module i2s_48k #(
    parameter I2S_DELAY = 1        // 1 = 严格 Philips I2S(数据延后 1 BCLK, **默认/正确**)
)(                             // 0 = 左对齐 LJ(旧行为, 只在对照实验里用)
    input [23:0] audio_l, input [23:0] audio_r,
    input clk, input rst_n,
    output reg bclk, output reg lrck, output wire sdata,
    output reg sample_req
);
    // BCLK 翻转率 = 2 × 48000 × 64 = 6.144MHz
    localparam [31:0] BCLK_INC = 32'd527765581;   // round(2^32 × 6.144e6 / 50e6)

    reg [32:0] bclk_acc;          // 33bit: 最高位是进位
    reg [5:0]  bclk_cnt;          // 0..63, 每帧 64 个 BCLK 翻转
    reg [23:0] shift, right_buf;
    reg        sdata_raw, sdata_d;

    wire bclk_tick = bclk_acc[32];          // 本拍是否翻转
    wire bclk_fall = bclk_tick & bclk;      // 这次翻转是从 1 到 0

    assign sdata = I2S_DELAY ? sdata_d : sdata_raw;

    //-------------------------------------------------- BCLK 小数分频
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bclk_acc <= 33'd0;
            bclk     <= 1'b0;
        end else begin
            bclk_acc <= {1'b0, bclk_acc[31:0]} + {1'b0, BCLK_INC};
            if (bclk_tick) bclk <= ~bclk;   // 平均 3.072MHz, 周期 16/17 clk 交替
        end
    end

    //-------------------------------------------------- 帧计数 + 串行输出
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bclk_cnt   <= 6'd0;
            shift      <= 24'd0;
            right_buf  <= 24'd0;
            lrck       <= 1'b0;
            sdata_raw  <= 1'b0;
            sample_req <= 1'b0;
        end else begin
            // sample_req 语义 = "上一帧已消费, 引擎可以出下一个样本"
            sample_req <= 1'b0;
            if (bclk_fall) begin
                bclk_cnt <= bclk_cnt + 6'd1;
                case (bclk_cnt)
                    6'd63: begin
                        lrck       <= 1'b0;
                        right_buf  <= audio_r;
                        // !! 2026-10-14 03:5x 撤销 02:50 的改动 (A/B 仿真判决) !!
                        // 02:50~03:5x 期间这里是 `shift <= audio_l;`, 当时的理由是
                        // "分析仪抓到的槽 = 0x555555 右移 1 位 = 串化器 bug"。
                        //   那个判读是错的: 抓到的 32 位槽 0010 1010 ... 1000 0000
                        //   = 0x2AAAAA80, 正是**严格 I2S 的正确样子** ——
                        //   首位那个 0 就是本模块有意做的 1 个 BCLK 数据延迟(I2S_DELAY)。
                        // 判决证据 (D:\piano_sim\ab\tb_i2s_ab.v, 同一 TB 同一采样沿):
                        //   改前: 左 = 0+字24位+7个0, 右 = 0+字24位+7个0   -> 左右一致 ✓
                        //   改后: 左 = 00+字24位+6个0, 右 = 0+字24位+7个0  -> 左声道晚 1 拍 ✗
                        //   即 `shift <= audio_l` 让左声道多送了一个比特 (MSB 重复),
                        //   右声道(6'd31 分支)仍是原来的下标 -> 左右不对称 = 左声道数据被破坏。
                        // 恢复: 装载 {b22..b0, 1'b0}, 并立刻把 b23 送上数据线;
                        //   下一拍 default 支路送 shift[23] = b22, 依次到 b0。
                        shift      <= {audio_l[22:0], 1'b0};
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

    //-------------------------------------------------- 数据线延后 1 个 BCLK
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sdata_d <= 1'b0;
        else if (bclk_fall) sdata_d <= sdata_raw;
    end

endmodule
