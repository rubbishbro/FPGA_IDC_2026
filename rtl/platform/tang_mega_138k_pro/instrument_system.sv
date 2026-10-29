`timescale 1ns/1ps
// One synth, one configuration owner; independent core/audio/pixel clocks.
module instrument_system #(
    parameter int CLK_HZ=100_000_000, BAUD=115200,
    parameter int KEY_DEBOUNCE=CLK_HZ/50, KEY_LONG=CLK_HZ*4/5,
    parameter bit NOTE_BANKS=0, BT_HAS_STATE=0,
    parameter logic [6:0] FIRST_MIDI=48,
    parameter logic [9:0] RESOURCE_MASK=10'b0000000001,
    parameter FONT_FILE="sidebar_font.mem"
)(
    input logic clk_core,clk_audio,clk_pix,rst_n,key0,key1,
    input logic [1:0] uart_rx,session_restart,
    input logic bt_state,
    output wire [1:0] uart_tx,
    output wire [3:0] pad_row,
    output wire [2:0] pad_ch,
    output wire led_dat,
    output wire flash_cs_n,flash_sck,
    inout wire [3:0] flash_dq,
    output wire amp_bclk,amp_ws,amp_din,amp_sd,
    output wire lcd_clk,lcd_en,
    output wire [5:0] lcd_r,lcd_g,lcd_b,
    output logic sample_valid,
    output logic signed [63:0] sample_value,
    output logic [2:0] audio_diagnostics
);
    import config_pkg::*;
    import pad_driver_pkg::*;
    (* ASYNC_REG="TRUE" *) logic [2:0] core_reset,audio_reset,pix_reset;
    always_ff @(posedge clk_core or negedge rst_n)
        if(!rst_n)core_reset<=0;else core_reset<={core_reset[1:0],1'b1};
    always_ff @(posedge clk_audio or negedge rst_n)
        if(!rst_n)audio_reset<=0;else audio_reset<={audio_reset[1:0],1'b1};
    always_ff @(posedge clk_pix or negedge rst_n)
        if(!rst_n)pix_reset<=0;else pix_reset<={pix_reset[1:0],1'b1};
    wire core_n=core_reset[2],pix_n=pix_reset[2];
    localparam int PAD_DIV=CLK_HZ/2_500_000;
    logic [$clog2(PAD_DIV+1)-1:0] pad_div;
    wire pad_tick=pad_div==PAD_DIV-1;
    always_ff @(posedge clk_core or negedge core_n)
        if(!core_n)pad_div<=0;else if(pad_tick)pad_div<=0;else pad_div<=pad_div+1'b1;
    input_param pad;
    led_param leds;
    logic joy_valid;
    logic [13:0] joy_x,joy_y;
    pad_driver u_pad(.cr({clk_core,pad_tick,core_n}),.led_p(leds),.dat(led_dat),.input_p(pad),
        .joy_sample_valid(joy_valid),.joy_raw_x(joy_x),.joy_raw_y(joy_y));
    assign pad_row=pad.row_s;assign pad_ch=pad.ch_s;
    // boardtest 4abc8b19: one cell drives a 2x2 LED block, not four cells.
    logic [5:0] fill_idx;
    logic filling;
    logic [12:0] led_gap;
    wire [2:0] led_x=fill_idx[2:0],led_y=fill_idx[5:3];
    wire [3:0] cell_idx={led_y[2:1],led_x[2:1]};
    wire [7:0] cell_raw=pad.fmap.raw[cell_idx*8 +:8];
    wire [7:0] brightness=!cell_raw[7] && cell_raw>16 ? cell_raw>>2 : 8'd0;
    always_ff @(posedge clk_core or negedge core_n)begin
        if(!core_n)begin fill_idx<=0;filling<=1;led_gap<=0;leds<='0;end
        else if(pad_tick)begin
            leds.x<=led_x;leds.y<=led_y;leds.pix<={brightness,brightness,brightness};leds.wr<=filling;
            if(filling)begin
                if(fill_idx==63)begin filling<=0;fill_idx<=0;led_gap<=0;end
                else fill_idx<=fill_idx+1'b1;
            end else if(led_gap==5999)begin filling<=1;fill_idx<=0;end
            else led_gap<=led_gap+1'b1;
        end
    end
    // Raw ADC byte16 is about 0.5V in the branch's measured voltage mode.
    // Scale force by four, saturating; use equivalent 16/12 raw hysteresis.
    mat4x4 force_map;
    for(genvar s=0;s<16;s++)begin:g_force
        wire [7:0] raw_force=pad.fmap.raw[s*8 +:8];
        assign force_map.raw[s*8 +:8]=raw_force[7] ? 8'd0 :
            (raw_force[6] ? 8'hff : {raw_force[5:0],2'b00});
    end

    logic event_valid,event_ready,event_source;
    logic [31:0] event_data;
    logic [1:0] quarantine,cleanup_done,source_idle;
    logic midi_idle,cfg_valid,cfg_ready,cfg_source,cfg_done,cfg_done_ready;
    logic [15:0] cfg_seq;
    logic [7:0] cfg_cmd,cfg_result;
    logic [4:0] cfg_len;
    logic [127:0] cfg_shadow;
    comm_top #(.CLK_HZ(CLK_HZ),.WIRED_BAUD(BAUD),.BT_BAUD(BAUD),.BT_HAS_STATE(BT_HAS_STATE)) u_comm(
        .clk(clk_core),.rst_n(core_n),.rx_i(uart_rx),.tx_o(uart_tx),.hc05_state_async(bt_state),
        .session_restart(session_restart),.source_cleanup_done(cleanup_done),.source_ops_idle(source_idle),
        .midi_ops_idle(midi_idle),.source_quarantine(quarantine),.link_fault_pending(),.error_sticky(),.rx_error_count(),
        .event_valid(event_valid),.event_ready(event_ready),.event_data(event_data),.event_source_id(event_source),.midi_parse_error(),
        .cfg_valid(cfg_valid),.cfg_ready(cfg_ready),.cfg_source_id(cfg_source),.cfg_seq(cfg_seq),.cfg_command(cfg_cmd),
        .cfg_payload_len(cfg_len),.cfg_shadow(cfg_shadow),.cfg_done_valid(cfg_done),.cfg_done_ready(cfg_done_ready),.cfg_result(cfg_result));

    logic backend_valid,backend_ready,backend_source,backend_rsp_valid,backend_rsp_ready;
    cfg_request_t backend_request;
    cfg_response_t backend_response,voice_response,policy_response;
    logic voice_ready,voice_rsp_valid,policy_rsp_valid;
    logic [19:0] voice_supported;
    logic audio_valid,audio_fault;
    audio_config_t audio_state;
    cfg_values_t values;
    sidebar_scene_t scene;
    logic [1:0] remote_permission;
    wire policy_req=backend_request.id==16'h0502;
    assign backend_ready=policy_req ? !policy_rsp_valid : voice_ready && !policy_rsp_valid;
    assign backend_rsp_valid=policy_rsp_valid || voice_rsp_valid;
    assign backend_response=policy_rsp_valid ? policy_response : voice_response;
    always_ff @(posedge clk_core or negedge core_n)begin
        if(!core_n)begin remote_permission<=3;policy_rsp_valid<=0;policy_response<='0;end
        else begin
            if(policy_rsp_valid && backend_rsp_ready)policy_rsp_valid<=0;
            if(backend_valid && backend_ready && policy_req)begin
                policy_response.tag<=backend_request.tag;policy_response.id<=backend_request.id;
                policy_response.applied_value<=32'(remote_permission);policy_rsp_valid<=1;
                if(backend_source)policy_response.result<=CFG_DENIED;
                else if(backend_request.value<0 || backend_request.value>3)policy_response.result<=CFG_OUT_OF_RANGE;
                else begin
                    remote_permission<=2'(backend_request.value);policy_response.applied_value<=backend_request.value;
                    policy_response.result<=CFG_OK;
                end
            end
        end
    end
    wire flash_oe;
    wire [3:0] flash_out;
    assign flash_dq=flash_oe ? flash_out : 4'bzzzz;
    midi_voice_top #(.CLK_HZ(CLK_HZ),.AUDIO_ENABLE(1),.CONFIG_BACKEND(1),.NOTE_BANKS(NOTE_BANKS),
        .RESOURCE_MASK(RESOURCE_MASK),.PAD_NOTE_ON_TH(64),.PAD_NOTE_OFF_TH(48)) u_sound(
        .clk(clk_core),.audio_clk(clk_audio),.rst_n(core_n),.run(1'b1),.fmap(force_map),
        .pad_instrument(router_pkg::INST_PIANO),.reverb_preset(router_pkg::REVERB_NONE),
        .reload(1'b0),.midi_select(1'b0),.midi_source_id(1'b0),.panic(1'b0),.selected_channel(4'd1),
        .note_bank(1'b0),.first_midi_note(FIRST_MIDI),.slot_note_map(router_pkg::default_note_map()),
        .backend_valid(backend_valid && !policy_req && !policy_rsp_valid),.backend_source(backend_source),
        .backend_ready(voice_ready),.backend_request(backend_request),.backend_rsp_valid(voice_rsp_valid),
        .backend_rsp_ready(backend_rsp_ready && !policy_rsp_valid),.backend_response(voice_response),
        .backend_supported(voice_supported),.backend_audio_valid(audio_valid),.backend_audio_fault(audio_fault),.backend_audio_state(audio_state),
        .event_valid(event_valid),.event_ready(event_ready),.event_data(event_data),.event_source_id(event_source),
        .source_cleanup_req(quarantine),.source_cleanup_done(cleanup_done),.source_ops_idle(source_idle),.midi_ops_idle(midi_idle),
        .control_valid(),.control_cancel(),.control_ready(1'b0),.control_data(),.control_source_id(),
        .channel_mapped(),.config_busy(),.config_failed(),.active_channel(),.active_bank(),.rejected_note_count(),
        .unsupported_count(),.control_timeout_count(),.dropped_count(),.error_sticky(),.ready(),.done(),.load_err(),
        .y_valid(sample_valid),.y_data(sample_value),.qspi_cs_n(flash_cs_n),.qspi_sck(flash_sck),
        .qspi_dq_oe(flash_oe),.qspi_dq_o(flash_out),.qspi_dq_i(flash_dq),
        .amp_bclk(amp_bclk),.amp_ws(amp_ws),.amp_din(amp_din),.audio_sample_tick(),
        .audio_deadline_miss(audio_diagnostics[0]),.audio_overflow(audio_diagnostics[1]),.audio_underflow(audio_diagnostics[2]));
    assign amp_sd=rst_n && audio_reset[2] && audio_valid && !audio_fault;

    logic ext_valid,ext_ready,ext_rsp_valid;
    cfg_request_t ext_request;
    cfg_response_t ext_response;
    typedef enum logic [2:0] {B_IDLE,B_CHECK,B_SEND,B_WAIT,B_DONE} bridge_t;
    bridge_t bridge_state;
    logic ctx_source;
    logic [15:0] ctx_seq;
    logic [7:0] ctx_cmd;
    logic [4:0] ctx_len;
    logic [127:0] ctx_shadow;
    assign cfg_ready=bridge_state==B_IDLE && core_n;
    assign cfg_done=bridge_state==B_DONE && core_n;
    assign ext_valid=bridge_state==B_SEND && !quarantine[ctx_source] && remote_permission[ctx_source];
    assign ext_request={ctx_seq,16'h0200,24'd0,ctx_shadow[15:8]};
    // Keep all physical context until the real response retires. Parser owns v1 cache/reply.
    always_ff @(posedge clk_core or negedge core_n)begin
        if(!core_n)begin bridge_state<=B_IDLE;cfg_result<=6;ctx_source<=0;ctx_seq<=0;ctx_cmd<=0;ctx_len<=0;ctx_shadow<=0;end
        else case(bridge_state)
            B_IDLE:if(cfg_valid)begin
                ctx_source<=cfg_source;ctx_seq<=cfg_seq;ctx_cmd<=cfg_cmd;ctx_len<=cfg_len;ctx_shadow<=cfg_shadow;bridge_state<=B_CHECK;
            end
            B_CHECK:begin
                cfg_result<=6;
                if(quarantine[ctx_source] || !remote_permission[ctx_source])bridge_state<=B_DONE;
                else if(ctx_cmd==2 && ctx_len==2 && ctx_shadow[15:8]<=2)bridge_state<=B_SEND;
                else begin cfg_result<=ctx_cmd==1 ? 8'd6 : 8'd1;bridge_state<=B_DONE;end
            end
            B_SEND:if(quarantine[ctx_source] || !remote_permission[ctx_source])begin cfg_result<=6;bridge_state<=B_DONE;end
                   else if(ext_ready)bridge_state<=B_WAIT;
            B_WAIT:if(ext_rsp_valid)begin
                if(ext_response.tag!=ctx_seq || ext_response.id!=16'h0200)cfg_result<=6;
                else case(ext_response.result)
                    CFG_OK:cfg_result<=0;CFG_UNSUPPORTED:cfg_result<=1;CFG_OUT_OF_RANGE:cfg_result<=3;default:cfg_result<=6;
                endcase
                bridge_state<=B_DONE;
            end
            B_DONE:if(cfg_done_ready)bridge_state<=B_IDLE;
            default:bridge_state<=B_IDLE;
        endcase
    end
    wire [9:0] pix_x,pix_y;
    wire de,frame_pulse,display_de;
    assign lcd_clk=clk_pix;
    lcd_timing u_timing(.lcd_clk(clk_pix),.rst_n(pix_n),.lcd_en(de),.frame_pulse(frame_pulse),.pix_x(pix_x),.pix_y(pix_y));
    wire key0_valid,key1_valid;
    wire [2:0] key0_event,key1_event;
    key_ui_event #(.DEBOUNCE_CNT(KEY_DEBOUNCE),.LONG_CNT(KEY_LONG),.SHORT_EVENT(1),.LONG_EVENT(2)) u_key0(
        .clk(clk_core),.rst_n(core_n),.key_in(key0),.ev_valid(key0_valid),.ev(key0_event));
    key_ui_event #(.DEBOUNCE_CNT(KEY_DEBOUNCE),.LONG_CNT(KEY_LONG),.SHORT_EVENT(3),.LONG_EVENT(4)) u_key1(
        .clk(clk_core),.rst_n(core_n),.key_in(key1),.ev_valid(key1_valid),.ev(key1_event));
    // Step 1: live UI, no synthetic FFT test source. Step 2 supplies these read ports.
    sidebar_system #(.CTRL_HZ(CLK_HZ),.AUDIO_BACKEND(1),.JOY_FILTER_CENTER(1),.FONT_FILE(FONT_FILE)) u_ui(
        .rst_n(rst_n),.ctrl_clk(clk_core),.pix_clk(clk_pix),.joy_sample_valid(joy_valid),.joy_raw_x(joy_x),.joy_raw_y(joy_y),
        .key_valid(key0_valid || key1_valid),.key_event(key0_valid ? key0_event : key1_event),
        .ext_cfg_valid(ext_valid),.ext_cfg_ready(ext_ready),.ext_cfg_request(ext_request),
        .ext_rsp_valid(ext_rsp_valid),.ext_rsp_ready(bridge_state==B_WAIT),.ext_cfg_response(ext_response),
        .backend_supported(voice_supported | 20'h02000),.backend_valid(backend_valid),.backend_ready(backend_ready),
        .backend_request(backend_request),.backend_source(backend_source),.backend_rsp_valid(backend_rsp_valid),
        .backend_rsp_ready(backend_rsp_ready),.backend_response(backend_response),
        .backend_audio_valid(audio_valid),.backend_audio_fault(audio_fault),.backend_audio_state(audio_state),
        .frame_pulse(frame_pulse),.lcd_valid(de),.pix_x(pix_x),.pix_y(pix_y),
        .q_y(10'd0),.q_ov(10'd0),.wave_rd_data(10'd0),.wave_rd_addr(),.curve_rd_data(40'd0),.curve_rd_addr(),
        .lcd_r(lcd_r),.lcd_g(lcd_g),.lcd_b(lcd_b),.lcd_valid_out(display_de),
        .active_values(values),.ui_scene(scene),.sidebar_width());
    assign lcd_en=display_de;
    // synthesis translate_off
    initial if(CLK_HZ<2_500_000 || CLK_HZ%2_500_000!=0)$fatal(1,"board PAD clock must divide to 2.5MHz");
    // synthesis translate_on
endmodule
