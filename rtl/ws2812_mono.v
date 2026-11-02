// ws2812_mono.v -- 单色 + 逐位置可控的灯条驱动
//
//   需求：整条灯带只用**一个颜色**，但 32 个位置可以分别点亮/熄灭（单色位图）。
//   代价远低于 ws2812_phy.v（那个是 24 位/像素 × 双缓冲 = 1,190 LUT + 682 FF）：
//   本模块只存 32 位亮灭掩码 + 24 位颜色，约 80~120 LUT、~70 FF。
//
//   协议（WS2812B，50 MHz 标定）：NPIX 颗 × 24 bit，MSB 先出，GRB 线序
//     T0H=20 拍(0.40us) T1H=40 拍(0.80us) TBIT=63 拍(1.25us) 帧尾 TRST=50000 拍(1ms)
//   颜色 = {G[7:0], R[7:0], B[7:0]}；mask[i]=1 的第 i 颗发 color，否则发 0（灭）。
module ws2812_mono #(
    parameter NPIX = 32,
    parameter T0H  = 20,
    parameter T1H  = 40,
    parameter TBIT = 63,
    parameter TRST = 50000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [23:0] color,     // 整条灯带的唯一颜色
    input  wire [31:0] mask,      // 每个位置亮/灭（bit i = 第 i 颗）
    output wire        din
);
    localparam S_RST = 1'b0, S_BIT = 1'b1;

    reg        st;
    reg [15:0] rst_cnt;
    reg [5:0]  tick;
    reg [4:0]  bpos;      // 像素内位序 0..23（0 = 最高位）
    reg [5:0]  pix;       // 当前像素 0..NPIX-1（NPIX 最大 32）
    reg [23:0] col;       // 帧首锁存
    reg [31:0] msk;       // 帧首锁存

    wire cur_on  = msk[pix];
    wire cur_bit = cur_on & col[5'd23 - bpos];

    assign din = (st == S_BIT) && (tick < (cur_bit ? T1H : T0H));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st      <= S_RST;
            rst_cnt <= TRST[15:0];
            tick    <= 6'd0;
            bpos    <= 5'd0;
            pix     <= 6'd0;
            col     <= 24'd0;
            msk     <= 32'd0;
        end else begin
            case (st)
            S_RST: begin
                if (rst_cnt == 16'd0) begin
                    st   <= S_BIT;
                    tick <= 6'd0;
                    bpos <= 5'd0;
                    pix  <= 6'd0;
                    col  <= color;          // 帧首同时锁存颜色与掩码
                    msk  <= mask;
                end else begin
                    rst_cnt <= rst_cnt - 16'd1;
                end
            end

            S_BIT: begin
                if (tick == TBIT[5:0] - 6'd1) begin
                    tick <= 6'd0;
                    if (bpos == 5'd23) begin
                        bpos <= 5'd0;
                        if (pix == NPIX[5:0] - 6'd1) begin
                            st      <= S_RST;       // 一帧发完
                            rst_cnt <= TRST[15:0];
                        end else begin
                            pix <= pix + 6'd1;
                        end
                    end else begin
                        bpos <= bpos + 5'd1;
                    end
                end else begin
                    tick <= tick + 6'd1;
                end
            end
            endcase
        end
    end
endmodule
