`timescale 1ns/1ps
// Production ENG1 -> envelope/trim arithmetic -> production body -> PCM16.
// Reverb NONE and a single centered voice are explicit calibration conditions.
module tb_added_instrument_pcm #(parameter int INSTRUMENT=6,SAMPLES=240000);
    import modal_step_pkg::*;
    import router_pkg::*;
    logic clk=0,rst_n=0,start=0,st_zero=0;
    always #5 clk=~clk;
    logic[6:0] n_modes;
    logic co_re,st_re,st_we,x_re,y_valid;
    logic[5:0] co_addr,st_addr,st_waddr;
    coeff_t co_data,co[64];
    logic signed[31:0] st_q,st_qdot,st_q_wdata,st_qdot_wdata,x_data=0;
    logic signed[63:0] y_data;
    logic[31:0] q[64],v[64];
    instrument_e inst=instrument_e'(INSTRUMENT);
    logic tick=0,gate=0,trig=0;
    logic[15:0] period=2;
    logic[31:0] attack=1,release_step=1;
    logic signed[0:0][31:0] xmap,emap;
    logic xvalid;
    exc_router #(.SLOTS(1)) excitation(.clk(clk),.rst_n(rst_n),.smp_tick(tick),
      .slot_period(period),.slot_pitch_delta(24'd0),.strike_level(8'd255),.retrigger(trig),
      .slot_clear(1'b0),.note_on(gate),.inst(inst),.xmap(xmap),.xmap_valid(xvalid));
    env_router #(.SLOTS(1)) envelope_dut(.clk(clk),.rst_n(rst_n),.smp_tick(tick),
      .slot_a_step(attack),.slot_r_step(release_step),.envelope_level(8'hff),.retrigger(trig),
      .slot_clear(1'b0),.midi_mode(1'b0),.note_on(gate),.note_gate(gate),.inst(inst),
      .emap(emap),.emap_valid(),.dead());
    eng1 dut(.*);
    always @(posedge clk)begin
        if(co_re)co_data<=co[co_addr];
        if(st_re)begin st_q<=q[st_addr];st_qdot<=v[st_addr];end
        if(st_we)begin q[st_waddr]<=st_q_wdata;v[st_waddr]<=st_qdot_wdata;end
    end
    logic body_valid=0,body_ready,body_out,clear_busy;
    logic signed[63:0] body_x,body_y;
    body_router #(.SLOTS(1)) body(.clk(clk),.rst_n(rst_n),.clear_req(1'b0),.clear_busy(clear_busy),.inst(inst),
      .in_valid(body_valid),.in_ready(body_ready),.x(body_x),.out_valid(body_out),.y(body_y));
    integer fd,of,rc,zero,cycles,clipped=0,profile,hold_samples,pp,aa,rr;
    logic[31:0] wanted_x,envelope;
    logic signed[63:0] wanted_engine,wanted_body;
    logic signed[127:0] enveloped,trimmed,pcm_wide;
    logic signed[15:0] pcm;
    initial begin
        $readmemh("pcm_coefficients.mem",co);
        for(int mode=0;mode<64;mode++)begin q[mode]=0;v[mode]=0;end
        n_modes=7'(n_modes_of(inst));
        profile=$fopen("pcm_frontend.txt","r");rc=$fscanf(profile,"%d %d %d %d",pp,aa,rr,hold_samples);$fclose(profile);
        if(rc!=4)$fatal(1,"FAIL frontend profile");
        period=16'(pp);attack=32'(aa);release_step=32'(rr);
        repeat(4)@(negedge clk);rst_n=1;
        repeat(4)@(negedge clk);wait(!clear_busy);
        // Retire exc_router's instrument-change clear before the first attack,
        // just as the production router's load/clear barrier does.
        @(negedge clk);tick=1;gate=0;trig=0;
        @(negedge clk);tick=0;repeat(2)@(negedge clk);
        fd=$fopen("pcm_vectors.txt","r");of=$fopen("rtl_pcm.txt","w");
        if(!fd||!of)$fatal(1,"FAIL opening PCM vectors/output");
        for(int sample=0;sample<SAMPLES;sample++)begin
            rc=$fscanf(fd,"%h %h %d %h %h",wanted_x,envelope,zero,wanted_engine,wanted_body);
            if(rc!=5)$fatal(1,"FAIL truncated PCM vectors n=%0d",sample);
            @(negedge clk);gate=sample<hold_samples;trig=sample==0;tick=1;
            @(negedge clk);tick=0;
            if(xmap[0]!==32'(wanted_x)||emap[0]!==32'(envelope))$fatal(1,"FAIL frontend inst=%0d n=%0d x=%0d/%0d env=%0d/%0d",INSTRUMENT,sample,xmap[0],$signed(wanted_x),emap[0],$signed(envelope));
            x_data=xmap[0];st_zero=1'(zero);start=1;
            @(negedge clk);start=0;cycles=0;
            while(!y_valid&&cycles<400)begin @(negedge clk);cycles++;end
            if(!y_valid||y_data!==wanted_engine)$fatal(1,"FAIL engine inst=%0d n=%0d got=%0d expected=%0d",INSTRUMENT,sample,y_data,wanted_engine);
            enveloped=(128'($signed(y_data))*128'($signed(envelope)))>>>31;
            trimmed=(enveloped*128'($signed(gain_q12_of(inst)))+128'sd2048)>>>12;
            while(!body_ready)@(negedge clk);
            body_x=64'(trimmed);body_valid=1;
            @(negedge clk);body_valid=0;cycles=0;
            while(!body_out&&cycles<160)begin @(negedge clk);cycles++;end
            if(!body_out||body_y!==wanted_body)$fatal(1,"FAIL body inst=%0d n=%0d got=%0d expected=%0d",INSTRUMENT,sample,body_y,wanted_body);
            pcm_wide=(128'($signed(body_y))+128'sd256)>>>9;
            pcm=pcm_wide>32767?16'sh7fff:pcm_wide< -32768?16'sh8000:16'(pcm_wide);
            if(pcm_wide>32767||pcm_wide< -32768)clipped++;
            $fwrite(of,"%0d %0d\n",body_y,pcm);
        end
        $fclose(fd);$fclose(of);
        if(clipped)$fatal(1,"FAIL PCM clipping count=%0d",clipped);
        $display("PASS tb_added_instrument_pcm instrument=%0d samples=%0d clipped=%0d",INSTRUMENT,SAMPLES,clipped);$finish;
    end
    initial begin #(64'd100000000000);$fatal(1,"FAIL PCM watchdog");end
endmodule
