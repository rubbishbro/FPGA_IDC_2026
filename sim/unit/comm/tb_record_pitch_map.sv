`timescale 1ns/1ps
module tb_record_pitch_map;
 logic clk=0;always #5 clk=~clk;
 logic rst_n=0,reload=0,tick=0;
 logic [111:0] notes=0;
 logic [111:0] snapshot;
 wire valid,cs,sck,oe;wire [3:0] dout,dq;
 integer cycles=0;
 always @(negedge clk)begin cycles++;tick=(cycles%200==0);end
 record_pitch_probe dut(.clk(clk),.rst_n(rst_n),.run(1'b1),.reload(reload),.tick(tick),.notes(notes),
 .fmap(128'd0),.inst(router_pkg::INST_PIANO),.dq(dq),.snapshot(snapshot),.valid(valid),.cs(cs),.sck(sck),.oe(oe),.dout(dout));
 w25q64_read_model #(.N_MODES(64)) flash(.cs_n(cs),.sck(sck),.dq_o(dout),.dq_oe(oe),.blank(1'b0),.dq_i(dq));
 task automatic check_map(input logic [111:0] expected);
  @(posedge valid);@(negedge clk);
  if(snapshot!==expected)$fatal(1,"FAIL recorded map got=%h expected=%h",snapshot,expected);
 endtask
 initial begin
  for(integer i=0;i<16;i++)notes[i*7+:7]=7'(44+i);
  repeat(5)@(negedge clk);rst_n=1;
  check_map(notes);
  begin
   logic [111:0] old_map;old_map=notes;
   // Resource identity remains the loaded map until a real reload.
   for(integer i=0;i<16;i++)notes[i*7+:7]=7'(60+i);
   check_map(old_map);
  end
  reload=1;@(negedge clk);reload=0;
  // A previous frame may finish before the reload begins; wait for QSPI.
  @(negedge cs);@(posedge cs);
  check_map(notes);
  $display("PASS tb_record_pitch_map 16 distinct pitches, loaded identity and reload");$finish;
 end
 initial begin #100000000;$fatal(1,"FAIL record pitch map timeout");end
endmodule
