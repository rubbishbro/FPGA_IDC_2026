`timescale 1ns/1ps
module tb_config_source_cancel;
import router_pkg::*;import config_pkg::*;
logic clk=0;always #5 clk=~clk;
logic rst_n=0,bvalid=0,bready,rvalid,source_valid=1,valid,fault;
cfg_request_t req;cfg_response_t rsp;audio_config_t state;
pad_driver_pkg::mat4x4 fmap='0;
wire cs,sck,oe;wire[3:0]dqo,dqi;
logic[31:0] before_g;
midi_voice_top #(.SLOTS(4),.N_MODES(3),.CLK_HZ(1_000_000),.NOTE_BANKS(1),.CONFIG_BACKEND(1),.RESOURCE_MASK(12'h003),.CONFIG_TIMEOUT_CYCLES(1_000_000)) dut(
.clk(clk),.rst_n(rst_n),.run(1'b1),.audio_clk(1'b0),.fmap(fmap),.pad_instrument(INST_PIANO),.reverb_preset(REVERB_NONE),.reload(1'b0),.midi_select(1'b0),.midi_source_id(1'b0),.panic(1'b0),.selected_channel(4'd1),.note_bank(1'b0),.first_midi_note(7'd21),.slot_note_map('0),.backend_valid(bvalid),.backend_source(1'b0),.backend_source_valid(source_valid),.backend_ready(bready),.backend_request(req),.backend_rsp_valid(rvalid),.backend_rsp_ready(1'b1),.backend_response(rsp),.backend_supported(),.backend_audio_valid(valid),.backend_audio_fault(fault),.backend_audio_state(state),.event_valid(1'b0),.event_data(32'd0),.event_source_id(1'b0),.source_cleanup_req(2'b0),.control_ready(1'b0),.qspi_cs_n(cs),.qspi_sck(sck),.qspi_dq_o(dqo),.qspi_dq_oe(oe),.qspi_dq_i(dqi));
w25q64_read_model #(.N_MODES(3),.WRITE_NS(0)) flash(.cs_n(cs),.sck(sck),.dq_o(dqo),.dq_oe(oe),.blank(1'b0),.dq_i(dqi));
// Sample coefficient RAM after the real loader, not just configuration IDs.
logic [31:0] saved_g[0:7];
logic monitor_cancel=0;
always @(negedge clk) if(monitor_cancel && valid && !rvalid)
    $fatal(1,"audio became valid before rollback response");
task automatic send(input logic [15:0] id,input logic [31:0] value);
    @(negedge clk);req={16'h11,id,value};bvalid=1;
    do @(posedge clk);while(!bready);
    @(negedge clk);bvalid=0;
endtask
task automatic response(input logic [7:0] result);
    wait(rvalid);#1;
    if(rsp.result!==result || rsp.tag!==16'h11 || fault || !valid)
        $fatal(1,"response result=%0d expected=%0d fault=%b valid=%b",rsp.result,result,fault,valid);
    @(negedge clk);monitor_cancel=0;
    @(negedge clk);
endtask
initial begin
    req='0;repeat(5)@(negedge clk);rst_n=1;wait(valid);
    repeat(20)@(negedge clk);
    // Normal scalar settings: instrument, reverb, bank and performance source.
    send(16'h0100,1);response(CFG_OK);
    if(state.instrument!=1)$fatal(1,"instrument commit");
    send(16'h0200,1);response(CFG_OK);
    if(state.reverb!=1)$fatal(1,"reverb commit");
    send(16'h0300,1);response(CFG_OK);
    if(state.bank!=1)$fatal(1,"bank commit");
    send(16'h0500,1);response(CFG_OK);
    if(state.source!=1)$fatal(1,"source commit");
    send(16'h0500,0);response(CFG_OK);
    send(16'h0300,0);response(CFG_OK);
    for(integer i=0;i<8;i++)saved_g[i]=dut.u_voice.ca_gq_a[i];
    before_g=saved_g[0];
    // Lose the source while loading. Recovery must not revive the request.
    send(16'h0300,1);
    wait(dut.u_voice.ld_busy);@(negedge clk);
    fmap.raw[7:0]=8'd255;source_valid=0;monitor_cancel=1;
    repeat(20)@(negedge clk);source_valid=1;
    response(CFG_FAILED);
    fmap='0;
    if(state.bank!=0 || dut.bank_q!=0 || rsp.applied_value!=0)
        $fatal(1,"canceled bank published");
    for(integer i=0;i<8;i++)if(dut.u_voice.ca_gq_a[i]!==saved_g[i])
        $fatal(1,"coefficient %0d not restored",i);
    if(dut.u_voice.pending_offsets[31:0]!=0)$fatal(1,"canceled offset retained");
    $display("PASS canceled load restored committed coefficient RAM after source recovery");
    // Invalid at acceptance must fail without ever starting a load.
    source_valid=0;send(16'h0300,1);response(CFG_FAILED);
    if(state.bank!=0 || dut.u_voice.ca_gq_a[0]!==before_g)$fatal(1,"invalid-source request changed bank");
    // A fresh valid request still commits after the failed requests.
    source_valid=1;send(16'h0300,1);response(CFG_OK);
    if(state.bank!=1 || dut.u_voice.ca_gq_a[0]===before_g)$fatal(1,"fresh request failed to load bank");
    $display("PASS tb_config_source_cancel");$finish;
end
initial begin #100000000;$fatal(1,"watchdog");end
endmodule
