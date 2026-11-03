`timescale 1ns/1ps
// Real production router/parts/engines. Blank Flash exercises boot/error return;
// synthetic coefficient return-bus fixtures isolate routing, not instrument acoustics.
module tb_router_midi;
    import router_pkg::*;
    logic clk=0,rst_n=0,run=1;
    always #5 clk=~clk;
    pad_driver_pkg::mat4x4 fmap='0;
    instrument_e pad_instrument=INST_PIANO;
    reverb_preset reverb_preset_i=REVERB_NONE;
    logic reload=0,midi_select=1;
    logic [3:0] selected_channel=1;
    logic [27:0] slot_note_map={7'd60,7'd44,7'd42,7'd40};
    logic event_valid=0,event_ready,event_source_id=0;
    logic [31:0] event_data=0;
    logic [1:0] source_cleanup_req=0,source_cleanup_done,source_ops_idle;
    logic midi_ops_idle,control_valid,control_ready=0,control_source_id,channel_mapped;
    logic [31:0] control_data,rejected_note_count;
    logic ready,done,load_err,y_valid;
    logic signed [63:0] y_data;
    logic [3:0] qspi_i;
    logic config_busy,config_failed;
    w25q64_read_model #(.N_MODES(4)) flash(.cs_n(dut.qspi_cs_n),.sck(dut.qspi_sck),
        .dq_o(dut.qspi_dq_o),.dq_oe(dut.qspi_dq_oe),.blank(1'b0),.dq_i(qspi_i));
    integer frames=0,checks=0,triggers=0,outputs=0,nonzero_outputs=0;
    logic [7:0] expected_level;
    midi_voice_top #(.SLOTS(4),.N_MODES(4),.SINGLE_SOURCE(0),.CONTROL_SUPPORTED(5'b10000),.CLK_HZ(10_000_000),.SR_HZ(10_000)) dut (
        .backend_source_valid(1'b1),.clk(clk),.rst_n(rst_n),.run(run),.fmap(fmap),.pad_instrument(pad_instrument),
        .reverb_preset(reverb_preset_i),.reload(reload),.midi_select(midi_select),
        .midi_source_id(1'b0),.panic(1'b0),.note_bank(1'b0),.first_midi_note(7'd0),
        .config_busy(config_busy),.config_failed(config_failed),.active_channel(),.active_bank(),
        .control_cancel(),.unsupported_count(),.control_timeout_count(),.dropped_count(),.error_sticky(),
        .backend_valid(1'b0),.backend_source(1'b0),.backend_ready(),.backend_request('0),
        .backend_rsp_valid(),.backend_rsp_ready(1'b1),.backend_response(),.backend_supported(),
        .backend_audio_valid(),.backend_audio_fault(),.backend_audio_state(),
        .selected_channel(selected_channel),.slot_note_map(slot_note_map),
        .event_valid(event_valid),.event_ready(event_ready),.event_data(event_data),.event_source_id(event_source_id),
        .source_cleanup_req(source_cleanup_req),.source_cleanup_done(source_cleanup_done),.source_ops_idle(source_ops_idle),
        .midi_ops_idle(midi_ops_idle),.control_valid(control_valid),.control_ready(control_ready),
        .control_data(control_data),.control_source_id(control_source_id),.channel_mapped(channel_mapped),
        .rejected_note_count(rejected_note_count),.ready(ready),.done(done),.load_err(load_err),
        .y_valid(y_valid),.y_data(y_data),.qspi_cs_n(),.qspi_sck(),.qspi_dq_oe(),.qspi_dq_o(),.qspi_dq_i(qspi_i)
    );
    task automatic ck(input logic ok,input string msg);
        checks++;
        if(ok!==1'b1) $fatal(1,"FAIL %s",msg);
    endtask
    // Registered instrument must equal the previous combinational contract
    // on every settled cycle, including mode/channel commit and fault paths.
    always @(negedge clk)if(rst_n && dut.inst_use !==
        (dut.mode_q && dut.channel_mapped ? dut.mapped_inst : dut.pad_q))
        $fatal(1,"FAIL instrument commit changed timing or identity");
    always @(posedge clk) if(rst_n) begin
        if(dut.u_voice.frame_start) frames++;
        if(y_valid) begin
            outputs++;
            if($isunknown(y_data)) $fatal(1,"FAIL unknown audio output");
            if(y_data!=0) nonzero_outputs++;
        end
        if(dut.u_voice.part_tick && dut.u_voice.part_trigger[3]) begin
            triggers++;
            expected_level=dut.u_voice.part_strike[31:24];
            #1;
            if(dut.u_voice.u_exc.u_gen.tgt[3] !== (32'(expected_level)<<16))
                $fatal(1,"FAIL velocity did not reach actual excitation target");
            if(dut.u_voice.u_env.u_adsr.lvl[3]!==0)
                $fatal(1,"FAIL retrigger did not reset actual envelope");
        end
    end
    task automatic wait_frames(input integer n);
        integer target;
        target=frames+n;
        while(frames<target) @(negedge clk);
        // Wait for those frames to retire too.
        while(!done) @(negedge clk);
    endtask
    task automatic send(input bit src,input integer kind,ch,d1,d2);
        @(negedge clk);
        event_valid=1;event_source_id=src;
        event_data={kind[3:0],ch[3:0],d1[6:0],d2[6:0],10'b0};
        while(!event_ready) @(negedge clk);
        @(negedge clk);event_valid=0;
    endtask
    task automatic drained;
        while(!midi_ops_idle) @(negedge clk);
        @(negedge clk);
    endtask
    task automatic coefficients;
        // Legal simulation force on coefficient return buses; the production
        // state RAM read/write schedule remains real. No always_ff RAM writes
        // from the testbench and no suppression of multiple-driver checks.
        force dut.u_voice.co_ra = {32'd268435456,32'd0,32'd0,32'd268435456,
                                   32'd1073741824,32'd0,32'd32768};
        force dut.u_voice.co_rb = {32'd268435456,32'd0,32'd0,32'd268435456,
                                   32'd1073741824,32'd0,32'd32768};
    endtask
    initial begin
        repeat(5) @(negedge clk);rst_n=1;
        wait(dut.channel_q==1 && dut.u_voice.inst_prev==INST_PIANO && midi_ops_idle);
        wait(done);@(negedge clk);coefficients();
        ck(!load_err && !config_failed,"valid Flash configuration committed");
        send(0,1,1,60,1);
        ck(!midi_ops_idle && !event_ready,"first On stays in flight until real engine frame completes");
        drained();
        ck(dut.u_voice.note_on[3] && fmap.raw==0 && triggers==1,"velocity1 bypasses PAD threshold");
        ck(dut.u_voice.u_exc.u_gen.tgt[3]==(32'(2)<<16),"low velocity target is exact");
        wait_frames(40);
        // 力度 1 的激励只有 2<<16，进钢琴腔体后会被整数截断成 0（不是设计错误），
        // 所以这里只查引擎状态真的被写入；音频非零放到力度 127 之后查。
        ck(dut.u_voice.q_ram_b[4]>0,"low velocity reaches real engine state");
        send(0,1,1,60,64);drained();
        ck(triggers==2 && dut.u_voice.u_exc.u_gen.tgt[3]==(32'(129)<<16),"same gate retrigger with velocity64");
        wait_frames(3);
        send(0,1,1,60,127);drained();
        ck(triggers==3 && dut.u_voice.u_exc.u_gen.tgt[3]==(32'(255)<<16),"velocity127 full excitation target");
        wait_frames(40);
        ck(nonzero_outputs>0,"MIDI velocity reaches audio output");
        ck(dut.u_voice.mod_req==0 && !dut.u_voice.mod_start,"MIDI velocity never requests pressure tuning");
        send(0,2,1,64,127);drained();send(0,0,1,60,0);drained();
        ck(dut.u_voice.note_on[3] && !dut.u_notes.slot_key_down[3],"sustain holds actual engine gate");
        send(0,2,1,64,0);drained();
        ck(!dut.u_voice.note_on[3] && dut.u_voice.u_env.u_adsr.lvl[3]>0,"Off enters release without hard clear");
        send(1,1,1,60,80);drained();
        ck(rejected_note_count==1 && !dut.u_notes.slot_source[3] && !dut.u_notes.slot_gate[3],
           "another owner cannot overwrite a releasing voice");
        send(1,1,1,40,80);drained();wait_frames(4);
        ck(dut.u_voice.q_ram_a[0]!=0,"other source has independent state");
        send(0,2,1,120,0);drained();
        for(integer i=4;i<8;i++)
            ck(dut.u_voice.q_ram_b[i]==0 && dut.u_voice.v_ram_b[i]==0,"hard clear retires after all target modes written zero");
        ck(dut.u_voice.q_ram_a[0]!=0 && dut.u_voice.note_on[0],"hard clear preserves other source");
        source_cleanup_req=2;
        while(!source_cleanup_done[1]) @(negedge clk);
        for(integer i=0;i<4;i++) ck(dut.u_voice.q_ram_a[i]==0,"source ack follows actual state clear");
        source_cleanup_req=0;repeat(3) @(negedge clk);
        // Non-note controls are held for a real consumer, not falsely acked.
        send(0,4,1,0,64);
        wait(control_valid);wait_frames(2);
        ck(!event_ready && !midi_ops_idle && control_data=={4'd4,4'd1,7'd0,7'd64,10'b0},"control backend backpressure");
        control_ready=1;@(negedge clk);control_ready=0;drained();
        // Same instrument source switch still reloads base coefficients.
        midi_select=0;
        wait(!dut.u_voice.active_midi && dut.u_notes.slot_owned==0 && midi_ops_idle);
        wait_frames(2);
        midi_select=1;
        wait(dut.u_voice.active_midi && dut.u_voice.inst_prev==INST_PIANO);
        wait_frames(3);drained();
        ck(dut.u_voice.note_on==0,"same-instrument source switch cannot replay old MIDI keys");
        // Hold a piano key while selecting guitar: clear old ownership first.
        send(0,1,1,60,80);drained();selected_channel=0;
        wait(dut.channel_q==0 && dut.u_voice.inst_prev==INST_GUITAR && midi_ops_idle);
        wait(done);@(negedge clk);coefficients();
        ck(dut.u_notes.slot_gate==0 && dut.u_notes.slot_owned==0,"channel switch cleaned old notes");
        send(0,1,1,60,80);drained();
        ck(dut.u_notes.slot_gate==0,"new On on unselected channel is filtered");
        send(0,1,0,40,64);drained();
        ck(dut.u_voice.u_exc.u_gen.tgt[0]==(32'(129)<<16),"guitar uses its own excitation parameters");
        wait_frames(2);
        ck(dut.u_voice.emap[0]==32'sh7fffffff,"guitar MIDI envelope does not multiply velocity twice");
        // Switching to PAD clears MIDI physical state before acknowledging its cleanup.
        fmap.raw=128'd250 << 8;midi_select=0;
        wait(!dut.u_voice.active_midi && dut.u_notes.slot_owned==0 && midi_ops_idle);
        wait_frames(4);
        ck(dut.u_voice.note_on[1] && !dut.u_voice.note_on[0],"PAD selected after MIDI cleanup");
        ck(dut.u_voice.strike_level[15:8]==250,"PAD pressure reaches excitation unchanged");
        $display("PASS tb_router_midi checks=%0d triggers=%0d outputs=%0d",checks,triggers,outputs);$finish;
    end
    initial begin #20000000;$fatal(1,"FAIL timeout frames=%0d state=%0d channel=%0d maintenance=%0d",frames,dut.u_voice.state,dut.channel_q,dut.cfg_state);end
endmodule
