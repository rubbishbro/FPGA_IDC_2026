`timescale 1ns/1ps
module tb_plucked_release;
    import router_pkg::*;
    logic clk=0,rst_n=0,gate=0,retrigger=0,clear=0,midi=0;
    always #5 clk=~clk;
    instrument_e inst=INST_BANJO;
    logic signed[0:0][31:0] emap;
    logic valid,dead;
    integer samples;
    env_router #(.SLOTS(1)) dut(.clk(clk),.rst_n(rst_n),.smp_tick(1'b1),
        .slot_a_step(32'd0),.slot_r_step(32'd0),.envelope_level(8'hff),
        .retrigger(retrigger),.slot_clear(clear),.midi_mode(midi),
        .note_on(gate),.note_gate(gate),.inst(inst),.emap(emap),.emap_valid(valid),.dead(dead));
    initial begin
        repeat(4)@(negedge clk);rst_n=1;
        for(int mode=0;mode<2;mode++)for(int instrument=7;instrument<=9;instrument++)begin
            midi=1'(mode);inst=instrument_e'(instrument);clear=1;
            repeat(4)@(negedge clk);clear=0;gate=1;retrigger=1;
            @(negedge clk);retrigger=0;repeat(40)@(negedge clk);
            if(dead || emap[0]!=32'h7fffffff)$fatal(1,"FAIL full sustain inst=%0d mode=%0d",inst,mode);
            gate=0;repeat(8)@(negedge clk);
            if(dead || emap[0]<=0 || emap[0]>=32'h7fffffff)$fatal(1,"FAIL immediate cut/no release");
            samples=8;
            while(!dead && samples<30000)begin @(negedge clk);samples++;end
            if(!dead || samples!=28800)$fatal(1,"FAIL release duration %0d",samples);
            repeat(2)@(negedge clk);if(emap[0]!=0)$fatal(1,"FAIL release nonzero");
            $display("PASS release inst=%0d midi=%0d samples=%0d",inst,mode,samples);
        end
        $display("PASS tb_plucked_release 3 instruments x PAD/MIDI, full release to dead");$finish;
    end
endmodule
