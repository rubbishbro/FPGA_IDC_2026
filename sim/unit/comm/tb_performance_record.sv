`timescale 1ns/1ps
module tb_performance_record;
 logic clk=0;always #5 clk=~clk;
 logic rst_n=0,tick=0,start_req=0,stop_req=0,abort_capture=0,eligible=1,snapshot=0;
 logic [3:0] gate=0;
 logic [31:0] levels=32'hff804002;
 logic [27:0] notes={7'd67,7'd64,7'd62,7'd60};
 logic active,draining,completed,failed,pvalid,pready;
 logic [191:0] payload;
 logic [15:0] seq;
 logic txvalid,txready=0;logic [7:0] txdata;
 logic reply_valid=0,reply_ready;
 performance_capture #(.SLOTS(4),.DEPTH(8),.MAX_FRAMES(100)) capture(
  .clk(clk),.rst_n(rst_n),.frame_tick(tick),.abort_capture(abort_capture),
  .start_req(start_req),.stop_req(stop_req),.request_id(32'hc0dbc0db),.eligible(eligible),.channel(4'd1),
  .snapshot_valid(snapshot),.snapshot_gate(gate),.snapshot_level(levels),.snapshot_notes(notes),
  .active(active),.draining(draining),.completed(completed),.failed(failed),
  .out_valid(pvalid),.out_ready(pready),.out_payload(payload),.out_seq(seq));
 transport_link link(.clk(clk),.rst_n(rst_n),.flush(abort_capture),.pin(1'b0),
  .rx_valid(1'b0),.rx_ready(),.rx_data(8'd0),.tx_valid(txvalid),.tx_ready(txready),.tx_data(txdata),
  .frame_valid(),.frame_ready(1'b1),.frame_data(),.frame_type(),.frame_seq(),.frame_payload_len(),
  .frame_first(),.frame_last(),.frame_available(),.protocol_errors(),
  .reply_valid(reply_valid),.reply_ready(reply_ready),.reply_seq(16'hdbc0),.reply_command(8'h13),.reply_result(8'd0),.tx_busy(),
  .perf_valid(pvalid),.perf_ready(pready),.perf_seq(seq),.perf_payload(payload));
 integer cycles=0,n=0,frames=0,event_count=0,starts=0,ends=0,replies=0;
 integer on_count=0,off_count=0;logic escaping=0;reg [7:0] body[0:63];reg [15:0] crc;
 reg [31:0] last_stamp=0,current_stamp;reg [31:0] ord=0;
 function automatic [15:0] crcbyte(input [15:0] c,input [7:0] b);
  reg[15:0]v;begin v=c^{b,8'd0};for(integer k=0;k<8;k++)v=v[15]?(v<<1)^16'h1021:v<<1;return v;end
 endfunction
 task checkframe;
  begin
   crc=16'hffff;for(integer i=0;i<n-2;i++)crc=crcbyte(crc,body[i]);
   if(crc!={body[n-1],body[n-2]})$fatal(1,"FAIL CRC");
   if(body[0]!=1 || n!==(8+body[4]))$fatal(1,"FAIL length/header");
   frames++;
   if(body[1]==8'h80)begin replies++;if(n!=11)$fatal(1,"FAIL reply");end
   else if(body[1]==8'h82)begin
    if(n!=32 || {body[13],body[12],body[11],body[10]}!=32'hc0dbc0db)$fatal(1,"FAIL stream identity");
    if({body[17],body[16],body[15],body[14]}!=ord)$fatal(1,"FAIL ordinal");ord++;
    current_stamp={body[21],body[20],body[19],body[18]};
    if(current_stamp<last_stamp)$fatal(1,"FAIL timestamp order");last_stamp=current_stamp;
    case(body[6])
     0:begin starts++;if({body[25],body[24],body[23],body[22]}!=12500000)$fatal(1,"FAIL rate");end
     1:begin on_count++;event_count++;if(body[22]!=(body[9]==0?60:62))$fatal(1,"FAIL on pitch");end
     2:begin off_count++;event_count++;if(body[22]!=60)$fatal(1,"FAIL original off pitch");end
     3:begin ends++;if(body[7]!=0)$fatal(1,"FAIL unexpected drop");end
     default:$fatal(1,"FAIL kind");
    endcase
   end else $fatal(1,"FAIL interleaved frame");
  end
 endtask
 always @(posedge clk)begin
  cycles<=cycles+1;txready<=cycles%3!=0;
  if(rst_n&&txvalid&&txready)begin
   if(txdata==8'hc0)begin if(escaping)$fatal(1,"FAIL escape terminator");if(n>0)checkframe();n=0;end
   else if(escaping)begin if(txdata!=8'hdc&&txdata!=8'hdd)$fatal(1,"FAIL escape");body[n]=txdata == 8'hdc ? 8'hc0 : 8'hdb;n++;escaping=0;end
   else if(txdata==8'hdb)escaping=1;
   else begin body[n]=txdata;n++;if(n>40)$fatal(1,"FAIL frame overflow");end
  end
 end
 task pulse_frame(input [3:0] g);
  @(negedge clk);tick=1;@(negedge clk);tick=0;gate=g;snapshot=1;
  @(negedge clk);snapshot=0;repeat(20)@(negedge clk);
 endtask
 initial begin
  repeat(4)@(negedge clk);rst_n=1;@(negedge clk);start_req=1;@(negedge clk);start_req=0;
  repeat(5)@(negedge clk);tick=1;@(negedge clk);tick=0;repeat(5)@(negedge clk);
  pulse_frame(4'b0011); // same timestamp for two keys
  // Changing live resource table must not change OFF identity for held note.
  notes[6:0]=72;pulse_frame(4'b0010);
  @(negedge clk);stop_req=1;@(negedge clk);stop_req=0;tick=1;@(negedge clk);tick=0;
  wait(completed);@(negedge clk);reply_valid=1;wait(reply_ready);@(negedge clk);reply_valid=0;
  wait(replies==1);repeat(5)@(negedge clk);
  if(starts!=1||ends!=1||on_count!=2||off_count!=1||event_count!=3)$fatal(1,"FAIL event counts %d %d %d %d",starts,ends,on_count,off_count);
  // Explicit session cancellation removes queued take and stops capture.
  start_req=1;@(negedge clk);start_req=0;repeat(4)@(negedge clk);abort_capture=1;@(negedge clk);abort_capture=0;
  if(active||draining||!failed)$fatal(1,"FAIL abort");
  $display("PASS tb_performance_record frames=%0d notes=%0d",frames,event_count);$finish;
 end
 initial begin #1000000;$fatal(1,"FAIL timeout");end
endmodule
