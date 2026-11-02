`timescale 1ns/1ps
//=============================================================================
// tb_fsr_key.v —— fsr_key + ads1115_if 端到端仿真 (含 ADS1115 行为模型)
//
// BFM: I2C 从机(地址 0x48) + 寄存器/单次转换行为, 电压->码值按 PGA ±4.096V。
// 激励直接改 volt[] 模拟 FSR402 分压电压(0=不按, 3.3V=重按)。
//
// 覆盖 (对应简报验收标准 1):
//   T1 空闲基线            —— 无伪事件
//   T2 单键按/松           —— note=60 on=1/0, vel 与码值一致
//   T3 双键重叠+交叉松开   —— 各通道独立, 事件序正确
//   T4 背压挂起            —— key_ready=0 期间不发 key_we, 释放后补发
//   T5 毛刺                —— 一次越阈(<CONFIRM 次采样)不产生事件
//   T6 重按力度            —— 3.3V -> vel=103, 钳位 [1,127] 正确
//
// 时序真实(未加速): I2C 400kHz + 1.3ms 转换等待, 4 通道一轮 ≈ 6.1ms。
// 全程约 120ms 仿真时间, ModelSim -c 数分钟内跑完。
//=============================================================================
module tb_fsr_key;

    //---------------------------------------------------------------- 时钟/复位
    reg clk = 1'b0;
    always #10 clk = ~clk;                 // 50MHz
    reg rst_n = 1'b0;

    //---------------------------------------------------------------- DUT
    reg  key_ready = 1'b1;
    wire key_we;
    wire [6:0] key_note, key_vel;
    wire key_on;
    wire i2c_scl;
    wire i2c_sda;
    wire i2c_err;

    fsr_key #(.TQ(31)) u_dut (
        .clk(clk), .rst_n(rst_n), .key_ready(key_ready),
        .key_we(key_we), .key_note(key_note), .key_on(key_on), .key_vel(key_vel),
        .i2c_scl(i2c_scl), .i2c_sda(i2c_sda), .i2c_err(i2c_err),
        .dbg_ch(), .dbg_data(), .ev_drop());

    pullup(i2c_sda);                       // 总线弱上拉(板上由 ADS1115 模块提供)

    //---------------------------------------------------------------- 激励: FSR 分压
    real volt[0:3];
    task press(input integer c, input real v);
        begin volt[c] = v; end
    endtask

    //---------------------------------------------------------------- 事件捕获
    reg [6:0] q_note[0:63];
    reg       q_on  [0:63];
    reg [6:0] q_vel [0:63];
    integer   qn = 0;

    always @(posedge clk) begin
        if (key_we) begin
            q_note[qn] <= key_note; q_on[qn] <= key_on; q_vel[qn] <= key_vel;
            $display("[%0t] EVT#%0d note=%0d on=%b vel=%0d",
                     $time, qn, key_note, key_on, key_vel);
            qn <= qn + 1;
        end
    end

    //---------------------------------------------------------------- 记分板
    integer errs = 0;

    function [6:0] exp_vel(input real v);      // 与 DUT 同式: 码值>>8 钳位
        integer c; reg [7:0] v8;
        begin
            c = $rtoi(v / 4.096 * 32767.0);
            if (c < 0) c = 0;
            if (c > 65535) c = 65535;
            v8 = c[15:8];
            if (v8 == 0)      exp_vel = 7'd1;
            else if (v8[7])   exp_vel = 7'd127;
            else              exp_vel = v8[6:0];
        end
    endfunction

    task wait_qn(input integer target, input integer timeout_ms);
        integer t0;
        begin
            t0 = $time;
            while (qn < target && ($time - t0) < timeout_ms * 1000000)
                @(posedge clk);
        end
    endtask

    task chk(input integer idx, input [6:0] enote, input eon, input [6:0] evel);
        begin
            if (qn <= idx) begin
                $display("FAIL: event#%0d missing (qn=%0d)", idx, qn);
                errs = errs + 1;
            end else if (q_note[idx] !== enote || q_on[idx] !== eon ||
                         q_vel[idx]  !== evel) begin
                $display("FAIL: event#%0d exp note=%0d on=%b vel=%0d, got note=%0d on=%b vel=%0d",
                         idx, enote, eon, evel, q_note[idx], q_on[idx], q_vel[idx]);
                errs = errs + 1;
            end else begin
                $display("PASS: event#%0d note=%0d on=%b vel=%0d", idx, enote, eon, evel);
            end
        end
    endtask

    task chk_no_event(input integer expect_qn);
        begin
            if (qn !== expect_qn) begin
                $display("FAIL: extra events (qn=%0d exp=%0d)", qn, expect_qn);
                errs = errs + 1;
            end else
                $display("PASS: no extra events");
        end
    endtask

    //---------------------------------------------------------------- ADS1115 行为模型
    // 寄存器/转换
    reg [7:0]  ptr_reg   = 8'h00;
    reg [7:0]  cfg_hi    = 8'h85;          // 上电默认 0x8583
    reg [15:0] conv_reg  = 16'h0000;
    reg        conv_busy = 1'b0;
    reg [1:0]  conv_mux  = 2'd0;
    reg [15:0] conv_cnt  = 16'd0;
    localparam integer CONV_CLKS = 58000;  // 860SPS ≈ 1.16ms

    // 电压->码值 (PGA ±4.096V, FSR 只会出正压)
    function [15:0] v2c(input real v);
        real c;
        begin
            c = v / 4.096 * 32767.0;
            if (c >= 32767.0) v2c = 16'h7FFF;
            else if (c <= 0.0) v2c = 16'h0000;
            else               v2c = $rtoi(c);
        end
    endfunction

    // 转换计时
    always @(posedge clk) begin
        if (conv_busy) begin
            if (conv_cnt <= 16'd1) begin
                conv_busy <= 1'b0;
                conv_reg  <= v2c(volt[conv_mux]);   // 用转换启动时的通道电压
            end else conv_cnt <= conv_cnt - 16'd1;
        end
    end

    // I2C 从机状态
    reg        m_active = 1'b0, m_rw = 1'b0, reading = 1'b0;
    reg [3:0]  nbit = 4'd0;                 // 4 位: 3 位时 3'd8 截断成 0 的坑
    reg [1:0]  bpos = 2'd0;                 // 0=地址, 1=指针, 2=cfgH, 3=cfgL
    reg [7:0]  rx = 8'h00;
    reg [15:0] tx = 16'h0000;
    reg [4:0]  nc = 5'd0;                  // 读期间 SCL 下降沿计数(声明须在使用前)
    reg        sdrv = 1'b1;                 // 0=拉低 SDA, 1=释放(开漏)
    assign i2c_sda = sdrv ? 1'bz : 1'b0;   // 从机侧开漏驱动

    // ACK 预判: 应答槽开始的下降沿处 rx 已锁存完整字节, 直接判
    // (地址字节: 匹配 0x48 才 ACK; 写数据字节: 总 ACK; 读数据字节: 主机回 ACK)
    wire       will_ack = (bpos == 2'd0) ? (rx[7:1] == 7'h48) : !m_rw;

    // START / STOP 检测: SCL 高电平期间的 SDA 跳变
    always @(negedge i2c_sda) begin
        if (i2c_scl === 1'b1) begin
            m_active <= 1'b1; m_rw <= 1'b0; bpos <= 2'd0; nbit <= 4'd0;
            sdrv <= 1'b1; nc <= 5'd0; reading <= 1'b0;
        end
    end
    always @(posedge i2c_sda) begin
        if (i2c_scl === 1'b1) begin
            m_active <= 1'b0; sdrv <= 1'b1; reading <= 1'b0;
        end
    end

    // 写字节处理
    task bfm_write(input [7:0] b);
        begin
            if (bpos == 2'd1)      begin ptr_reg <= b; bpos <= 2'd2; end
            else if (bpos == 2'd2) begin cfg_hi  <= b; bpos <= 2'd3; end
            else begin
                if (cfg_hi[7]) begin               // OS=1: 启动单次转换
                    conv_busy <= 1'b1;
                    conv_mux  <= cfg_hi[5:4];
                    conv_cnt  <= CONV_CLKS;
                end
                bpos <= 2'd1;
            end
        end
    endtask

    // 主机数据在 SCL 上升沿采样
    always @(posedge i2c_scl) begin
        if (m_active && !reading) begin
            if (nbit < 4'd8) begin
                rx   <= {rx[6:0], i2c_sda};
                nbit <= nbit + 4'd1;
            end else begin
                nbit <= 4'd0;
                if (bpos == 2'd0) begin
                    if (rx[7:1] == 7'h48) begin
                        bpos <= 2'd1;
                        m_rw <= rx[0];
                        if (rx[0]) begin           // 读传输: 备好发送数据
                            reading <= 1'b1;
                            tx <= (ptr_reg == 8'h00) ? conv_reg : 16'hxxxx;
                            nc <= 5'd0;
                        end
                    end else begin                 // 地址不符
                        m_active <= 1'b0;
                    end
                end else if (!m_rw) begin
                    bfm_write(rx);
                end
            end
        end
    end

    // 从机在 SCL 下降沿换位
    // 读时序: 每个 9 位槽 = 8 数据位 + 1 应答槽; 应答槽(negedge 计数 nc=8/17)必须
    // 释放 SDA 让主机回 ACK/NACK, 否则第二字节错位
    integer bidx;
    always @(negedge i2c_scl) begin
        if (m_active && !reading) begin
            if (nbit == 4'd8) sdrv <= will_ack ? 1'b0 : 1'b1;   // 应答位
            else              sdrv <= 1'b1;                     // 数据位间释放
        end else if (m_active && reading) begin
            if (nc == 5'd17) begin                // 末字节应答槽结束: 读毕
                sdrv    <= 1'b1;
                reading <= 1'b0;
            end else if (nc == 5'd8) begin
                sdrv <= 1'b1;                     // 应答槽: 释放
            end else begin
                bidx  = (nc < 5'd8) ? nc : nc - 5'd9;   // 跨过第一个应答槽
                sdrv <= (nc < 5'd8) ? tx[15 - bidx]    // 字节1: tx[15:8]
                                    : tx[7 - bidx]     // 字节2: tx[7:0]
                     ? 1'b1 : 1'b0;
            end
            nc <= nc + 5'd1;
        end
    end

    //---------------------------------------------------------------- 测试序列
    initial begin
        volt[0] = 0.0; volt[1] = 0.0; volt[2] = 0.0; volt[3] = 0.0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;

        $display("=== T1: idle baseline (10ms, no events) ===");
        #10_000_000;
        chk_no_event(0);

        $display("=== T2: single key press/release (ch0, 2.0V) ===");
        press(0, 2.0);                          // 16000 码 -> vel=62
        wait_qn(1, 20);
        chk(0, 7'd60, 1'b1, exp_vel(2.0));
        #2_000_000;
        press(0, 0.05);                         // 松开
        wait_qn(2, 20);
        chk(1, 7'd60, 1'b0, 7'd0);
        #2_000_000;

        $display("=== T3: two-key overlap + cross release ===");
        press(1, 3.0);                          // ch1: note62, vel=93
        wait_qn(3, 20);
        chk(2, 7'd62, 1'b1, exp_vel(3.0));
        press(0, 1.5);                          // ch0 叠上: note60, vel=46
        wait_qn(4, 20);
        chk(3, 7'd60, 1'b1, exp_vel(1.5));
        press(0, 0.02);                         // ch0 松开, ch1 仍按着
        wait_qn(5, 20);
        chk(4, 7'd60, 1'b0, 7'd0);
        press(1, 0.02);                         // ch1 松开
        wait_qn(6, 20);
        chk(5, 7'd62, 1'b0, 7'd0);
        #2_000_000;

        $display("=== T4: backpressure (ready=0, event queued) ===");
        key_ready = 1'b0;
        press(2, 2.5);                          // ch2: note64, vel=78
        #12_000_000;                            // 12ms: 事件早已入 FIFO
        chk_no_event(6);
        key_ready = 1'b1;
        wait_qn(7, 20);
        chk(6, 7'd64, 1'b1, exp_vel(2.5));
        press(2, 0.02);                         // 复位 ch2 状态
        wait_qn(8, 20);
        chk(7, 7'd64, 1'b0, 7'd0);
        #2_000_000;

        $display("=== T5: glitch (3ms blip < 2 samples, no event) ===");
        press(3, 1.5);
        #3_000_000;
        press(3, 0.02);
        #16_000_000;
        chk_no_event(8);

        $display("=== T6: hard press (ch3, 3.3V -> vel=103) ===");
        press(3, 3.3);
        wait_qn(9, 20);
        chk(8, 7'd66, 1'b1, exp_vel(3.3));
        press(3, 0.02);
        wait_qn(10, 20);
        chk(9, 7'd66, 1'b0, 7'd0);

        // 收尾
        #10_000_000;
        if (i2c_err) begin
            $display("FAIL: i2c_err set (NACK seen)");
            errs = errs + 1;
        end else
            $display("PASS: no I2C NACK");

        if (errs == 0) $display("==== ALL PASS (10 checks) ====");
        else           $display("==== FAILED: %0d checks ====", errs);
        $finish;
    end

    //---------------------------------------------------------------- 看门狗
    initial begin
        #250_000_000;                           // 250ms 上限
        $display("FAIL: watchdog timeout, qn=%0d", qn);
        $finish;
    end


endmodule
