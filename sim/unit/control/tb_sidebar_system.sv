`timescale 1ns/1ps
module tb_sidebar_system #(parameter integer PIX_HALF=7);
    import config_pkg::*;
    logic ctrl_clk=0,pix_clk=0,rst_n=0;
    always #5 ctrl_clk=~ctrl_clk;
    always #(PIX_HALF) pix_clk=~pix_clk;
    logic joy_sample_valid=0;
    logic[13:0] joy_raw_x=8192,joy_raw_y=8192,target_x=8192,target_y=8192;
    integer sample_count=0;
    logic samples_enabled=1,frames_enabled=1;
    always @(negedge ctrl_clk)begin
        sample_count=sample_count+1;
        joy_sample_valid=samples_enabled&&(sample_count%20==0);
        joy_raw_x=target_x;joy_raw_y=target_y;
    end
    logic frame_pulse=0;
    integer frame_count=0;
    always @(negedge pix_clk)begin
        frame_count=frame_count+1;
        frame_pulse=frames_enabled&&(frame_count%50==0);
    end
    logic key_valid=0;
    logic[2:0] key_event=0;
    logic ext_cfg_valid=0,ext_cfg_ready,ext_rsp_valid,ext_rsp_ready=0;
    cfg_request_t ext_cfg_request;
    cfg_response_t ext_cfg_response;
    logic[19:0] backend_supported=20'h00003;
    logic backend_valid,backend_ready=0,backend_source,backend_rsp_valid=0,backend_rsp_ready;
    cfg_request_t backend_request;
    cfg_response_t backend_response;
    logic lcd_valid=1,lcd_valid_out;
    logic[5:0] lcd_r,lcd_g,lcd_b;
    logic[9:0] wave_rd_addr,curve_rd_addr;
    cfg_values_t active_values;
    sidebar_scene_t ui_scene;
    wire[8:0] sidebar_width;
    sidebar_system #(.CTRL_HZ(10000),.CALIB_LOG2(2),.HOT_DWELL_MS(3)) dut(
        .rst_n(rst_n),.ctrl_clk(ctrl_clk),.pix_clk(pix_clk),
        .joy_sample_valid(joy_sample_valid),.joy_raw_x(joy_raw_x),.joy_raw_y(joy_raw_y),
        .key_valid(key_valid),.key_event(key_event),
        .ext_cfg_valid(ext_cfg_valid),.ext_cfg_ready(ext_cfg_ready),.ext_cfg_request(ext_cfg_request),
        .ext_rsp_valid(ext_rsp_valid),.ext_rsp_ready(ext_rsp_ready),.ext_cfg_response(ext_cfg_response),
        .backend_supported(backend_supported),.backend_valid(backend_valid),.backend_ready(backend_ready),
        .backend_request(backend_request),.backend_source(backend_source),
        .backend_rsp_valid(backend_rsp_valid),.backend_rsp_ready(backend_rsp_ready),.backend_response(backend_response),
        .frame_pulse(frame_pulse),.lcd_valid(lcd_valid),.pix_x(10'd700),.pix_y(10'd300),
        .q_y(10'd160),.q_ov(10'd180),.wave_rd_data(10'd240),.wave_rd_addr(wave_rd_addr),
        .curve_rd_data({10'd180,10'd200,10'd220,10'd240}),.curve_rd_addr(curve_rd_addr),
        .lcd_r(lcd_r),.lcd_g(lcd_g),.lcd_b(lcd_b),.lcd_valid_out(lcd_valid_out),
        .active_values(active_values),.ui_scene(ui_scene),.sidebar_width(sidebar_width));
    integer requests=0,backend_accepts=0,results=0;
    logic rsp_held=0,backend_held=0,ui_held=0;
    cfg_response_t rsp_previous;
    cfg_request_t backend_previous,ui_previous;
    always @(posedge ctrl_clk)begin
        if(!rst_n)begin rsp_held=0;backend_held=0;ui_held=0;end
        else begin
            if(rsp_held&&(!ext_rsp_valid||ext_cfg_response!==rsp_previous))$fatal(1,"result changed under backpressure");
            if(backend_held&&(!backend_valid||backend_request!==backend_previous))$fatal(1,"backend request changed under backpressure");
            if(ui_held&&(!dut.ui_cfg_valid||dut.ui_request!==ui_previous))$fatal(1,"UI request changed under backpressure");
            rsp_held=ext_rsp_valid&&!ext_rsp_ready;rsp_previous=ext_cfg_response;
            backend_held=backend_valid&&!backend_ready;backend_previous=backend_request;
            ui_held=dut.ui_cfg_valid&&!dut.ui_cfg_ready;ui_previous=dut.ui_request;
            if(ext_cfg_valid&&ext_cfg_ready)requests=requests+1;
            if(ext_rsp_valid&&ext_rsp_ready)results=results+1;
            if(backend_valid&&backend_ready)backend_accepts=backend_accepts+1;
        end
    end
    task automatic clocks(input integer n);repeat(n)begin @(posedge ctrl_clk);#1;end endtask
    task automatic key(input logic[2:0] event_code);
        @(negedge ctrl_clk);key_valid=1;key_event=event_code;
        @(negedge ctrl_clk);key_valid=0;clocks(2);
    endtask
    task automatic neutral();target_x=8192;target_y=8192;clocks(45);endtask
    task automatic send(input logic[15:0] tag,input logic[15:0] id,input integer value);
        @(negedge ctrl_clk);ext_cfg_request.tag=tag;ext_cfg_request.id=id;ext_cfg_request.value=value;ext_cfg_valid=1;
        do begin @(posedge ctrl_clk);end while(!ext_cfg_ready);
        @(negedge ctrl_clk);ext_cfg_valid=0;
    endtask
    task automatic result(input logic[15:0] tag,input logic[15:0] id,input logic[7:0] code);
        wait(ext_rsp_valid);#1;
        if(ext_cfg_response.tag!=tag||ext_cfg_response.id!=id||ext_cfg_response.result!=code)
            $fatal(1,"wrong result tag=%h id=%h code=%0d wanted %h/%h/%0d",ext_cfg_response.tag,
                   ext_cfg_response.id,ext_cfg_response.result,tag,id,code);
        @(negedge ctrl_clk);ext_rsp_ready=1;
        @(negedge ctrl_clk);ext_rsp_ready=0;clocks(3);
    endtask
    task automatic reply_backend(input logic[7:0] code,input integer value,input bit wrong_tag);
        wait(backend_valid);clocks(12);
        if(!backend_source)$fatal(1,"backend source routing");
        backend_response.tag=backend_request.tag+(wrong_tag?1:0);
        backend_response.id=backend_request.id;backend_response.result=code;backend_response.applied_value=value;
        @(negedge ctrl_clk);backend_ready=1;
        @(negedge ctrl_clk);backend_ready=0;backend_rsp_valid=1;
        do begin @(posedge ctrl_clk);end while(!backend_rsp_ready);
        @(negedge ctrl_clk);backend_rsp_valid=0;
    endtask
    initial begin
        ext_cfg_request='0;backend_response='0;
        clocks(5);@(negedge ctrl_clk);rst_n=1;
        wait(dut.joy_calibrated);neutral();
        if(ui_scene.open||active_values[6]!=0)$fatal(1,"startup");
        target_x=0;
        wait(ui_scene.open);clocks(45);
        if(ui_scene.layer!=0)$fatal(1,"opening deflection entered a menu");
        neutral();target_x=16383;clocks(45);
        if(ui_scene.layer!=1||ui_scene.category!=0)$fatal(1,"joystick right enter");
        target_x=0;clocks(45);
        if(ui_scene.layer!=1)$fatal(1,"changed layer without neutral");
        neutral();target_x=0;clocks(45);
        if(ui_scene.layer!=0||!ui_scene.open)$fatal(1,"joystick back");
        neutral();
        key(1);key(1);key(1);key(2);
        if(ui_scene.category!=3||ui_scene.layer!=1)$fatal(1,"display menu");
        key(2);key(1);key(4);
        if(ui_scene.layer!=1||active_values[6]!=0||dut.ui_cfg_valid)$fatal(1,"cancel wrote a draft");
        key(2);key(1);key(2);
        wait(!ui_scene.busy);clocks(3);
        if(active_values[6]!=1||!ui_scene.has_result||ui_scene.result!=CFG_OK)$fatal(1,"UI -> loop -> frame commit");
        target_x=0;clocks(45);key(4); // 左推返回根，再由兼容键关栏，保持左推。
        clocks(500);
        if(ui_scene.open)$fatal(1,"held closing deflection reopened sidebar");
        neutral();
        frames_enabled=0;clocks(100);
        send(16'h100,16'h0400,2);clocks(400);
        if(ext_rsp_valid||active_values[6]!=1)$fatal(1,"false success without a frame");
        frames_enabled=1;wait(ext_rsp_valid);clocks(50);
        if(active_values[6]!=2)$fatal(1,"display active not committed");
        result(16'h100,16'h0400,CFG_OK);
        send(16'h101,16'h0400,256);result(16'h101,16'h0400,CFG_UNSUPPORTED);
        if(active_values[6]!=2)$fatal(1,"style truncated to low bits");
        send(16'h102,16'h0401,2);result(16'h102,16'h0401,CFG_OUT_OF_RANGE);
        send(16'h103,16'h7777,0);result(16'h103,16'h7777,CFG_UNSUPPORTED);
        backend_supported=0;
        send(16'h104,16'h0101,500);result(16'h104,16'h0101,CFG_UNSUPPORTED);
        if(backend_accepts!=0||active_values[1]!=1000)$fatal(1,"unsupported backend applied");
        backend_supported=3;
        send(16'h105,16'h0100,5);reply_backend(CFG_OK,5,0);result(16'h105,16'h0100,CFG_OK);
        if(active_values[0]!=5)$fatal(1,"instrument ID not forwarded intact");
        send(16'h106,16'h0100,1);reply_backend(CFG_DENIED,0,0);result(16'h106,16'h0100,CFG_DENIED);
        if(active_values[0]!=5)$fatal(1,"failure overwrote active value");
        send(16'h107,16'h0101,700);reply_backend(CFG_OK,-1,0);result(16'h107,16'h0101,CFG_FAILED);
        send(16'h108,16'h0100,1);reply_backend(CFG_OK,1,1);result(16'h108,16'h0100,CFG_FAILED);
        if(active_values[0]!=5)$fatal(1,"mismatched completion adopted");
        send(16'h109,16'h8000,0);result(16'h109,16'h8000,CFG_OK);
        if(!dut.joy_calibrated)$fatal(1,"calibration prematurely completed");
        // 配置结果反压期间，可在 loop 暂存下一条，但不能覆盖正在返回的结果。
        send(16'h10a,16'h0402,0);wait(ext_rsp_valid);
        send(16'h10b,16'h0404,0);clocks(80);
        result(16'h10a,16'h0402,CFG_OK);result(16'h10b,16'h0404,CFG_OK);
        if(active_values[8]!=0||active_values[10]!=0)$fatal(1,"buffered config lost");
        if(requests!=results)$fatal(1,"request/result accounting %0d/%0d",requests,results);
        frames_enabled=0;clocks(100);send(16'h200,16'h0400,0);clocks(100);
        @(negedge ctrl_clk);rst_n=0;clocks(5);@(negedge ctrl_clk);rst_n=1;
        frames_enabled=1;clocks(200);
        if(ext_rsp_valid||backend_valid||ui_scene.busy||active_values[6]!=0)$fatal(1,"stale transaction after reset");
        @(negedge pix_clk);lcd_valid=0;
        repeat(3)@(negedge pix_clk);
        if(lcd_valid_out||{lcd_r,lcd_g,lcd_b}!=0)$fatal(1,"DE/RGB alignment");
        $display("PASS sidebar_system pixel_half=%0d completed=%0d backend=%0d",PIX_HALF,results,backend_accepts);
        $finish;
    end
    initial begin #2000000;$fatal(1,"watchdog");end
endmodule
