// viz_lissa.v -- OLED 李萨如 / 音频 X-Y 相图（显示模式 2）
//
//   X = 音频经 A 支路两级一阶全通（相位基准）
//   Y = 音频经 B 支路两级一阶全通，两支路相差 90 度
//       系数由 tools/lissa_design2.py 差分进化优化:
//       65..4200 Hz（6 个八度）内相位误差最大 6.74 度, rms 4.66 度
//
//   定点约定: 17 位信号域（audio[23:7]）, 系数 Q1.15,
//             差值 18 位 × 系数 16 位 = 34 位乘积, 取 [33:15] 回 19 位,
//             加 x[n-1] 后 20 位饱和回 17 位
//             => 乘法器 16x18, 4 个全通共用 1 个, 8 周期/样本（预算 516）
//
//   采样: 每 2048 样本一帧, 隔点采集 1024 点写入点缓存
//   绘制: 帧边界先清屏(1024 写) 再逐点读-改-写
//         点缓存双 bank: 本帧采 bank_w, 同时绘上一帧 bank_r
//         => 画面整帧瞬变, 不会"逐点长出来"
module viz_lissa #(
    parameter [15:0] CA0 = 16'hC4AF,   // -15185
    parameter [15:0] CA1 = 16'h8435,   // -31691
    parameter [15:0] CB0 = 16'h80CE,   // -32562
    parameter [15:0] CB1 = 16'h909B    // -28517
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_req,
    input  wire signed [23:0] audio,
    // 帧存 A 口（读-改-写）
    output reg                we,
    output reg  [9:0]         waddr,
    output reg  [7:0]         wdata,
    output reg  [9:0]         raddr_a,
    input  wire [7:0]         rdata_a,
    output wire               busy
);
    // ------------------------------------------------------------------ 常量
    localparam [3:0] DR_IDLE = 4'd0, DR_CLR = 4'd1, DR_PT = 4'd2, DR_PTW = 4'd3,
                     DR_FBRD = 4'd4, DR_FBW = 4'd7, DR_WR = 4'd5, DR_NEXT = 4'd6;

    // ------------------------------------------------------------------ 17 位域
    wire signed [16:0] x17 = audio[23:7];

    function signed [16:0] sat17(input signed [19:0] v);
        begin
            if (v > 20'sd65535)       sat17 = 17'sd65535;
            else if (v < -20'sd65536) sat17 = -17'sd65536;
            else                      sat17 = v[16:0];
        end
    endfunction

    reg  signed [16:0] a1p, a1y, a2p, a2y;   // A 支路: 输入延迟 / 输出延迟
    reg  signed [16:0] b1p, b1y, b2p, b2y;   // B 支路
    reg  signed [16:0] x_lat;                // 本样本输入（已过直流阻断）
    reg  signed [16:0] o1;                   // A1 输出（A2 的输入）
    reg  signed [16:0] o2;                   // B1 输出（B2 的输入）
    reg  signed [16:0] yA, yB;               // 最终 X / Y
    reg  signed [33:0] p;                    // 共用乘法器输出
    reg  [3:0]         fst;

    // ---- 直流阻断（放在两条支路之前, 相位差不受影响; 无乘法器）
    //   y[n] = x[n] - x[n-1] + y[n-1] - (y[n-1] >>> 8)
    //   极点 1-2^-8 ≈ 0.99609, 转折约 fs/2^8/2pi ≈ 30 Hz
    //   用途: 吉他/琴体输出直流可达峰值的 40%, 会把相图整体推偏约 25 像素
    reg  signed [16:0] dcx_prev, dcy_prev;
    wire signed [18:0] dc_a = $signed({x17[16], x17}) - $signed({dcx_prev[16], dcx_prev});
    wire signed [18:0] dc_b = $signed({dcy_prev[16], dcy_prev}) -
                              $signed({{9{dcy_prev[16]}}, dcy_prev[16:8]});
    wire signed [19:0] dc_sum = $signed({dc_a[18], dc_a}) + $signed({dc_b[18], dc_b});
    wire signed [16:0] dc_y   = sat17(dc_sum);

    // 各步的差值 / 系数 / 加数（全部先声明）
    reg  signed [17:0] d_in;
    reg  [15:0]        c_in;
    reg  signed [16:0] xp_in;                // 该级 x[n-1]
    wire signed [33:0] prod   = $signed(c_in) * $signed(d_in);
    wire signed [18:0] t19    = p[33:15];
    wire signed [19:0] ysum   = $signed({{3{xp_in[16]}}, xp_in}) +
                                $signed({{1{t19[18]}}, t19});
    wire signed [16:0] ysat   = sat17(ysum);

    // ------------------------------------------------------------------ 帧计数 / 采集
    reg [10:0] fcnt;
    reg        bank_w, bank_r;
    reg        dr_start;
    reg [9:0]  k_lat;
    reg        collect;
    reg        bw_lat;

    // ------------------------------------------------------------------ 点缓存
    reg [15:0] pt_q [0:2047];
    reg [15:0] pt_d;
    reg        pt_we;
    reg [10:0] pt_waddr;
    reg [13:0] pt_wdata;
    reg [10:0] pt_raddr;

    // ------------------------------------------------------------------ 绘制
    reg [3:0]  dr;
    reg [9:0]  dr_i, dr_cnt;
    reg [15:0] pt_lat;
    reg [7:0]  mask;
    reg [9:0]  addr_lat;

    assign busy = (fst != 4'd0) || (dr != DR_IDLE);

    // ------------------------------------------------------------------ 坐标映射（17 位 -> 像素）
    // X 取已寄存的 yA; Y 取本拍组合的 ysat（fst=9 时即 B2 输出, 避免少打一拍）
    // ---- AGC: 逐帧峰值 -> 移位选择（无乘法器, 不削顶）
    //   规则: 让本帧峰值 << g 落在 [32768, 65536), 即映射到 ±32..±64 像素。
    //   g=0 对应原来的"增益 1"(满幅=满屏); g 最大 3(最多放大 8 倍)。
    //   增益在帧边界更新, 作用于下一帧采集; 点缓存里存的是已定标的坐标, 所以不会串帧。
    reg  [1:0]  agc_g;
    reg  [17:0] agc_pk;
    wire signed [17:0] yA18 = {{1{yA[16]}}, yA};
    wire signed [17:0] yB18 = {{1{ysat[16]}}, ysat};
    wire [17:0] magA = yA18[17] ? (~yA18 + 1'b1) : yA18;
    wire [17:0] magB = yB18[17] ? (~yB18 + 1'b1) : yB18;
    wire [17:0] mag_max = (magA > magB) ? magA : magB;

    wire signed [19:0] xg = $signed({{3{yA[16]}}, yA})   <<< agc_g;
    wire signed [19:0] yg = $signed({{3{ysat[16]}}, ysat}) <<< agc_g;
    wire signed [9:0]  xv = 10'sd64 + (xg >>> 10);
    wire signed [9:0]  yv = 10'sd32 - (yg >>> 11);
    wire [6:0] px_w = (xv < 10'sd0) ? 7'd0 : (xv > 10'sd127) ? 7'd127 : xv[6:0];
    wire [5:0] py_w = (yv < 10'sd0) ? 6'd0 : (yv > 10'sd63)  ? 6'd63  : yv[5:0];

    // ------------------------------------------------------------------ 点缓存读写
    always @(posedge clk) begin
        if (pt_we) pt_q[pt_waddr] <= pt_wdata;
        pt_d <= pt_q[pt_raddr];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a1p <= 0; a1y <= 0; a2p <= 0; a2y <= 0;
            b1p <= 0; b1y <= 0; b2p <= 0; b2y <= 0;
            x_lat <= 0; o1 <= 0; o2 <= 0; yA <= 0; yB <= 0; p <= 0; fst <= 0;
            dcx_prev <= 0; dcy_prev <= 0;
            agc_g <= 2'd0; agc_pk <= 18'd0;
            d_in <= 0; c_in <= 0; xp_in <= 0;
            fcnt <= 0; bank_w <= 1'b0; bank_r <= 1'b1; dr_start <= 1'b0;
            k_lat <= 0; collect <= 1'b0; bw_lat <= 1'b0;
            pt_we <= 1'b0; pt_waddr <= 0; pt_wdata <= 0; pt_raddr <= 0;
            dr <= DR_IDLE; dr_i <= 0; dr_cnt <= 0; pt_lat <= 0; mask <= 0; addr_lat <= 0;
            we <= 1'b0; waddr <= 0; wdata <= 0; raddr_a <= 0;
            // 注意: 点缓存 pt_q 不做复位。理由:
            //  1) Gowin 综合器 for 循环上限 2000 次, 2048 深复位会直接报 EX3934 变黑盒;
            //  2) 大数组复位会让 BSRAM 推成触发器;
            //  3) 本设计不需要: 第一次绘制发生在第 1 帧结束, 那时 bank 已整帧写满。
        end else begin
            pt_we <= 1'b0;
            we    <= 1'b0;

            // ---------------- 4 级全通, 每级 2 周期
            case (fst)
            // ---- A1
            4'd1: begin
                d_in <= $signed({x_lat[16], x_lat}) - $signed({a1y[16], a1y});
                c_in <= CA0;
                fst  <= 4'd2;
            end
            4'd2: begin
                p    <= prod;
                xp_in <= a1p;
                fst  <= 4'd3;
            end
            4'd3: begin
                o1  <= ysat;
                a1p <= x_lat;
                a1y <= ysat;
                d_in <= $signed({ysat[16], ysat}) - $signed({a2y[16], a2y});
                c_in <= CA1;
                fst  <= 4'd4;
            end
            // ---- A2
            4'd4: begin
                p     <= prod;
                xp_in <= a2p;
                fst   <= 4'd5;
            end
            4'd5: begin
                yA  <= ysat;
                a2p <= o1;
                a2y <= ysat;
                d_in <= $signed({x_lat[16], x_lat}) - $signed({b1y[16], b1y});
                c_in <= CB0;
                fst  <= 4'd6;
            end
            // ---- B1
            4'd6: begin
                p     <= prod;
                xp_in <= b1p;
                fst   <= 4'd7;
            end
            4'd7: begin
                o2  <= ysat;
                b1p <= x_lat;
                b1y <= ysat;
                d_in <= $signed({ysat[16], ysat}) - $signed({b2y[16], b2y});
                c_in <= CB1;
                fst  <= 4'd8;
            end
            // ---- B2
            4'd8: begin
                p     <= prod;
                xp_in <= b2p;
                fst   <= 4'd9;
            end
            4'd9: begin
                yB  <= ysat;
                b2p <= o2;
                b2y <= ysat;
                fst <= 4'd0;
                if (mag_max > agc_pk) agc_pk <= mag_max;
                if (collect) begin
                    pt_we    <= 1'b1;
                    pt_waddr <= {bw_lat, k_lat};
                    pt_wdata <= {1'b0, py_w, px_w};
                end
            end
            default: fst <= 4'd0;
            endcase

            // ---------------- 绘制序列
            case (dr)
            DR_IDLE: begin
                if (dr_start) begin
                    dr_start <= 1'b0;
                    dr_cnt   <= 0;
                    dr_i     <= 0;
                    dr       <= DR_CLR;
                end
            end
            DR_CLR: begin
                we    <= 1'b1;
                waddr <= dr_cnt;
                wdata <= 8'h00;
                if (dr_cnt == 10'd1023) begin
                    dr <= DR_PT;
                end else begin
                    dr_cnt <= dr_cnt + 1'b1;
                end
            end
            DR_PT: begin
                pt_raddr <= {bank_r, dr_i};
                dr       <= DR_PTW;
            end
            DR_PTW: begin
                dr <= DR_FBRD;
            end
            DR_FBRD: begin
                pt_lat   <= pt_d;
                raddr_a  <= {pt_d[12:10], pt_d[6:0]};
                addr_lat <= {pt_d[12:10], pt_d[6:0]};
                mask     <= 8'h01 << pt_d[9:7];
                dr       <= DR_FBW;
            end
            DR_FBW: begin
                // 等帧存的同步读数据有效
                dr <= DR_WR;
            end
            DR_WR: begin
                we    <= 1'b1;
                waddr <= addr_lat;
                wdata <= rdata_a | mask;
                dr    <= DR_NEXT;
            end
            DR_NEXT: begin
                if (dr_i == 10'd1023) begin
                    dr <= DR_IDLE;
                end else begin
                    dr_i <= dr_i + 1'b1;
                    dr   <= DR_PT;
                end
            end
            default: dr <= DR_IDLE;
            endcase

            // ---------------- 新样本: 启动流水 + 帧计数
            //   必须放在 case(fst) 之后: 同一 always 块里后写的非阻塞赋值优先,
            //   否则 default: fst<=0 会把本拍的 fst<=1 覆盖掉（曾致滤波永不启动）
            if (sample_req && (fst == 4'd0)) begin
                x_lat    <= dc_y;          // 直流阻断后再进支路
                dcx_prev <= x17;
                dcy_prev <= dc_y;
                fst     <= 4'd1;
                collect <= (fcnt[0] == 1'b0);
                k_lat   <= fcnt[10:1];
                bw_lat  <= bank_w;
                if (fcnt == 11'd2047) begin
                    fcnt     <= 11'd0;
                    bank_w   <= ~bank_w;
                    bank_r   <= bank_w;       // 刚采集完的 bank
                    dr_start <= 1'b1;
                    // AGC 档位: 下一帧生效
                    if      (agc_pk >= 18'd32768) agc_g <= 2'd0;
                    else if (agc_pk >= 18'd16384) agc_g <= 2'd1;
                    else if (agc_pk >= 18'd8192)  agc_g <= 2'd2;
                    else                           agc_g <= 2'd3;
                    agc_pk <= 18'd0;
                end else begin
                    fcnt <= fcnt + 1'b1;
                end
            end
        end
    end
endmodule
