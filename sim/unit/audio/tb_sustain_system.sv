`timescale 1ns/1ps
// Real generated ABC Flash -> existing MIDI lifecycle -> router -> I2S.
// Independent sample-level arithmetic compares every synthesized output.
module tb_sustain_system;
    import router_pkg::*;
    parameter int INST=2,SAMPLES=48000;
    logic clk=0,aclk=0,rst_n=0,run=1,reload=0,bank=0,blank=0;
    always #5 clk=~clk;
    initial begin #3.137;forever #40.690104166667 aclk=~aclk;end
    logic ev=0,src=0,er,ready,failed,busy,yv,tick,late,over,under,bclk,ws,din;
    logic [31:0] data=0,rejected;
    logic signed [63:0] y;
    logic cs,sck,oe;
    logic [3:0] dqo,dqi;
    pad_driver_pkg::mat4x4 fmap='0;
    midi_voice_top #(.STEREO_ENABLE(0),.AUDIO_ENABLE(1),.NOTE_BANKS(1),.SINGLE_SOURCE(0),.RESOURCE_MASK(10'b0000111111)) dut(
        .backend_source_valid(1'b1),.clk(clk),.audio_clk(aclk),.rst_n(rst_n),.run(run),.fmap(fmap),.pad_instrument(INST_PIANO),.reverb_preset(REVERB_NONE),
        .reload(reload),.midi_select(1'b1),.midi_source_id(1'b0),.panic(1'b0),
        .selected_channel(4'(config_pkg::instrument_channel(16'(INST))-1)),.note_bank(bank),.first_midi_note(7'd48),.slot_note_map('0),
        .backend_ready(),.backend_rsp_valid(),.backend_response(),.backend_supported(),
        .backend_audio_valid(),.backend_audio_fault(),.backend_audio_state(),.source_cleanup_done(),
        .source_ops_idle(),.midi_ops_idle(),.control_valid(),.control_cancel(),.control_data(),.control_source_id(),
        .channel_mapped(),.active_channel(),.active_bank(),.unsupported_count(),.control_timeout_count(),.dropped_count(),
        .error_sticky(),.done(),.load_err(),
        .backend_valid(1'b0),.backend_source(1'b0),.backend_request('0),.backend_rsp_ready(1'b1),
        .event_valid(ev),.event_ready(er),.event_data(data),.event_source_id(src),.source_cleanup_req('0),.control_ready(1'b1),
        .ready(ready),.config_failed(failed),.config_busy(busy),.y_valid(yv),.y_data(y),.rejected_note_count(rejected),
        .qspi_cs_n(cs),.qspi_sck(sck),.qspi_dq_o(dqo),.qspi_dq_oe(oe),.qspi_dq_i(dqi),
        .amp_bclk(bclk),.amp_ws(ws),.amp_din(din),.audio_sample_tick(tick),
        .audio_deadline_miss(late),.audio_overflow(over),.audio_underflow(under));
    w25q64_read_model #(.N_MODES(64),.MEM_FILE("sustain_flash.mem"),.MEM_BYTES(12*32*4096+4096)) flash(
        .cs_n(cs),.sck(sck),.dq_o(dqo),.dq_oe(oe),.blank(blank),.dq_i(dqi));
    integer periods[32],attack[32],release_step[32];
    integer gg[32][48],aa[32][48],bb[32][48];
    integer q[16][48],v[16][48],phase[16],lvl[16],estate[16],prev_gate[16];
    integer expect_x[16],expect_e[16];
    integer core_frames=0,checks=0,pcm_frames,nz,mode_checks=0;
    logic verify=0,expect_pending=0,full_hold=0;
    longint signed expected_y,acc,shifted,sum_voice,coefficient1,coefficient2;
    logic signed [95:0] product;
    integer expected_gain=0,expected_count;
    logic [15:0] expected_pcm;
    logic pcm_pending=0;
    logic [15:0] last_pcm=0;
    wire active=run && !busy && !failed;
    assign expected_pcm=active && pcm_pending ? last_pcm : 16'd0;
    i2s_scoreboard wirecheck(clk,rst_n,bclk,ws,din,tick,expected_pcm,pcm_frames,nz);
    always @(posedge clk)if(rst_n)begin
        if(!active)pcm_pending<=0;
        else if(yv)begin
            shifted=(y+64'sd2048)>>>12;
            last_pcm<=shifted>32767?16'h7fff:shifted< -32768?16'h8000:16'(shifted);pcm_pending<=1;
        end
        if(tick)pcm_pending<=0;
        if(dut.u_voice.effects_clear)expected_gain=0;
        if(late || over || under)$fatal(1,"FAIL audio diagnostics %b %b %b",late,over,under);
        if(verify && dut.u_voice.frame_start)begin
            for(int s=0;s<16;s++)begin
                int ni;longint tmp;
                ni=int'(dut.u_voice.pending_notes[s*7 +:7])-48;
                if(ni<0 || ni>=32)$fatal(1,"FAIL resource note map");
                expect_x[s]=0;
                if(dut.u_voice.part_clear[s] || !dut.u_voice.part_gate[s])phase[s]=0;
                // Use the same frame snapshot as excitation/envelope. The
                // live performance trigger has already been consumed here.
                else if(dut.u_voice.part_trigger[s] || !prev_gate[s] || phase[s]==0)begin
                    expect_x[s]=int'(dut.u_voice.part_strike[s*8 +:8])<<16;phase[s]=periods[ni]-1;
                end else phase[s]--;
                if(dut.u_voice.part_clear[s])begin lvl[s]=0;estate[s]=0;end
                else if(dut.u_voice.part_trigger[s] || (dut.u_voice.part_gate[s] && !prev_gate[s]))begin lvl[s]=0;estate[s]=1;end
                else if(!dut.u_voice.part_gate[s])begin
                    if(lvl[s]<=(INST==5?559241:release_step[ni]))begin lvl[s]=0;estate[s]=0;end
                    else begin lvl[s]-=(INST==5?559241:release_step[ni]);estate[s]=4;end
                end else if(estate[s]==1)begin
                    tmp=longint'(lvl[s])+(INST==5?2236963:attack[ni]);
                    if(tmp>2147483647)begin lvl[s]=2147483647;estate[s]=2;end else lvl[s]=int'(tmp);
                end else if(estate[s]==2)begin
                    if(INST==5)begin lvl[s]=2147483647;estate[s]=3;end
                    else if(lvl[s]<=536870911+1048576)begin lvl[s]=536870911;estate[s]=3;end else lvl[s]-=1048576;
                end else if(estate[s]==0)estate[s]=1;
                prev_gate[s]=dut.u_voice.part_gate[s];expect_e[s]=lvl[s];
            end
        end
        if(verify && dut.u_voice.xw_run)begin
            expected_y=0;expect_pending=1;expected_count=0;
            for(int s=0;s<16;s++)begin
                int ni;bit zero;
                ni=int'(dut.u_voice.pending_notes[s*7 +:7])-48;
                zero=dut.u_voice.note_f[s] || dut.u_voice.dead_f[s] || dut.u_voice.init_zero || dut.u_voice.clear_f[s];
                if(dut.u_voice.xmap[s]!==expect_x[s] || dut.u_voice.emap[s]!==expect_e[s])
                    $fatal(1,"FAIL frame input inst=%d slot=%d x=%d/%d E=%d/%d",INST,s,dut.u_voice.xmap[s],expect_x[s],dut.u_voice.emap[s],expect_e[s]);
                if(full_hold && zero)$fatal(1,"FAIL held voice was unexpectedly cleared slot=%d",s);
                sum_voice=0;
                for(int m=0;m<48;m++)begin
                    if(zero)begin q[s][m]=0;v[s][m]=0;end
                    coefficient1=blank ? 0 : longint'(aa[ni][m]);coefficient2=blank ? 0 : longint'(bb[ni][m]);
                    acc=(blank ? 64'sd0 : longint'(gg[ni][m]))*longint'(expect_x[s])-coefficient1*longint'(q[s][m])-coefficient2*longint'(v[s][m]);
                    shifted=(acc+64'sd8388608)>>>24;
                    if(shifted>64'sd2147483647)shifted=64'sd2147483647;
                    else if(shifted< -64'sd2147483648)shifted=-64'sd2147483648;
                    v[s][m]=q[s][m];q[s][m]=int'(shifted);sum_voice+=shifted;
                end
                product=sum_voice*longint'(expect_e[s]);
                expected_y+=64'(product>>>31);
                if(expect_e[s]>0)expected_count++;
            end
            expected_gain=expected_count==4 ? 2 : (expected_count>=2 && expected_count<=7 ? 1 : 0);
            expected_y=expected_y<<<expected_gain;
            core_frames++;
        end
        if(verify && dut.u_voice.y_valid)begin
            if(!expect_pending || dut.u_voice.y_data!==expected_y)
                $fatal(1,"FAIL real ABC output frame=%d got=%d expected=%d",core_frames,dut.u_voice.y_data,expected_y);
            checks++;expect_pending=0;
        end
        if(verify && dut.u_voice.frame_retire && dut.u_voice.inst_prev==instrument_e'(INST))begin
            for(int s=0;s<16;s++)if(dut.voice_idle[s])begin
                // Idle cannot precede the actual per-slot state writes/retirement.
                if(lvl[s]!=0 || dut.u_voice.note_gate[s])$fatal(1,"FAIL premature voice idle");
            end
        end
    end
    for(genvar slot=0;slot<16;slot++)begin:g_idle_state_check
        always @(posedge dut.voice_idle[slot])begin
            #1;
            if(verify)for(int m=0;m<48;m++)begin
                if(slot<8)begin
                    if(dut.u_voice.q_ram_a[slot*64+m]!==0 || dut.u_voice.v_ram_a[slot*64+m]!==0)
                        $fatal(1,"FAIL idle before A state cleared slot=%d mode=%d",slot,m);
                end else if(dut.u_voice.q_ram_b[(slot-8)*64+m]!==0 || dut.u_voice.v_ram_b[(slot-8)*64+m]!==0)
                    $fatal(1,"FAIL idle before B state cleared slot=%d mode=%d",slot,m);
            end
        end
    end
    task automatic event_send(input int kind,key,value,source=0);
        @(negedge clk);data={4'(kind),4'(config_pkg::instrument_channel(16'(INST))-1),7'(key),7'(value),10'd0};src=1'(source);ev=1;
        do @(negedge clk);while(!er);
        ev=0;wait(dut.state_idle);@(negedge clk);
    endtask
    task automatic frames(input int count);
        repeat(count)begin @(posedge tick);@(negedge clk);end
    endtask
    integer fd,rc,base_count;
    logic [15:0] old_period;
    initial begin
        fd=$fopen($sformatf("oracle_%0d.txt",INST),"r");if(!fd)$fatal(1,"FAIL no oracle");
        for(int n=0;n<32;n++)begin
            rc=$fscanf(fd,"%d %d %d",periods[n],attack[n],release_step[n]);
            for(int m=0;m<48;m++)rc=$fscanf(fd,"%d %d %d",gg[n][m],aa[n][m],bb[n][m]);
        end
        for(int s=0;s<16;s++)begin
            phase[s]=0;lvl[s]=0;estate[s]=0;prev_gate[s]=0;
            for(int m=0;m<48;m++)begin q[s][m]=0;v[s][m]=0;end
        end
        repeat(5)@(negedge clk);rst_n=1;wait(ready);@(negedge clk);verify=1;
        event_send(1,48,1);event_send(1,56,100);frames(40);
        event_send(1,48,127); // reset phase/envelope/history while held
        frames(1000);event_send(2,64,127);event_send(0,48,0);frames(20);
        if(!dut.gate[0])$fatal(1,"FAIL sustain did not hold");
        event_send(2,64,0);
        if(dut.voice_idle[0])$fatal(1,"FAIL release skipped");
        event_send(1,48,64,1); // other owner cannot claim a releasing slot
        if(rejected==0 || dut.u_notes.slot_source[0]!=0)$fatal(1,"FAIL release owner stolen");
        wait(dut.voice_idle[0]);event_send(1,48,64,1);
        if(dut.u_notes.slot_source[0]!=1)$fatal(1,"FAIL retired slot not reusable");
        event_send(2,120,0,1);event_send(2,120,0,0);
        wait(&dut.voice_idle);frames(3);
        // All 16 slots, real 48-mode tables, one common audio time base.
        for(int s=0;s<16;s++)event_send(1,48+s,64+s*4);
        base_count=checks;full_hold=1;wait(checks-base_count>=SAMPLES);full_hold=0;
        for(int s=0;s<16;s++)event_send(0,48+s,0);
        wait(&dut.voice_idle);frames(2);
        old_period=dut.u_voice.active_play[0].period;
        // Zero payload is accepted; loader does not classify record contents.
        blank=1;bank=1;wait(busy);wait(failed);
        if(dut.active_bank!=0)$fatal(1,"FAIL invalid sustain profile committed");
        @(negedge clk);blank=0;reload=1;@(negedge clk);reload=0;wait(ready);frames(3);
        if(dut.active_bank!=1 || dut.u_voice.active_play[0].period!=periods[16])$fatal(1,"FAIL bank profile commit");
        event_send(1,64,100);frames(100);event_send(2,120,0);wait(&dut.voice_idle);
        if(checks<SAMPLES || nz<100)$fatal(1,"FAIL inadequate real audio coverage");
        $display("PASS tb_sustain_system inst=%0d all16_samples=%0d bit_exact_frames=%0d I2S_frames=%0d nonzero=%0d reject_count=%0d",INST,SAMPLES,checks,pcm_frames,nz,rejected);$finish;
    end
    initial begin #2000000000;$fatal(1,"FAIL sustain watchdog inst=%d cfg=%d state=%d",INST,dut.cfg_state,dut.u_voice.state);end
endmodule
