`timescale 1ns/1ps
// Optional observational wrapper: unmodified real-Flash/MIDI/I2S system test.
module tb_eng1_model_trace;
    parameter int INST=4,SAMPLES=2048;
    tb_eng1_pitch_system #(.INST(INST),.SAMPLES(SAMPLES),.CORE_HZ(50_000_000)) suite();
    integer fd,epoch=0,seq=0;
    bit pending=0,retire_pending=0;
    logic [15:0] zero;
    longint slot_y[16];
    initial begin
        fd=$fopen($sformatf("eng1_trace_%0d.txt",INST),"w");
        if(!fd)$fatal(1,"FAIL cannot open model trace");
    end
    always @(posedge suite.clk) if(suite.rst_n)begin
        if(suite.dut.u_voice.ld_done && !suite.dut.u_voice.ld_err)epoch++;
        if(suite.verify && suite.dut.u_voice.xw_run && suite.dut.u_voice.table_valid)begin
            zero=suite.dut.u_voice.note_f | suite.dut.u_voice.dead_f |
                 suite.dut.u_voice.clear_f | {16{suite.dut.u_voice.init_zero}};
            seq++;pending=1;
            $fwrite(fd,"I %0d %0d %0d %0d %0d %0d %0d",epoch,seq,
                suite.dut.u_voice.part_gate,suite.dut.u_voice.part_trigger,
                suite.dut.u_voice.part_clear,suite.dut.u_voice.pitch_slot_source,zero);
            for(int s=0;s<16;s++)$fwrite(fd," %0d",suite.dut.u_voice.pending_notes[s*7 +:7]);
            for(int s=0;s<16;s++)$fwrite(fd," %0d",suite.dut.u_voice.part_strike[s*8 +:8]);
            for(int s=0;s<16;s++)$fwrite(fd," %0d",$signed(suite.dut.u_voice.part_pitch_delta[s*24 +:24]));
            for(int s=0;s<16;s++)$fwrite(fd," %0d",suite.dut.u_voice.xmap[s]);
            for(int s=0;s<16;s++)$fwrite(fd," %0d",suite.dut.u_voice.emap[s]);
            $fwrite(fd,"\n");
        end
        if(suite.dut.u_voice.state==suite.dut.u_voice.S_RUN_V && suite.dut.u_voice.era_yv && suite.dut.u_voice.erb_yv)begin
            slot_y[suite.dut.u_voice.g]=suite.dut.u_voice.era_y;
            slot_y[suite.dut.u_voice.g+8]=suite.dut.u_voice.erb_y;
        end
        if(pending && suite.dut.u_voice.y_valid)begin
            $fwrite(fd,"O %0d %0d %0d %0d",epoch,seq,suite.dut.u_voice.y_data,suite.dut.u_voice.mix_q);
            for(int s=0;s<16;s++)$fwrite(fd," %0d",slot_y[s]);
            $fwrite(fd,"\n");pending=0;retire_pending=1;
        end
        if(retire_pending && suite.verify && suite.dut.u_voice.frame_retire)begin
            #1;$fwrite(fd,"R %0d %0d %0d\n",epoch,seq,suite.dut.voice_idle);
            retire_pending=0;
        end
    end
endmodule
