`timescale 1ns/1ps
module tb_performance_input_mux;
    logic clk=0, rst_n=0;
    always #5 clk=~clk;
    logic sample_commit=0, frame_retire=0, maintenance_clear=0, maintenance_done, midi_inflight;
    logic [3:0] pad_gate=0, midi_gate=0, midi_retrigger=0, midi_hard_clear=0;
    logic [31:0] pad_level=32'hfafafafa;
    logic midi_select=0, midi_valid=0, midi_ready, active_midi;
    logic [27:0] midi_velocity=0;
    logic [3:0] gate, trigger, hard_clear;
    logic [31:0] strike_level,envelope_level;
    integer checks=0;
    performance_input_mux #(.SLOTS(4),.MIDI_ENABLE(1)) dut(.*);
    task automatic ck(input logic ok,input string msg);
        checks++;
        if(ok!==1'b1) $fatal(1,"FAIL %s",msg);
    endtask
    task automatic commit;
        @(negedge clk); sample_commit=1;
        @(negedge clk); sample_commit=0; #1;
    endtask
    task automatic retire;
        @(negedge clk); frame_retire=1;
        @(negedge clk); frame_retire=0;
    endtask
    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        pad_gate=5; #1;
        ck(gate==5 && strike_level==pad_level,"PAD passes through");
        midi_select=1; midi_valid=1; midi_gate=1; midi_velocity=1; midi_retrigger=1;
        @(negedge clk); sample_commit=1; #1;
        ck(hard_clear==15 && gate==0 && !midi_ready,"source switch clears old voices first");
        @(negedge clk); sample_commit=0;
        ck(active_midi && !midi_ready,"MIDI waits through source switch frame");
        retire();
        @(negedge clk); sample_commit=1; #1;
        ck(gate==1 && trigger==1 && strike_level[7:0]==2 && envelope_level[7:0]==255,
           "velocity1 gates independently and reaches excitation only");
        @(negedge clk); sample_commit=0;
        repeat(3) @(negedge clk);
        ck(gate==1 && trigger==0 && !midi_ready,"held state, one-shot trigger, no early ack");
        @(negedge clk); frame_retire=1; #1;
        ck(midi_ready,"ack only after real frame retirement");
        @(negedge clk); frame_retire=0; midi_valid=0;
        // Every nonzero velocity has a distinct excitation magnitude.
        for(integer v=1;v<128;v++) begin
            midi_valid=1; midi_velocity[6:0]=v[6:0]; midi_retrigger=1;
            @(negedge clk); sample_commit=1; #1;
            ck(strike_level[7:0]==(2*v+v/64) && trigger==1 && gate==1,"monotonic endpoint-preserving velocity map");
            @(negedge clk); sample_commit=0; retire(); midi_valid=0;
        end
        midi_valid=1; midi_hard_clear=1; midi_retrigger=1;
        @(negedge clk); sample_commit=1; #1;
        ck(gate==0 && trigger==0 && hard_clear==1,"clear has priority over simultaneous retrigger");
        @(negedge clk); sample_commit=0; retire(); midi_valid=0;
        midi_select=0; commit();
        ck(!active_midi && gate==0,"PAD remains blank through switch frame");
        retire(); commit(); #1;
        ck(gate==5 && strike_level==pad_level,"PAD resumes at next frame boundary");
        $display("PASS tb_performance_input_mux checks=%0d",checks); $finish;
    end
    initial begin #100000; $fatal(1,"FAIL timeout"); end
endmodule
