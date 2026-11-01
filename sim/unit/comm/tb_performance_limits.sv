`timescale 1ns/1ps
module tb_performance_limits;
 logic clk=0;always #5 clk=~clk;
 logic rst=0,tick=0,start=0,stop=0,abort_req=0,snapshot=0,eligible=1;
 logic [3:0] gate=0;logic active,draining,complete,failed,valid,ready=0;
 logic [191:0] payload;logic [15:0] seq;
 integer starts=0,ends=0,events=0;logic end_failed=0;
 performance_capture #(.SLOTS(4),.DEPTH(4),.MAX_FRAMES(12)) dut(
 .clk(clk),.rst_n(rst),.frame_tick(tick),.abort_capture(abort_req),.start_req(start),.stop_req(stop),.request_id(32'd7),
 .eligible(eligible),.channel(4'd1),.snapshot_valid(snapshot),.snapshot_gate(gate),.snapshot_level(32'hffffffff),
 .snapshot_notes({7'd67,7'd64,7'd62,7'd60}),.active(active),.draining(draining),.completed(complete),.failed(failed),
 .out_valid(valid),.out_ready(ready),.out_payload(payload),.out_seq(seq));
 always @(posedge clk)if(rst&&valid&&ready)case(payload[7:0])
 0:starts++;
 1,2:events++;
 3:begin ends++;end_failed=payload[8];end
 endcase
 task boundary;
  @(negedge clk);tick=1;@(negedge clk);tick=0;repeat(12)@(negedge clk);
 endtask
 task arm;
  @(negedge clk);start=1;@(negedge clk);start=0;
  repeat(3)@(negedge clk);if(active)$fatal(1,"FAIL START not frame aligned");
  boundary();if(!active)$fatal(1,"FAIL START never active");
 endtask
 initial begin
  repeat(3)@(negedge clk);rst=1;arm();
  @(negedge clk);gate=15;snapshot=1;@(negedge clk);snapshot=0;repeat(10)@(negedge clk);
  if(!failed||active)$fatal(1,"FAIL queue overflow not visible");
  ready=1;wait(complete);repeat(4)@(negedge clk);
  if(starts!=1||ends!=1||!end_failed||events!=3)$fatal(1,"FAIL overflow drain stats");
  // Empty take still has START/END and STOP must wait for a frame boundary.
  arm();@(negedge clk);stop=1;@(negedge clk);stop=0;
  repeat(3)@(negedge clk);if(!active)$fatal(1,"FAIL STOP not aligned");boundary();wait(complete);repeat(3)@(negedge clk);
  if(starts!=2||ends!=2||end_failed)$fatal(1,"FAIL empty take");
  arm();repeat(14)boundary();wait(complete);repeat(3)@(negedge clk);
  if(ends!=3||active)$fatal(1,"FAIL device autonomous limit");
  $display("PASS tb_performance_limits overflow_empty_frame_boundaries_autolimit");$finish;
 end
 initial begin #100000;$fatal(1,"FAIL timeout");end
endmodule
