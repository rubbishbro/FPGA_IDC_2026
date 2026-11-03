`timescale 1ns/1ps
// Real config loop, display CDC, loader, pressure path and engines; synthetic Flash coefficients.
module tb_midi_keymap;
    import config_pkg::*;
    import router_pkg::*;
    logic clk=0,pix_clk=0,rst_n=0;
    always #5 clk=~clk;
    always #7 pix_clk=~pix_clk;
    logic [10:0] pixels=0;
    always @(posedge pix_clk)if(!rst_n)pixels<=0;else pixels<=pixels==1999?0:pixels+1'b1;
    wire frame_pulse=pixels==1999;
    logic ext_valid=0,ext_ready,ext_rsp_valid,ext_rsp_ready=0;
    cfg_request_t ext_request='0,backend_request;
    cfg_response_t ext_response,backend_response;
    logic backend_valid,backend_ready,backend_source,backend_rsp_valid,backend_rsp_ready;
    cfg_supported_t supported;
    audio_config_t audio_state;
    guide_display_t guide;
    cfg_values_t values;
    sidebar_scene_t scene;
    logic audio_valid,audio_fault,key_valid=0;
    logic [2:0] key_event=0;
    logic keymap_valid=0,keymap_ready,keymap_rsp_valid,keymap_rsp_ready=0;
    logic [255:0] keymap_entries=0;
    logic [7:0] keymap_result;
    logic event_valid=0,event_ready,event_source=0;
    logic [31:0] event_data=0;
    logic [1:0] cleanup_req=0,cleanup_done;
    logic idle,ready,y_valid;
    logic signed [63:0] y_data;
    pad_driver_pkg::mat4x4 fmap='0;
    logic cs,sck,oe,blank=0;
    logic [3:0] dqo,dqi;
    integer checks=0,frames=0,triggers=0,nonzero=0,accepted=0,retired=0,tag=0;
    sidebar_system #(.CTRL_HZ(1_000_000),.HAS_JOYSTICK(0),.AUDIO_BACKEND(1)) ui(
        .rst_n(rst_n),.ctrl_clk(clk),.pix_clk(pix_clk),.joy_sample_valid(1'b0),.joy_raw_x(14'd0),.joy_raw_y(14'd0),
        .key_valid(key_valid),.key_event(key_event),
        .ext_cfg_valid(ext_valid),.ext_cfg_ready(ext_ready),.ext_cfg_request(ext_request),
        .ext_rsp_valid(ext_rsp_valid),.ext_rsp_ready(ext_rsp_ready),.ext_cfg_response(ext_response),
        .backend_supported(supported),.backend_valid(backend_valid),.backend_ready(backend_ready),
        .backend_request(backend_request),.backend_source(backend_source),
        .backend_rsp_valid(backend_rsp_valid),.backend_rsp_ready(backend_rsp_ready),.backend_response(backend_response),
        .backend_audio_valid(audio_valid),.backend_audio_fault(audio_fault),.backend_audio_state(audio_state),.guide_display(guide),
        .frame_pulse(frame_pulse),.lcd_valid(1'b0),.pix_x(10'd0),.pix_y(10'd0),.q_y(10'd0),.q_ov(10'd0),
        .wave_rd_data(10'd0),.wave_rd_addr(),.curve_rd_data(40'd0),.curve_rd_addr(),
        .lcd_r(),.lcd_g(),.lcd_b(),.lcd_valid_out(),.active_values(values),.ui_scene(scene),.sidebar_width());
    midi_voice_top #(.SLOTS(16),.N_MODES(4),.CLK_HZ(1_000_000),.SR_HZ(48000),
        .NOTE_BANKS(1),.INSTRUMENT_NOTE_RANGES(1),.RESOURCE_MASK(12'h003),.CONFIG_BACKEND(1),.SINGLE_SOURCE(0),.CONFIG_TIMEOUT_CYCLES(300_000)) sound(
        .backend_source_valid(1'b1),.clk(clk),.rst_n(rst_n),.audio_clk(clk),.run(1'b1),.fmap(fmap),
        .pan_position(6'd16),.itd_enable(1'b0),.amp_bclk(),.amp_ws(),.amp_din(),
        .audio_sample_tick(),.audio_deadline_miss(),.audio_overflow(),.audio_underflow(),.pad_instrument(INST_PIANO),.reverb_preset(REVERB_NONE),
        .reload(1'b0),.midi_select(1'b0),.midi_source_id(1'b0),.panic(1'b0),.selected_channel(4'd1),
        .note_bank(1'b0),.first_midi_note(7'd48),.slot_note_map(default_note_map()),
        .backend_valid(backend_valid),.backend_ready(backend_ready),.backend_source(backend_source),.backend_request(backend_request),
        .backend_rsp_valid(backend_rsp_valid),.backend_rsp_ready(backend_rsp_ready),.backend_response(backend_response),
        .backend_supported(supported),.backend_audio_valid(audio_valid),.backend_audio_fault(audio_fault),.backend_audio_state(audio_state),
        .guide_display(guide),.keymap_valid(keymap_valid),.keymap_ready(keymap_ready),.keymap_entries(keymap_entries),
        .keymap_rsp_valid(keymap_rsp_valid),.keymap_rsp_ready(keymap_rsp_ready),.keymap_result(keymap_result),.event_valid(event_valid),.event_ready(event_ready),.event_data(event_data),.event_source_id(event_source),
        .source_cleanup_req(cleanup_req),.source_cleanup_done(cleanup_done),.source_ops_idle(),.midi_ops_idle(idle),
        .control_valid(),.control_ready(1'b0),.control_data(),.control_source_id(),.control_cancel(),
        .channel_mapped(),.config_busy(),.config_failed(),.active_channel(),.active_bank(),.rejected_note_count(),
        .unsupported_count(),.control_timeout_count(),.dropped_count(),.error_sticky(),
        .ready(ready),.done(),.load_err(),.y_valid(y_valid),.y_data(y_data),
        .qspi_cs_n(cs),.qspi_sck(sck),.qspi_dq_oe(oe),.qspi_dq_o(dqo),.qspi_dq_i(dqi));
    w25q64_read_model #(.N_MODES(4),.ENG0_COEFF(1)) flash(
        .cs_n(cs),.sck(sck),.dq_o(dqo),.dq_oe(oe),.blank(blank),.dq_i(dqi));
    always @(posedge clk)if(rst_n)begin
        if(sound.u_voice.frame_start)frames++;
        if(sound.u_voice.frame_start && (|sound.u_voice.note_f))triggers++;
        if(y_valid && y_data!=0)nonzero++;
        if(event_valid && event_ready)accepted++;
        if(backend_rsp_valid && backend_rsp_ready)retired++;
        if(guide.enabled && sound.u_voice.midi_select)$fatal(1,"FAIL guide leaked into MIDI synth selector");
        if(guide.enabled && sound.state_valid)$fatal(1,"FAIL guide delivered event to audio consumer");
    end
    task automatic ck(input logic ok,input string msg);
        checks++;if(ok!==1'b1)$fatal(1,"FAIL %s",msg);
    endtask
    task automatic config_send(input logic[15:0] id,input integer value);
        @(negedge clk);tag++;ext_request={16'(tag),id,32'(value)};ext_valid=1;
        while(!ext_ready)@(negedge clk);
        @(negedge clk);ext_valid=0;
    endtask
    task automatic config_result(input logic[7:0] code);
        wait(ext_rsp_valid);@(negedge clk);
        ck(ext_response.tag==tag && ext_response.id==ext_request.id && ext_response.result==code,"matched final config result");
        ext_rsp_ready=1;@(negedge clk);ext_rsp_ready=0;
    endtask
    task automatic config_set(input logic[15:0] id,input integer value);
        config_send(id,value);config_result(CFG_OK);
    endtask
    task automatic key(input integer ev);
        @(negedge clk);key_valid=1;key_event=3'(ev);@(negedge clk);key_valid=0;repeat(4)@(negedge clk);
    endtask
    task automatic send(input bit src,input integer kind,ch,note,velocity);
        @(negedge clk);event_source=src;event_data={4'(kind),4'(ch),7'(note),7'(velocity),10'd0};event_valid=1;
        while(!event_ready)@(negedge clk);
        @(negedge clk);event_valid=0;repeat(4)@(negedge clk);
    endtask
    task automatic samples(input integer count);
        integer goal;goal=frames+count;
        while(frames<goal)@(negedge clk);
        wait(sound.done);@(negedge clk);
    endtask
    task automatic table_prepare(input integer instrument);
        for(integer i=0;i<16;i++)begin
            keymap_entries[i*16 +:8]=8'(instrument);
            // Repeated notes, reordered, drawn across the complete 32-note range.
            keymap_entries[i*16+8 +:8]=8'(router_pkg::note_first(router_pkg::instrument_e'(instrument))+((63-i*3)%32));
        end
        keymap_entries[16+8 +:8]=keymap_entries[8 +:8];
    endtask
    task automatic table_send;
        @(negedge clk);keymap_valid=1;
        while(!keymap_ready)@(negedge clk);
        @(negedge clk);keymap_valid=0;
    endtask
    task automatic table_result(input integer expected);
        wait(keymap_rsp_valid);@(negedge clk);
        ck(keymap_result==expected,$sformatf("table result got %0d expected %0d",keymap_result,expected));
        keymap_rsp_ready=1;@(negedge clk);keymap_rsp_ready=0;
        repeat(20)@(negedge clk);
    endtask
    logic [111:0] saved_map;
    integer old_transactions;
    initial begin
        repeat(5)@(negedge clk);rst_n=1;wait(audio_valid);repeat(20)@(negedge clk);
        ck(!audio_state.custom_keys && sound.note_map[6:0]==21,"default low bank boot");$display("KEYMAP boot t=%t",$time);
        table_prepare(0);fmap.raw[0 +:8]=255;table_send();
        wait(guide.waiting_release);$display("KEYMAP waiting_release t=%t",$time);repeat(20)@(negedge clk);
        ck(!keymap_rsp_valid && !audio_state.custom_keys && values[5]==0,"no custom commit before PAD release");
        fmap='0;table_result(0);
        wait(values[5]==2);wait(ui.pixel_guide.audio.custom_keys);$display("KEYMAP custom committed t=%t",$time);
        ck(audio_valid && audio_state.custom_keys && sound.note_map[6:0]==52 && sound.note_map[13:7]==52,"custom duplicate map committed");
        ck(sound.offsets[31:0]==31*4*64 && sound.offsets[63:32]==31*4*64,"duplicate/cross-bank offsets match MIDI-first");
        ck(ui.pixel_guide.note_map==sound.note_map,"guide CDC uses the applied custom table");
        saved_map=sound.note_map;
        wait(ui.u_sidebar.value_labels[5]==126);
        key(2);key(1);key(1);key(2);key(2);
        ck(scene.edit_index==5 && scene.draft==0,"custom binding edits default groups from a valid draft");
        key(4);key(4);key(4);
        ck(values[5]==2 && sound.note_map==saved_map,"cancel default selection preserves custom binding");
        // Bad/mixed tables must not start a reload or change the committed UI.
        table_prepare(0);keymap_entries[3*16 +:8]=1;old_transactions=flash.transactions;
        table_send();table_result(3);
        ck(sound.note_map==saved_map && values[5]==2 && flash.transactions==old_transactions,"mixed instruments rejected atomically");
        table_prepare(0);keymap_entries[8 +:8]=53;
        table_send();table_result(3);
        ck(sound.note_map==saved_map && values[5]==2,"out of range rejected atomically");
        table_prepare(10);table_send();table_result(3);
        ck(sound.note_map==saved_map,"uninstalled timbre rejected");
        // PAD actually triggers its custom-mapped voice.
        fmap.raw[0 +:8]=255;samples(40);fmap='0;samples(10);
        ck(triggers>0 && nonzero>0,"custom pressure key runs real engine");
        // Guide preserves custom map across source/mode changes.
        config_set(16'h0500,2);config_set(16'h0503,1);
        ck(audio_state.custom_keys && sound.note_map==saved_map,"source change preserves custom binding");
        send(1,1,1,52,100);
        ck(guide.target[1:0]==2'b11,"duplicate custom notes light both bound keys");
        ck(guide.matched==0,"MIDI target alone is not matched");
        fmap.raw[0 +:8]=255;samples(4);
        ck(guide.matched[1:0]==2'b11 && guide.pressed[1:0]==2'b01,"first physical alias marks both targets matched");
        ck(sound.u_voice.note_on[1:0]==2'b01,"display linkage does not trigger the second voice");
        wait(ui.pixel_guide.matched[1:0]==2'b11);
        ck(ui.pixel_guide.pressed[1:0]==2'b01,"CDC preserves physical vs grouped state");
        fmap.raw[8 +:8]=255;samples(4);fmap.raw[0 +:8]=0;samples(4);
        ck(guide.matched[1:0]==2'b11 && guide.pressed[1:0]==2'b10,"remaining held alias keeps both matched");
        fmap='0;samples(4);
        ck(guide.matched==0 && guide.target[1:0]==2'b11,"last release immediately clears matched without latching");
        wait(ui.pixel_guide.matched==0);
        fmap.raw[2*8 +:8]=255;samples(4);
        ck(guide.matched==0 && guide.pressed[2],"different pitch cannot satisfy target");
        fmap='0;samples(4);fmap.raw[8 +:8]=255;samples(4);
        ck(guide.matched[1:0]==2'b11,"second alias also independently satisfies both");
        send(1,0,1,52,0);
        ck(guide.target==0 && guide.matched==0 && guide.pressed[1],"MIDI Off removes match without faking physical release");
        fmap='0;samples(4);
        // Returning to the high/default group replaces custom map and UI state.
        config_set(16'h0300,1);wait(values[5]==1);
        ck(!audio_state.custom_keys && sound.note_map[6:0]==37,"default high bank exits custom binding");
        config_set(16'h0500,0);
        // A different installed single instrument is selected by the table.
        table_prepare(1);table_send();table_result(0);wait(values[5]==2);
        ck(audio_state.instrument==1 && audio_state.custom_keys && sound.note_map[6:0]==71,"table selects guitar and its range");
        ck(sound.offsets[31:0]==31*4*64,"guitar custom offset uses guitar first MIDI");
        // Fail only the new reload, then permit the rollback to old resources.
        saved_map=sound.note_map;table_prepare(0);table_send();
        // Zero-valued coefficients are legal; inject a real loader error result
        // rather than assuming the all-zero Flash fixture is invalid.
        wait(sound.load_complete);force sound.load_err=1'b1;
        wait(sound.cfg_state==sound.C_FAULT);release sound.load_err;
        table_result(6);
        ck(audio_valid && !audio_fault && audio_state.instrument==1 && audio_state.custom_keys && sound.note_map==saved_map,"load failure restores committed guitar custom binding");
        ck(values[0]==1 && values[5]==2,"failed attempt never publishes new UI identity");
        $display("PASS tb_midi_keymap checks=%0d",checks);$finish;
    end
    initial begin #50000000;$fatal(1,"FAIL keymap watchdog cfg=%0d voice=%0d",sound.cfg_state,sound.u_voice.state);end
endmodule
