`define idle 0
`define confirming 1
`define receiving 2
`define stopwait 3
`define baud_div 50000000/115200
module UART_Receiver(rx, clk, rst_n, receive_data, rx_done);
    input rx;
    input clk;
    input rst_n;
    output reg rx_done;
    output reg[7:0]receive_data;
    reg rx1,rx2;
    reg [15:0]clk_cnt;
    reg [1:0]state;
    reg [3:0]bitn;                 // renamed from `bit` (SV keyword, breaks Gowin sysv2017)
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            // restructured for Gowin (EX3534): assignments under both clock edges
            // in one always are rejected; behavior identical to the original.
            clk_cnt<=0;
            bitn<=0;
            state<=`idle;
            rx1<=1;
            rx2<=1;
            rx_done<=0;
        end
        else begin
            rx1<=rx;
            rx2<=rx1;
            rx_done<=0;
            case(state)
                `idle:if(!rx2)begin
                    clk_cnt<=0;
                    bitn<=0;
                    state<=`confirming;
                end
                `confirming:if(clk_cnt<`baud_div/2)begin
                    clk_cnt<=clk_cnt+1;
                end
                else if(clk_cnt==`baud_div/2)begin
                    if(rx2==0)begin
                        clk_cnt<=0;
                        state<=`receiving;
                    end
                    else begin
                        clk_cnt<=0;
                        state<=`idle;
                    end
                end
                `receiving:if(clk_cnt==`baud_div-1)begin
                    clk_cnt<=0;
                    if(bitn<8)begin
                        receive_data[bitn]<=rx2;
                        bitn<=bitn+1;
                    end
                    else if(bitn==8)begin
                        bitn<=0;
                        rx_done<=1;
                        state<=`stopwait;   // FIX: 原来回 idle, 在停止位中点线上仍为低,
                    end                     // 会被误判成新起始位 -> 背靠背字节全部错帧
                end
                else if(clk_cnt!=`baud_div-1)begin
                    clk_cnt<=clk_cnt+1;
                end
                `stopwait:if(rx2)begin      // 等线回高(停止位真正结束)才重新武装检测
                    state<=`idle;
                end
                default :begin 
                    state<=`idle;
                end
            endcase
        end
    end
endmodule