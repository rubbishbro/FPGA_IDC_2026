// -----------------------------------------------------------------------------
// dry_wet_mix.sv -- 归一化 dry/wet 混合
// gd/gw 为 UQ1.15，要求 gd + gw = 32768（1.0）。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module dry_wet_mix (
    input  logic clk, rst_n,
    input  logic in_valid,
    input  logic signed [63:0] dry,
    input  logic signed [63:0] wet,
    input  logic [15:0] gd,
    input  logic [15:0] gw,
    output logic out_valid,
    output logic signed [63:0] out_data
);
    logic signed [79:0] pd, pw, sum, rounded;
    logic signed [63:0] sat;

    always_comb begin
        pd = $signed(dry) * $signed({1'b0, gd});
        pw = $signed(wet) * $signed({1'b0, gw});
        sum = pd + pw;
        rounded = (sum + 80'sd16384) >>> 15;
        if (rounded > 80'sd9223372036854775807)      sat = 64'sh7FFFFFFFFFFFFFFF;
        else if (rounded < -80'sd9223372036854775808) sat = 64'sh8000000000000000;
        else                                          sat = rounded[63:0];
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin out_valid <= 1'b0; out_data <= 64'sd0; end
        else begin out_valid <= in_valid; if (in_valid) out_data <= sat; end
    end
endmodule
