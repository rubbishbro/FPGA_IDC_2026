`timescale 1ns/1ps
// Real UI loop/dispatch/mailbox -> real configuration FSM -> real loader/router.
// Only Flash and pixel frame pulses are models. Menu requests also exercise source0.
module tb_joint_config;
    import config_pkg::*;
    import router_pkg::*;
    logic clk=0,pix_clk=0,rst_n=0;
    always #5 clk=~clk;
    always #7 pix_clk=~pix_clk;
    logic [10:0] pixels=0;
    always @(posedge pix_clk) if(!rst_n)pixels<=0;else pixels<=pixels==1999?0:pixels+1'b1;
    wire frame_pulse=pixels==1999;
    logic ext_valid=0,ext_ready,ext_rsp_valid,ext_rsp_ready=0;
    cfg_request_t ext_request;
    cfg_response_t ext_response,backend_response;
    logic backend_valid,backend_ready,backend_source,backend_rsp_valid,backend_rsp_ready;
    cfg_request_t backend_request;
    logic [19:0] backend_supported;
    audio_config_t audio_state;
    logic audio_valid,audio_fault;
    cfg_values_t values;
    sidebar_scene_t scene;
    logic key_valid=0;
    logic [2:0] key_event=0;
    logic event_valid=0,event_ready;
    logic [31:0] event_data=0;
    logic midi_idle,config_busy,config_failed,load_err,y_valid;
    logic [1:0] cleanup_done;
    logic [3:0] active_channel;
    logic active_bank;
    logic signed [63:0] y_data;
    logic cs,sck,oe,blank=0;
    logic [3:0] dqo,dqi;
    integer checks=0,accepted=0,completed=0,menu_completed=0;
    pad_driver_pkg::mat4x4 fmap='0;
    sidebar_system #(.CTRL_HZ(1_000_000),.HAS_JOYSTICK(0),.AUDIO_BACKEND(1)) ui(
        .rst_n(rst_n),.ctrl_clk(clk),.pix_clk(pix_clk),
        .joy_sample_valid(1'b0),.joy_raw_x(14'd0),.joy_raw_y(14'd0),
        .key_valid(key_valid),.key_event(key_event),
        .ext_cfg_valid(ext_valid),.ext_cfg_ready(ext_ready),.ext_cfg_request(ext_request),
        .ext_rsp_valid(ext_rsp_valid),.ext_rsp_ready(ext_rsp_ready),.ext_cfg_response(ext_response),
        .backend_supported(backend_supported),.backend_valid(backend_valid),.backend_ready(backend_ready),
        .backend_request(backend_request),.backend_source(backend_source),
        .backend_rsp_valid(backend_rsp_valid),.backend_rsp_ready(backend_rsp_ready),.backend_response(backend_response),
        .backend_audio_valid(audio_valid),.backend_audio_fault(audio_fault),.backend_audio_state(audio_state),
        .frame_pulse(frame_pulse),.lcd_valid(1'b0),.pix_x(10'd0),.pix_y(9'd0),
        .q_y(10'd0),.q_ov(10'd0),.wave_rd_data(10'd0),.wave_rd_addr(),
        .curve_rd_data(40'd0),.curve_rd_addr(),.lcd_r(),.lcd_g(),.lcd_b(),.lcd_valid_out(),
        .active_values(values),.ui_scene(scene),.sidebar_width()
    );
    midi_voice_top #(.SLOTS(16),.N_MODES(64),.NOTE_BANKS(1),.CONFIG_BACKEND(1),
        .RESOURCE_MASK(10'b0000000011),.CONFIG_TIMEOUT_CYCLES(1_000_000)) sound(
        .clk(clk),.rst_n(rst_n),.run(1'b1),.fmap(fmap),
        .pad_instrument(INST_PIANO),.reverb_preset(REVERB_NONE),
        .reload(1'b0),.midi_select(1'b0),.midi_source_id(1'b0),.panic(1'b0),
        .selected_channel(4'd0),.note_bank(1'b0),.first_midi_note(7'd48),.slot_note_map('0),
        .backend_valid(backend_valid),.backend_ready(backend_ready),.backend_request(backend_request),
        .backend_source(backend_source),.backend_rsp_valid(backend_rsp_valid),.backend_rsp_ready(backend_rsp_ready),
        .backend_response(backend_response),.backend_supported(backend_supported),
        .backend_audio_valid(audio_valid),.backend_audio_fault(audio_fault),.backend_audio_state(audio_state),
        .event_valid(event_valid),.event_ready(event_ready),.event_data(event_data),.event_source_id(1'b0),
        .source_cleanup_req(2'b0),.source_cleanup_done(cleanup_done),.source_ops_idle(),.midi_ops_idle(midi_idle),
        .control_valid(),.control_cancel(),.control_ready(1'b0),.control_data(),.control_source_id(),
        .channel_mapped(),.config_busy(config_busy),.config_failed(config_failed),
        .active_channel(active_channel),.active_bank(active_bank),.rejected_note_count(),
        .unsupported_count(),.control_timeout_count(),.dropped_count(),.error_sticky(),
        .ready(),.done(),.load_err(load_err),.y_valid(y_valid),.y_data(y_data),
        .qspi_cs_n(cs),.qspi_sck(sck),.qspi_dq_oe(oe),.qspi_dq_o(dqo),.qspi_dq_i(dqi)
    );
    w25q64_read_model #(.N_MODES(64)) flash(.cs_n(cs),.sck(sck),.dq_o(dqo),.dq_oe(oe),.blank(blank),.dq_i(dqi));
    task automatic ck(input logic ok,input string msg);
        checks++;if(ok!==1'b1)$fatal(1,"FAIL %s",msg);
    endtask
    always @(posedge clk) if(rst_n)begin
        if(backend_valid && backend_ready)accepted++;
        if(backend_rsp_valid && backend_rsp_ready)completed++;
        if(ui.ui_rsp_valid)menu_completed++;
        if(values[11]!=0 && values[0]!=midi_instrument(5'(values[12])))
            $fatal(1,"FAIL control-domain half joint configuration");
        if(config_failed && y_valid && y_data!=0)$fatal(1,"FAIL audio after failed configuration");
    end
    always @(posedge pix_clk) if(rst_n && ui.pixel_view.values[11]!=0 &&
        ui.pixel_view.values[0]!=midi_instrument(5'(ui.pixel_view.values[12])))
        $fatal(1,"FAIL pixel-domain half joint configuration");
    task automatic send(input logic [15:0] tag,id,input integer value);
        @(negedge clk);ext_request={tag,id,32'(value)};ext_valid=1;
        while(!ext_ready)@(negedge clk);
        @(negedge clk);ext_valid=0;
    endtask
    task automatic result(input logic [15:0] tag,id,input logic [7:0] code);
        wait(ext_rsp_valid);@(negedge clk);
        ck(ext_response.tag==tag && ext_response.id==id && ext_response.result==code,"matching final result");
        ext_rsp_ready=1;@(negedge clk);ext_rsp_ready=0;
    endtask
    task automatic request(input logic [15:0] tag,id,input integer value);
        send(tag,id,value);result(tag,id,CFG_OK);
    endtask
    task automatic key(input logic [2:0] ev);
        @(negedge clk);key_event=ev;key_valid=1;@(negedge clk);key_valid=0;
        repeat(4)@(negedge clk);
    endtask
    task automatic note_on;
        @(negedge clk);event_data={4'd1,4'd0,7'd60,7'd100,10'b0};event_valid=1;
        while(!event_ready)@(negedge clk);
        @(negedge clk);event_valid=0;while(!midi_idle)@(negedge clk);
    endtask
    initial begin
        ext_request='0;repeat(5)@(negedge clk);rst_n=1;
        wait(audio_valid);repeat(5)@(negedge clk);
        ck(values[0]==0 && values[12]==2 && values[11]==0,"boot synchronizes actual defaults");
        send(1,16'h0500,1);wait(config_busy);
        ck(values[11]==0,"pending source is not active");
        result(1,16'h0500,CFG_OK);
        ck(values[11]==1 && values[0]==0 && values[12]==2,"MIDI source commits mapped piano");
        // Local menu: open -> sound -> instrument -> guitar -> confirm.
        key(2);key(2);key(2);key(1);key(2);
        wait(!scene.busy);repeat(5)@(negedge clk);
        ck(scene.has_result && scene.result==CFG_OK && menu_completed==1,"local UI received its own completion");
        ck(values[0]==1 && values[12]==1 && active_channel==0,"one menu request jointly commits guitar/channel1");
        note_on();ck(sound.u_notes.slot_gate[12],"held guitar note before switch");
        // Select piano while the note is held; no second channel request is sent.
        key(2);key(3);key(2);wait(config_busy);
        ck(values[0]==1 && values[12]==1,"old pair held during loading");
        wait(!scene.busy);repeat(5)@(negedge clk);
        ck(values[0]==0 && values[12]==2 && sound.u_notes.slot_owned==0,"piano switch clears held note and commits both fields");
        request(2,16'h0501,1);
        ck(values[0]==1 && values[12]==1,"channel edit reverse-maps guitar in same transaction");
        begin
            integer before_spi;before_spi=flash.transactions;
            send(3,16'h0100,2);result(3,16'h0100,CFG_UNSUPPORTED);
            send(4,16'h0501,0);result(4,16'h0501,CFG_UNSUPPORTED);
            ck(values[0]==1 && values[12]==1 && flash.transactions==before_spi,"unsupported resource/all-channel cannot partially change state");
        end
        blank=1;send(5,16'h0100,0);result(5,16'h0100,CFG_FAILED);
        ck(audio_fault && !audio_valid && !sound.u_voice.table_valid && sound.u_voice.inst_prev==INST_GUITAR,
           "failed table is not a successful instrument commit");
        ck(values[0]==1 && values[12]==1,"failure preserves both last-successful UI identities");
        wait(ui.pixel_view.scene.has_result && ui.pixel_view.scene.result==CFG_FAILED);
        blank=0;request(6,16'h0100,0);
        ck(!audio_fault && values[0]==0 && values[12]==2,"explicit retry recovers same target");
        request(7,16'h0300,1);
        ck(values[5]==1 && active_bank==1 && sound.u_voice.ca_a11_b[0]==32'h10180000,
           "full16-slot/64-mode upper-half offsets match 32-note resource");
        request(8,16'h0500,0);request(9,16'h0100,1);
        ck(values[0]==1 && values[12]==2 && values[11]==0,"PAD instrument remains independent");
        request(10,16'h0500,2);
        ck(values[0]==0 && values[12]==2 && values[11]==2,"return to MIDI publishes channel-bound instrument and BT source");
        request(11,16'h0200,2);
        ck(values[2]==2 && sound.reverb_q==REVERB_BATHROOM,"UI reverb enumeration explicitly translated");
        // Stalled maintenance has a real failure result; timeout is never success.
        force sound.u_voice.smp_tick=0;
        send(12,16'h0300,0);result(12,16'h0300,CFG_FAILED);
        ck(audio_fault && cleanup_done==0 && values[5]==1,"timeout does not publish target bank or false cleanup completion");
        release sound.u_voice.smp_tick;
        request(13,16'h8001,0);
        ck(!audio_fault && sound.u_notes.slot_owned==0,"clear action recovers only after real maintenance");
        wait(ui.pixel_view.values[11]==values[11] && ui.pixel_view.values[0]==values[0] &&
             ui.pixel_view.values[12]==values[12]);
        ck(accepted==completed,"one final result per accepted backend transaction");
        $display("PASS tb_joint_config checks=%0d accepted=%0d menu_results=%0d",checks,accepted,menu_completed);$finish;
    end
    initial begin #200000000;$fatal(1,"FAIL joint config watchdog state=%0d cfg=%0d voice=%0d",ui.u_config.state,sound.cfg_state,sound.u_voice.state);end
endmodule
