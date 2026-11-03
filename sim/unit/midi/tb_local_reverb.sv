`timescale 1ns/1ps
// Real UI loop/dispatch/mailbox -> real configuration FSM -> real loader/router.
// Six deployed instruments: both note banks and NONE/HALL via authoritative dispatch replies.
// Flash and pixel frame pulses are modeled; resources use the real 0x800000 layout.
module tb_local_reverb;
    import config_pkg::*;
    import router_pkg::*;
    logic clk=0,pix_clk=0,rst_n=0;
    always #10 clk=~clk;
    always #7 pix_clk=~pix_clk;
    logic [10:0] pixels=0;
    always @(posedge pix_clk) if(!rst_n)pixels<=0;else pixels<=pixels==1999?0:pixels+1'b1;
    wire frame_pulse=pixels==1999;
    logic ext_valid=0,ext_ready,ext_rsp_valid,ext_rsp_ready=0;
    cfg_request_t ext_request;
    cfg_response_t ext_response,backend_response;
    logic backend_valid,backend_ready,backend_source,backend_rsp_valid,backend_rsp_ready;
    cfg_request_t backend_request;
    logic [config_pkg::CFG_COUNT-1:0] backend_supported;
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
    logic source_valid=1;
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
    midi_voice_top #(.CLK_HZ(50_000_000),.SLOTS(16),.N_MODES(64),.NOTE_BANKS(1),.CONFIG_BACKEND(1),
        .INSTRUMENT_NOTE_RANGES(1),.FLASH_BASE(32'h00800000),.FLASH_BYTES(16777216),.RESOURCE_MASK(12'b110000101011),.CONFIG_TIMEOUT_CYCLES(20_000_000)) sound(
        .clk(clk),.rst_n(rst_n),.run(1'b1),.fmap(fmap),
        .pad_instrument(INST_PIANO),.reverb_preset(REVERB_NONE),
        .reload(1'b0),.midi_select(1'b0),.midi_source_id(1'b0),.panic(1'b0),
        .selected_channel(4'd0),.note_bank(1'b0),.first_midi_note(7'd48),.slot_note_map('0),
        .backend_valid(backend_valid),.backend_ready(backend_ready),.backend_request(backend_request),
        .backend_source(backend_source),.backend_source_valid(source_valid),.backend_rsp_valid(backend_rsp_valid),.backend_rsp_ready(backend_rsp_ready),
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
    w25q64_read_model #(.N_MODES(64),.RESOURCE_BASE(32'h00800000),.FLASH_BYTES(16777216),
        .FORBID_PROGRAM_READ(1),.MEM_FILE("performance_resources.mem"),.MEM_BYTES(1576960)) flash(.cs_n(cs),.sck(sck),.dq_o(dqo),.dq_oe(oe),.blank(blank),.dq_i(dqi));
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

    task automatic apply_local(input int preset, input int expected_code);
        ck(scene.layer==1 && scene.category==1,"effects list selected");
        key(2);
        ck(scene.layer==2 && scene.edit_index==2,"reverb editor selected");
        while(scene.draft<preset)key(1);
        while(scene.draft>preset)key(3);
        ck(scene.draft==preset,"exact reverb draft");
        key(2);
        wait(ui.ui_rsp_valid);@(negedge clk);
        ck(backend_request.id==16'h0200 && backend_request.value==preset,"correct local request id/value");
        ck(backend_source==0,"request is local UI");
        ck(ui.response.result==expected_code,"local result matches expected");
        if(expected_code==0)begin
            ck(audio_valid && !audio_fault && audio_state.reverb==preset,"authoritative reverb commit");
            ck(values[2]==preset,"UI active reverb matches commit");
            ck(sound.reverb_q==preset,"actual effect selection matches commit");
        end
        repeat(10)@(negedge clk);
        ck(!scene.busy && scene.has_result && scene.result==expected_code,"menu receives final result");
        $display("PASS local reverb draft=%0d result=%0d committed=%0d effect=%0d pads=%h",preset,expected_code,audio_state.reverb,sound.reverb_q,fmap.raw);
    endtask
    initial begin
        ext_request='0;repeat(5)@(negedge clk);rst_n=1;
        wait(audio_valid);repeat(20)@(negedge clk);
        key(2);key(1);key(2); // cold boot -> effects
        apply_local(1,0);apply_local(2,0);apply_local(3,0);apply_local(0,0);
        // Holding a PAD must not prevent a reverb-only commit.
        fmap.raw[7:0]=8'd100;#1_000_000;
        apply_local(1,0);
        fmap='0;#1_000_000;
        apply_local(0,0);
        source_valid=0;
        apply_local(1,6);
        ck(audio_state.reverb==0 && values[2]==0,"failed gate preserves committed snapshot");
        $display("PASS tb_local_reverb checks=%0d accepted=%0d completed=%0d",checks,accepted,completed);$finish;
    end
    initial begin #800_000_000;$fatal(1,"FAIL watchdog UI=%0d cfg=%0d loader=%0d",scene.layer,sound.cfg_state,sound.u_voice.u_ld.st);end
endmodule
