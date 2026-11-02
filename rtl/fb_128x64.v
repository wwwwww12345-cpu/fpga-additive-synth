// fb_128x64.v -- 1 KB 帧存（128x64，按页：addr = {page[2:0], col[6:0]}）
//   A 口：读-改-写（图形侧；李萨如散点需要"先读、或上像素、再写"）
//   B 口：只读（ssd1306 整屏连续刷新）
//
// 综合实测（Gowin GW5A-25A）：本模块吃 2 块 BSRAM、0 LUT、0 DSP；
// 曾试过"拆成两块单写单读 RAM"，资源一模一样（也是 2 块），所以保留这块更简单的写法。
// 踩过的坑: 综合包装里若把 raddr_b 直接接到 waddr（读写永远同址），Gowin 会报
//   PA2122 Not support 'mem'(DPB) WRITE_MODE0 = 2'b10
// 真实设计里 raddr_b 来自 ssd1306 的扫描地址，与写地址无关，不会触发。
module fb_128x64 (
    input  wire       clk,
    input  wire       we,        // A 口写使能
    input  wire [9:0] waddr,
    input  wire [7:0] wdata,
    input  wire [9:0] raddr_a,   // A 口读地址（图形侧读-改-写）
    output reg  [7:0] rdata_a,
    input  wire [9:0] raddr_b,   // B 口读地址（ssd1306）
    output reg  [7:0] rdata_b
);
    reg [7:0] mem [0:1023];
    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata_a <= mem[raddr_a];
        rdata_b <= mem[raddr_b];
    end
endmodule
