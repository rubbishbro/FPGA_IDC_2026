`timescale 1ns/1ps
// Full 16-slot / 64-storage-mode workload at the actual I2S frame rate.
// Piano uses the checked-in image; eng1 uses an explicit stable ABC wire fixture.
module polyphonic_audio_case #(parameter bit ALT=0)(input logic clk,aclk,rst_n,output logic finished=0);
    import router_pkg::*;
    localparam logic[3:0] CHANNEL=ALT?5:1;
    logic event_valid=0,event_ready;
    logic[31:0] event_data=0;
    logic[1:0] cleanup=0,cleanup_done;
    logic ops_idle,ready,done,load_err,yv,tick,bclk,ws,din,late,overflow,underflow;
    logic signed[63:0] y;
    logic[3:0] dqi,dqo;
    logic cs,sck,oe,run=1;
    wire[111:0] note_map=default_note_map();
    midi_voice_top #(.SLOTS(16),.N_MODES(64),.AUDIO_ENABLE(1)) dut(
        .clk(clk),.audio_clk(aclk),.rst_n(rst_n),.run(run),.fmap('0),.pad_instrument(INST_PIANO),
        .reverb_preset(REVERB_HALL),.reload(1'b0),.midi_select(1'b1),.midi_source_id(1'b0),.panic(1'b0),
        .selected_channel(CHANNEL),.note_bank(1'b0),.first_midi_note(7'd0),.slot_note_map(note_map),
        .backend_ready(),.backend_rsp_valid(),.backend_response(),.backend_supported(),
        .backend_audio_valid(),.backend_audio_fault(),.backend_audio_state(),
        .source_ops_idle(),.control_valid(),.control_cancel(),.control_data(),.control_source_id(),
        .channel_mapped(),.config_busy(),.config_failed(),.active_channel(),.active_bank(),
        .rejected_note_count(),.unsupported_count(),.control_timeout_count(),.dropped_count(),.error_sticky(),
        .backend_valid(1'b0),.backend_source(1'b0),.backend_request('0),.backend_rsp_ready(1'b1),
        .event_valid(event_valid),.event_ready(event_ready),.event_data(event_data),.event_source_id(1'b0),
        .source_cleanup_req(cleanup),.source_cleanup_done(cleanup_done),.midi_ops_idle(ops_idle),
        .control_ready(1'b0),.ready(ready),.done(done),.load_err(load_err),.y_valid(yv),.y_data(y),
        .qspi_cs_n(cs),.qspi_sck(sck),.qspi_dq_oe(oe),.qspi_dq_o(dqo),.qspi_dq_i(dqi),
        .amp_bclk(bclk),.amp_ws(ws),.amp_din(din),.audio_sample_tick(tick),
        .audio_deadline_miss(late),.audio_overflow(overflow),.audio_underflow(underflow));
    w25q64_read_model #(.N_MODES(64),.ABC_COEFF(ALT),
        .MEM_FILE(ALT?"":"piano_flash.mem"),.MEM_BYTES(65536)) flash(
        .cs_n(cs),.sck(sck),.dq_o(dqo),.dq_oe(oe),.blank(1'b0),.dq_i(dqi));
    logic pending=0;logic[15:0] pcm=0;
    wire active=ready && !dut.maintain_req && run;
    wire[15:0] expected_pcm=active && pending ? pcm : 16'd0;
    integer frames,nz,cycles=0,last_tick=0,max_latency=0,produced=0;
    integer last_part_tick=0,min_part_gap=2147483647;
    i2s_scoreboard wire_check(clk,rst_n,bclk,ws,din,tick,expected_pcm,frames,nz);
    always @(posedge clk)begin
        logic signed[64:0] scaled;
        cycles++;
        if(!rst_n)begin last_part_tick=0;min_part_gap=2147483647;end
        else if(dut.u_voice.part_tick)begin
            if(last_part_tick!=0)begin
                if(cycles-last_part_tick<2047)$fatal(1,"FAIL sample enable pulses too close: %d",cycles-last_part_tick);
                if(cycles-last_part_tick<min_part_gap)min_part_gap=cycles-last_part_tick;
            end
            last_part_tick=cycles;
        end
        if(!rst_n || !active)begin pending<=0;pcm<=0;end
        else begin
            if(yv)begin
                scaled=($signed({y[63],y})+65'sd2048)>>>12;
                pcm<=scaled>32767?16'h7fff:scaled< -32768?16'h8000:16'(scaled);pending<=1;
            end
            if(tick)pending<=0;
        end
        if(rst_n)begin
            if(late||overflow||underflow||(ready&&load_err)||dut.config_failed)$fatal(1,"FAIL full polyphony ALT=%b diagnostics=%b%b%b load=%b",ALT,late,overflow,underflow,load_err);
            if(tick)last_tick=cycles;
            if(yv && active)begin
                produced++;
                if(cycles-last_tick>max_latency)max_latency=cycles-last_tick;
                if(cycles-last_tick>=2048)$fatal(1,"FAIL sample exceeded I2S frame deadline");
            end
        end
    end
    task automatic send(input logic[3:0] kind,input logic[6:0] a,b);
        @(negedge clk);event_valid=1;event_data={kind,CHANNEL,a,b,10'd0};
        while(!event_ready)@(negedge clk);
        @(negedge clk);event_valid=0;
        wait(ops_idle);@(negedge clk);
    endtask
    task automatic hold_frames(input integer n);
        repeat(n)begin @(posedge tick);@(negedge clk);end
    endtask
    initial begin
        wait(rst_n);wait(ready && dut.mode_q && done);
        for(integer i=0;i<16;i++)send(1,note_map[i*7 +:7],7'(80+i));
        if(dut.gate!==16'hffff || dut.u_notes.slot_owned!==16'hffff)$fatal(1,"FAIL sixteen notes not allocated");
        hold_frames(128);
        for(integer i=0;i<16;i++)send(1,note_map[i*7 +:7],i[0]?7'd1:7'd127);
        send(2,64,127);
        for(integer i=0;i<16;i++)send(0,note_map[i*7 +:7],0);
        if(dut.gate!==16'hffff)$fatal(1,"FAIL sustain lost held chord");
        hold_frames(64);send(2,64,0);hold_frames(8);
        @(negedge clk);cleanup=1;run=0;wait(cleanup_done[0]);@(negedge clk);
        for(integer slot=0;slot<8;slot++)for(integer mode=0;mode<(ALT?48:64);mode++)begin
            if(dut.u_voice.q_ram_a[slot*64+mode]!==0 || dut.u_voice.v_ram_a[slot*64+mode]!==0 ||
               dut.u_voice.q_ram_b[slot*64+mode]!==0 || dut.u_voice.v_ram_b[slot*64+mode]!==0)
                $fatal(1,"FAIL cleanup acknowledged before state RAM zero");
        end
        cleanup=0;run=1;repeat(3)@(negedge clk);send(1,note_map[6:0],90);hold_frames(8);
        if(!dut.gate[0] || nz<20 || produced<200)$fatal(1,"FAIL polyphony produced no audio/reuse");
        $display("PASS polyphonic_audio ALT=%b slots=16 storage_modes=64 frames=%d nonzero=%d max_compute_cycles=%d min_sample_gap=%d",ALT,frames,nz,max_latency,min_part_gap);
        finished=1;
    end
endmodule
module tb_polyphonic_audio;
    logic clk=0,aclk=0,rst_n=0;
    always #5 clk=~clk;
    initial begin #13;forever #40 aclk=~aclk;end
    wire a,b;
    polyphonic_audio_case #(.ALT(0)) piano(clk,aclk,rst_n,a);
    polyphonic_audio_case #(.ALT(1)) flute(clk,aclk,rst_n,b);
    initial begin repeat(5)@(negedge clk);rst_n=1;wait(a&&b);$display("PASS tb_polyphonic_audio both_engines");$finish;end
    initial begin #60000000;$fatal(1,"FAIL polyphony timeout");end
endmodule
