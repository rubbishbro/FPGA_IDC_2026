// -----------------------------------------------------------------------------
// seed_rom.sv -- C 的 64-bit seed 只读表
// 地址布局由 router 决定：piece*192 + variant*48 + mode（具体参数在外部）。
// 同步读 1 拍；不提供写口。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module seed_rom #(
    parameter int DEPTH = 1152,
    parameter int AW    = (DEPTH < 2) ? 1 : $clog2(DEPTH),
    parameter     FILE  = ""
) (
    input  logic          clk,
    input  logic [AW-1:0] addr,
    output logic [63:0]   data
);

    logic [63:0] mem [0:DEPTH-1];

    initial begin
        if (FILE != "") $readmemh(FILE, mem);
    end

    always_ff @(posedge clk)
        data <= mem[addr];

endmodule
