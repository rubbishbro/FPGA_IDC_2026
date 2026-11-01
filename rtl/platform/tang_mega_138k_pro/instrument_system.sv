`timescale 1ns/1ps
// One synth, one configuration owner; independent core/audio/pixel clocks.
module instrument_system #(
    parameter int CLK_HZ=50_000_000, BAUD=115200,
    parameter int KEY_DEBOUNCE=CLK_HZ/50, KEY_LONG=CLK_HZ*4/5,
    parameter bit NOTE_BANKS=1, BT_HAS_STATE=0,
    parameter int PCM_HEADROOM_BITS=3,
    parameter bit LCD_ROTATE_180=1'b1,
    // Legacy probe fallback; production NOTE_BANKS uses per-instrument note_first.
    parameter logic [6:0] FIRST_MIDI=48,
    parameter logic [11:0] RESOURCE_MASK=12'b110000101011,
    parameter logic [31:0] FLASH_BASE=32'h0080_0000,
    parameter int FLASH_BYTES=16_777_216,
    parameter bit STEREO_ENABLE=1'b1,STEREO_AUTO_SWEEP=1'b0,
    parameter int SWEEP_HOLD_FRAMES=3072,
    parameter FONT_FILE="sidebar_font.mem"
)(
    input logic clk_core,clk_audio,clk_pix,rst_n,key0,key1,
    input logic [1:0] uart_rx,session_restart,
    input logic bt_state,
    input logic [5:0] pan_position=6'd16,
    input logic itd_enable=1'b1,
    output wire [1:0] uart_tx,
    output wire [3:0] pad_row,
    output wire [2:0] pad_ch,
    output wire led_dat,
    output wire flash_cs_n,flash_sck,
    inout wire [3:0] flash_dq,
    output wire amp_bclk,amp_ws,amp_din,amp_sd,
    output wire dac_bck,dac_ws,dac_din,dac_pa_en,
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
    // Optional demonstration moves the same mono mix; it does not synthesize audio.
    wire spatial_frame_tick;
    wire [5:0] spatial_pan;
    generate if(STEREO_AUTO_SWEEP)begin:g_sweep
        localparam int CW=(SWEEP_HOLD_FRAMES<2)?1:$clog2(SWEEP_HOLD_FRAMES);
        logic [CW-1:0] count;
        logic [5:0] position;
        logic backwards;
        initial if(SWEEP_HOLD_FRAMES<1)$error("SWEEP_HOLD_FRAMES must be >=1");
        always_ff @(posedge clk_core or negedge core_n)begin
            if(!core_n)begin count<=0;position<=16;backwards<=0;end
            else if(spatial_frame_tick)begin
                if(count==SWEEP_HOLD_FRAMES-1)begin
                    count<=0;
                    if(position==32)begin position<=31;backwards<=1;end
                    else if(position==0)begin position<=1;backwards<=0;end
                    else position<=backwards?position-1'b1:position+1'b1;
                end else count<=count+1'b1;
            end
        end
        assign spatial_pan=position;
    end else begin:g_fixed_pan
        assign spatial_pan=pan_position;
    end endgenerate
    localparam int PAD_DIV=CLK_HZ/2_500_000;
    logic [$clog2(PAD_DIV+1)-1:0] pad_div;
    wire pad_tick=pad_div==PAD_DIV-1;
    always_ff @(posedge clk_core or negedge core_n)
        if(!core_n)pad_div<=0;else if(pad_tick)pad_div<=0;else pad_div<=pad_div+1'b1;
    input_param pad;
    led_param leds;
    logic led_busy,led_frame_done;
    logic joy_valid;
    logic [13:0] joy_x,joy_y;
    pad_driver u_pad(.cr({clk_core,pad_tick,core_n}),.led_p(leds),.dat(led_dat),.input_p(pad),
        .joy_sample_valid(joy_valid),.joy_raw_x(joy_x),.joy_raw_y(joy_y),
        .led_busy(led_busy),.led_frame_done(led_frame_done));
    assign pad_row=pad.row_s;assign pad_ch=pad.ch_s;
    // Raw ADC byte16 is about 0.5V in the branch's measured voltage mode.
    // Scale force by four, saturating; use equivalent 16/12 raw hysteresis.
    mat4x4 force_map;
    for(genvar s=0;s<16;s++)begin:g_force
        wire [7:0] raw_force=pad.fmap.raw[s*8 +:8];
        assign force_map.raw[s*8 +:8]=raw_force[7] ? 8'd0 :
            (raw_force[6] ? 8'hff : {raw_force[5:0],2'b00});
    end
    pad_led_effects u_pad_leds(.cr({clk_core,pad_tick,core_n}),.force_map(force_map),
        .led_busy(led_busy),.led_frame_done(led_frame_done),.leds(leds));

    logic [1:0] quarantine,cleanup_done,source_idle;
    logic audio_valid,audio_fault;
    audio_config_t audio_state;
    logic record_snapshot_valid,rec_active,rec_draining,rec_completed,rec_failed;
    logic [15:0] record_snapshot_gate;
    logic [127:0] record_snapshot_level;
    logic [111:0] record_snapshot_notes;
    logic rec_start,rec_stop,rec_abort,perf_valid,perf_ready;
    logic [31:0] rec_wait_timer;
    logic [191:0] perf_payload;
    logic [15:0] perf_seq;
    logic [31:0] rec_request_id,rec_current_id;
    wire [4:0] rec_ui_channel=config_pkg::instrument_channel(audio_state.instrument);
    wire rec_eligible=audio_valid && !audio_fault && audio_state.source==0 && rec_ui_channel!=0;
    performance_capture u_record(
        .clk(clk_core),.rst_n(core_n),.frame_tick(spatial_frame_tick),.abort_capture(quarantine[0] || rec_abort),
        .start_req(rec_start),.stop_req(rec_stop),.request_id(rec_request_id),
        .eligible(rec_eligible),.channel(4'(rec_ui_channel-1'b1)),
        .snapshot_valid(record_snapshot_valid),.snapshot_gate(record_snapshot_gate),
        .snapshot_level(record_snapshot_level),.snapshot_notes(record_snapshot_notes),
        .active(rec_active),.draining(rec_draining),.completed(rec_completed),.failed(rec_failed),
        .out_valid(perf_valid),.out_ready(perf_ready),.out_payload(perf_payload),.out_seq(perf_seq));
    logic event_valid,event_ready,event_source;
    logic [31:0] event_data;
    logic midi_idle,cfg_valid,cfg_ready,cfg_source,cfg_done,cfg_done_ready;
    logic [15:0] cfg_seq;
    logic [7:0] cfg_cmd,cfg_result;
    logic [6:0] cfg_len;
    logic [511:0] cfg_shadow;
    comm_top #(.CLK_HZ(CLK_HZ),.WIRED_BAUD(BAUD),.BT_BAUD(BAUD),.BT_HAS_STATE(BT_HAS_STATE),.SUPPORTED_INSTRUMENTS({4'b0,RESOURCE_MASK})) u_comm(
        .clk(clk_core),.rst_n(core_n),.rx_i(uart_rx),.tx_o(uart_tx),.hc05_state_async(bt_state),
        .session_restart(session_restart),.source_cleanup_done(cleanup_done),.source_ops_idle(source_idle),
        .midi_ops_idle(midi_idle),.source_quarantine(quarantine),.link_fault_pending(),.error_sticky(),.rx_error_count(),
        .event_valid(event_valid),.event_ready(event_ready),.event_data(event_data),.event_source_id(event_source),.midi_parse_error(),
        .cfg_valid(cfg_valid),.cfg_ready(cfg_ready),.cfg_source_id(cfg_source),.cfg_seq(cfg_seq),.cfg_command(cfg_cmd),
        .cfg_payload_len(cfg_len),.cfg_shadow(cfg_shadow),.cfg_done_valid(cfg_done),.cfg_done_ready(cfg_done_ready),.cfg_result(cfg_result),.perf_valid(perf_valid),.perf_ready(perf_ready),.perf_seq(perf_seq),.perf_payload(perf_payload));

    logic backend_valid,backend_ready,backend_source,backend_rsp_valid,backend_rsp_ready;
    cfg_request_t backend_request;
    cfg_response_t backend_response,voice_response,policy_response;
    logic voice_ready,voice_rsp_valid,policy_rsp_valid;
    logic [config_pkg::CFG_COUNT-1:0] voice_supported;
    cfg_values_t values;
    sidebar_scene_t scene;
    guide_display_t guide_display;
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
    midi_voice_top #(.CLK_HZ(CLK_HZ),.AUDIO_ENABLE(1),.PT8211_ENABLE(1),.STEREO_ENABLE(STEREO_ENABLE),.CONFIG_BACKEND(1),.NOTE_BANKS(NOTE_BANKS),.INSTRUMENT_NOTE_RANGES(NOTE_BANKS),
        .PCM_HEADROOM_BITS(PCM_HEADROOM_BITS),
        .FLASH_BASE(FLASH_BASE),.FLASH_BYTES(FLASH_BYTES),.RESOURCE_MASK(RESOURCE_MASK),.PAD_NOTE_ON_TH(64),.PAD_NOTE_OFF_TH(48)) u_sound(
        .clk(clk_core),.audio_clk(clk_audio),.rst_n(core_n),.run(1'b1),.fmap(force_map),
        .record_snapshot_valid(record_snapshot_valid),.record_snapshot_gate(record_snapshot_gate),
        .record_snapshot_level(record_snapshot_level),.record_snapshot_notes(record_snapshot_notes),
        .pan_position(spatial_pan),.itd_enable(itd_enable),
        .pad_instrument(router_pkg::INST_PIANO),.reverb_preset(router_pkg::REVERB_NONE),
        .reload(1'b0),.midi_select(1'b0),.midi_source_id(1'b0),.panic(1'b0),.selected_channel(4'd1),
        .note_bank(1'b0),.first_midi_note(FIRST_MIDI),.slot_note_map(router_pkg::default_note_map()),
        .backend_valid(backend_valid && !policy_req && !policy_rsp_valid),.backend_source(backend_source),
        .backend_ready(voice_ready),.backend_request(backend_request),.backend_rsp_valid(voice_rsp_valid),
        .backend_rsp_ready(backend_rsp_ready && !policy_rsp_valid),.backend_response(voice_response),
        .backend_supported(voice_supported),.backend_audio_valid(audio_valid),.backend_audio_fault(audio_fault),.backend_audio_state(audio_state),.guide_display(guide_display),
        .event_valid(event_valid),.event_ready(event_ready),.event_data(event_data),.event_source_id(event_source),
        .source_cleanup_req(quarantine),.source_cleanup_done(cleanup_done),.source_ops_idle(source_idle),.midi_ops_idle(midi_idle),
        .control_valid(),.control_cancel(),.control_ready(1'b0),.control_data(),.control_source_id(),
        .channel_mapped(),.config_busy(),.config_failed(),.active_channel(),.active_bank(),.rejected_note_count(),
        .unsupported_count(),.control_timeout_count(),.dropped_count(),.error_sticky(),.ready(),.done(),.load_err(),
        .y_valid(sample_valid),.y_data(sample_value),.qspi_cs_n(flash_cs_n),.qspi_sck(flash_sck),
        .qspi_dq_oe(flash_oe),.qspi_dq_o(flash_out),.qspi_dq_i(flash_dq),
        .amp_bclk(amp_bclk),.amp_ws(amp_ws),.amp_din(amp_din),
        .dac_bck(dac_bck),.dac_ws(dac_ws),.dac_din(dac_din),.audio_sample_tick(spatial_frame_tick),
        .audio_deadline_miss(audio_diagnostics[0]),.audio_overflow(audio_diagnostics[1]),.audio_underflow(audio_diagnostics[2]));
    assign dac_pa_en=amp_sd; // XPT4809 active-high enable, board H17.
    assign amp_sd=rst_n && audio_reset[2] && audio_valid && !audio_fault;

    logic ext_valid,ext_ready,ext_rsp_valid;
    cfg_request_t ext_request;
    cfg_response_t ext_response;
    typedef enum logic [2:0] {B_IDLE,B_CHECK,B_SEND,B_WAIT,B_DONE,B_KEY_SCAN} bridge_t;
    bridge_t bridge_state;
    logic ctx_source;
    logic [15:0] ctx_seq;
    logic [7:0] ctx_cmd;
    logic [6:0] ctx_len;
    logic [511:0] ctx_shadow;
    logic [$clog2(CLK_HZ/50+1)-1:0] remote_admit_age;
    logic [3:0] key_scan_slot;
    logic key_note_supported;
    localparam logic [111:0] COMM_NOTE_MAP=router_pkg::default_note_map();
    wire [7:0] key_scan_note=ctx_shadow[(2+2*key_scan_slot)*8 +:8];
    always_comb begin
        key_note_supported=0;
        if(NOTE_BANKS)key_note_supported=router_pkg::note_in_range(
            router_pkg::instrument_e'(ctx_shadow[(1+2*key_scan_slot)*8 +:4]),key_scan_note);
        else for(int slot=0;slot<16;slot++)
            if(key_scan_note=={1'b0,COMM_NOTE_MAP[slot*7 +:7]})key_note_supported=1;
    end
    assign cfg_ready=bridge_state==B_IDLE && core_n;
    assign cfg_done=bridge_state==B_DONE && core_n;
    assign ext_valid=bridge_state==B_SEND && !quarantine[ctx_source] && remote_permission[ctx_source];
    assign ext_request={ctx_seq,16'h0200,24'd0,ctx_shadow[15:8]};
    // Keep all physical context until the real response retires. Parser owns duplicate-request cache/reply.
    always_ff @(posedge clk_core or negedge core_n)begin
        if(!core_n)begin bridge_state<=B_IDLE;cfg_result<=6;ctx_source<=0;ctx_seq<=0;ctx_cmd<=0;ctx_len<=0;ctx_shadow<=0;rec_start<=0;rec_stop<=0;rec_abort<=0;rec_wait_timer<=0;rec_request_id<=0;rec_current_id<=0;remote_admit_age<=0;key_scan_slot<=0;end
        else begin
        rec_start<=0;rec_stop<=0;rec_abort<=0;
        if(bridge_state!=B_SEND)remote_admit_age<=0;
        else if(remote_admit_age<CLK_HZ/50)remote_admit_age<=remote_admit_age+1'b1;
        rec_wait_timer<=0;
        case(bridge_state)
            B_IDLE:if(cfg_valid)begin
                ctx_source<=cfg_source;ctx_seq<=cfg_seq;ctx_cmd<=cfg_cmd;ctx_len<=cfg_len;ctx_shadow<=cfg_shadow;bridge_state<=B_CHECK;
            end
            B_CHECK:begin
                cfg_result<=6;
                if(quarantine[ctx_source] || !remote_permission[ctx_source])bridge_state<=B_DONE;
                else if(ctx_cmd==2 && ctx_len==2 && ctx_shadow[15:8]<=2)bridge_state<=B_SEND;
                else if(ctx_cmd==8'h20 && ctx_len==33)begin
                    // Protocol supports the atomic table descriptor, but this backend
                    // cannot route a different instrument for every pad. No partial write.
                    key_scan_slot<=0;bridge_state<=B_KEY_SCAN;
                end else begin cfg_result<=1;bridge_state<=B_DONE;end
            end
            B_SEND:if(quarantine[ctx_source] || !remote_permission[ctx_source])begin cfg_result<=6;bridge_state<=B_DONE;end
                   else if(ext_ready)bridge_state<=B_WAIT;
                   else if(remote_admit_age>=CLK_HZ/50)begin cfg_result<=4;bridge_state<=B_DONE;end
            B_WAIT:if(ext_rsp_valid)begin
                if(ext_response.tag!=ctx_seq || ext_response.id!=16'h0200)cfg_result<=6;
                else case(ext_response.result)
                    CFG_OK:cfg_result<=0;CFG_UNSUPPORTED:cfg_result<=1;CFG_OUT_OF_RANGE:cfg_result<=3;CFG_BUSY:cfg_result<=4;default:cfg_result<=6;
                endcase
                bridge_state<=B_DONE;
            end
            B_KEY_SCAN:begin
                if(!key_note_supported)begin cfg_result<=3;bridge_state<=B_DONE;end
                else if(key_scan_slot==15)begin cfg_result<=6;bridge_state<=B_DONE;end
                else key_scan_slot<=key_scan_slot+1'b1;
            end
            B_DONE:if(cfg_done_ready)bridge_state<=B_IDLE;
            default:bridge_state<=B_IDLE;
        endcase
        end
    end
    wire [9:0] pix_x,pix_y;
    wire de,frame_pulse,display_de;
    assign lcd_clk=clk_pix;
    lcd_timing #(.ROTATE_180(LCD_ROTATE_180)) u_timing(
        .lcd_clk(clk_pix),.rst_n(pix_n),.lcd_en(de),.frame_pulse(frame_pulse),.pix_x(pix_x),.pix_y(pix_y));
    wire key0_valid,key1_valid;
    wire [2:0] key0_event,key1_event;
    key_ui_event #(.DEBOUNCE_CNT(KEY_DEBOUNCE),.LONG_CNT(KEY_LONG),.SHORT_EVENT(1),.LONG_EVENT(2)) u_key0(
        .clk(clk_core),.rst_n(core_n),.key_in(key0),.ev_valid(key0_valid),.ev(key0_event));
    key_ui_event #(.DEBOUNCE_CNT(KEY_DEBOUNCE),.LONG_CNT(KEY_LONG),.SHORT_EVENT(3),.LONG_EVENT(4)) u_key1(
        .clk(clk_core),.rst_n(core_n),.key_in(key1),.ev_valid(key1_valid),.ev(key1_event));
    // ---- FFT display chain (pix domain) ----
    // One of 128 bars every 6 pixels, matching the FFT demo top.
    reg [6:0] bar_idx_disp_r;
    reg [2:0] xmod_d;
    always_ff @(posedge clk_pix or negedge pix_n) begin
        if (!pix_n) begin
            xmod_d <= 3'd0;
            bar_idx_disp_r <= 7'd0;
        end else if (LCD_ROTATE_180) begin
            // Logical X runs 799..0. The 32-pixel non-spectrum margin primes
            // the last bar, then each six descending pixels selects one bar.
            if (pix_x >= 10'd767) begin
                xmod_d <= 3'd5;
                bar_idx_disp_r <= 7'd127;
            end else if (xmod_d == 3'd0) begin
                xmod_d <= 3'd5;
                if (bar_idx_disp_r != 0) bar_idx_disp_r <= bar_idx_disp_r - 1'b1;
            end else xmod_d <= xmod_d - 1'b1;
        end else if (pix_x == 10'd0) begin
            xmod_d <= 3'd0;
            bar_idx_disp_r <= 7'd0;
        end else if (xmod_d == 3'd5) begin
            xmod_d <= 3'd0;
            if (bar_idx_disp_r < 7'd127) bar_idx_disp_r <= bar_idx_disp_r + 7'd1;
        end else begin
            xmod_d <= xmod_d + 3'd1;
        end
    end
    wire [6:0] bar_idx_disp = bar_idx_disp_r;
    wire       rd_valid     = (pix_x < 10'd768);

    // PCM tap: router result is in the 50 MHz core domain, FFT chain in pix.
    function automatic logic signed [23:0] sat24(input logic signed [63:0] v);
        begin
            if (v > 64'sd8388607) sat24 = 24'sh7FFFFF;
            else if (v < -64'sd8388608) sat24 = 24'sh800000;
            else sat24 = v[23:0];
        end
    endfunction
    wire [23:0] pcm24_pix;
    wire pcm_valid_pix,visualizer_ready;
    // Separate observation queue: display must never back-pressure the DAC path.
    // A shared reset flushes queued samples; each FIFO domain releases synchronously.
    logic visualizer_overflow;
    always_ff @(posedge clk_core or negedge core_n)
        if(!core_n) visualizer_overflow<=1'b0;
        else if(sample_valid && !visualizer_ready) visualizer_overflow<=1'b1;
    audio_async_fifo #(.WIDTH(24),.DEPTH(16)) u_visualizer_fifo(
        .wclk(clk_core),.rclk(clk_pix),.rst_n(rst_n),
        .wvalid(sample_valid),.wready(visualizer_ready),.wdata(sat24(sample_value >>> 2)),
        .rvalid(pcm_valid_pix),.rready(1'b1),.rdata(pcm24_pix),.wfull(),.rempty()
    );

    wire [9:0] q_y_fft, q_ov_fft;
    wire [9:0] wave_rd_data_fft, wave_rd_addr_fft;
    wire [39:0] curve_rd_data_fft;
    wire [9:0] curve_rd_addr_fft;
    real_audio_chain u_fft_chain (
        .clk_core    (clk_pix),
        .rst_core_n  (pix_n),
        .clk_pix     (clk_pix),
        .rst_pix_n   (pix_n),
        .pcm_valid   (pcm_valid_pix),
        .pcm_data    (pcm24_pix),
        .frame_pulse (frame_pulse),
        .rd_bar_idx  (bar_idx_disp),
        .rd_valid    (rd_valid),
        .rd_q_y      (q_y_fft),
        .rd_q_ov     (q_ov_fft),
        .wave_rd_addr(wave_rd_addr_fft),
        .wave_rd_data(wave_rd_data_fft),
        .curve_rd_addr(curve_rd_addr_fft),
        .curve_rd_data(curve_rd_data_fft)
    );

    // TEMP_FMAP_DISPLAY_20261101: route original RGB through the separate debug
    // overlay below. Restore u_ui outputs directly to lcd_r/g/b when removing it.
    wire [5:0] temp_base_r,temp_base_g,temp_base_b;
    // Pixel FFT data and local guide/menu overlays share the existing sidebar path.
    // Keep the swapped axes and horizontal orientation; flip only final UP/DOWN
    // relative to the 2026-10-31 profile (previously JOY_INVERT_Y=1).
    sidebar_system #(.CTRL_HZ(CLK_HZ),.AUDIO_BACKEND(1),.JOY_FILTER_CENTER(1),
                     .JOY_SWAP_XY(1),.JOY_INVERT_X(1),.JOY_INVERT_Y(0),
                     .REVERSE_SCAN(LCD_ROTATE_180),.FONT_FILE(FONT_FILE),
                     .JOY_DEADZONE_ON(200),.JOY_DEADZONE_OFF(100)) u_ui(
        .rst_n(rst_n),.ctrl_clk(clk_core),.pix_clk(clk_pix),.joy_sample_valid(joy_valid),.joy_raw_x(joy_x),.joy_raw_y(joy_y),
        .key_valid(key0_valid || key1_valid),.key_event(key0_valid ? key0_event : key1_event),
        .ext_cfg_valid(ext_valid),.ext_cfg_ready(ext_ready),.ext_cfg_request(ext_request),
        .ext_rsp_valid(ext_rsp_valid),.ext_rsp_ready(bridge_state==B_WAIT),.ext_cfg_response(ext_response),
        .backend_supported(voice_supported | 20'h02000),.backend_valid(backend_valid),.backend_ready(backend_ready),
        .backend_request(backend_request),.backend_source(backend_source),.backend_rsp_valid(backend_rsp_valid),
        .backend_rsp_ready(backend_rsp_ready),.backend_response(backend_response),
        .backend_audio_valid(audio_valid),.backend_audio_fault(audio_fault),.backend_audio_state(audio_state),.guide_display(guide_display),
        .frame_pulse(frame_pulse),.lcd_valid(de),.pix_x(pix_x),.pix_y(pix_y),
        .q_y(q_y_fft),.q_ov(q_ov_fft),.wave_rd_data(wave_rd_data_fft),.wave_rd_addr(wave_rd_addr_fft),.curve_rd_data(curve_rd_data_fft),.curve_rd_addr(curve_rd_addr_fft),
        .lcd_r(temp_base_r),.lcd_g(temp_base_g),.lcd_b(temp_base_b),.lcd_valid_out(display_de),
        .active_values(values),.ui_scene(scene),.sidebar_width());
    // TEMP_FMAP_DISPLAY_20261101: raw pad.fmap (not the scaled force_map).
    // Keep LCD rotation, DE and the existing UI's four-clock pixel latency.
    temporary_fmap_display u_temp_fmap(
        .rst_n(rst_n),.core_clk(clk_core),.pix_clk(clk_pix),
        .frame_pulse(frame_pulse),.lcd_valid(de),.fmap_raw(pad.fmap.raw),
        .pix_x(pix_x),.pix_y(pix_y),
        .base_r(temp_base_r),.base_g(temp_base_g),.base_b(temp_base_b),
        .lcd_r(lcd_r),.lcd_g(lcd_g),.lcd_b(lcd_b));
    // END TEMP_FMAP_DISPLAY_20261101
    assign lcd_en=display_de;
    // synthesis translate_off
    initial if(CLK_HZ<2_500_000 || CLK_HZ%2_500_000!=0)$fatal(1,"board PAD clock must divide to 2.5MHz");
    // synthesis translate_on
endmodule
