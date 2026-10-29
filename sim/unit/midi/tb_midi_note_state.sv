`timescale 1ns/1ps
module tb_midi_note_state;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    logic event_valid = 0, event_ready, event_source_id = 0;
    logic [31:0] event_data = 0;
    logic [111:0] slot_note_map;
    logic [15:0] voice_idle='1;
    logic [1:0] source_cleanup_req = 0, source_cleanup_done, source_ops_idle;
    logic midi_ops_idle, op_valid, op_ready = 0, op_source_id, op_rejected;
    logic [31:0] op_event_data, rejected_note_count;
    logic [1:0] op_cleanup_sources;
    logic [15:0] op_retrigger, op_hard_clear, slot_owned, slot_key_down, slot_gate, slot_source;
    logic [111:0] slot_velocity, slot_original_note;
    logic [63:0] slot_channel;
    integer checks = 0;
    midi_note_state dut (.*);

    task automatic ck(input logic ok, input string msg);
        checks++;
        if (ok !== 1'b1) $fatal(1, "FAIL %s", msg);
    endtask
    task automatic offer(input bit src, input integer k, ch, d1, d2);
        @(negedge clk);
        ck(event_ready, "event can be accepted");
        event_valid = 1;
        event_source_id = src;
        event_data = {k[3:0], ch[3:0], d1[6:0], d2[6:0], 10'b0};
        @(negedge clk);
        event_valid = 0;
        while(!op_valid) @(negedge clk);
        ck(op_valid && !event_ready && !midi_ops_idle, "op waits for retirement");
    endtask
    task automatic retire;
        @(negedge clk); op_ready = 1;
        @(negedge clk); op_ready = 0;
        ck(!op_valid && midi_ops_idle, "retired, independent of held gates");
    endtask
    task automatic send(input bit src, input integer k, ch, d1, d2);
        offer(src, k, ch, d1, d2); retire();
    endtask
    logic [511:0] saved;
    initial begin
        // Default piano image: slot 0 at low bits, not a chromatic allocator.
        slot_note_map = {7'd76,7'd71,7'd67,7'd64,7'd62,7'd60,7'd58,7'd56,
                         7'd54,7'd52,7'd50,7'd48,7'd46,7'd44,7'd42,7'd40};
        repeat (3) @(negedge clk); rst_n = 1;
        ck(slot_gate == 0 && slot_owned == 0, "reset has no notes");
        offer(0,1,0,60,1);
        ck(slot_gate == 16'h400 && slot_velocity[70 +: 7] == 1 &&
           op_retrigger == 16'h400, "velocity 1 preserved at piano slot 10");
        ck(source_ops_idle == 2'b10, "only wired operation in flight");
        saved = {slot_owned,slot_key_down,slot_gate,slot_velocity,slot_original_note,slot_source,slot_channel,
                 op_event_data,op_retrigger,op_hard_clear,op_cleanup_sources,op_rejected};
        // An unaccepted Off must not overwrite the pending On.
        event_valid = 1; event_data = {4'd0,4'd0,7'd60,7'd0,10'd0};
        repeat (8) begin
            @(negedge clk);
            ck({slot_owned,slot_key_down,slot_gate,slot_velocity,slot_original_note,slot_source,slot_channel,
                op_event_data,op_retrigger,op_hard_clear,op_cleanup_sources,op_rejected}
                == saved, "backpressure preserves complete op");
        end
        event_valid = 0; retire();
        ck(slot_gate[10] && midi_ops_idle, "held note is not a pending operation");
        offer(0,0,0,60,0); ck(!slot_gate[10] && op_hard_clear == 0, "Off is release, not hard clear"); retire();
        send(0,1,0,60,64);
        offer(0,1,0,60,127);
        ck(op_retrigger[10] && slot_velocity[70 +: 7] == 127, "same owner retriggers latest velocity"); retire();
        send(1,0,0,60,0); ck(slot_gate[10], "other source cannot release wired note");
        send(0,0,1,60,0); ck(slot_gate[10], "other channel cannot release note");
        offer(1,1,0,60,100); ck(op_rejected && slot_source[10] == 0, "busy pitch rejected without stealing"); retire();
        offer(0,1,0,61,90); ck(op_rejected && rejected_note_count == 2, "unsupported pitch rejected and counted"); retire();
        send(0,2,0,64,127); send(0,0,0,60,0);
        ck(slot_gate[10] && !slot_key_down[10], "sustain holds released key");
        send(0,1,0,62,100); send(0,2,0,64,0);
        ck(!slot_gate[10] && slot_gate[11] && slot_key_down[11], "pedal up releases only released keys");
        // Do not resurrect a released slot after a later pedal-down.
        send(0,2,0,64,127); send(0,0,0,60,0);
        ck(!slot_gate[10], "duplicate Off cannot resurrect released note");
        send(0,2,0,123,0);
        ck(!slot_gate[10] && slot_gate[11] && !slot_key_down[11], "All Notes Off respects sustain without resurrection");
        offer(0,2,0,120,0);
        ck(!slot_gate[11] && op_hard_clear[11] && op_hard_clear[10], "All Sound Off also clears owned release tails"); retire();
        send(0,1,0,60,100); send(0,1,0,60,0);
        ck(slot_gate[10] && !slot_key_down[10], "On velocity zero is Off under sustain");
        send(0,2,0,64,0); ck(!slot_gate[10], "velocity-zero Off releases after pedal up");
        // Map changes do not change identity used by Off. Real resource changes
        // must be coordinated with cleanup; this exercises lookup independence.
        send(0,1,0,60,100); slot_note_map[70 +: 7] = 7'd61;
        send(0,0,0,60,0); ck(!slot_gate[10], "Off uses original ownership, not current map");
        slot_note_map[70 +: 7] = 7'd60;
        send(1,1,2,64,80); send(0,1,0,60,90);
        offer(0,4,0,1,64);
        ck(op_event_data == {4'd4,4'd0,7'd1,7'd64,10'd0}, "Bend preserved for later DSP consumer");
        // Cleanup arriving during a stall must not mutate the offered snapshot.
        source_cleanup_req = 2'b01;
        repeat (4) @(negedge clk);
        ck(slot_gate[10] && !source_cleanup_done[0] && op_cleanup_sources == 0,
           "cleanup waits for previous operation"); retire();
        @(negedge clk);
        ck(op_valid && op_cleanup_sources == 1 && !slot_gate[10] && slot_gate[12] &&
           op_hard_clear[10] && !op_hard_clear[12], "cleanup isolates the requested source");
        ck(source_cleanup_done == 0, "cleanup not acknowledged before backend");
        retire(); ck(source_cleanup_done == 1 && !event_ready, "ack after retirement, source remains quarantined");
        repeat (5) @(negedge clk);
        ck(!op_valid, "held cleanup request is not repeated");
        source_cleanup_req = 0; @(negedge clk);
        ck(source_cleanup_done == 0 && event_ready, "cleanup re-arms after deassert");
        send(0,1,0,60,10); send(0,0,0,60,0);
        ck(!slot_gate[10], "cleanup also reset source sustain state");
        source_cleanup_req = 3; repeat (2) @(negedge clk);
        ck(op_cleanup_sources == 3 && slot_gate == 0 && slot_owned == 0, "simultaneous source cleanup");
        retire(); ck(source_cleanup_done == 3, "both cleanup acknowledgements");
        source_cleanup_req = 0; @(negedge clk);
        // Exercise all 32 source/channel pedal registers and ensure another
        // channel cannot turn off this owner's pedal or note.
        for (integer c = 0; c < 32; c = c + 1) begin
            send(c[4],1,c%16,40,64);
            send(c[4],2,c%16,64,127);
            send(c[4],0,c%16,40,0);
            send(c[4],2,(c+1)%16,64,0);
            ck(slot_gate[0] && !slot_key_down[0], "pedal state isolated per source/channel");
            send(c[4],2,c%16,64,0);
            ck(!slot_gate[0], "matching pedal register releases note");
        end
        // A quarantine may arrive in either pre-commit cycle. The accepted
        // event must not leak an On, and cleanup cannot acknowledge itself.
        for(integer delay_cycles=0;delay_cycles<2;delay_cycles++) begin
            @(negedge clk);event_valid=1;event_source_id=0;
            event_data={4'd1,4'd0,7'd60,7'd100,10'd0};
            @(negedge clk);event_valid=0;
            ck(!event_ready && !midi_ops_idle && !source_ops_idle[0] && !op_valid,
               "accepted staged event participates in barriers");
            // Change unaccepted input immediately: accepted payload is held.
            event_data={4'd1,4'd9,7'd61,7'd1,10'd0};event_source_id=1;
            repeat(delay_cycles) @(negedge clk);
            source_cleanup_req=1;
            wait(op_valid);@(negedge clk);
            ck(op_cleanup_sources==1 && !slot_gate[10] && op_retrigger==0,
               "quarantine cancels precommit On, publishes only cleanup");
            ck(!source_cleanup_done[0],"staged cancellation does not bypass backend retirement");
            retire();ck(source_cleanup_done[0],"cancelled source cleanup retires normally");
            source_cleanup_req=0;@(negedge clk);
        end
        // A peer quarantine does not discard an already accepted healthy event.
        @(negedge clk);event_valid=1;event_source_id=0;
        event_data={4'd1,4'd0,7'd60,7'd73,10'd0};
        @(negedge clk);event_valid=0;source_cleanup_req=2;
        event_data=0;event_source_id=1;
        wait(op_valid);@(negedge clk);
        ck(op_cleanup_sources==0 && !op_source_id && slot_gate[10] && slot_velocity[70 +:7]==73,
           "peer cleanup preserves accepted source and payload");
        retire();wait(op_valid);@(negedge clk);
        ck(op_cleanup_sources==2 && slot_gate[10],"peer cleanup follows accepted op and isolates owner");
        retire();source_cleanup_req=0;@(negedge clk);
        offer(0,1,0,60,100);
        rst_n = 0; @(negedge clk);
        ck(!op_valid && slot_gate == 0 && rejected_note_count == 0, "reset clears all state");
        $display("PASS tb_midi_note_state checks=%0d", checks); $finish;
    end
    initial begin #200000; $fatal(1, "FAIL timeout"); end
endmodule
