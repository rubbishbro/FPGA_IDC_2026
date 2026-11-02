`timescale 1ns/1ps
// Check malformed/stale backend responses cannot partially publish a joint state.
module tb_config_joint_result;
    import config_pkg::*;
    logic clk=0,rst_n=0,req_valid=0,req_ready,rsp_valid,rsp_ready=0;
    always #5 clk=~clk;
    cfg_request_t request;
    cfg_response_t response,backend_response;
    logic backend_valid,backend_rsp_valid=0,backend_rsp_ready,audio_valid=1;
    audio_config_t audio_state;
    cfg_values_t values;
    integer checks=0;
    config_dispatch #(.AUDIO_BACKEND(1)) dut(
        .clk(clk),.rst_n(rst_n),.tick_ms(1'b0),.req_valid(req_valid),.req_ready(req_ready),
        .request(request),.request_source(1'b0),.rsp_valid(rsp_valid),.rsp_ready(rsp_ready),
        .response(response),.response_source(),.backend_supported(21'h118001),
        .backend_valid(backend_valid),.backend_ready(1'b1),.backend_request(),.backend_source(),
        .backend_rsp_valid(backend_rsp_valid),.backend_rsp_ready(backend_rsp_ready),.backend_response(backend_response),
        .backend_audio_valid(audio_valid),.backend_audio_state(audio_state),.active_values(values),
        .render_config(),.render_epoch(),.display_done(1'b0),.display_done_epoch(16'd0),
        .joy_recalibrate(),.joy_calibrated(1'b0),.joy_stale(1'b0));
    task automatic ck(input logic ok,input string msg);
        checks++;if(ok!==1'b1)$fatal(1,"FAIL %s",msg);
    endtask
    task automatic send(input logic[15:0] tag);
        @(negedge clk);request={tag,16'h0100,32'd1};req_valid=1;
        while(!req_ready)@(negedge clk);
        @(negedge clk);req_valid=0;wait(backend_rsp_ready);@(negedge clk);
    endtask
    task automatic send_guide(input logic[15:0] tag);
        @(negedge clk);request={tag,16'h0503,32'd1};req_valid=1;
        while(!req_ready)@(negedge clk);
        @(negedge clk);req_valid=0;wait(backend_rsp_ready);@(negedge clk);
    endtask
    task automatic complete(input logic[15:0] tag,input logic[7:0] result_code);
        backend_response={tag,16'h0100,result_code,32'd1};backend_rsp_valid=1;
        @(negedge clk);backend_rsp_valid=0;wait(rsp_valid);@(negedge clk);
    endtask
    task automatic ack;
        rsp_ready=1;@(negedge clk);rsp_ready=0;repeat(2)@(negedge clk);
    endtask
    initial begin
        request='0;backend_response='0;audio_state={16'd0,5'd2,2'd1,1'b0,2'd0,1'b0,1'b0};
        repeat(5)@(negedge clk);rst_n=1;repeat(3)@(negedge clk);
        ck(values[0]==0 && values[12]==2 && values[11]==1,"initial actual snapshot");
        send(1);audio_state.instrument=1;audio_state.channel=1;
        complete(2,CFG_OK);
        ck(response.result==CFG_FAILED && values[0]==0 && values[12]==2,"wrong tag cannot publish snapshot");
        ack();
        send(3);audio_state.channel=2;complete(3,CFG_OK);
        ck(response.result==CFG_FAILED && values[0]==0 && values[12]==2,"inconsistent pair rejected");ack();
        send(4);audio_state.channel=1;audio_valid=0;complete(4,CFG_OK);
        ck(response.result==CFG_FAILED && values[0]==0 && values[12]==2,"no valid resource means no successful result");ack();
        send(5);audio_valid=1;complete(5,CFG_FAILED);
        ck(response.result==CFG_FAILED && values[0]==0 && values[12]==2,"failed result cannot publish a new pair");ack();
        send(6);complete(6,CFG_OK);
        ck(response.result==CFG_OK && values[0]==1 && values[12]==1,"matched result commits both fields");
        repeat(20)@(negedge clk);
        ck(rsp_valid && response.tag==6 && values[0]==1 && values[12]==1,"response stable under backpressure");ack();
        send_guide(7);backend_response={16'd7,16'h0503,CFG_OK,32'd1};backend_rsp_valid=1;
        @(negedge clk);backend_rsp_valid=0;wait(rsp_valid);@(negedge clk);
        ck(response.result==CFG_FAILED && values[20]==0,"scalar guide success cannot override actual mode snapshot");ack();
        send_guide(8);audio_state.guide=1;
        backend_response={16'd8,16'h0503,CFG_OK,32'd1};backend_rsp_valid=1;
        @(negedge clk);backend_rsp_valid=0;wait(rsp_valid);@(negedge clk);
        ck(response.result==CFG_OK && values[20]==1 && values[11]==1,"guide publishes only with matching actual snapshot");ack();
        send_guide(9);audio_state.source=0;
        backend_response={16'd9,16'h0503,CFG_OK,32'd1};backend_rsp_valid=1;
        @(negedge clk);backend_rsp_valid=0;wait(rsp_valid);@(negedge clk);
        ck(response.result==CFG_FAILED && values[20]==1 && values[11]==1,"PAD plus guide invalid snapshot cannot partially publish");ack();
        $display("PASS tb_config_joint_result checks=%0d",checks);$finish;
    end
    initial begin #100000;$fatal(1,"FAIL joint result watchdog");end
endmodule
