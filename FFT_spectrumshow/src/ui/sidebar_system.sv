`timescale 1ns/1ps
// 正式集成边界：主时钟域的原始摇杆/请求/真实后端，像素域的已有频谱读口。
module sidebar_system #(
    parameter integer CTRL_HZ=100_000_000,
    parameter integer CALIB_LOG2=4,
    parameter integer HOT_DWELL_MS=180,
    parameter bit HAS_JOYSTICK=1'b1,
    parameter FONT_FILE="sidebar_font.mem"
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
    input logic[19:0] backend_supported,
    output logic backend_valid,
    input logic backend_ready,
    output config_pkg::cfg_request_t backend_request,
    output logic backend_source,
    input logic backend_rsp_valid,
    output logic backend_rsp_ready,
    input config_pkg::cfg_response_t backend_response,
    input logic frame_pulse,lcd_valid,
    input logic[9:0] pix_x,pix_y,q_y,q_ov,
    input logic[9:0] wave_rd_data,
    output wire[9:0] wave_rd_addr,
    input logic[39:0] curve_rd_data,
    output wire[9:0] curve_rd_addr,
    output wire[5:0] lcd_r,lcd_g,lcd_b,
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
    joystick_adapter #(.CLK_HZ(CTRL_HZ),.CALIB_LOG2(CALIB_LOG2)) u_joystick(
        .clk(ctrl_clk),.rst_n(ctrl_n),.recalibrate(joy_recalibrate),
        .sample_valid(joy_sample_valid),.raw_x(joy_raw_x),.raw_y(joy_raw_y),
        .calibrated(joy_calibrated),.stale(joy_stale),.center_x(),.center_y(),
        .position_update(joy_update),.dx(dx),.dy(dy),.direction(direction),
        .nav_valid(nav_valid),.nav_ready(nav_ready),.nav_dir(nav_dir),.nav_repeat(nav_repeat));
    logic ui_cfg_valid,ui_cfg_ready,ui_rsp_valid;
    cfg_request_t ui_request,request;
    cfg_response_t response;
    logic req_valid,req_ready,req_source,rsp_valid,rsp_ready,rsp_source;
    localparam logic[19:0] LOCAL_SUPPORTED=HAS_JOYSTICK?LOCAL_MASK:DISPLAY_MASK;
    wire[19:0] supported=backend_supported|LOCAL_SUPPORTED;
    sidebar_ctrl #(.HOT_DWELL_MS(HOT_DWELL_MS)) u_ui(
        .clk(ctrl_clk),.rst_n(ctrl_n),.tick_ms(tick_ms),
        .joy_calibrated(joy_calibrated),.joy_stale(joy_stale),.dx(dx),.dy(dy),.direction(direction),
        .nav_valid(nav_valid),.nav_ready(nav_ready),.nav_repeat(nav_repeat),.nav_dir(nav_dir),
        .key_valid(key_valid),.key_event(key_event),.active_values(active_values),.supported(supported),
        .cfg_valid(ui_cfg_valid),.cfg_ready(ui_cfg_ready),.cfg_request(ui_request),
        .rsp_valid(ui_rsp_valid),.rsp_ready(),.cfg_response(response),.scene(ui_scene));
    control_loop #(.SOURCES(2),.REQUEST_W($bits(cfg_request_t))) u_loop(
        .clk(ctrl_clk),.rst_n(ctrl_n),.poll_tick(tick_ms),
        .src_valid({ext_cfg_valid,ui_cfg_valid}),.src_ready({ext_cfg_ready,ui_cfg_ready}),
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
    config_dispatch #(.LOCAL_SUPPORTED(LOCAL_SUPPORTED)) u_config(
        .clk(ctrl_clk),.rst_n(ctrl_n),.tick_ms(tick_ms),.req_valid(req_valid),.req_ready(req_ready),
        .request(request),.request_source(req_source),.rsp_valid(rsp_valid),.rsp_ready(rsp_ready),
        .response(response),.response_source(rsp_source),.backend_supported(backend_supported),
        .backend_valid(backend_valid),.backend_ready(backend_ready),.backend_request(backend_request),
        .backend_source(backend_source),.backend_rsp_valid(backend_rsp_valid),.backend_rsp_ready(backend_rsp_ready),
        .backend_response(backend_response),.active_values(active_values),.render_config(render_config),
        .render_epoch(render_epoch),.display_done(view_done),.display_done_epoch(done_view.epoch),
        .joy_recalibrate(joy_recalibrate),.joy_calibrated(joy_calibrated),.joy_stale(joy_stale));
    always_comb begin
        current_view.epoch=render_epoch;current_view.display_cfg=render_config;
        current_view.scene=ui_scene;current_view.values=active_values;current_view.supported=supported;
    end
    logic snapshot_ready,snapshot_valid,sent_once;
    wire snapshot_offer=!sent_once||(current_view!=sent_view);
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
    wire[1:0] page=(pixel_view.display_cfg.style_id==16'd0)?2'd0:
                    (pixel_view.display_cfg.style_id==16'd1)?2'd1:
                    (pixel_view.display_cfg.style_id==16'd2)?2'd2:2'd3;
    wire[3:0] effects={pixel_view.display_cfg.grid,pixel_view.display_cfg.theme,
                        pixel_view.display_cfg.peak,pixel_view.display_cfg.smooth};
    wire[5:0] base_r,base_g,base_b,overlay_r,overlay_g,overlay_b;
    logic[5:0] base_r_q,base_g_q,base_b_q;
    wire overlay_hit;
    lcd_draw #(.LEGACY_UI(1'b0)) u_spectrum(
        .clk(pix_clk),.rst_n(pix_n),.frame_pulse(frame_pulse),.lcd_valid(lcd_valid),
        .pix_x(pix_x),.pix_y(pix_y),.page_sel(page),.ui_setting_sel(2'd0),.effects(effects),
        .q_y(q_y),.q_ov(q_ov),.wave_rd_data(wave_rd_data),.wave_rd_addr(wave_rd_addr),
        .curve_rd_data(curve_rd_data),.curve_rd_addr(curve_rd_addr),
        .lcd_r(base_r),.lcd_g(base_g),.lcd_b(base_b));
    lcd_sidebar #(.FONT_FILE(FONT_FILE)) u_sidebar(
        .clk(pix_clk),.rst_n(pix_n),.frame_pulse(frame_pulse),.lcd_valid(lcd_valid),
        .pix_x(pix_x),.pix_y(pix_y),.view(pixel_view),.hit(overlay_hit),
        .r(overlay_r),.g(overlay_g),.b(overlay_b),.visible_width(sidebar_width));
    always_ff @(posedge pix_clk or negedge pix_n)begin
        if(!pix_n)begin base_r_q<=0;base_g_q<=0;base_b_q<=0;lcd_valid_out<=0;end
        else begin base_r_q<=base_r;base_g_q<=base_g;base_b_q<=base_b;lcd_valid_out<=lcd_valid;end
    end
    assign lcd_r=lcd_valid_out?(overlay_hit?overlay_r:base_r_q):6'd0;
    assign lcd_g=lcd_valid_out?(overlay_hit?overlay_g:base_g_q):6'd0;
    assign lcd_b=lcd_valid_out?(overlay_hit?overlay_b:base_b_q):6'd0;
endmodule
