`timescale 1ns/1ps
//=============================================================================
// ads1115_if.v —— ADS1115 16bit I2C ADC 主机驱动 (FSR402 力敏电阻力度采样)
//
// 协议: 4 通道(AIN0..AIN3 单端对地)单次转换轮询, 每通道一步序:
//   START | W 0x90 | W 0x01 | W cfgH | W cfgL | STOP | 等转换(1.3ms)
//   START | W 0x90 | W 0x00 | SrSTART | W 0x91 | R(ACK) | R(NACK) | STOP
//   cfgH = {OS=1, MUX=100|ch, PGA=001(±4.096V), MODE=1(单次)}
//          ch0..3 = 0xC3/0xD3/0xE3/0xF3; 3.3V 满量程 ≈ 26500 码
//   cfgL = 0xE3 (DR=860SPS, 比较器关)
//
// 物理层: 单主机 —— SCL 推挽直驱(ADS1115 不拉伸时钟), SDA 开漏(oe=拉低,
//         释放靠外部上拉, 板上 ADS1115 模块自带 10k 上拉)。
// 时序:   TQ = SCL 四分之一周期的 clk 数 (50MHz/400kHz/4 ≈ 31);
//         每位 4*TQ, 写应答/读数据均在 SCL 高电平中点采样。
//         4 通道整轮 ≈ 8.5ms(400kHz); 传感→事件最坏 ≈ 10ms, 见 handoff 记录。
// 诊断:   i2c_err 任一字节从机 NACK 置位(粘滞, 复位清) —— 板级排错第一入口。
//
// 抗 X: 所有 FF 带复位值, 无未初始化存储器 —— ModelSim 直接可仿(坑册#1)。
//=============================================================================
module ads1115_if #(
    parameter integer TQ        = 31,        // SCL 四分之一周期 clk 数
    parameter [15:0]  CONV_WAIT = 16'd65000, // 单次转换等待 clk: 860SPS 1.16ms + 裕量 = 1.3ms
    parameter         I2C_ADDR  = 7'h48     // ADS1115 ADDR=GND
)(
    input  wire        clk,
    input  wire        rst_n,
    output reg         ch_valid,   // 1 拍: ch/ch_data 为刚扫完通道的结果
    output reg  [1:0]  ch,
    output reg  [15:0] ch_data,
    output reg         i2c_err,    // 粘滞 NACK 标志
    output reg         bus_bad,    // 1 拍: 本轮读数非法(0xFFFF / >0x7FFF), 已丢弃
    output wire        i2c_scl,
    inout  wire        i2c_sda
);

    //---------------------------------------------------------------- 命令集
    localparam [2:0] OP_START  = 3'd0,
                     OP_WR     = 3'd1,
                     OP_RDACK  = 3'd2,   // 读一字节, 第 9 位回 ACK(0)
                     OP_RDNACK = 3'd3,   // 读一字节, 第 9 位回 NACK(1) —— 末字节
                     OP_STOP   = 3'd4,
                     OP_WAIT   = 3'd5;

    //---------------------------------------------------------------- 步表
    // 一次通道扫描 = 配置写(启动转换) + 等待 + 指针写 + 重复起始读结果
    reg [3:0] step;
    reg [2:0] op;
    reg [7:0] wdata;
    reg [1:0] ch_q;          // 步表当前配置指向的通道

    wire [7:0] cfg_h  = {1'b1, 1'b1, ch_q, 3'b001, 1'b1};
    wire [7:0] cfg_l  = 8'hE3;
    wire [7:0] addr_w = {I2C_ADDR, 1'b0};
    wire [7:0] addr_r = {I2C_ADDR, 1'b1};

    always @(*) begin
        case (step)
            4'd1, 4'd8:  wdata = addr_w;
            4'd2:        wdata = 8'h01;   // 指针 -> 配置寄存器
            4'd3:        wdata = cfg_h;
            4'd4:        wdata = cfg_l;
            4'd9:        wdata = 8'h00;   // 指针 -> 转换结果寄存器
            4'd11:       wdata = addr_r;
            default:     wdata = 8'h00;
        endcase
    end

    always @(*) begin
        case (step)
            4'd0, 4'd7, 4'd10:      op = OP_START;   // 10 = 重复起始 Sr
            4'd1, 4'd2, 4'd3, 4'd4,
            4'd8, 4'd9, 4'd11:      op = OP_WR;
            4'd12:                  op = OP_RDACK;
            4'd13:                  op = OP_RDNACK;
            4'd5, 4'd14:            op = OP_STOP;
            4'd6:                   op = OP_WAIT;
            default:                op = OP_STOP;    // step15 不进引擎(本地消化)
        endcase
    end

    //---------------------------------------------------------------- 微序列器
    reg       op_en, op_done;
    reg [7:0] msb_q, lsb_q;
    reg       ack_nak;       // 写字节第 9 位采到 1 = NACK (位引擎写, 序列器读)
    reg [7:0] rx_byte;       // 位引擎最近读到的字节 (序列器收集)

    // ------------------------------------------------------------------------
    // 2026-10-15 修正 ——【幻影四音案】根因
    //   症状: 上电后什么都不按, 板子自己发出 C4/D4/E4/F4 四个满力度音。
    //   机理(逐行): ADS1115 模块未接 / FSR 分压未接 -> SDA 被上拉或浮空恒为 1 ->
    //     本模块 E_RD 相位每拍采到的都是 1 -> rx_byte=0xFF -> 拼出 ch_data=0xFFFF;
    //     而 ch_valid 在 step==15 是**无条件**发出的, NACK 只置粘滞标志、不中止事务;
    //     下游 fsr_key 按**无符号**比较: 65535 >= TH_ON(6000) -> 判定"按下" ->
    //     四通道各发一个 vel=127 的 note-on; 释放条件 ch_data<3000 永不满足 ->
    //     永不抬键 -> 四个音靠 per-partial 衰减慢慢变小, ADSR 停在 sustain 不归零。
    //   为什么 0xFFFF 是非法值: 本模块用的是单端 + PGA=001(±4.096V), 转换结果
    //     物理上只可能是 0..0x7FFF (3.3V 满量程约 26500 码)。0xFFFF 在二补数里
    //     是 −1, 只可能来自"总线沉默被读成全 1"。
    //   修法: 非法读数**不发 ch_valid**、ch_data 清 0(下游看到 0 = 无压力),
    //     并给一个**一次性** bus_bad 脉冲 —— 不用粘滞标志, 否则一次干扰会永久静音 FSR。
    // ------------------------------------------------------------------------
    wire [15:0] ch_data_raw = {msb_q, lsb_q};
    wire ch_data_bad = (ch_data_raw == 16'hFFFF) || (ch_data_raw > 16'h7FFF);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            step <= 4'd0; op_en <= 1'b0; ch_q <= 2'd0;
            ch_valid <= 1'b0; ch <= 2'd0; ch_data <= 16'd0;
            i2c_err <= 1'b0; msb_q <= 8'h00; lsb_q <= 8'h00;
            bus_bad <= 1'b0;
        end else begin
            ch_valid <= 1'b0;
            if (!op_en) begin
                if (step == 4'd15) begin
                    if (ch_data_bad) begin
                        ch_valid <= 1'b0;                        // 非法: 不报"有效"
                        ch_data  <= 16'd0;                       // 0 = 无压力
                        bus_bad  <= 1'b1;
                    end else begin
                        ch_valid <= 1'b1;
                        ch       <= ch_q;
                        ch_data  <= ch_data_raw;
                        bus_bad  <= 1'b0;
                    end
                    ch_q <= ch_q + 2'd1;
                    step <= 4'd0;
                end else begin
                    op_en <= 1'b1;
                end
            end else if (op_done) begin
                op_en <= 1'b0;
                if (op == OP_WR && ack_nak) i2c_err <= 1'b1; // 从机 NACK: 总线异常
                if (op == OP_RDACK)  msb_q <= rx_byte;
                if (op == OP_RDNACK) lsb_q <= rx_byte;
                step <= step + 4'd1;
            end
        end
    end

    //---------------------------------------------------------------- I2C 位引擎
    // 状态 × 相位(ph, 各 TQ clk) 译码出 SCL/SDA; 采样沿在 ph2 末(SCL 高中点)
    localparam [2:0] E_IDLE = 3'd0, E_START = 3'd1, E_WR = 3'd2,
                     E_RD   = 3'd3, E_STOP  = 3'd4, E_WAIT = 3'd5;

    reg [2:0]  est;
    reg [7:0]  qcnt;
    reg [1:0]  ph;
    reg [3:0]  bitn;         // 0..7 数据位, 8 = 应答位
    reg [7:0]  sh;
    reg        scl_hold;     // 起始~停止之间 SCL 空闲保持低(防伪 STOP)
    reg [15:0] wait_cnt;
    reg        op_en_d;      // op_en 打一拍: 只在上升沿启动 op (消握手竞态)

    wire       tick     = (qcnt == TQ-1);
    wire       sda_in   = i2c_sda;
    wire       op_start = op_en & ~op_en_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            est <= E_IDLE; qcnt <= 8'd0; ph <= 2'd0; bitn <= 4'd0; sh <= 8'h00;
            ack_nak <= 1'b0; op_done <= 1'b0; rx_byte <= 8'h00;
            scl_hold <= 1'b0; wait_cnt <= 16'd0; op_en_d <= 1'b0;
        end else begin
            op_done <= 1'b0;
            op_en_d <= op_en;
            if (est == E_IDLE) begin
                qcnt <= 8'd0; ph <= 2'd0; bitn <= 4'd0;
                if (op_start) begin
                    case (op)
                        OP_START:  est <= E_START;
                        OP_WR:     begin est <= E_WR; sh <= wdata; end
                        OP_RDACK,
                        OP_RDNACK: begin est <= E_RD; sh <= 8'h00; end
                        OP_STOP:   est <= E_STOP;
                        default:   begin est <= E_WAIT; wait_cnt <= CONV_WAIT; end
                    endcase
                end
            end else if (est == E_WAIT) begin
                if (wait_cnt == 16'd0) begin est <= E_IDLE; op_done <= 1'b1; end
                else wait_cnt <= wait_cnt - 16'd1;
            end else if (tick) begin
                qcnt <= 8'd0;
                case (est)
                E_START: begin
                    if (ph == 2'd2) begin
                        ph <= 2'd0; est <= E_IDLE; op_done <= 1'b1; scl_hold <= 1'b1;
                    end else ph <= ph + 2'd1;
                end
                E_WR: begin
                    if (ph == 2'd2 && bitn == 4'd8)
                        ack_nak <= sda_in;                    // SCL 高: 采从机应答
                    if (ph == 2'd3) begin
                        ph <= 2'd0;
                        if (bitn == 4'd8) begin est <= E_IDLE; op_done <= 1'b1; end
                        else begin bitn <= bitn + 4'd1; sh <= {sh[6:0], 1'b0}; end
                    end else ph <= ph + 2'd1;
                end
                E_RD: begin
                    if (ph == 2'd2 && bitn < 4'd8)
                        sh <= {sh[6:0], sda_in};              // SCL 高: 采从机数据
                    if (ph == 2'd3) begin
                        ph <= 2'd0;
                        if (bitn == 4'd8) begin est <= E_IDLE; op_done <= 1'b1; end
                        else begin
                            if (bitn == 4'd7) rx_byte <= sh;  // 第 8 位已随 ph2 入 sh, 整字节直取
                            bitn <= bitn + 4'd1;
                        end
                    end else ph <= ph + 2'd1;
                end
                E_STOP: begin
                    if (ph == 2'd3) begin
                        ph <= 2'd0; est <= E_IDLE; op_done <= 1'b1; scl_hold <= 1'b0;
                    end else ph <= ph + 2'd1;
                end
                default: est <= E_IDLE;
                endcase
            end else begin
                qcnt <= qcnt + 8'd1;
            end
        end
    end

    //---------------------------------------------------------------- 电平译码
    // SCL 推挽; SDA 开漏: oe=1 拉低, oe=0 释放(靠上拉读 1)
    reg scl_c, sda_oe_c;
    always @(*) begin
        scl_c = 1'b1; sda_oe_c = 1'b0;              // 默认: 总线空闲
        case (est)
            E_START: begin
                scl_c    = (ph != 2'd2);            // ph0/1 高, ph2 拉低收尾
                sda_oe_c = (ph == 2'd1);            // ph1 拉低 = 起始条件
            end
            E_WR: begin
                scl_c    = (ph == 2'd1 || ph == 2'd2);
                sda_oe_c = (bitn < 4'd8) && !sh[7]; // 数据 0 拉低, 1 释放
            end
            E_RD: begin
                scl_c    = (ph == 2'd1 || ph == 2'd2);
                sda_oe_c = (bitn == 4'd8) && (op == OP_RDACK); // 第 9 位回 ACK
            end
            E_STOP: begin
                scl_c    = (ph != 2'd0);            // ph0 低, 之后拉高
                sda_oe_c = (ph == 2'd0 || ph == 2'd1); // SDA 低 -> 释放 = 停止条件
            end
            E_WAIT:  scl_c = 1'b1;                  // 等转换, 总线放空
            default: scl_c = ~scl_hold;             // E_IDLE: 事务中保持 SCL 低
        endcase
    end

    assign i2c_scl = scl_c;
    assign i2c_sda = sda_oe_c ? 1'b0 : 1'bz;

endmodule
