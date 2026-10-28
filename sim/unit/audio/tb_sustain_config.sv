`timescale 1ns/1ps
module tb_sustain_config;
 import router_pkg::*;
 logic clk=0,rst_n=0,reload=0;
 always #5 clk=~clk;
 instrument_e inst=INST_FLUTE;
 pad_driver_pkg::mat4x4 fmap='0;
 logic [4*7-1:0] notes;
 logic [127:0] offsets,saved_offsets;
 logic valid,error,done,ready,yv,complete,cs,sck,oe;
 logic [3:0] dqo,dqi,idle;
 integer loads=0,completions=0;
 voice_router #(.SLOTS(4),.N_MODES(64),.LOAD_OFFSETS(1),.FLASH_NOTES(32)) dut(
  .clk(clk),.rst_n(rst_n),.start(1'b1),.sample_tick(1'b0),.slot_note_map(notes),.inst(inst),.fmap(fmap),.reverb_preset(REVERB_NONE),
  .reload(reload),.done(done),.ready(ready),.load_err(error),.table_valid(valid),.load_complete(complete),.voice_idle(idle),.y_valid(yv),.y_data(),
  .qspi_cs_n(cs),.qspi_sck(sck),.qspi_dq_o(dqo),.qspi_dq_oe(oe),.qspi_dq_i(dqi),
  .midi_select(1'b0),.midi_valid(1'b0),.midi_ready(),.midi_gate('0),.midi_retrigger('0),.midi_hard_clear('0),.midi_velocity('0),
  .maintenance_clear(1'b0),.maintenance_done(),.midi_inflight(),.map_reload(1'b0),.load_offsets(offsets),
  .ns_rd_en(1'b0),.ns_rd_addr('0),.ns_rd_sel(1'b0),.ns_rd_data(),.ns_rd_valid());
 w25q64_read_model #(.N_MODES(64),.ABC_COEFF(1)) flash(.cs_n(cs),.sck(sck),.dq_o(dqo),.dq_oe(oe),.blank(1'b0),.dq_i(dqi));
 always @(posedge clk)if(rst_n)begin
  if(dut.ld_start)loads++;
  if(complete)completions++;
 end
 task automatic pulse;
  @(negedge clk);reload=1;@(negedge clk);reload=0;
 endtask
 integer old_period,before_loads;
 initial begin
  for(int i=0;i<4;i++)offsets[i*32 +:32]=i*4096;
  saved_offsets=offsets;
  notes={4{7'd60}};repeat(5)@(negedge clk);rst_n=1;
  wait(valid);wait(yv);@(negedge clk);old_period=dut.active_play[0].period;
  fmap.flat_d[0].val=250;repeat(5000)@(negedge clk);
  inst=INST_TRUMPET;notes={4{7'd69}};
  repeat(10000)@(negedge clk);
  if(ready || dut.inst_prev!=INST_FLUTE || dut.active_play[0].period!=old_period)$fatal(1,"FAIL pending resource profile changed old sound");
  fmap='0;wait(dut.state==dut.S_CFG);@(negedge clk);notes={4{7'd72}};
  for(int i=0;i<4;i++)offsets[i*32 +:32]=(i+16)*4096;
  wait(valid && dut.inst_prev==INST_TRUMPET);wait(yv);@(negedge clk);
  if(dut.active_play[0].period!=109 || dut.u_ld.offsets_r!=saved_offsets)$fatal(1,"FAIL load-time map was not latched");
  before_loads=loads;notes='x;inst=INST_FLUTE;
  wait(error && done);@(negedge clk);
  if(valid || loads!=before_loads || dut.inst_prev!=INST_TRUMPET || dut.active_play[0].period!=109)
   $fatal(1,"FAIL invalid profile committed or started Flash");
  notes={4{7'd72}};pulse();wait(valid && dut.inst_prev==INST_FLUTE);wait(yv);
  if(error || dut.active_play[0].period!=92)$fatal(1,"FAIL explicit profile recovery");
  if(completions!=4 || loads!=3)$fatal(1,"FAIL profile failure completion contract %d %d",completions,loads);
  $display("PASS tb_sustain_config load/profile atomicity, immutable map, bounded invalid completion and recovery");$finish;
 end
 initial begin #20000000;$fatal(1,"FAIL profile watchdog state=%d",dut.state);end
endmodule
