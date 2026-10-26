`timescale 1ns/1ps
// Timing/area probe, NOT a board/audio top. Real UART pins keep RX logic
// observable; synthetic consumers/backend exercise the communication endpoint.
module comm_probe (
    input logic clk, rst_n,
    input logic [1:0] rx_i,
    input logic state_async,
    output logic [1:0] tx_o,
    output logic led
);
    logic [31:0] lfsr;
    logic ev_valid, ev_source, parse_error;
    logic [31:0] ev_data;
    logic cfg_valid, cfg_ready, cfg_source, cfg_done_valid, cfg_done_ready;
    logic [15:0] cfg_seq;
    logic [7:0] cfg_command, cfg_result;
    logic [4:0] cfg_len;
    logic [127:0] cfg_shadow;
    logic [1:0] quarantine, pending;
    logic [15:0] errors;
    logic [63:0] error_count;
    logic [31:0] event_sig, config_sig[0:3];
    logic [2:0] backend_delay;
    logic backend_pending;
    assign cfg_ready = !backend_pending;
    assign cfg_done_valid = backend_pending && backend_delay == 0;
    comm_top #(.BT_HAS_STATE(1'b1)) u_comm (
        .clk(clk),.rst_n(rst_n),.rx_i(rx_i),.tx_o(tx_o),.hc05_state_async(state_async),
        .session_restart({2{&lfsr[11:0]}}),.source_cleanup_done(2'b11),
        .source_ops_idle(2'b11),.midi_ops_idle(1'b1),
        .source_quarantine(quarantine),.link_fault_pending(pending),
        .error_sticky(errors),.rx_error_count(error_count),
        .event_valid(ev_valid),.event_ready(lfsr[0]),.event_data(ev_data),
        .event_source_id(ev_source),.midi_parse_error(parse_error),
        .cfg_valid(cfg_valid),.cfg_ready(cfg_ready),.cfg_source_id(cfg_source),
        .cfg_seq(cfg_seq),.cfg_command(cfg_command),.cfg_payload_len(cfg_len),.cfg_shadow(cfg_shadow),
        .cfg_done_valid(cfg_done_valid),.cfg_done_ready(cfg_done_ready),.cfg_result(cfg_result)
    );
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            lfsr<=32'h1234abcd;event_sig<=0;backend_pending<=0;backend_delay<=0;
            cfg_result<=0;led<=0;
            for(int i=0;i<4;i++) config_sig[i]<=0;
        end else begin
            lfsr<={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
            if(ev_valid&&lfsr[0]) event_sig<=event_sig^ev_data^{31'd0,ev_source};
            if(cfg_valid&&cfg_ready) begin
                backend_pending<=1;backend_delay<=3;
                cfg_result<=lfsr[2:0]==7 ? 8'd6 : {5'd0,lfsr[2:0]};
                for(int i=0;i<4;i++) config_sig[i]<=config_sig[i]^cfg_shadow[i*32+:32];
                event_sig<=event_sig^{cfg_seq,cfg_command,2'd0,cfg_len,cfg_source};
            end else if(backend_pending) begin
                if(backend_delay!=0) backend_delay<=backend_delay-1'b1;
                else if(cfg_done_valid&&cfg_done_ready) backend_pending<=0;
            end
            led<=^event_sig ^ ^config_sig[0] ^ ^config_sig[1] ^ ^config_sig[2] ^ ^config_sig[3] ^
                 ^errors ^ ^error_count ^ ^pending ^ ^quarantine ^ parse_error;
        end
    end
endmodule
