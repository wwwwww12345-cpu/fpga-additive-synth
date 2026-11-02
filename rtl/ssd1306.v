// ssd1306.v -- 128x64 OLED (SSD1306 / SH1106 兼容) 页地址模式驱动
//   上电初始化 20 字节命令，然后循环整屏: 每页 B0+p / 列低 / 列高 + 128 字节数据
//   COL_OFF: SH1106 = 2, SSD1306 = 0（1.3" 模块常见 SH1106，默认 2）
module ssd1306 #(
    parameter COL_OFF = 2,
    parameter SH1106 = 0          // 1 = SH1106 (0xAD 0x8B 开 DC-DC), 0 = SSD1306 (0x8D 0x14)
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] fb_rdata,
    output reg  [9:0] fb_raddr,
    output reg        spi_start,
    output reg  [7:0] spi_data,
    output reg        dc,
    output reg        cs_n,
    input  wire       spi_busy,
    input  wire       spi_done,
    output reg        init_done
);
    // 初始化命令（全 dc=0）
    function [7:0] init_cmd(input [4:0] i);
        case (i)
            5'd0:  init_cmd = 8'hAE;   // display off
            5'd1:  init_cmd = 8'hD5;   // clock div
            5'd2:  init_cmd = 8'h80;
            5'd3:  init_cmd = 8'hA8;   // multiplex 64
            5'd4:  init_cmd = 8'h3F;
            5'd5:  init_cmd = 8'hD3;   // display offset 0
            5'd6:  init_cmd = 8'h00;
            5'd7:  init_cmd = 8'h40;   // start line 0
            5'd8:  init_cmd = SH1106 ? 8'hAD : 8'h8D;
            5'd9:  init_cmd = SH1106 ? 8'h8B : 8'h14;
            5'd10: init_cmd = 8'hA1;   // segment remap
            5'd11: init_cmd = 8'hC8;   // COM scan dec
            5'd12: init_cmd = 8'hDA;   // COM pins
            5'd13: init_cmd = 8'h12;
            5'd14: init_cmd = 8'h81;   // contrast
            5'd15: init_cmd = 8'hCF;
            5'd16: init_cmd = 8'hD9;   // precharge
            5'd17: init_cmd = 8'hF1;
            5'd18: init_cmd = 8'hDB;   // VCOMH
            5'd19: init_cmd = 8'h40;
            5'd20: init_cmd = 8'hA4;   // resume from RAM
            5'd21: init_cmd = 8'hA6;   // normal
            5'd22: init_cmd = 8'hAF;   // display on
            default: init_cmd = 8'hE3; // NOP
        endcase
    endfunction
    localparam N_INIT = 23;

    localparam [3:0] S_IDLE = 4'd0, S_INIT = 4'd1, S_INIT_WAIT = 4'd2,
                     S_CMD = 4'd3, S_CMD_WAIT = 4'd4, S_DATA = 4'd5,
                     S_DATA_LAT = 4'd6, S_DATA_SEND = 4'd9,
                     S_DATA_WAIT = 4'd7, S_NEXT = 4'd8;

    reg [3:0]  st;
    reg [4:0]  idx;
    reg [2:0]  page;
    reg [7:0]  col;
    reg [1:0]  sub;
    reg [7:0]  data_lat;
    reg        start_d;

    // 命令字节（页 / 列）
    reg [7:0] cmd_byte;
    always @* begin
        case (sub)
            2'd0: cmd_byte = 8'hB0 | {5'd0, page};
            2'd1: cmd_byte = 8'h00 | ((col + COL_OFF[7:0]) & 8'h0F);
            default: cmd_byte = 8'h10 | (((col + COL_OFF[7:0]) >> 4) & 8'h0F);  // SH1106 needs 0x08 for col 128..129
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; idx <= 0; page <= 0; col <= 0; sub <= 0;
            spi_start <= 0; spi_data <= 0; dc <= 0; cs_n <= 0;
            fb_raddr <= 0; init_done <= 0; data_lat <= 0; start_d <= 0;
        end else begin
            spi_start <= 1'b0;
            start_d <= spi_start;
            case (st)
            S_IDLE: begin
                idx <= 0; page <= 0; col <= 0; sub <= 0; init_done <= 0;
                st <= S_INIT;
            end

            S_INIT: begin
                if (!spi_busy) begin
                    if (idx < N_INIT) begin
                        spi_data <= init_cmd(idx);
                        dc <= 1'b0;
                        spi_start <= 1'b1;
                        st <= S_INIT_WAIT;
                    end else begin
                        init_done <= 1'b1;
                        sub <= 0;
                        st <= S_CMD;
                    end
                end
            end

            // 每字节统一等待: 用 spi_done 推进
            S_INIT_WAIT: begin
                if (spi_done) begin idx <= idx + 1'b1; st <= S_INIT; end
            end

            S_CMD: begin
                if (!spi_busy) begin
                    spi_data <= cmd_byte;
                    dc <= 1'b0;
                    spi_start <= 1'b1;
                    st <= S_CMD_WAIT;
                end
            end
            S_CMD_WAIT: begin
                if (spi_done) begin
                    if (sub == 2'd2) begin sub <= 0; st <= S_DATA; end
                    else begin sub <= sub + 1'b1; st <= S_CMD; end
                end
            end

            S_DATA: begin
                if (!spi_busy) begin
                    fb_raddr <= {page, col[6:0]};
                    sub <= 2'd1;
                    st <= S_DATA_LAT;
                end
            end
            S_DATA_LAT: begin
                // 多等一拍: 同步读的 rdata 在下个上升沿才有效
                st <= S_DATA_SEND;
            end
            S_DATA_SEND: begin
                data_lat <= fb_rdata;
                spi_data <= fb_rdata;
                dc <= 1'b1;
                spi_start <= 1'b1;
                st <= S_DATA_WAIT;
            end
            S_DATA_WAIT: begin
                if (spi_done) begin
                    st <= S_NEXT;
                end
            end
            S_NEXT: begin
                if (col == 8'd127) begin
                    col <= 8'd0;
                    page <= (page == 3'd7) ? 3'd0 : (page + 1'b1);
                    sub <= 2'd0;
                    st <= S_CMD;
                end else begin
                    col <= col + 1'b1;
                    st <= S_DATA;
                end
            end

            default: st <= S_IDLE;
            endcase
        end
    end
    `ifndef SYNTHESIS
    // 仅供仿真: 额外状态
    `endif
endmodule
