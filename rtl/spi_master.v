// spi_master.v -- 8 bit SPI, mode 0 (CPOL=0, CPHA=0), DIV 分频
//   每位 3 个 DIV 段: 置 MOSI -> SCK 高 -> SCK 低并移位
//   50 MHz / DIV=3 -> SCK ≈ 8.3 MHz
module spi_master #(
    parameter DIV = 3
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,      // 单拍启动
    input  wire [7:0] din,
    output reg        sck,
    output reg        mosi,
    output reg        busy,
    output reg        done        // 发完一拍脉冲
);
    reg [7:0]  sh;
    reg [3:0]  bit_i;
    reg [1:0]  ph;
    reg [15:0] tick;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sck <= 0; mosi <= 0; busy <= 0; done <= 0;
            sh <= 0; bit_i <= 0; ph <= 0; tick <= 0;
        end else begin
            done <= 1'b0;
            if (!busy) begin
                if (start) begin
                    sh <= din; bit_i <= 0; ph <= 0; tick <= 0;
                    sck <= 0; mosi <= din[7]; busy <= 1'b1;
                end
            end else begin
                if (tick == DIV - 1) begin
                    tick <= 0;
                    case (ph)
                    2'd0: begin sck <= 1'b1; ph <= 2'd1; end
                    2'd1: begin sck <= 1'b0; ph <= 2'd2; end
                    default: begin
                        sh <= {sh[6:0], 1'b0};
                        if (bit_i == 4'd7) begin busy <= 1'b0; done <= 1'b1; end
                        else begin bit_i <= bit_i + 1'b1; mosi <= sh[6]; ph <= 2'd0; end
                    end
                    endcase
                end else tick <= tick + 1'b1;
            end
        end
    end
endmodule
