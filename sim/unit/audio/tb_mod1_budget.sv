`timescale 1ns/1ps
// Scheduling experiment: production router/engines/excitation, deployed records
// preloaded after reset. Flash transport is deliberately outside this experiment.
module tb_mod1_budget #(parameter int CAP=4,INSTRUMENT=3,FRAME_CYCLES=1024,TEST_FRAMES=48);
    import router_pkg::*;
    logic clk=0,rst_n=0,tick=0,run=0;
    always #10 clk=~clk;
    pad_driver_pkg::mat4x4 fmap='0;
    logic yv,done,valid,err;
    logic signed [63:0] y;
    integer cycle=0,divider=0,frame=0,origin=0,outputs=0,max_audio=0;
    integer starts=0,commits=0,writes=0,max_job=0,job_start=0,job_slot=-1;
    integer min_jobs=1000,max_jobs=0,frame_jobs=0,engine_end=0,last_commit=0,max_tail=0;
    integer opportunities=0,deferred=0,overlap_reads=0,bank_writes=0;
    logic [15:0] coverage=0,total_coverage=0;
    integer lowest_coverage=16,checked_frames=0;
    logic [511:0] records[1024];
    logic [79:0] profiles[16];
    logic [31:0] table_words[1024];
    integer signed expected_delta[16];
    logic signed [31:0] expected_a1[1024];
    logic pending_a1[1024];
    integer nonzero=0,read_a=0,read_b=0,late_pairs=0,max_gap=0;
    integer last_slot_commit[16];
    logic read_av=0,read_bv=0;
    always @(negedge clk)if(run)begin
        if(read_av && dut.co_a12_ra!==expected_a1[read_a])$fatal(1,"FAIL engine A coefficient read");
        if(read_bv && dut.co_a12_rb!==expected_a1[read_b])$fatal(1,"FAIL engine B coefficient read");
    end
    voice_router #(.SLOTS(16),.N_MODES(64),.CLK_HZ(50_000_000),.SR_HZ(48000),
        .MOD1_MODES_PER_JOB(CAP),.EXTERNAL_SAMPLE_TICK(1),.MIDI_ENABLE(1)) dut(
        .clk(clk),.rst_n(rst_n),.fmap(fmap),.inst(instrument_e'(INSTRUMENT)),.reverb_preset(REVERB_NONE),
        .start(run),.sample_tick(tick),.reload(1'b0),.done(done),.ready(),.load_err(err),
        .y_valid(yv),.y_data(y),.qspi_cs_n(),.qspi_sck(),.qspi_dq_o(),.qspi_dq_oe(),.qspi_dq_i(4'd0),
        .midi_select(1'b0),.midi_valid(1'b0),.midi_ready(),.midi_gate(16'd0),.midi_retrigger(16'd0),
        .midi_hard_clear(16'd0),.midi_velocity(112'd0),.pitch_cleanup(2'd0),.pitch_slot_source(16'd0),
        .maintenance_clear(1'b0),.map_reload(1'b0),.load_offsets(512'd0),.maintenance_done(),
        .midi_inflight(),.load_complete(),.table_valid(valid),.voice_idle(),
        .ns_rd_en(1'b0),.ns_rd_addr(10'd0),.ns_rd_sel(1'b0),.ns_rd_data(),.ns_rd_valid());
    function automatic integer signed word(input integer addr,k);
        return $signed(records[addr][511-k*32 -:32]);
    endfunction
    function automatic integer delta_for(input integer p);
        integer q,i,f;longint signed v;
        q=(p>102 ? (p-102)*768+2 : 0)/5;i=(q+56320)>>8;f=(q+56320)&255;
        v=$signed({1'b0,table_words[i+1][24:0]})-$signed({1'b0,table_words[i][24:0]});
        return 32'($signed({1'b0,table_words[i][24:0]})+((v*f+128)>>>8)-16777216);
    endfunction
    initial begin
        string name;
        if(!$value$plusargs("records=%s",name))$fatal(1,"missing records");$readmemh(name,records);
        if(!$value$plusargs("profiles=%s",name))$fatal(1,"missing profiles");$readmemh(name,profiles);
        $readmemh("pitch_tables.mem",table_words);
        for(int i=0;i<1024;i++)begin expected_a1[i]=word(i,1);pending_a1[i]=0;end
        for(int i=0;i<16;i++)begin expected_delta[i]=0;last_slot_commit[i]=0;end
        repeat(5)@(negedge clk);rst_n=1;repeat(12)@(negedge clk);
        // Seed only the loaded resource identity. Scheduling runs unforced.
        force dut.state=dut.S_DONE;force dut.inst_lat=instrument_e'(INSTRUMENT);
        force dut.inst_prev=instrument_e'(INSTRUMENT);force dut.nm_lat=7'd48;
        force dut.table_valid=1;force dut.zero_frames=0;
        for(int s=0;s<16;s++)begin
            dut.active_play[s]={1'b1,profiles[s]};
            for(int m=0;m<64;m++)begin
                if(s<8)begin
                    dut.ca_a11_a[s*64+m]=word(s*64+m,0);dut.ca_a12_a[s*64+m]=word(s*64+m,1);
                    dut.ca_a21_a[s*64+m]=word(s*64+m,2);dut.ca_a22_a[s*64+m]=word(s*64+m,3);
                    dut.ca_gq_a[s*64+m]=word(s*64+m,4);dut.ca_gv_a[s*64+m]=word(s*64+m,5);
                    dut.ca_wo_a[s*64+m]=word(s*64+m,6);dut.q_ram_a[s*64+m]=0;dut.v_ram_a[s*64+m]=0;
                end else begin
                    dut.ca_a11_b[(s-8)*64+m]=word(s*64+m,0);dut.ca_a12_b[(s-8)*64+m]=word(s*64+m,1);
                    dut.ca_a21_b[(s-8)*64+m]=word(s*64+m,2);dut.ca_a22_b[(s-8)*64+m]=word(s*64+m,3);
                    dut.ca_gq_b[(s-8)*64+m]=word(s*64+m,4);dut.ca_gv_b[(s-8)*64+m]=word(s*64+m,5);
                    dut.ca_wo_b[(s-8)*64+m]=word(s*64+m,6);dut.q_ram_b[(s-8)*64+m]=0;dut.v_ram_b[(s-8)*64+m]=0;
                end
                dut.pm_a11[s*64+m]=word(s*64+m,8);dut.pm_a12[s*64+m]=word(s*64+m,9);
                dut.pm_a22[s*64+m]=word(s*64+m,10);dut.pm_wo[s*64+m]=word(s*64+m,11);
                dut.pm_s11[s*64+m]=word(s*64+m,12);dut.pm_s12[s*64+m]=word(s*64+m,13);
                dut.pm_s22[s*64+m]=word(s*64+m,14);dut.pm_swo[s*64+m]=word(s*64+m,15);
            end
        end
        for(int i=0;i<512;i++)begin
            dut.u_modr.u_pitch.ratio0[i]=table_words[i][24:0];
            dut.u_modr.u_pitch.ratio1[i]=table_words[i][24:0];
        end
        @(negedge clk);release dut.state;release dut.inst_lat;release dut.inst_prev;
        release dut.nm_lat;release dut.table_valid;release dut.zero_frames;
        run=1;
        for(int s=0;s<16;s++)fmap.raw[s*8 +:8]=8'(180+s*3);
        repeat(TEST_FRAMES)@(posedge tick);
        @(negedge clk);
        $display("RESULT cap=%0d inst=%0d frames=%0d outputs=%0d audio=%0d job=%0d jobs_min=%0d jobs_max=%0d commits=%0d coverage=%0d tail=%0d deferred=%0d nonzero=%0d late_pairs=%0d gap=%0d",
            CAP,INSTRUMENT,checked_frames,outputs,max_audio,max_job,min_jobs,max_jobs,commits,lowest_coverage,max_tail,deferred,nonzero,late_pairs,max_gap);
        $display("DEBUG gate=%h trigger=%h x0=%d env0=%d cfg=%h mix=%d",dut.part_gate,dut.note_f,dut.xmap[0],dut.emap[0],dut.active_play[0],dut.mix_q);
        if(overlap_reads!=0 || total_coverage!=16'hffff || outputs<TEST_FRAMES-5 || nonzero==0)
            $fatal(1,"FAIL scheduler coverage/audio");
        $display("PASS tb_mod1_budget");$finish;
    end
    always @(posedge clk)begin
        cycle++;
        if(!run)begin divider<=0;tick<=0;end
        else begin
            tick<=divider==FRAME_CYCLES-1;
            divider<=divider==FRAME_CYCLES-1?0:divider+1;
            if(tick)begin
                if(frame>4)begin
                    if(frame_jobs<min_jobs)min_jobs=frame_jobs;
                    if(frame_jobs>max_jobs)max_jobs=frame_jobs;
                    if($countones(coverage)<lowest_coverage)lowest_coverage=$countones(coverage);
                    if(last_commit>engine_end && last_commit-engine_end>max_tail)max_tail=last_commit-engine_end;
                    checked_frames++;
                end
                frame++;origin=cycle;frame_jobs=0;coverage=0;
                if(dut.mod_busy)$fatal(1,"FAIL in-place job crossed sample boundary");
            end
            read_av=dut.era_co_re;read_bv=dut.erb_co_re;
            read_a=int'(dut.g)*64+int'(dut.era_co_addr);
            read_b=(int'(dut.g)+8)*64+int'(dut.erb_co_addr);
            if(dut.mod_start && dut.mod1_path)begin
                starts++;job_start=cycle;job_slot=dut.mod_slot;
                if(!dut.mod_safe[job_slot])$fatal(1,"FAIL launch before engine retirement");
                expected_delta[job_slot]=delta_for(dut.fmap_q.raw[job_slot*8 +:8]);
            end
            if(dut.mod1_path && |dut.mod_eligible && !dut.mod_busy && !dut.mod_window_ok)deferred++;
            if(dut.mod_co_we[1])begin
                integer a;longint signed v;
                a=int'(dut.mod_slot)*64+int'(dut.mod_co_mode);
                if((a%64)>=CAP)$fatal(1,"FAIL write beyond cap");
                v=word(a,9)+((64'(word(a,13))*64'(expected_delta[job_slot])+2097152)>>>22);
                if(v>word(a,10))v=word(a,10);if(v<word(a,8))v=word(a,8);
                if(dut.mod_co_wdata.a12!==32'(v))$fatal(1,"FAIL coefficient arithmetic");
                expected_a1[a]=32'(v);pending_a1[a]=1;writes++;
                if(dut.state==dut.S_RUN_V && dut.g==job_slot%8)begin
                    overlap_reads++;$fatal(1,"FAIL write during slot engine job");
                end
            end
            if(dut.pitch_commit)begin
                if(last_slot_commit[job_slot]!=0 && cycle-last_slot_commit[job_slot]>max_gap)
                    max_gap=cycle-last_slot_commit[job_slot];
                last_slot_commit[job_slot]=cycle;
                commits++;frame_jobs++;coverage[job_slot]=1;total_coverage[job_slot]=1;last_commit=cycle;
                if(cycle-job_start>max_job)max_job=cycle-job_start;
                if($signed(dut.pitch_delta[job_slot*24 +:24])!=expected_delta[job_slot])$fatal(1,"FAIL delta arithmetic");
            end
            if(dut.state==dut.S_RUN_V && dut.era_yv && dut.erb_yv)begin
                if(frame>4 && dut.g>0 && (!coverage[dut.g-1] || !coverage[dut.g+7]))late_pairs++;
                if(dut.g==7)engine_end=cycle;
            end
            if(yv)begin
                outputs++;if(y!=0)nonzero++;
                if(cycle-origin>max_audio)max_audio=cycle-origin;
                if(cycle-origin>=FRAME_CYCLES)$fatal(1,"FAIL audio deadline");
            end
        end
    end
    // Every computed frame changes all 16 pressures (no easy unchanged-slot case).
    always @(negedge clk)if(run && tick && frame>2)
        for(int s=0;s<16;s++)fmap.raw[s*8 +:8]=8'(130+((frame*31+s*7)%120));
    initial begin #((TEST_FRAMES+4)*FRAME_CYCLES*20);$fatal(1,"budget watchdog");end
endmodule
