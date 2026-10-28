`timescale 1ns/1ps
module tb_i2s_synthesis;
    import router_pkg::*;
    parameter bit ENG1=0,EXACT_48K=0,PAD_TOP=0;
    localparam real AUDIO_HALF=EXACT_48K ? 40.6901041666667 : 40.0;
    logic clk=0,aclk=0,rst_n=0,run=1,reload=0,panic=0,blank=0;
    always #5 clk=~clk;
    initial begin #3.137;forever #(AUDIO_HALF)aclk=~aclk;end
    pad_driver_pkg::mat4x4 fmap='0;
    logic cs,sck,oe,bclk,ws,din,tick,late,overflow,underflow,yv,ready,busy,failed;
    logic [3:0] dqo,dqi;
    logic signed [63:0] y;
    logic midi_mode=0,event_valid=0,event_ready,notes_idle;
    logic [31:0] event_data=0;
    logic [15:0] midi_gates;
    logic [6:0] actual_modes;
    generate if(!PAD_TOP) begin : g_midi
    midi_voice_top #(.AUDIO_ENABLE(1),.NOTE_BANKS(1)) dut(
        .clk(clk),.audio_clk(aclk),.rst_n(rst_n),.run(run),.fmap(fmap),
        .pad_instrument(ENG1 ? INST_FLUTE : INST_PIANO),.reverb_preset(REVERB_NONE),
        .reload(reload),.midi_select(midi_mode),.midi_source_id(1'b0),.panic(panic),
        .backend_ready(),.backend_rsp_valid(),.backend_response(),.backend_supported(),
        .backend_audio_valid(),.backend_audio_fault(),.backend_audio_state(),.event_ready(event_ready),
        .source_cleanup_done(),.source_ops_idle(),.midi_ops_idle(notes_idle),.control_valid(),.control_cancel(),
        .control_data(),.control_source_id(),.channel_mapped(),.active_channel(),.active_bank(),
        .rejected_note_count(),.unsupported_count(),.control_timeout_count(),.dropped_count(),.error_sticky(),.done(),.load_err(),
        .selected_channel(ENG1 ? 4'd5 : 4'd1),.note_bank(1'b0),.first_midi_note(7'd48),.slot_note_map('0),
        .backend_valid(1'b0),.backend_source(1'b0),.backend_request('0),.backend_rsp_ready(1'b1),
        .event_valid(event_valid),.event_data(event_data),.event_source_id(1'b0),.source_cleanup_req('0),.control_ready(1'b1),
        .ready(ready),.config_busy(busy),.config_failed(failed),.y_valid(yv),.y_data(y),
        .qspi_cs_n(cs),.qspi_sck(sck),.qspi_dq_o(dqo),.qspi_dq_oe(oe),.qspi_dq_i(dqi),
        .amp_bclk(bclk),.amp_ws(ws),.amp_din(din),.audio_sample_tick(tick),
        .audio_deadline_miss(late),.audio_overflow(overflow),.audio_underflow(underflow));
    assign actual_modes=dut.u_voice.nm_lat;
    assign midi_gates=dut.gate;
    end else begin : g_pad
        logic valid,err;
        pad_voice_top #(.USE_PAD_DRIVER(0),.AUDIO_ENABLE(1)) dut(
            .clk(clk),.rst_n(rst_n),.audio_clk(aclk),.run(run),.reload(reload),
            .inst(ENG1 ? INST_FLUTE : INST_PIANO),.reverb_preset(REVERB_NONE),.src_sel(1'b1),.fmap_ext(fmap),
            .pad_row_s(),.pad_ch_s(),.pad_fmap(),.pad_pos(),.led_dat(),.joy_sample_valid(),.joy_raw_x(),.joy_raw_y(),
            .ready(),.busy(),.done(),.load_err(err),.table_valid(valid),.y_valid(yv),.y_data(y),
            .qspi_cs_n(cs),.qspi_sck(sck),.qspi_dq_o(dqo),.qspi_dq_oe(oe),.qspi_dq_i(dqi),
            .amp_bclk(bclk),.amp_ws(ws),.amp_din(din),.audio_sample_tick(tick),
            .audio_deadline_miss(late),.audio_overflow(overflow),.audio_underflow(underflow));
        assign ready=valid && !err;
        assign busy=!valid && !err;
        assign failed=err;
        assign actual_modes=dut.u_voice.nm_lat;
        assign midi_gates=0;assign event_ready=0;assign notes_idle=1;
    end endgenerate
    w25q64_read_model #(.N_MODES(64),.ABC_COEFF(ENG1)) flash(.cs_n(cs),.sck(sck),.dq_o(dqo),.dq_oe(oe),.blank(blank),.dq_i(dqi));
    // Scoreboard captures public sample results, independently converts Q24 to PCM.
    logic pending=0;
    logic [15:0] last_pcm=0,exp_pcm;
    wire active=run && !busy && !failed && !panic;
    longint signed scaled;
    assign exp_pcm=active && pending ? last_pcm : 16'd0;
    integer frames,nz,ticks=0,outputs=0,steady=0,max_latency=0,job_cycle=0;
    integer cycles=0,last_tick=0,min_interval=1000000,max_interval=0;
    i2s_scoreboard checkwire(clk,rst_n,bclk,ws,din,tick,exp_pcm,frames,nz);
    always @(posedge clk) if(rst_n) begin
        cycles++;
        if(!active)pending<=0;
        else if(yv)begin
            scaled=($signed(y)+64'sd2048)>>>12;
            last_pcm<=scaled>32767 ? 16'h7fff : scaled< -32768 ? 16'h8000 : 16'(scaled);
            pending<=1;
        end
        if(tick) begin
            ticks++;
            if(last_tick!=0)begin
                if(cycles-last_tick<min_interval)min_interval=cycles-last_tick;
                if(cycles-last_tick>max_interval)max_interval=cycles-last_tick;
            end
            last_tick=cycles;job_cycle=cycles;pending<=0;
        end
        if(yv)begin
            if($isunknown(y))$fatal(1,"FAIL unknown synthesis sample");
            outputs++;
            if(active)begin
                steady++;
                if(cycles-job_cycle>max_latency)max_latency=cycles-job_cycle;
            end
        end
        if(late || overflow || underflow)$fatal(1,"FAIL audio diagnostics late=%b full=%b empty=%b",late,overflow,underflow);
        if(actual_modes>64)$fatal(1,"FAIL mode count");
    end
    task automatic midi_event(input logic [3:0] kind,input logic [6:0] key,value);
        @(negedge clk);event_data={kind,(ENG1?4'd5:4'd1),key,value,10'd0};event_valid=1;
        do @(negedge clk);while(!event_ready);
        event_valid=0;
        wait(notes_idle);@(negedge clk);
    endtask
    initial begin
        repeat(5)@(negedge clk);rst_n=1;
        wait(ready);@(negedge clk);fmap.flat_d[0].val=250;fmap.flat_d[8].val=240;
        wait(steady>=1600);
        if(actual_modes != (ENG1?48:64))$fatal(1,"FAIL active modes vs storage");
        if(nz<100)$fatal(1,"FAIL no meaningful PCM frames %d",nz);
        if(!PAD_TOP) begin
            // Exercise real MIDI snapshots with the external I2S sample clock.
            midi_mode=1;wait(busy);wait(ready);
            midi_event(1,48,100);midi_event(1,56,64);
            if((midi_gates & 16'h0101)!=16'h0101)$fatal(1,"FAIL MIDI A/B note admission");
            repeat(24)begin @(posedge tick);@(negedge clk);end
            midi_event(1,56,127); // repeated note-on must retire/retrigger
            midi_event(2,64,127);midi_event(0,48,0); // sustain owns the released key
            if(!midi_gates[0])$fatal(1,"FAIL I2S-paced sustain");
            midi_event(2,64,0);midi_event(2,120,0); // real hard-clear operation
            if(midi_gates!=0)$fatal(1,"FAIL I2S-paced MIDI clear");
            midi_mode=0;wait(busy);wait(ready);
        end
        // Reload is a planned multi-ms silence, not a FIFO starvation event.
        fmap='0;repeat(5)begin @(posedge tick);@(negedge clk);end
        reload=1;@(negedge clk);reload=0;wait(busy);wait(ready);
        repeat(8)begin @(posedge tick);@(negedge clk);end
        // Failed table remains silent; explicit reload recovers without drift.
        blank=1;reload=1;@(negedge clk);reload=0;wait(failed);
        repeat(10)begin @(posedge tick);@(negedge clk);end
        blank=0;reload=1;@(negedge clk);reload=0;wait(ready);
        repeat(8)begin @(posedge tick);@(negedge clk);end
        run=0;repeat(8)begin @(posedge tick);@(negedge clk);end
        run=1;repeat(8)begin @(posedge tick);@(negedge clk);end
        if(EXACT_48K ? (min_interval<2083 || max_interval>2084) : (min_interval!=2048 || max_interval!=2048))
            $fatal(1,"FAIL I2S master interval %d..%d",min_interval,max_interval);
        $display("PASS tb_i2s_synthesis eng=%0d exact48=%0d pad=%0d steady=%0d frames=%0d nonzero=%0d interval=%0d..%0d max_core_latency=%0d",ENG1,EXACT_48K,PAD_TOP,steady,frames,nz,min_interval,max_interval,max_latency);
        $finish;
    end
    initial begin #100000000;$fatal(1,"FAIL I2S synthesis timeout");end
endmodule
