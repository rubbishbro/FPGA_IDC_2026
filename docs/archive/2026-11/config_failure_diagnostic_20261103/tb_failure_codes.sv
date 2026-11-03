`timescale 1ns/1ps
module tb_failure_codes;
import config_pkg::*;
logic clk=0;always #5 clk=~clk;
logic rst_n=0,req_valid=0,req_ready,rsp_valid,backend_valid,backend_rsp_ready,backend_rsp_valid=0,audio_valid=1;
cfg_request_t request;cfg_response_t response,back;audio_config_t audio;cfg_values_t values;
config_dispatch #(.AUDIO_BACKEND(1)) dut(.clk(clk),.rst_n(rst_n),.tick_ms(1'b0),.req_valid(req_valid),.req_ready(req_ready),.request(request),.request_source(1'b0),.rsp_valid(rsp_valid),.rsp_ready(1'b1),.response(response),.response_source(),.backend_supported('1),.backend_valid(backend_valid),.backend_ready(1'b1),.backend_request(),.backend_source(),.backend_rsp_valid(backend_rsp_valid),.backend_rsp_ready(backend_rsp_ready),.backend_response(back),.backend_audio_valid(audio_valid),.backend_audio_state(audio),.active_values(values),.render_config(),.render_epoch(),.display_done(1'b0),.display_done_epoch(16'd0),.joy_recalibrate(),.joy_calibrated(1'b1),.joy_stale(1'b0));
integer checks=0;
task automatic probe(input int kind,input logic[7:0] expected);
 @(negedge clk);audio='0;audio.channel=2;audio_valid=1;repeat(5)@(negedge clk);
 request={16'(kind+1),16'h0200,32'd1};req_valid=1;
 do @(posedge clk);while(!req_ready);
 @(negedge clk);req_valid=0;wait(backend_rsp_ready);@(negedge clk);
 audio.reverb=router_pkg::REVERB_HALL;back={16'(kind+1),16'h0200,CFG_OK,32'd1};
 case(kind)
 1:back.tag=16'hff;
 2:back.id=16'h0300;
 3:back.applied_value=4;
 4:audio_valid=0;
 5:audio.channel=0;
 6:audio.reverb=router_pkg::REVERB_NONE;
 7:begin back.applied_value=0;audio.reverb=router_pkg::REVERB_NONE;end
 8:back.result=CFG_FAILED;
 endcase
 backend_rsp_valid=1;@(negedge clk);backend_rsp_valid=0;wait(rsp_valid);#1;
 $display("CASE %0d RESULT %02h EXPECT %02h",kind,response.result,expected);
 if(response.result!==expected)$fatal(1,"wrong diagnostic classification");
 checks++;@(negedge clk);repeat(5)@(negedge clk);
endtask
initial begin request='0;back='0;audio='0;audio.channel=2;repeat(4)@(negedge clk);rst_n=1;
probe(0,8'h00);probe(1,8'h81);probe(2,8'h82);probe(3,8'h83);probe(4,8'h91);probe(5,8'h92);probe(6,8'h94);probe(7,8'h98);probe(8,8'ha4);
$display("PASS failure_codes cases=%0d",checks);$finish;end
initial begin #100000;$fatal(1,"watchdog");end
endmodule
