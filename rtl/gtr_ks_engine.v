// gtr_ks_engine.v -- 16 声部 Karplus-Strong 吉他引擎（与 tools/gtr_ks_int_model.py 逐位一致）
//
//   延迟线 dly[voice*MAXN + idx] (Q15), 长度 N 每音查表
//   循环: lp = (21299*x + 11469*prev) >>> 15;  y = (g*lp) >>> 15; 写回; prev = x
//   激励: 三角(step 查表) + LFSR 单极点噪声; 起振前 288 样本乘 6ms 升余弦
//   note-on: 加载状态机每拍写一个激励点（N ≤ 640 拍，采样间隔 1024 拍内完成）
module gtr_ks_engine #(
    parameter VOICES = 16,
    parameter MAXN   = 640,
    // 激励里"成型噪声"的幅度(原实现 6554 = 三角峰的 20%)。0 = 完全关掉噪声,
    // 只留三角激励 —— 用来做"扫弦沙沙声到底是不是它"的 A/B。
    parameter [15:0] NZ_GAIN = 16'd6554,
    // 噪声频谱: 0 = 原实现(121Hz 低通, 能量在基频以下 -> 听着"闷/割裂")
    //           1 = 高通(lfsr - 低通), 能量挪到中高频 -> 像拨片/指甲摩擦
    parameter NZ_MODE = 0,
    // 抬键语义: 0 = v24 行为(松手不阻尼, 弦自己响到自然衰减);
    //           1 = 抬键精确释放该音(会瞬断, 手感偏"短促")
    parameter RELEASE_ON_OFF = 0,
    // v29: 激励三角是否改双极性。原实现是 0..32767 的全正三角, 均值 16384,
    //      等于每次拨弦都往弦里灌一个 +16384(50%FS) 的直流阶跃。弦的环路直流
    //      增益≈1、每周期只乘 g/32768(≈0.99), 这个阶跃要 ~0.4s 才衰减掉,
    //      而琴体是近直流极点 → 被放大成一段低/次声摆动（"呼"）。
    //      1 = 居中到 ±16384（AC 幅度完全不变, 只去掉直流）。
    parameter EXC_BIPOLAR = 1,
    // v30: 三角激励右移位数（降权）。KS 环路是梳状滤波器, **稳态音色 = 激励波形本身的形状**:
    //      上下对称的三角只含奇次谐波 -> 只能是风琴/空灵音色(实测 k2 比 k1 低 55 dB)。
    //      4 = 三角/16, 配合 NZ_GAIN=16384 + NZ_MODE=1(白噪声) -> k2 只低 7.9 dB, 全谐波。
    parameter TRI_SHIFT = 0
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_req,
    input  wire        note_we,
    input  wire [6:0]  note,
    input  wire        note_off_we,          // v25: 抬键释放（原来 top.v 把 off 事件过滤掉了）
    input  wire [6:0]  off_note,
    output reg  signed [23:0] audio_out,
    output reg  [5:0]  active_cnt
);
    localparam ALPHA = 16'd21299;
    localparam BETA  = 16'd11469;

    reg [10:0] ntab  [0:127];
    reg [15:0] gtab  [0:127];
    reg [15:0] sttab [0:127];
    reg [15:0] env_rom [0:287];
    reg [15:0] body_c [0:14];
    initial begin
        $readmemh("rtl/rom/gtr_delay_n.hex", ntab);
        $readmemh("rtl/rom/gtr_loop_g.hex", gtab);
        $readmemh("rtl/rom/gtr_tri_step.hex", sttab);
        $readmemh("rtl/rom/gtr_env.hex", env_rom);
        $readmemh("rtl/rom/gtr_body_coef.hex", body_c);
    end

    // 琴体: 3 个 biquad (Direct Form I, Q14, 每拍一个乘法)
    reg signed [15:0] bx1 [0:2], bx2 [0:2], byy1 [0:2], byy2 [0:2];
    reg signed [15:0] xb_reg, yv_reg, outv_reg;
    reg signed [31:0] yacc, ytot;
    reg [1:0] band;
    reg [2:0] bs;
    integer bi;
    wire [2:0] cidx = (bs >= 3'd1 && bs <= 3'd5) ? (bs - 3'd1) : 3'd0;
    wire signed [15:0] c_sel = body_c[band * 5 + cidx];
    wire signed [15:0] v_sel = (bs == 3'd1) ? xb_reg :
                               (bs == 3'd2) ? bx1[band] :
                               (bs == 3'd3) ? bx2[band] :
                               (bs == 3'd4) ? byy1[band] : byy2[band];
    // 2026-11-01 实测结论: 原来的 c32*v32 写法**并没有多花 DSP** —— 综合器把两个
    //   符号扩展的 16bit 操作数常量折叠回了 16x16 乘法（改成 16bit 直乘后资源一点没变）。
    //   所以本模块这 7 个 DSP 是 7 个**互不相同**的乘法，只能靠"合并运算"省；
    //   下面 tri_prod 已把三角激励的两条互斥乘法并成 1 个（见 :145 附近）。
    wire signed [31:0] body_prod = c_sel * v_sel;

    reg [15:0] dly [0:VOICES*MAXN-1];
    reg [9:0]  idx  [0:VOICES-1];
    reg signed [15:0] prev [0:VOICES-1];
    reg [10:0] nn   [0:VOICES-1];
    reg [15:0] gg   [0:VOICES-1];
    reg [8:0]  onp  [0:VOICES-1];
    reg        act  [0:VOICES-1];
    reg [6:0]  vnote [0:VOICES-1];       // v25: 每声部占用的音号, 用于 note-off 精确释放
    reg [13:0] quiet [0:VOICES-1];       // v26: 连续低电平计数(判静音回收, 不能用瞬时值)

    // 读端口（BSRAM 同步读）
    reg  [13:0] rd_addr;
    reg  signed [15:0] rd_data;
    always @(posedge clk) rd_data <= dly[rd_addr];

    // 事件锁存
    reg        pend;
    reg [6:0]  p_note;
    reg [3:0]  p_voice;
    reg        pend2;
    reg [6:0]  p_note2;
    reg [3:0]  p_voice2;
    reg [3:0]  alloc_ptr;

    // 主状态机
    localparam S_IDLE = 2'd0, S_RUN = 2'd1, S_LOAD = 2'd2, S_FIN = 2'd3, S_BODY = 2'd4;
    reg [1:0]  fsm;
    reg [4:0]  vsel;
    // v32: 每声部一个"延迟线地址指针" —— RAM 地址路径上只剩一次 16:1 mux,
    //      加法与 ×640 乘法被彻底移出去。原因: Gowin 会把只喂 RAM 地址口的
    //      寄存器并进 BSRAM 自己的地址寄存器, 所以对原式 vsel*MAXN+idx[vsel]
    //      拆流水级是无效的(实测 v31 反而更差)。
    reg [13:0] dptr [0:VOICES-1];
    reg [1:0]  phase;
    reg        ld_on;
    reg [10:0] ld_i;
    reg [10:0] ld_n;
    reg [15:0] ld_g, ld_step;
    reg [3:0]  ld_v;
    reg [15:0] lfsr;
    reg signed [15:0] lp;
    reg signed [23:0] acc;
    reg [5:0]  act_acc;

    // 处理中的临时量（模块级，Verilog-2001）
    reg signed [15:0] x_r, lpv_r, yv_r, ox_r;
    reg signed [31:0] m_r;
    reg [15:0] env_v;
    reg [9:0]  idx_n;

    // LFSR 下一状态 + 单极点
    wire fb = lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10];
    wire [15:0] lfsr_n = {lfsr[14:0], fb};
    wire signed [15:0] ns_next = lfsr_n;
    wire signed [15:0] lp_next = lp + ((ns_next - lp) >>> 6);
    // 噪声整形: HP 模式取 (lfsr - 低通状态) = 高通, 把能量从"基频以下"挪到中高频
    wire signed [16:0] nz_hp  = $signed({lfsr_n[15], lfsr_n}) - $signed({lp_next[15], lp_next});
    wire signed [15:0] nz_src = (NZ_MODE != 0) ? nz_hp[15:0] : lp_next;
    // 2026-10-30 移植到双引擎板时 DSP 差 1 个：NZ_GAIN=16384 时
    //   (16384*x)>>>15 与 x>>>1 逐位相同（16384=2^14），参数为 16384 时走右移，
    //   不例化乘法器；其它 NZ_GAIN 取值仍走原来的乘法，行为不变。
    wire signed [15:0] nz_v;
    generate
        if (NZ_GAIN == 16'd16384) begin : g_nz_half
            assign nz_v = $signed(nz_src) >>> 1;
        end else begin : g_nz_mul
            wire signed [31:0] nz_p = ($signed({16'd0, NZ_GAIN}) * $signed(nz_src)) >>> 15;
            assign nz_v = nz_p[15:0];
        end
    endgenerate
    wire [15:0] half = {1'b0, ld_n[10:1]};
    // 2026-11-01 资源优化（**逐位不变**，验收见 tb/tb_gtr_ks_engine_bitref.v）:
    //   三角激励原来是两条并排乘法 ld_i*ld_step 与 (ld_i-half)*ld_step，而它们由
    //   ld_i<half **互斥**决定走哪条 -> 现在先把操作数 mux 出来共用一个乘法器（省 1 DSP）。
    //   两条分支原式都只取乘积低 16 位（第一支显式 tri_prod[15:0]；第二支在 16bit
    //   上下文里算、也是截到 16 位），所以合并后取 tri_prod[15:0] 与原值逐位相同。
    wire [10:0] tri_x    = (ld_i < half) ? ld_i : (ld_i - half);
    wire [31:0] tri_prod = tri_x * ld_step;
    wire [15:0] tri_raw  = (ld_i < half) ? tri_prod[15:0]
                                         : (16'sd32767 - tri_prod[15:0]);
    // v29: 双极性化（减掉三角均值 16384），AC 幅度不变、直流归零
    wire signed [16:0] tri_c = $signed({1'b0, tri_raw}) - 17'sd16384;
    wire signed [15:0] tri_b = (EXC_BIPOLAR != 0) ? tri_c[15:0] : $signed(tri_raw);
    // v30: 三角降权（TRI_SHIFT=4 即 /16），让噪声成分主导 -> 全谐波
    wire signed [15:0] tri_v = (TRI_SHIFT != 0) ? (tri_b >>> TRI_SHIFT) : tri_b;
    // 激励写入饱和到 Q15（物理正确：回绕会产生满幅伪尖峰；模型 clip16 与之对应）
    wire signed [16:0] exc_sum = tri_v + nz_v;
    wire signed [15:0] exc_v = (exc_sum > 17'sd32767)  ? 16'sd32767  :
                               (exc_sum < -17'sd32768) ? -16'sd32768 :
                                                          exc_sum[15:0];

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fsm <= S_IDLE; vsel <= 0; phase <= 0;
            acc <= 0; act_acc <= 0;
            pend <= 0; pend2 <= 0; alloc_ptr <= 0; ld_i <= 0; ld_on <= 0;
            lfsr <= 16'hACE1; lp <= 0; audio_out <= 0; active_cnt <= 0;
            rd_addr <= 0; bs <= 0; band <= 0; yacc <= 0; ytot <= 0;
            xb_reg <= 0; outv_reg <= 0; yv_reg <= 0;
            for (bi = 0; bi < 3; bi = bi + 1) begin
                bx1[bi] <= 0; bx2[bi] <= 0; byy1[bi] <= 0; byy2[bi] <= 0;
            end
            for (k = 0; k < VOICES; k = k + 1) begin
                act[k] <= 0; idx[k] <= 0; prev[k] <= 0; onp[k] <= 0;
                nn[k] <= 0; gg[k] <= 0; vnote[k] <= 7'd0; quiet[k] <= 14'd0;
                dptr[k] <= k * MAXN;              // v32: 各声部基址(常量, 综合成常数表)
            end
        end else begin
            if (note_we) begin
                if (!pend) begin
                    pend <= 1'b1; p_note <= note; p_voice <= alloc_ptr;
                    alloc_ptr <= alloc_ptr + 1'b1;
                end else if (!pend2) begin
                    pend2 <= 1'b1; p_note2 <= note; p_voice2 <= alloc_ptr;
                    alloc_ptr <= alloc_ptr + 1'b1;
                end
            end

            // v27: 抬键释放 —— release_on_off=0 时保持 v24 行为(松手不阻尼);
            //      只在"静音回收"里释放声部, 从根上消掉 16 路残留叠加的沙沙声。
            if (RELEASE_ON_OFF != 0 && note_off_we) begin
                for (k = 0; k < VOICES; k = k + 1)
                    if (act[k] && (vnote[k] == off_note)) begin
                        act[k] <= 1'b0;
                        gg[k]  <= 16'd0;
                    end
            end

            case (fsm)
            S_IDLE: begin
                acc <= 0; act_acc <= 0;
                if (sample_req) begin fsm <= S_RUN; vsel <= 0; phase <= 0; end
            end

            S_RUN: begin
                if (phase == 2'd0) begin
                    // v32: RAM 地址 = 该声部自己的指针, 路径上只剩一次 16:1 mux
                    rd_addr <= dptr[vsel];
                    phase   <= 2'd1;
                end else if (phase == 2'd1) begin
                    // BSRAM 同步读: 地址(P0末有效) → 内部地址寄存器(P1) → 出数据(P2末)
                    phase <= 2'd2;
                end else if (phase == 2'd2) begin
                    phase <= 2'd3;
                end else begin
                    if (act[vsel]) begin
                        x_r = rd_data;
                        // 2026-10-30: 21299x+11469p 等价改写为 x + (11469*(p-x))>>15（21299 = 32768-11469，
                        //   且 32768x 是 2^15 的整数倍，算术右移可拆开）——只占 1 个乘法器、关键路径更短。
                        begin : ks_lp_1mul
                            logic signed [16:0] dif;
                            dif = $signed({prev[vsel][15], prev[vsel]}) - $signed({x_r[15], x_r});
                            m_r = $signed({{16{x_r[15]}}, x_r}) + (($signed(dif) * 17'sd11469) >>> 15);
                        end
                        lpv_r = m_r[15:0];
                        m_r = ($signed({16'd0, gg[vsel]}) * lpv_r) >>> 15;
                        yv_r = m_r[15:0];
                        // v31: 写口复用已寄存的 rd_addr —— 与读口同址, 且本拍内 idx[vsel] 还没更新,
                        //      所以写地址与原来 vsel*MAXN+idx[vsel] 逐位相同; 省掉一份 mux+乘法,
                        //      同时消掉写地址那条长路径。
                        dly[rd_addr] <= yv_r;
                        prev[vsel] <= x_r;
                        // v26: 修复 v25 的致命错误 —— 不能用"瞬时值"判静音!
                        //      KS 输出是 AC 波形, 每个周期必然过零, 过零那 1~2 拍会被
                        //      误判成"已衰减完"而把声部杀掉 => 音被腰斩 / 高音直接没声。
                        //      改为"连续 8192 拍(≈168ms)都 < 3 LSB"才回收; 最低音周期
                        //      640 拍, 正常发声时每半个周期就会把计数器清零, 不可能误杀。
                        if ((x_r < 16'sd3) && (x_r > -16'sd3)) begin
                            if (quiet[vsel] < 14'd8191) quiet[vsel] <= quiet[vsel] + 14'd1;
                            else                        act[vsel]   <= 1'b0;
                        end else begin
                            quiet[vsel] <= 14'd0;
                        end
                        if (onp[vsel] < 288) begin
                            env_v = env_rom[onp[vsel]];
                            ox_r = ($signed({16'd0, env_v}) * x_r) >>> 15;
                            onp[vsel] <= onp[vsel] + 1'b1;
                        end else ox_r = x_r;
                        acc <= acc + ox_r;
                        act_acc <= act_acc + 6'd1;
                        idx_n = idx[vsel] + 1'b1;
                        idx[vsel] <= (idx_n >= nn[vsel]) ? 10'd0 : idx_n;
                        // v32: 指针同步推进; 回卷时回到基址(= 当前地址 - 当前索引)
                        dptr[vsel] <= (idx_n >= nn[vsel]) ? (rd_addr - {4'd0, idx[vsel]})
                                                          : (rd_addr + 1'b1);
                    end
                    phase <= 2'd0;
                    if (vsel == VOICES - 1) fsm <= (pend || pend2) ? S_LOAD : S_FIN;
                    else vsel <= vsel + 1'b1;
                end
            end

            S_LOAD: begin
                if (!ld_on) begin
                    if (pend) begin
                        ld_v <= p_voice; ld_n <= ntab[p_note]; ld_g <= gtab[p_note];
                        ld_step <= sttab[p_note];
                        p_note <= p_note2; p_voice <= p_voice2; pend <= pend2; pend2 <= 1'b0;
                        // v28: 不再复位 LFSR/lp —— 复位会让每次拨弦的噪声逐样本相同(机械感很重)
                        ld_i <= 0;
                        act[p_voice] <= 1'b1; idx[p_voice] <= 0; prev[p_voice] <= 0;
                        dptr[p_voice] <= p_voice * MAXN;   // v32: 指针回到本声部基址(idx=0)
                        onp[p_voice] <= 0; nn[p_voice] <= ntab[p_note]; gg[p_voice] <= gtab[p_note];
                        vnote[p_voice] <= p_note;
                        quiet[p_voice] <= 14'd0;      // v26: 重触发要清静音计数
                        // v25: 同音重触发 —— 先释放同音号的旧声部, 防止"敲两下叠两个"
                        for (k = 0; k < VOICES; k = k + 1)
                            if (act[k] && (k != p_voice) && (vnote[k] == p_note)) act[k] <= 1'b0;
                        ld_on <= 1'b1;
                    end else begin
                        fsm <= S_FIN;
                    end
                end else begin
                    if (ld_i < 3) $display("LD i=%0d tri=%0d nz=%0d n=%0d step=%0d lp=%0d lfsr=%h",
                                           ld_i, tri_v, nz_v, ld_n, ld_step, lp, lfsr);
                    dly[ld_v * MAXN + ld_i] <= exc_v;
                    // 循环 prev 初值 = 最后一个激励样本（环形缓冲连续性，与模型 prev=buf[N-1] 一致）
                    prev[ld_v] <= exc_v;
                    lfsr <= lfsr_n;
                    lp <= lp_next;
                    ld_i <= ld_i + 1'b1;
                    if (ld_i + 1'b1 >= ld_n) begin
                        ld_on <= 1'b0;
                        if (!pend && !pend2) fsm <= S_FIN;
                    end
                end
            end

            S_BODY: begin
                case (bs)
                3'd0: begin
                    $display("BODY0 acc=%0d", acc);
                    xb_reg <= (acc >>> 4);
                    ytot <= 0; band <= 2'd0; bs <= 3'd1;
                end
                3'd1: begin yacc <= body_prod;                 bs <= 3'd2; end
                3'd2: begin yacc <= yacc + body_prod;          bs <= 3'd3; end
                3'd3: begin yacc <= yacc + body_prod;          bs <= 3'd4; end
                3'd4: begin yacc <= yacc + body_prod;          bs <= 3'd5; end
                3'd5: begin yacc <= yacc + body_prod;          bs <= 3'd6; end
                3'd6: begin
                    yv_reg <= yacc[29:14];
                    bx2[band] <= bx1[band]; bx1[band] <= xb_reg;
                    byy2[band] <= byy1[band]; byy1[band] <= yacc[29:14];
                    ytot <= ytot + yacc[29:14];
                    if (band == 2'd2) begin
                        outv_reg <= xb_reg + ytot + yacc[29:14];
                        bs <= 3'd7;
                    end else begin
                        band <= band + 2'd1;
                        bs <= 3'd1;
                    end
                end
                3'd7: begin
                    $display("BODY acc=%0d outv=%0d", acc, outv_reg);
                    audio_out <= {outv_reg[15:0], 8'd0};
                    bs <= 3'd0;
                    fsm <= S_FIN;
                end
                default: begin bs <= 3'd0; fsm <= S_FIN; end
                endcase
            end

            S_FIN: begin
                if (acc > 24'sd8388607) audio_out <= 24'sd8388607;
                else if (acc < -24'sd8388608) audio_out <= -24'sd8388608;
                else audio_out <= acc;
                active_cnt <= act_acc;
                fsm <= S_IDLE;
            end
            endcase
        end
    end
endmodule
