`timescale 1ns/1ps
// Observe committed PAD snapshots only. A 16-slot scan preserves simultaneous timestamps.
// Never back-pressure the synthesis path. Overflow closes a flagged, incomplete take.
module performance_capture #(
 parameter int SLOTS=16,DEPTH=128,MAX_FRAMES=29296875,
 parameter int RATE_NUM=12500000,RATE_DEN=256
)(
 input logic clk,rst_n,frame_tick,abort_capture,
 input logic start_req,stop_req,input logic [31:0] request_id,
 input logic eligible,input logic [3:0] channel,
 input logic snapshot_valid,input logic [SLOTS-1:0] snapshot_gate,
 input logic [SLOTS*8-1:0] snapshot_level,input logic [SLOTS*7-1:0] snapshot_notes,
 output logic active,draining,completed,failed,
 output logic out_valid,input logic out_ready,output logic [191:0] out_payload,
 output logic [15:0] out_seq
);
 logic [$clog2(DEPTH+1)-1:0] count;
 logic queue_ready;
 logic [31:0] id,ticks,ordinal,scan_tick;
 logic [3:0] ch;
 logic [SLOTS-1:0] prev_gate,scan_gate;
 logic [SLOTS*8-1:0] levels;
 logic [SLOTS*7-1:0] notes,owned_notes;
 logic scanning,started,end_queued,start_pending,stop_pending;
 logic [31:0] pending_id;logic [3:0] pending_channel;
 logic [$clog2(SLOTS)-1:0] slot;
 wire pop=out_valid&&out_ready&&!abort_capture;
 logic push;
 logic [111:0] entry,queue_data;
 wire change=scanning && scan_gate[slot]!=prev_gate[slot];
 wire [7:0] level=levels[slot*8 +:8];
 // For every 8-bit level, floor((level*127+127)/255) equals level>>1.
 // Preserve the nonzero MIDI floor without a divider or multiplier in this path.
 wire [7:0] velocity=level[7:1]==0 ? 8'd1 : {1'b0,level[7:1]};
 wire [6:0] pitch=scan_gate[slot]?notes[slot*7 +:7]:owned_notes[slot*7 +:7];
 // FIFO stores only variable event fields. ID/channel/rate belong to the take,
 // and are stable until every descriptor has been accepted by the TX encoder.
 function automatic [111:0] packet(input [7:0] kind,input [7:0] flags,input [7:0] key_slot,
 input [31:0] stamp,input [31:0] a,input [31:0] b);
  return {ordinal,stamp,8'd0,kind,flags,key_slot,a[15:8],a[7:0]};
 endfunction
 wire [7:0] read_kind=queue_data[39:32];
 wire [31:0] read_ordinal=queue_data[111:80];
 wire [31:0] read_a=read_kind==0 ? RATE_NUM : read_kind==3 ? 32'd0 : {16'd0,queue_data[15:0]};
 wire [31:0] read_b=read_kind==0 ? RATE_DEN : read_kind==3 ? read_ordinal-1'b1 : 32'd0;
 assign out_payload={read_b,read_a,queue_data[79:48],read_ordinal,id,queue_data[23:16],4'd0,ch,queue_data[31:24],read_kind};
 always_comb begin
  out_seq=out_payload[79:64];
  push=0;entry=0;
  if(active&&!started)begin push=1;entry=packet(0,0,0,0,RATE_NUM,RATE_DEN);end
  else if(change)begin
   push=1;entry=packet(scan_gate[slot]?1:2,0,8'(slot),scan_tick,{16'd0,velocity,1'b0,pitch},0);
  end else if(draining&&!scanning&&!end_queued)begin
   push=1;entry=packet(3,{7'd0,failed},0,ticks,0,ordinal-1'b1);
  end
 end
 comm_fifo #(.WIDTH(112),.DEPTH(DEPTH)) u_events(
  .clk(clk),.rst_n(rst_n),.flush(abort_capture || (start_pending && frame_tick)),
  .s_valid(push),.s_ready(queue_ready),.s_data(entry),
  .m_valid(out_valid),.m_ready(out_ready),.m_data(queue_data),.level(count));
 always_ff @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   id<=0;ticks<=0;ordinal<=0;ch<=0;
   active<=0;draining<=0;completed<=0;failed<=0;prev_gate<=0;scan_gate<=0;
   levels<=0;notes<=0;owned_notes<=0;scanning<=0;slot<=0;started<=0;end_queued<=0;scan_tick<=0;start_pending<=0;stop_pending<=0;pending_id<=0;pending_channel<=0;
  end else if(abort_capture)begin
   active<=0;draining<=0;completed<=1;failed<=1;scanning<=0;start_pending<=0;stop_pending<=0;
  end else if(start_pending && frame_tick)begin
   start_pending<=0;stop_pending<=0;
   id<=pending_id;ticks<=0;ordinal<=0;ch<=pending_channel;active<=1;draining<=0;completed<=0;failed<=0;
   prev_gate<=0;scanning<=0;started<=0;end_queued<=0;
  end else begin
   if(start_req&&!active&&!draining&&!start_pending)begin start_pending<=1;pending_id<=request_id;pending_channel<=channel;completed<=0;end
   if(stop_req)stop_pending<=1;
   if(active&&frame_tick)ticks<=ticks+1'b1;
   if(active&&started&&(((stop_pending||stop_req)&&frame_tick)||!eligible||channel!=ch||ticks>=MAX_FRAMES))begin active<=0;draining<=1;if(!eligible||channel!=ch)failed<=1;end
   if(active&&started&&snapshot_valid&&!scanning&&!stop_req&&!stop_pending)begin
    scanning<=1;slot<=0;scan_gate<=snapshot_gate;levels<=snapshot_level;notes<=snapshot_notes;scan_tick<=ticks;
   end
   if(scanning)begin
    if(slot==SLOTS-1)scanning<=0;else slot<=slot+1;
    prev_gate[slot]<=scan_gate[slot];
    if(scan_gate[slot])owned_notes[slot*7 +:7]<=notes[slot*7 +:7];
   end
   if(snapshot_valid&&scanning)begin failed<=1;active<=0;draining<=1;end
   if(pop)begin
    if(out_payload[7:0]==3)begin draining<=0;completed<=1;end
   end
   if(push&&queue_ready)begin
    ordinal<=ordinal+1'b1;
    if(!started)started<=1;
    if(entry[39:32]==3)end_queued<=1;
   end else if(push&&!queue_ready&&entry[39:32]!=3)begin
    active<=0;draining<=1;failed<=1;
   end
  end
 end
endmodule
