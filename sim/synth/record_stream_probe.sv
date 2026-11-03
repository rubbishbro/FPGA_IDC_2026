`timescale 1ns/1ps
// Production communication endpoint; synthetic descriptor producer only.
// Combinational descriptor wiring deliberately matches instrument_system.
module record_stream_probe(
    input wire clk,rst_n,trigger,permit,
    input wire [15:0] seq,
    input wire [191:0] payload,
    output wire ready,
    output wire [1:0] tx
);
    wire descriptor_valid=trigger && permit;
    wire [191:0] descriptor_payload=payload ^ 192'd0;
    comm_top #(.CLK_HZ(50_000_000),.WIRED_BAUD(1_000_000),.BT_BAUD(9600)) dut(
        .clk(clk),.rst_n(rst_n),.rx_i(2'b11),.tx_o(tx),.hc05_state_async(1'b0),
        .session_restart(2'b0),.source_cleanup_done(2'b11),.source_ops_idle(2'b11),.midi_ops_idle(1'b1),
        .event_ready(1'b1),.cfg_ready(1'b1),.cfg_done_valid(1'b0),.cfg_result(8'd0),
        .perf_valid(descriptor_valid),.perf_ready(ready),.perf_seq(seq),.perf_payload(descriptor_payload));
endmodule
