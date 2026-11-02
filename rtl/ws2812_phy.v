// =============================================================================
// ws2812_phy.v -- WS2812B 单线归零码物理层 (1 根 IO 驱动整条灯带)
//
//   位周期 1.25us, 高电平宽度区分 0/1:
//     0 = 0.40us 高 + 0.85us 低      1 = 0.80us 高 + 0.45us 低
//   帧尾: din 持续低 >=50us -> 全链锁存、变色。
//   线序: 每颗灯 24bit = G[7:0] R[7:0] B[7:0], MSB 先出; 位置即地址。
//   !! 2026-10-13 上板实测教训: 新版/clone 灯珠 (WS2812B-V5 等) 要求的复位低电平
//      可达 **280us ~ 1ms**, 80us 可能不被接受(表现为"颜色乱/只亮几颗")。
//      复位时间加长对自己没有任何坏处(只是多等一会儿), 所以默认改成 1ms(TRST=50000)。
//      影响: 帧周期 = 24 颗 x 24bit x 1.25us + 1ms ≈ 1.72ms -> 刷新率仍 ~580Hz。
//
//   时序常数按 50MHz 主时钟硬算 (1 拍 = 20ns):
//     T0H=20, T1H=40, TBIT=63, TRST=50000
//   !!! 改主时钟必须按 (ns/20) 重算这四个常数 (与 i2s_48k 的 BCLK_INC 同理) !!!
//
//   双缓冲: px_* 写口永远写入"不在发送"的那一块; 每帧发送完进入复位相时
//   翻转发送块并打出一拍 frame_start —— viz_led 收到后在此相内(1ms >> 24拍)
//   刷新完 24 个像素, 与发送永不重叠。发送自由连续跑(约 580Hz/帧),
//   viz_led 的数据更新率由它自己的 dirty/frame_start 决定。
// =============================================================================
module ws2812_phy #(
    parameter NPIX = 24,     // 灯数, <=32
    parameter T0H  = 20,     // 0 码高电平拍数 (0.40us)
    parameter T1H  = 40,     // 1 码高电平拍数 (0.80us)
    parameter TBIT = 63,     // 位周期拍数    (1.25us)
    parameter TRST = 50000   // 帧尾复位拍数  (1000us, 兼容 WS2812B-V5/clone)
)(
    input  wire        clk,
    input  wire        rst_n,
    output reg         din,          // 直驱灯带 DIN (3.3V, 见 handoff 坑 13: 电平/供电)
    output reg         frame_start,  // 复位相开始的一拍脉冲, 此时写另一缓冲最安全
    input  wire        px_we,        // 像素写使能 (1 拍 1 像素)
    input  wire [4:0]  px_waddr,     // 像素序号 0..NPIX-1
    input  wire [23:0] px_wdata      // {G[7:0], R[7:0], B[7:0]}, 线序即此顺序
);

    // 双缓冲像素存储: 寻址 = {bank, pix}, pix 5bit -> 每块自然步长 32,
    // 所以深度必须开 2*32=64 (NPIX<=32); 开 2*NPIX 会把 bank1 后半读越界(X)!
    // (本例教训: {bank,pix} 拼接的步长跟 pix 位宽走, 跟 NPIX 无关)
    reg [23:0] mem [0:63];
    reg        bank;      // 当前发送的块
    reg        st;        // 0=复位相 1=发送相
    reg [15:0] rst_cnt;      // !! 必须放得下 TRST: 原来是 [12:0](最大 8191),
                             //    TRST 改成 50000 后会被截断成 848 拍(=17us, 比原来还短!)
                             //    实测办法: 综合日志里 ws2812_phy 若出现
                             //    "Expression size 16 truncated to fit in target size 13" 就是它。
    reg [4:0]  pix;       // 当前像素 0..NPIX-1
    reg [4:0]  bpos;      // 当前像素内位序 0..23 (MSB 先发)
    reg [5:0]  tick;      // 位内拍计数 0..TBIT-1
    reg        clr_done;  // 上电清零完成标志 (先把整个 mem 扫一遍 0 再开发)
    reg [5:0]  clr_cnt;
    integer i;
    initial for (i = 0; i < 64; i = i + 1) mem[i] = 24'd0;

    wire [23:0] cur_word = mem[{bank, pix}];
    wire        cur_bit  = cur_word[5'd23 - bpos];

    // 组合出波形: 发送相内 tick < 高宽度 时为高; 复位相恒低
    always @* din = (st == 1'b1) && (tick < (cur_bit ? T1H : T0H));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= 1'b0; bank <= 1'b0; rst_cnt <= TRST;
            pix <= 5'd0; bpos <= 5'd0; tick <= 6'd0; frame_start <= 1'b0;
            clr_done <= 1'b0; clr_cnt <= 6'd0;
        end else begin
            frame_start <= 1'b0;
            if (px_we) mem[{~bank, px_waddr}] <= px_wdata;   // 写入非发送块
            if (st == 1'b0) begin                            // ---- 复位相 ----
                if (!clr_done) begin
                    // 上电全清: 存储上电内容不确定 (handoff 坑8 同款教训)。
                    // initial 块只救仿真不救板子 —— 本例连仿真都暴露了缺口。
                    mem[clr_cnt] <= 24'd0;
                    clr_cnt <= clr_cnt + 6'd1;
                    if (clr_cnt == 6'd63) clr_done <= 1'b1;   // 扫满 64 格
                end else if (rst_cnt == 16'd0) begin
                    bank <= ~bank;                           // 切到刚写好的块
                    pix <= 5'd0; bpos <= 5'd0; tick <= 6'd0;
                    st <= 1'b1;
                end else begin
                    rst_cnt <= rst_cnt - 16'd1;
                end
            end else begin                                   // ---- 发送相 ----
                if (tick == TBIT - 1) begin
                    tick <= 6'd0;
                    if (bpos == 5'd23) begin
                        bpos <= 5'd0;
                        if (pix == NPIX - 1) begin           // 一帧发完
                            st <= 1'b0;
                            rst_cnt <= TRST;
                            frame_start <= 1'b1;             // 喊 viz_led 换帧
                        end else begin
                            pix <= pix + 5'd1;
                        end
                    end else begin
                        bpos <= bpos + 5'd1;
                    end
                end else begin
                    tick <= tick + 6'd1;
                end
            end
        end
    end
endmodule
