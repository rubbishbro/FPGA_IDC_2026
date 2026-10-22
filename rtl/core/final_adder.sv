// -----------------------------------------------------------------------------
// final_adder.sv -- 多 bus 最终求和（饱和）
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module final_adder #(parameter int N = 2) (
    input  logic clk, rst_n,
    input  logic in_valid,
    input  logic signed [N*64-1:0] in_bus,
    output logic out_valid,
    output logic signed [63:0] out_data
);
    logic signed [79:0] acc;
    logic signed [63:0] sat;
    integer i;
    always_comb begin
        acc = 80'sd0;
        for (i = 0; i < N; i = i + 1)
            acc = acc + $signed(in_bus[i*64 +: 64]);
        if (acc > 80'sd9223372036854775807)      sat = 64'sh7FFFFFFFFFFFFFFF;
        else if (acc < -80'sd9223372036854775808) sat = 64'sh8000000000000000;
        else                                      sat = acc[63:0];
    end
    always_ff @(posedge clk) begin
        if (!rst_n) begin out_valid <= 1'b0; out_data <= 64'sd0; end
        else begin out_valid <= in_valid; if (in_valid) out_data <= sat; end
    end
endmodule
