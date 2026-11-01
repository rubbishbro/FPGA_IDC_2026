`timescale 1ns/1ps
// 正式集成边界：主时钟域的原始摇杆/请求/真实后端，像素域的已有频谱读口。
module sidebar_system #(
    parameter integer CTRL_HZ=100_000_000,
    parameter integer CALIB_LOG2=4,
    parameter integer HOT_DWELL_MS=180,
    parameter bit HAS_JOYSTICK=1'b1,
    parameter bit AUDIO_BACKEND=1'b0,
    parameter integer JOY_DEADZONE_ON=1400, JOY_DEADZONE_OFF=900,
    parameter bit JOY_FILTER_CENTER=1'b0,
    parameter bit JOY_SWAP_XY=1'b0,
    parameter bit JOY_INVERT_X=1'b0, JOY_INVERT_Y=1'b0,
    parameter bit REVERSE_SCAN=1'b0,
    parameter FONT_FILE="sidebar_font.mem",
    parameter LABEL_FILE="sidebar_labels.mem"
)(
    input logic rst_n,ctrl_clk,pix_clk,
    input logic joy_sample_valid,
    input logic[13:0] joy_raw_x,joy_raw_y,
    input logic key_valid,
    input logic[2:0] key_event,
    input logic ext_cfg_valid,
    output logic ext_cfg_ready,
    input config_pkg::cfg_request_t ext_cfg_request,
    output logic ext_rsp_valid,
    input logic ext_rsp_ready,
    output config_pkg::cfg_response_t ext_cfg_response,
    input logic[config_pkg::CFG_COUNT-1:0] backend_supported,
    output logic backend_valid,
    input logic backend_ready,
    output config_pkg::cfg_request_t backend_request,
    output logic backend_source,
    input logic backend_rsp_valid,
    output logic backend_rsp_ready,
    input config_pkg::cfg_response_t backend_response,
    input logic backend_audio_valid,backend_audio_fault,
    input config_pkg::audio_config_t backend_audio_state,
    input config_pkg::guide_display_t guide_display = '0,
    input logic frame_pulse,lcd_valid,
    input logic[9:0] pix_x,pix_y,q_y,q_ov,
    input logic[9:0] wave_rd_data,
    output wire[9:0] wave_rd_addr,
    input logic[39:0] curve_rd_data,
    output wire[9:0] curve_rd_addr,
    output logic[5:0] lcd_r,lcd_g,lcd_b,
    output logic lcd_valid_out,
    output config_pkg::cfg_values_t active_values,
    output config_pkg::sidebar_scene_t ui_scene,
    output wire[8:0] sidebar_width
);
    import config_pkg::*;
    logic[1:0] ctrl_reset,pix_reset;
    always_ff @(posedge ctrl_clk or negedge rst_n)
        if(!rst_n)ctrl_reset<=0;else ctrl_reset<={ctrl_reset[0],1'b1};
    always_ff @(posedge pix_clk or negedge rst_n)
        if(!rst_n)pix_reset<=0;else pix_reset<={pix_reset[0],1'b1};
    wire ctrl_n=ctrl_reset[1],pix_n=pix_reset[1];
    localparam integer DIV=CTRL_HZ/1000;
    logic[$clog2(DIV+1)-1:0] ms_count;
    wire tick_ms=ms_count==DIV-1;
    always_ff @(posedge ctrl_clk or negedge ctrl_n)
        if(!ctrl_n)ms_count<=0;
        else if(tick_ms)ms_count<=0;else ms_count<=ms_count+1'b1;
    logic joy_calibrated,joy_stale,joy_update,joy_recalibrate;
    logic signed[14:0] dx,dy;
    joystick_pkg::joy_dir_t direction,nav_dir;
    logic nav_valid,nav_ready,nav_repeat;
    joystick_adapter #(.CLK_HZ(CTRL_HZ),.CALIB_LOG2(CALIB_LOG2),
        .DEADZONE_ON(JOY_DEADZONE_ON),.DEADZONE_OFF(JOY_DEADZONE_OFF),.FILTER_CENTER(JOY_FILTER_CENTER),
        .SWAP_XY(JOY_SWAP_XY),.INVERT_X(JOY_INVERT_X),.INVERT_Y(JOY_INVERT_Y)) u_joystick(
        .clk(ctrl_clk),.rst_n(ctrl_n),.recalibrate(joy_recalibrate),
        .sample_valid(joy_sample_valid),.raw_x(joy_raw_x),.raw_y(joy_raw_y),
        .calibrated(joy_calibrated),.stale(joy_stale),.center_x(),.center_y(),
        .position_update(joy_update),.dx(dx),.dy(dy),.direction(direction),
        .nav_valid(nav_valid),.nav_ready(nav_ready),.nav_dir(nav_dir),.nav_repeat(nav_repeat));
    logic ui_cfg_valid,ui_cfg_ready,ui_rsp_valid;
    cfg_request_t ui_request,request;
    cfg_response_t response;
    logic req_valid,req_ready,req_source,rsp_valid,rsp_ready,rsp_source;
    localparam logic[config_pkg::CFG_COUNT-1:0] LOCAL_SUPPORTED=HAS_JOYSTICK?LOCAL_MASK:DISPLAY_MASK;
    wire[config_pkg::CFG_COUNT-1:0] supported=backend_supported|LOCAL_SUPPORTED;
    sidebar_ctrl #(.HOT_DWELL_MS(HOT_DWELL_MS)) u_ui(
        .clk(ctrl_clk),.rst_n(ctrl_n),.tick_ms(tick_ms),
        .joy_calibrated(joy_calibrated),.joy_stale(joy_stale),.dx(dx),.dy(dy),.direction(direction),
        .nav_valid(nav_valid),.nav_ready(nav_ready),.nav_repeat(nav_repeat),.nav_dir(nav_dir),
        .key_valid(key_valid),.key_event(key_event),.active_values(active_values),.supported(supported),
        .cfg_valid(ui_cfg_valid),.cfg_ready(ui_cfg_ready),.cfg_request(ui_request),
        .rsp_valid(ui_rsp_valid),.rsp_ready(),.cfg_response(response),.scene(ui_scene));
    logic ext_loop_ready;
    wire ext_admit=req_ready && !req_valid;
    assign ext_cfg_ready=ext_loop_ready && ext_admit;
    control_loop #(.SOURCES(2),.REQUEST_W($bits(cfg_request_t))) u_loop(
        .clk(ctrl_clk),.rst_n(ctrl_n),.poll_tick(tick_ms),
        .src_valid({ext_cfg_valid && ext_admit,ui_cfg_valid}),.src_ready({ext_loop_ready,ui_cfg_ready}),
        .src_request({ext_cfg_request,ui_request}),.req_valid(req_valid),.req_ready(req_ready),
        .req_request(request),.req_source(req_source));
    assign ui_rsp_valid=rsp_valid&&!rsp_source;
    assign ext_rsp_valid=rsp_valid&&rsp_source;
    assign ext_cfg_response=response;
    assign rsp_ready=rsp_source?ext_rsp_ready:1'b1;
    display_config_t render_config;
    logic[15:0] render_epoch;
    logic view_done;
    sidebar_snapshot_t current_view,sent_view,done_view,wire_view,pixel_view;
    config_dispatch #(.LOCAL_SUPPORTED(LOCAL_SUPPORTED),.AUDIO_BACKEND(AUDIO_BACKEND)) u_config(
        .clk(ctrl_clk),.rst_n(ctrl_n),.tick_ms(tick_ms),.req_valid(req_valid),.req_ready(req_ready),
        .request(request),.request_source(req_source),.rsp_valid(rsp_valid),.rsp_ready(rsp_ready),
        .response(response),.response_source(rsp_source),.backend_supported(backend_supported),
        .backend_valid(backend_valid),.backend_ready(backend_ready),.backend_request(backend_request),
        .backend_source(backend_source),.backend_rsp_valid(backend_rsp_valid),.backend_rsp_ready(backend_rsp_ready),
        .backend_response(backend_response),.active_values(active_values),.render_config(render_config),
        .backend_audio_valid(backend_audio_valid),.backend_audio_state(backend_audio_state),
        .render_epoch(render_epoch),.display_done(view_done),.display_done_epoch(done_view.epoch),
        .joy_recalibrate(joy_recalibrate),.joy_calibrated(joy_calibrated),.joy_stale(joy_stale));
    always_comb begin
        current_view.epoch=render_epoch;current_view.display_cfg=render_config;
        current_view.scene=ui_scene;current_view.values=active_values;current_view.supported=supported;
        // 故障时旧active只是历史身份；沿用已有结果显示明确提示声音后端故障。
        if(AUDIO_BACKEND && backend_audio_fault)begin
            current_view.scene.has_result=1'b1;current_view.scene.result=CFG_FAILED;
        end
    end
    logic snapshot_ready,snapshot_valid,sent_once;
    // Compare independent words in parallel, then register the dirty vector.
    // A monolithic ~800-bit inequality otherwise becomes a long LUT cascade
    // driving every held snapshot register's CE. Capture remains whole-packet.
    localparam integer VIEW_W=$bits(sidebar_snapshot_t),VIEW_WORDS=(VIEW_W+31)/32;
    logic[VIEW_WORDS-1:0] view_dirty;
    wire[VIEW_WORDS*32-1:0] current_bits={{(VIEW_WORDS*32-VIEW_W){1'b0}},current_view};
    wire[VIEW_WORDS*32-1:0] sent_bits={{(VIEW_WORDS*32-VIEW_W){1'b0}},sent_view};
    always_ff @(posedge ctrl_clk or negedge ctrl_n)begin
        if(!ctrl_n)view_dirty<='1;
        else for(integer word_index=0;word_index<VIEW_WORDS;word_index++)
            view_dirty[word_index]<=current_bits[word_index*32 +:32]!=sent_bits[word_index*32 +:32];
    end
    wire snapshot_offer=!sent_once||(|view_dirty);
    always_ff @(posedge ctrl_clk or negedge ctrl_n)begin
        if(!ctrl_n)begin sent_view<='0;sent_once<=0;end
        else if(snapshot_offer&&snapshot_ready)begin sent_view<=current_view;sent_once<=1;end
    end
    sidebar_mailbox #(.WIDTH($bits(sidebar_snapshot_t))) u_view_cdc(
        .rst_n(rst_n),.src_clk(ctrl_clk),.dst_clk(pix_clk),
        .src_valid(snapshot_offer&&ctrl_n),.src_ready(snapshot_ready),.src_data(current_view),
        .src_done(view_done),.src_done_data(done_view),.dst_valid(snapshot_valid),
        .dst_ready(frame_pulse&&pix_n),.dst_data(wire_view));
    always_ff @(posedge pix_clk or negedge pix_n)begin
        if(!pix_n)begin pixel_view<='0;pixel_view.display_cfg<=display_defaults();end
        else if(snapshot_valid&&frame_pulse)pixel_view<=wire_view;
    end
    // Live guide traffic uses its own whole-packet mailbox; never blocks config or audio.
    guide_display_t guide_sent,guide_wire,pixel_guide;
    logic guide_sent_once,guide_cdc_ready,guide_cdc_valid;
    localparam integer GUIDE_W=$bits(guide_display_t),GUIDE_WORDS=(GUIDE_W+31)/32;
    logic [GUIDE_WORDS-1:0] guide_dirty;
    wire [GUIDE_WORDS*32-1:0] guide_bits={{(GUIDE_WORDS*32-GUIDE_W){1'b0}},guide_display};
    wire [GUIDE_WORDS*32-1:0] guide_prev_bits={{(GUIDE_WORDS*32-GUIDE_W){1'b0}},guide_sent};
    always_ff @(posedge ctrl_clk or negedge ctrl_n)begin
        if(!ctrl_n)begin guide_sent_once<=0;guide_sent<='0;guide_dirty<='1;end
        else begin
            for(integer i=0;i<GUIDE_WORDS;i++)guide_dirty[i]<=guide_bits[i*32 +:32]!=guide_prev_bits[i*32 +:32];
            if((!guide_sent_once || (|guide_dirty)) && guide_cdc_ready)begin
                guide_sent<=guide_display;guide_sent_once<=1;
            end
        end
    end
    sidebar_mailbox #(.WIDTH($bits(guide_display_t))) u_guide_cdc(
        .rst_n(rst_n),.src_clk(ctrl_clk),.dst_clk(pix_clk),
        .src_valid(ctrl_n && (!guide_sent_once || (|guide_dirty))),.src_ready(guide_cdc_ready),
        .src_data(guide_display),.src_done(),.src_done_data(),
        .dst_valid(guide_cdc_valid),.dst_ready(frame_pulse && pix_n),.dst_data(guide_wire));
    always_ff @(posedge pix_clk or negedge pix_n)begin
        if(!pix_n)pixel_guide<='0;
        else if(guide_cdc_valid && frame_pulse)pixel_guide<=guide_wire;
    end
    wire[1:0] page=(pixel_view.display_cfg.style_id==16'd0)?2'd0:
                    (pixel_view.display_cfg.style_id==16'd1)?2'd1:
                    (pixel_view.display_cfg.style_id==16'd2)?2'd2:2'd3;
    wire[3:0] effects={pixel_view.display_cfg.grid,pixel_view.display_cfg.theme,
                        pixel_view.display_cfg.peak,pixel_view.display_cfg.smooth};
    wire[5:0] base_r,base_g,base_b,overlay_r,overlay_g,overlay_b;
    logic[2:0][5:0] base_r_q,base_g_q,base_b_q;
    logic[2:0] de_q;
    wire overlay_hit,guide_hit;
    wire [5:0] guide_r,guide_g,guide_b;
    lcd_draw #(.LEGACY_UI(1'b0),.REVERSE_SCAN(REVERSE_SCAN)) u_spectrum(
        .clk(pix_clk),.rst_n(pix_n),.frame_pulse(frame_pulse),.lcd_valid(lcd_valid),
        .pix_x(pix_x),.pix_y(pix_y),.page_sel(page),.ui_setting_sel(2'd0),.effects(effects),
        .q_y(q_y),.q_ov(q_ov),.wave_rd_data(wave_rd_data),.wave_rd_addr(wave_rd_addr),
        .curve_rd_data(curve_rd_data),.curve_rd_addr(curve_rd_addr),
        .lcd_r(base_r),.lcd_g(base_g),.lcd_b(base_b));
    lcd_pad_guide #(.FONT_FILE(FONT_FILE),.LABEL_FILE(LABEL_FILE)) u_guide_page(
        .clk(pix_clk),.rst_n(pix_n),.frame_pulse(frame_pulse),.lcd_valid(lcd_valid),
        .pix_x(pix_x),.pix_y(pix_y),.view(pixel_guide),.hit(guide_hit),.r(guide_r),.g(guide_g),.b(guide_b));
    lcd_sidebar #(.FONT_FILE(FONT_FILE),.LABEL_FILE(LABEL_FILE)) u_sidebar(
        .clk(pix_clk),.rst_n(pix_n),.frame_pulse(frame_pulse),.lcd_valid(lcd_valid),
        .pix_x(pix_x),.pix_y(pix_y),.view(pixel_view),.guide_view(pixel_guide),.hit(overlay_hit),
        .r(overlay_r),.g(overlay_g),.b(overlay_b),.visible_width(sidebar_width));
    // de_q masks all unfilled RGB stages after reset; color data needs no reset.
    always_ff @(posedge pix_clk)begin
        base_r_q<={base_r_q[1:0],base_r};base_g_q<={base_g_q[1:0],base_g};base_b_q<={base_b_q[1:0],base_b};
    end
    always_ff @(posedge pix_clk or negedge pix_n)begin
        if(!pix_n)de_q<=0;
        else de_q<={de_q[1:0],lcd_valid};
    end
    // Final color/DE register: the synchronous font ROM no longer drives pads
    // through glyph-bit selection and the full overlay compositor in one path.
    always_ff @(posedge pix_clk or negedge pix_n)begin
        if(!pix_n)begin lcd_valid_out<=0;lcd_r<=0;lcd_g<=0;lcd_b<=0;end
        else begin
            lcd_valid_out<=de_q[2];
            lcd_r<=de_q[2]?(overlay_hit?overlay_r:guide_hit?guide_r:base_r_q[2]):6'd0;
            lcd_g<=de_q[2]?(overlay_hit?overlay_g:guide_hit?guide_g:base_g_q[2]):6'd0;
            lcd_b<=de_q[2]?(overlay_hit?overlay_b:guide_hit?guide_b:base_b_q[2]):6'd0;
        end
    end
endmodule
