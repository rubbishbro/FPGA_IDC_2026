`timescale 1ns/1ps
module tb_instrument_board;
import config_pkg::*;
logic clk=0,audio=0,pix=0,rst_n=0;
always #10 clk=~clk;
always #7 audio=~audio;
always #13 pix=~pix;
wire [3:0] dq,pad_row;
wire [2:0] pad_ch;
logic pad_enabled=0;
instrument_system dut(.clk_core(clk),.clk_audio(audio),.clk_pix(pix),.rst_n(rst_n),
.key0(1'b1),.key1(1'b1),.uart_rx(2'b11),.session_restart(2'b0),.bt_state(1'b0),
.pan_position(6'd8),.pad_row(pad_row),.pad_ch(pad_ch),.flash_dq(dq));
cfg_request_t request;
logic offer=0;
initial begin
force dut.u_ui.ui_cfg_valid=offer;
force dut.u_ui.ui_request=request;
#100;rst_n=1;repeat(20)@(negedge clk);
if(dut.spatial_pan!=8 || dut.values[21]!=8)$fatal(1,"reset pan mismatch");
if(!dut.u_ui.supported[21])$fatal(1,"pan unavailable");
for(integer i=0;i<5;i++)begin
request.tag=16'(i);request.id=16'h0102;
case(i)0:request.value=0;1:request.value=16;2:request.value=32;3:request.value=33;4:request.value=-1;endcase
offer=1;
do @(posedge clk);while(!dut.u_ui.ui_cfg_ready);
@(negedge clk);offer=0;
wait(dut.u_ui.ui_rsp_valid);
if(dut.u_ui.response.result!=(i<3?CFG_OK:CFG_OUT_OF_RANGE))$fatal(1,"pan result %d",i);
if(dut.spatial_pan!=(i<3?request.value:32) || dut.values[21]!=(i<3?request.value:32))$fatal(1,"pan commit %d",i);
if(dut.u_sound.pan_position!=dut.spatial_pan)$fatal(1,"pan output disconnected");
repeat(5)@(negedge clk);
end
$display("PASS runtime pan: reset seed, left/center/right, invalid ranges, snapshot and audio wiring");$finish;
end
initial begin #200000;$fatal(1,"pan watchdog");end
endmodule
