`timescale 1ns/1ps
// Real parser -> note state -> delayed mock consumer. The mock acknowledges
// operations, not real voice_router sampling; this is not an audio test.
module tb_midi_note_pipeline;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    logic s_valid = 0, s_ready, s_first = 0, s_last = 0;
    logic [7:0] s_data = 0;
    logic event_valid, event_ready, event_source_id, frame_done, parse_error, busy;
    logic [31:0] event_data;
    logic op_valid, op_ready = 0;
    logic [15:0] gate, retrigger;
    logic [111:0] velocity;
    integer delay_count = 0, accepted = 0, retired = 0;
    midi_analyzer parser (
        .clk(clk), .rst_n(rst_n), .flush(1'b0),
        .s_valid(s_valid), .s_ready(s_ready), .s_data(s_data),
        .s_first(s_first), .s_last(s_last), .s_source_id(1'b1), .s_payload_len(6'd5),
        .event_valid(event_valid), .event_ready(event_ready), .event_data(event_data),
        .event_source_id(event_source_id), .frame_done(frame_done), .parse_error(parse_error), .busy(busy)
    );
    midi_note_state consumer (
        .clk(clk), .rst_n(rst_n), .event_valid(event_valid), .event_ready(event_ready),
        .event_data(event_data), .event_source_id(event_source_id),
        .slot_note_map({7'd76,7'd71,7'd67,7'd64,7'd62,7'd60,7'd58,7'd56,
                        7'd54,7'd52,7'd50,7'd48,7'd46,7'd44,7'd42,7'd40}),
        .source_cleanup_req(2'b0), .source_cleanup_done(), .source_ops_idle(), .midi_ops_idle(),
        .op_valid(op_valid), .op_ready(op_ready), .op_event_data(), .op_source_id(),
        .op_cleanup_sources(), .op_rejected(), .op_retrigger(retrigger), .op_hard_clear(),
        .slot_owned(), .slot_key_down(), .slot_gate(gate), .slot_velocity(velocity),
        .slot_source(), .slot_channel(), .slot_original_note(), .rejected_note_count()
    );
    // Simulate a consumer that takes several cycles to observe each change.
    always @(negedge clk) begin
        if (op_valid) begin
            delay_count = delay_count + 1;
            op_ready = delay_count >= 8;
        end else begin
            delay_count = 0; op_ready = 0;
        end
    end
    always @(posedge clk) if (rst_n) begin
        if (parse_error) $fatal(1, "FAIL parser error");
        if (event_valid && event_ready) accepted = accepted + 1;
        if (op_valid && op_ready) begin
            if (retired == 0 && !(gate == 16'h400 && retrigger == 16'h400 && velocity[70 +: 7] == 80))
                $fatal(1, "FAIL On lost before consumer observed it");
            if (retired == 1 && gate != 0) $fatal(1, "FAIL Off did not follow On");
            if (retired >= 2) $fatal(1, "FAIL extra operation");
            retired = retired + 1;
        end
    end
    task automatic byte_in(input logic [7:0] data, input bit first, last_byte);
        @(negedge clk);
        s_valid = 1; s_data = data; s_first = first; s_last = last_byte;
        while (!s_ready) @(negedge clk);
        @(negedge clk); s_valid = 0; s_first = 0; s_last = 0;
    endtask
    initial begin
        repeat (3) @(negedge clk); rst_n = 1;
        byte_in(8'h90, 1, 0);
        byte_in(60, 0, 0); byte_in(80, 0, 0);
        // Same-frame running status, zero-velocity Note On -> Note Off.
        byte_in(60, 0, 0); byte_in(0, 0, 1);
        wait (retired == 2); repeat (4) @(negedge clk);
        if (accepted != 2 || busy || gate != 0) $fatal(1, "FAIL pipeline did not drain");
        $display("PASS tb_midi_note_pipeline ordered_ops=%0d", retired); $finish;
    end
    initial begin #20000; $fatal(1, "FAIL timeout"); end
endmodule
