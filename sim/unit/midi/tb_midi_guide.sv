`timescale 1ns/1ps
// Real config loop, display CDC, loader, pressure path and engines; synthetic Flash coefficients.
module tb_midi_guide;
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
    midi_voice_top #(.SLOTS(16),.N_MODES(4),.CLK_HZ(10_000_000),.SR_HZ(1000),
        .NOTE_BANKS(1),.CONFIG_BACKEND(1),.SINGLE_SOURCE(0),.CONFIG_TIMEOUT_CYCLES(3_000_000)) sound(
        .clk(clk),.rst_n(rst_n),.audio_clk(clk),.run(1'b1),.fmap(fmap),
        .pan_position(6'd16),.itd_enable(1'b0),.amp_bclk(),.amp_ws(),.amp_din(),
        .audio_sample_tick(),.audio_deadline_miss(),.audio_overflow(),.audio_underflow(),.pad_instrument(INST_PIANO),.reverb_preset(REVERB_NONE),
        .reload(1'b0),.midi_select(1'b0),.midi_source_id(1'b0),.panic(1'b0),.selected_channel(4'd1),
        .note_bank(1'b0),.first_midi_note(7'd48),.slot_note_map(default_note_map()),
        .backend_valid(backend_valid),.backend_ready(backend_ready),.backend_source(backend_source),.backend_request(backend_request),
        .backend_rsp_valid(backend_rsp_valid),.backend_rsp_ready(backend_rsp_ready),.backend_response(backend_response),
        .backend_supported(supported),.backend_audio_valid(audio_valid),.backend_audio_fault(audio_fault),.backend_audio_state(audio_state),
        .guide_display(guide),.event_valid(event_valid),.event_ready(event_ready),.event_data(event_data),.event_source_id(event_source),
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
    initial begin
        repeat(5)@(negedge clk);rst_n=1;wait(audio_valid);repeat(6)@(negedge clk);
        config_send(16'h0503,1);config_result(CFG_UNSUPPORTED);
        ck(values[20]==0 && !audio_state.guide,"PAD cannot enable guide");
        config_set(16'h0500,1);ck(values[11]==1 && values[20]==0,"UART starts in auto");
        // Actual local input menu: category4 -> fourth item (stable index20) -> guide.
        key(2);repeat(4)key(1);key(2);repeat(3)key(1);key(2);
        ck(scene.edit_index==20,"guide available in local input menu");
        key(1);fmap.raw[12*8 +:8]=255;key(2);
        wait(guide.waiting_release);repeat(50)@(negedge clk);
        ck(scene.busy && values[20]==0 && !guide.enabled && !audio_valid,"held PAD delays successful guide commit");
        fmap='0;wait(!scene.busy);repeat(6)@(negedge clk);
        ck(scene.result==CFG_OK && values[20]==1 && audio_state.guide && audio_state.source==1,"mode committed through real UI/dispatch");
        wait(ui.pixel_guide.enabled);
        ck(ui.pixel_guide.audio.guide && ui.pixel_guide.note_map[12*7 +:7]==60,"whole-packet display identity/map");
        send(1,1,1,60,100);send(0,1,0,60,100);
        ck(guide.target==0,"other source/channel cannot light keys");
        send(0,1,1,60,127);send(0,1,1,62,1);
        ck(guide.target==16'h5000,"incoming MIDI chord maps to bank slots");
        samples(20);ck(triggers==0 && nonzero==0 && sound.u_notes.slot_gate==0,"MIDI prompts alone produce no engine onset or audio");
        wait(ui.pixel_guide.target==16'h5000);
        send(0,1,1,90,100);ck(guide.outside_count==1 && guide.last_outside==90,"out-of-bank pitch reported");
        fmap.raw[12*8 +:8]=255;samples(30);
        ck(triggers>0 && nonzero>0 && guide.pressed[12],$sformatf("pressure drives actual excitation/engines and display feedback triggers=%0d nz=%0d pressed=%h gate=%h note_f=%h",triggers,nonzero,guide.pressed,sound.u_voice.note_on,sound.u_voice.note_f));
        send(0,2,1,64,127);send(0,0,1,60,0);
        ck(!guide.target[12] && sound.u_voice.note_on[12],"MIDI Off/pedal never releases physical PAD");
        send(0,2,1,120,0);ck(guide.target==0 && sound.u_voice.note_on[12],"remote clear affects prompt only");
        cleanup_req=1;wait(cleanup_done[0]);samples(3);
        ck(guide.target==0 && sound.u_voice.note_on[12] && guide.link_fault,"quarantine clears prompts while user continues playing");
        cleanup_req=0;fmap='0;samples(3);
        config_set(16'h0300,1);send(0,1,1,60,100);ck(guide.target==0,"old bank pitch cannot light new bank");
        send(0,1,1,64,100);ck(guide.target==1,"new bank starts at64");
        wait(ui.pixel_guide.audio.bank && ui.pixel_guide.target==1);
        ck(ui.pixel_guide.note_map[6:0]==64,"CDC changes note labels and target together");
        config_set(16'h0500,2);ck(values[11]==2 && values[20]==0 && !guide.enabled,"switch to Bluetooth resets guide atomically");
        config_set(16'h0503,1);send(0,1,1,64,100);ck(guide.target==0,"UART ignored in Bluetooth guide");
        send(1,1,1,64,100);ck(guide.target==1,"Bluetooth uses same guide consumer");
        config_set(16'h0503,0);send(1,1,1,64,100);wait(idle);samples(3);
        ck(sound.u_notes.slot_gate[0] && sound.u_voice.note_on[0],"auto MIDI performance restored");
        config_set(16'h0503,1);ck(sound.u_notes.slot_gate==0 && guide.target==0,"auto to guide clears old MIDI ownership");
        blank=1;config_send(16'h0300,0);config_result(CFG_FAILED);
        ck(audio_fault && !guide.enabled && values[5]==1 && values[20]==1,"failed load never publishes target map/mode");
        blank=0;config_set(16'h8001,0);ck(!audio_fault && guide.enabled && guide.target==0,"explicit clear recovers guide after real reload");
        config_set(16'h0500,0);ck(values[20]==0 && audio_state.source==0,"return to PAD resets guide in joint snapshot");
        ck(accepted==13 && retired==11,"one FIFO pop and final result per sent event/config");
        $display("PASS tb_midi_guide checks=%0d events=%0d configs=%0d pad_triggers=%0d audio_nonzero=%0d",checks,accepted,retired,triggers,nonzero);$finish;
    end
    initial begin #300000000;$fatal(1,"FAIL guide integration watchdog cfg=%0d ui=%0d voice=%0d",sound.cfg_state,ui.u_config.state,sound.u_voice.state);end
endmodule
