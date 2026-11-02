//=============================================================================
// song_ram.v —— 曲谱存储 512 × 24bit (note/vel/dur)
//
// 24bit 字: {note[6:0], vel[6:0], dur[6:0], 2'b00}
//   note=0 → 休止符;  dur 单位 10ms (1..127)
// 512×24 = 12Kb, Gowin 推断为 1 个 BSRAM。
// 写口只在 0x90~0x92 期间由 ble_cmd 驱动; 演奏期间禁止改写(ble_cmd 保证)。
//=============================================================================
`timescale 1ns/1ps

module song_ram (
    input  wire        clk,
    input  wire        we,
    input  wire [8:0]  waddr,
    input  wire [23:0] wdata,
    input  wire [8:0]  raddr,
    output reg  [23:0] rdata
);
    reg [23:0] mem [0:511];

    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end
endmodule
