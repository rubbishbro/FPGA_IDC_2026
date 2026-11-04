`timescale 1ns/1ps
module tb_reverb_presets;
    import router_pkg::*;
    import config_pkg::*;
    logic clk=0,rst_n=0;
    always #5 clk=~clk;
    reverb_preset preset=REVERB_NONE;
    logic iv=0,ov;
    logic signed [63:0] x=0,y;
    reverb_router dsp(.clk(clk),.rst_n(rst_n),.clear_req(1'b0),.preset(preset),
        .in_valid(iv),.x(x),.out_valid(ov),.y(y));
    cfg_request_t request,backend_request;
    cfg_response_t response,backend_response;
    audio_config_t audio_state;
    cfg_values_t values;
    logic request_source=1;
    logic req_valid=0,req_ready,rsp_valid,backend_valid,backend_rsp_valid=0,backend_rsp_ready;
    config_dispatch #(.AUDIO_BACKEND(1)) cfg(
        .clk(clk),.rst_n(rst_n),.tick_ms(1'b0),.initial_pan(6'd16),.req_valid(req_valid),.req_ready(req_ready),
        .request(request),.request_source(request_source),.rsp_valid(rsp_valid),.rsp_ready(1'b1),
        .response(response),.response_source(),.backend_supported(22'h4),
        .backend_valid(backend_valid),.backend_ready(1'b1),.backend_request(backend_request),
        .backend_source(),.backend_rsp_valid(backend_rsp_valid),.backend_rsp_ready(backend_rsp_ready),
        .backend_response(backend_response),.backend_audio_valid(1'b1),.backend_audio_state(audio_state),
        .active_values(values),.render_config(),.render_epoch(),.display_done(1'b0),
        .display_done_epoch(16'd0),.joy_recalibrate(),.joy_calibrated(1'b1),.joy_stale(1'b0));
    sidebar_snapshot_t view;
    lcd_sidebar labels(.clk(clk),.rst_n(rst_n),.frame_pulse(1'b0),.lcd_valid(1'b0),
        .pix_x(10'd0),.pix_y(10'd0),.view(view),.guide_view('0),.hit(),.r(),.g(),.b(),.visible_width());
    always @(posedge clk)begin
        if(backend_rsp_valid && backend_rsp_ready)backend_rsp_valid<=0;
        if(backend_valid)begin
            audio_state.reverb<=reverb_preset'(backend_request.value);
            backend_response.tag<=backend_request.tag;backend_response.id<=backend_request.id;
            backend_response.result<=CFG_OK;backend_response.applied_value<=backend_request.value;
            backend_rsp_valid<=1;
        end
    end
    task automatic configure(input integer value,input logic[7:0] result);
        @(negedge clk);while(!req_ready)@(negedge clk);request='{tag:16'(value),id:16'h0200,value:32'(value)};req_valid=1;
        @(negedge clk);req_valid=0;wait(rsp_valid);
        if(response.result!==result)$fatal(1,"FAIL configuration value=%h result=%h",value,response.result);
        if(result==CFG_OK && values[2]!==32'(value))$fatal(1,"FAIL UI committed snapshot");
        @(negedge clk);
    endtask
    task automatic sample(input logic signed[63:0] value);
        @(negedge clk);x=value;iv=1;@(negedge clk);iv=0;
        wait(ov);#1;if(y!==value)$fatal(1,"FAIL dry passthrough preset=%d x=%h y=%h",preset,value,y);
        repeat(3)@(negedge clk);
    endtask
    initial begin
        audio_state='0;audio_state.channel=1;view='0;request='0;backend_response='0;
        if(REVERB_NONE!=0 || REVERB_HALL!=1 || REVERB_BATHROOM!=2 || REVERB_CHAMBER!=3)
            $fatal(1,"FAIL stable protocol IDs");
        repeat(4)@(negedge clk);rst_n=1;
        configure(REVERB_NONE,CFG_OK);configure(REVERB_HALL,CFG_OK);
        configure(REVERB_BATHROOM,CFG_OK);configure(REVERB_CHAMBER,CFG_OK);
        configure(4,CFG_OUT_OF_RANGE);configure(256,CFG_OUT_OF_RANGE);configure(-1,CFG_OUT_OF_RANGE);
        if(values[2]!=32'(REVERB_CHAMBER))$fatal(1,"FAIL invalid value changed UI");
        request_source=0;configure(REVERB_CHORUS,CFG_OK);
        request_source=1;configure(REVERB_CHORUS,CFG_OUT_OF_RANGE);
        if(values[2]!=32'(REVERB_CHORUS))$fatal(1,"FAIL remote rejection changed local chorus");
        if(cfg_max(2)!=4 || !reverb_value_valid(4) || reverb_wire_value_valid(4) || reverb_value_valid(8))
            $fatal(1,"FAIL local/wire preset domains");
        if(labels.value_label(2,REVERB_CHORUS)!=128)$fatal(1,"FAIL chorus UI label");
        preset=REVERB_CHORUS;#1;
        if(dsp.len[0]!=577 || dsp.len[1]!=743 || dsp.len[2]!=941 || dsp.len[3]!=1193 ||
           dsp.gc!='0 || dsp.wc[0]!=50331648 || dsp.wc[1]!=33554432 ||
           dsp.wc[2]!=33554432 || dsp.wc[3]!=16777216 || dsp.gd!=100663296 || dsp.gw!=33554432)
            $fatal(1,"FAIL chorus parameters");
        if(labels.value_label(2,REVERB_NONE)!=50 || labels.value_label(2,REVERB_HALL)!=52 ||
           labels.value_label(2,REVERB_BATHROOM)!=53 || labels.value_label(2,REVERB_CHAMBER)!=127)
            $fatal(1,"FAIL preset labels");
        preset=REVERB_HALL;#1;
        if(dsp.len[0]!=1214 || dsp.gw!=32'sd67108864)$fatal(1,"FAIL HALL parameters");
        preset=REVERB_BATHROOM;#1;
        if(dsp.len[0]!=293 || dsp.gw!=32'sd33554432)$fatal(1,"FAIL BATHROOM parameters");
        preset=REVERB_CHAMBER;#1;
        if(dsp.len[0]!=431 || dsp.gw!=32'sd24159191 || dsp.gc[0]!=32'sd121035857)
            $fatal(1,"FAIL CHAMBER parameters");
        for(integer p=0;p<1;p++)begin
            @(negedge clk);preset=p==0?REVERB_NONE:REVERB_CHAMBER;
            repeat(3)@(negedge clk);
            for(integer k=0;k<4;k++)if(dsp.len[k]!=1 || dsp.gc[k]!=0 || dsp.wc[k]!=0)
                $fatal(1,"FAIL NONE/CHAMBER comb parameters");
            if(dsp.gd!=32'sd134217728 || dsp.gw!=0)$fatal(1,"FAIL dry gains");
            sample(0);sample(64'sh7fff_ffff_ffff_ffff);sample(64'sh8000_0000_0000_0000);
            sample(-123456789);sample(123456789);
        end
        $display("PASS tb_reverb_presets five internal/four external IDs, local-only chorus/UI/DSP, invalid values, tuned CHAMBER/BATHROOM, NONE dry extremes");$finish;
    end
    initial begin #100000;$fatal(1,"FAIL reverb test watchdog");end
endmodule
