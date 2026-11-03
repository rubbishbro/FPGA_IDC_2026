`timescale 1ns/1ps
// Actual 16-slot voice_router, checked-in piano Flash, board pressure thresholds.
// Report raw signed64 integers only; no PCM conversion or audio normalization.
module tb_piano_force_peak;
 import router_pkg::*;
 logic clk=0,rst_n=0,tick=0;
 always #10 clk=~clk;
 pad_driver_pkg::mat4x4 fmap='0;
 logic valid,err,yv,ready,cs,sck,oe;
 logic[3:0] dqo,dqi;
 logic signed[63:0] y;
 voice_router #(.CLK_HZ(50000000),.SR_HZ(48000),.SLOTS(16),.N_MODES(64),
  .PAD_NOTE_ON_TH(64),.PAD_NOTE_OFF_TH(48),.EXTERNAL_SAMPLE_TICK(1),
  .FLASH_BASE(32'h00800000),.FLASH_BYTES(16777216)) dut(
  .slot_note_map(112'(router_pkg::default_note_map())),
        .clk(clk),.rst_n(rst_n),.sample_tick(tick),.start(1'b1),.fmap(fmap),.inst(INST_PIANO),
  .reverb_preset(REVERB_NONE),.reload(1'b0),.ready(ready),.done(),.load_err(err),.table_valid(valid),
  .load_complete(),.voice_idle(),.y_valid(yv),.y_data(y),
  .qspi_cs_n(cs),.qspi_sck(sck),.qspi_dq_o(dqo),.qspi_dq_oe(oe),.qspi_dq_i(dqi),
  .midi_select(1'b0),.midi_valid(1'b0),.midi_ready(),.midi_gate('0),.midi_retrigger('0),
  .midi_hard_clear('0),.midi_velocity('0),.maintenance_clear(1'b0),.maintenance_done(),.midi_inflight(),
  .map_reload(1'b0),.load_offsets('0),.ns_rd_en(1'b0),.ns_rd_addr('0),.ns_rd_sel(1'b0),.ns_rd_data(),.ns_rd_valid());
 w25q64_read_model #(.N_MODES(64),.RESOURCE_BASE(32'h00800000),.FLASH_BYTES(16777216),
  .FORBID_PROGRAM_READ(1),.MEM_FILE("piano_flash.mem"),.MEM_BYTES(65536)) flash(
  .cs_n(cs),.sck(sck),.dq_o(dqo),.dq_oe(oe),.blank(1'b0),.dq_i(dqi));
 integer fd,case_id=-1,n_out=0,slot=0,force_level=0,frame=0;
 logic capture=0;
 logic signed[63:0] engine_frame;
 always @(posedge clk)if(rst_n)begin
  if(dut.state==dut.S_RUN_V && dut.era_yv && dut.erb_yv && int'(dut.g)==(slot%8))
   engine_frame<=slot<8?dut.era_y:dut.erb_y;
  if(capture && yv)begin
   if($isunknown(y) || err)$fatal(1,"FAIL invalid output");
   $fdisplay(fd,"%0d %0d %0d %0d %0d %0d %0d %0d %0d",case_id,n_out,
    dut.x_q[slot],dut.emap_frame[slot],engine_frame,dut.mix_q,dut.body_y,y,dut.u_body.body_sat);
   n_out++;
  end
 end
 task automatic sample;
  integer before_out;
  before_out=n_out;
  @(negedge clk);tick=1;@(negedge clk);tick=0;
  repeat(1022)@(negedge clk);
  if(capture && n_out!=before_out+1)$fatal(1,"FAIL missing or repeated frame %0d/%0d",n_out,before_out);
 endtask
 task automatic run_case(input integer ident,selected,force_value,input bit all16);
  capture=0;rst_n=0;fmap='0;tick=0;slot=selected;case_id=ident;force_level=force_value;
  repeat(5)@(negedge clk);rst_n=1;
  wait(valid);repeat(10)@(negedge clk);
  // Retire the required post-load clearing frame before the actual strike.
  sample();sample();
  for(int s=0;s<16;s++)fmap.raw[s*8+:8]=(all16 || s==slot)?8'(force_value):8'd0;
  repeat(5)@(negedge clk);n_out=0;capture=1;
  repeat(4096)sample();
  capture=0;fmap='0;
  $display("PASS piano force case=%0d slot=%0d force=%0d all16=%0d raw_frames=%0d",ident,slot,force_value,all16,n_out);
 endtask
 initial begin
  fd=$fopen("raw_trace.txt","w");if(!fd)$fatal(1,"FAIL open raw trace");
  run_case(0,0,68,0);run_case(1,0,128,0);run_case(2,0,255,0);
  run_case(3,10,68,0);run_case(4,10,128,0);run_case(5,10,255,0);
  run_case(6,0,255,1);
  $fclose(fd);$display("PASS tb_piano_force_peak raw signed64 capture complete");$finish;
 end
 initial begin #1500000000;$fatal(1,"FAIL piano peak timeout");end
endmodule
