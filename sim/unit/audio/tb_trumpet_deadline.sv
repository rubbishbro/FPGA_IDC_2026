`timescale 1ns/1ps
// Real deployed 16-slot / 48-mode trumpet, 50MHz, stricter 1024-cycle frame.
module tb_trumpet_deadline;
import router_pkg::*;
logic clk=0,rst_n=0,tick=0,maintenance=0;
always #10 clk=~clk;
integer divider=0,cycles=0,last_tick=0,outputs=0,max_latency=0,nonzero=0;
logic monitor=0,seen=0;
integer trace_fd=0,trace_seq=0;
logic trace_pending=0;
longint slot_y[16];
logic [15:0] captured_events;
logic captured_pitch_bank;
logic frame_latched=0;
always @(posedge clk)if(rst_n)begin
 if(dut.event_capture)begin
  captured_events<=dut.note_pend | dut.note_ev;
  captured_pitch_bank<=dut.pitch_bank;frame_latched<=1;
 end else if(dut.part_commit && frame_latched)begin
  if(dut.note_f!==captured_events)$fatal(1,"events changed after frame capture");
  if(dut.pitch_bank!==captured_pitch_bank)$fatal(1,"pitch bank changed during excitation");
 end
 if(trace_fd!=0)begin
  if(dut.xw_run && valid)begin
   trace_seq++;trace_pending=1;
   $fwrite(trace_fd,"I 1 %0d %0d %0d %0d %0d %0d",trace_seq,
    dut.part_gate,dut.part_trigger,dut.part_clear,dut.pitch_slot_source,
    dut.note_f | dut.dead_f | dut.clear_f | {16{dut.init_zero}});
   for(int s=0;s<16;s++)$fwrite(trace_fd," %0d",dut.pending_notes[s*7 +:7]);
   for(int s=0;s<16;s++)$fwrite(trace_fd," %0d",dut.part_strike[s*8 +:8]);
   for(int s=0;s<16;s++)$fwrite(trace_fd," %0d",32'($signed(dut.part_pitch_delta[s*24 +:24])));
   for(int s=0;s<16;s++)$fwrite(trace_fd," %0d",$signed(dut.xmap[s]));
   for(int s=0;s<16;s++)$fwrite(trace_fd," %0d",dut.emap[s]);
   $fwrite(trace_fd,"\n");
  end
  if(dut.state==4'd4 && dut.era_yv && dut.erb_yv)begin
   slot_y[dut.g]=dut.era_y;slot_y[dut.g+8]=dut.erb_y;
  end
  if(trace_pending && yv)begin
   $fwrite(trace_fd,"O 1 %0d %0d %0d",trace_seq,y,dut.mix_q);
   for(int s=0;s<16;s++)$fwrite(trace_fd," %0d",slot_y[s]);
   $fwrite(trace_fd,"\n");trace_pending=0;
  end
 end
end
pad_driver_pkg::mat4x4 fmap='0;
logic [111:0] notes;
logic [511:0] offsets;
logic valid,done,err,yv,maintenance_done;
logic signed [63:0] y;
logic [3:0] dqi;
for(genvar s=0;s<16;s++)begin
assign notes[s*7 +:7]=7'(51+s);
assign offsets[s*32 +:32]=32'(s*4096);
end
voice_router #(.SLOTS(16),.N_MODES(64),.CLK_HZ(50_000_000),.SR_HZ(48000),
.EXTERNAL_SAMPLE_TICK(1),.MIDI_ENABLE(1),.LOAD_OFFSETS(1),.FLASH_NOTES(32),
.FLASH_BASE(32'h800000),.FLASH_BYTES(16_777_216)) dut(
.clk(clk),.rst_n(rst_n),.fmap(fmap),.inst(INST_TRUMPET),.reverb_preset(REVERB_HALL),
.reload(1'b0),.start(1'b1),.sample_tick(tick),.slot_note_map(notes),
.done(done),.load_err(err),.table_valid(valid),.y_valid(yv),.y_data(y),.qspi_dq_i(dqi),
.midi_select(1'b0),.midi_valid(1'b0),.midi_gate('0),.midi_retrigger('0),.midi_hard_clear('0),.midi_velocity('0),
.maintenance_clear(maintenance),.maintenance_done(maintenance_done),.map_reload(1'b0),.load_offsets(offsets),
.ns_rd_en(1'b0),.ns_rd_addr('0),.ns_rd_sel(1'b0));
w25q64_read_model #(.N_MODES(64),.MEM_FILE("resources.mem"),.MEM_BYTES(1576960),
.RESOURCE_BASE(32'h800000),.FLASH_BYTES(16_777_216),.FORBID_PROGRAM_READ(1)) flash(
.cs_n(dut.qspi_cs_n),.sck(dut.qspi_sck),.dq_o(dut.qspi_dq_o),.dq_oe(dut.qspi_dq_oe),.blank(1'b0),.dq_i(dqi));
always @(posedge clk)begin
cycles++;
if(!rst_n)begin divider<=0;tick<=0;end
else begin
 tick<=divider==1023;
 if(divider==1023)divider<=0;else divider<=divider+1;
 if(tick)begin
  if(monitor && outputs>8 && !seen)$fatal(1,"frame missed at 1024 clocks");
  last_tick=cycles;seen=0;
 end
 if(yv && monitor)begin
  if(seen)$fatal(1,"duplicate output in one frame");
  seen=1;outputs++;
  if(cycles-last_tick>=1024)$fatal(1,"audio deadline exceeded");
  if(cycles-last_tick>max_latency)max_latency=cycles-last_tick;
  if(y!=0)nonzero++;
 end
 if(err)$fatal(1,"resource load error");
end
end
initial begin
repeat(8)@(negedge clk);rst_n=1;
wait(valid && done);@(negedge clk);trace_fd=$fopen("trumpet_trace.txt","w");repeat(8)@(posedge tick);
for(integer s=0;s<16;s++)fmap.raw[s*8 +:8]=8'(180+s*3);
repeat(16)@(posedge tick);@(negedge clk);monitor=1;
wait(outputs>=128);
// A gate edge arriving while the TDM job is running belongs to the next frame.
@(posedge tick);repeat(30)@(negedge clk);fmap.raw[7*8 +:8]=0;
repeat(2)@(posedge tick);repeat(30)@(negedge clk);fmap.raw[7*8 +:8]=201;
wait(outputs>=256);
if(dut.part_gate!==16'hffff)$fatal(1,"not all16 voices active");
for(integer s=0;s<16;s++)fmap.raw[s*8 +:8]=8'(240-s*3);
wait(outputs>=512);
@(negedge clk);monitor=0;maintenance=1;
wait(maintenance_done);repeat(2)@(negedge clk);
if(dut.voice_idle!==16'hffff)$fatal(1,"maintenance not retired");
maintenance=0;fmap='0;repeat(8)@(posedge tick);
for(integer s=0;s<16;s++)fmap.raw[s*8 +:8]=200;
repeat(16)@(posedge tick);@(negedge clk);seen=1;monitor=1;
wait(outputs>=640);
@(negedge clk);$fclose(trace_fd);trace_fd=0;
if(nonzero<512)$fatal(1,"no audible output");
$display("PASS tb_trumpet_deadline voices=16 outputs=%d max_latency=%d frame_budget=1024 50MHz realFlash HALL pressure_change maintenance_restart",outputs,max_latency);
$finish;
end
initial begin #500000000;$fatal(1,"watchdog outputs=%d state=%d",outputs,dut.state);end
endmodule
