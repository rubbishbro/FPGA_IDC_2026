// TEST ONLY: adapter for the exact isolated Gowin body netlist port names.
// The global reset primitive is from the UNMODIFIED vendor GW5A library.
// The isolated synthesis harness tied clear_valid=0; in_ready and clear_ready
// became the same output and coeff_error was constant-folded to 0. This adapter
// reconstructs those observed connections, NOT a replacement arithmetic/ROM.
// Accordingly this netlist test does NOT verify clear or bad-ROM rejection.
`timescale 1ns/1ps
module body_netlist_review_top (
    input logic clk, rst_n, clear_valid, in_valid,
    input logic signed [63:0] in_sum,
    output wire clear_ready, in_ready, out_valid,
    output wire signed [63:0] out_sum,
    output wire [3:0] out_sat,
    output wire [2:0] sat_count,
    output wire coeff_ready, coeff_error
);
    GSR GSR (.GSRI(1'b1));
    wire reset_high;
    INV reset_inv (.I(rst_n), .O(reset_high));
    assign in_ready = clear_ready;
    assign coeff_error = 1'b0;
    body_filter u_body (
        .clk_d(clk), .n218_6(reset_high), .rst_n_d(rst_n),
        .in_valid(in_valid), .lfsr(in_sum), .clear_ready_Z(clear_ready),
        .out_valid_Z(out_valid), .out_sum_Z(out_sum),
        .out_sat_Z(out_sat), .sat_count_Z(sat_count), .coeff_ready_Z(coeff_ready)
    );
endmodule
