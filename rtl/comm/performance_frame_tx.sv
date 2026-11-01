`timescale 1ns/1ps
// Fixed v1 TYPE82, LEN24. Descriptor is immutable until the trailing END retires.
module performance_frame_tx(
 input logic clk,rst_n,flush,
 input logic s_valid, output logic s_ready,
 input logic [15:0] s_seq,input logic [191:0] s_payload,
 output logic m_valid,input logic m_ready,output logic [7:0] m_data,
 output logic m_last,output logic busy
);
 import comm_pkg::*;
 typedef enum logic [2:0]{IDLE,LEAD,BODY,ESC,TRAIL} state_t;
 state_t state;
 logic [191:0] payload;
 logic [15:0] seq,crc;
 logic [5:0] idx;
 logic [7:0] b;
 always_comb begin
  case(idx)
   0:b=1;1:b=8'h82;2:b=seq[7:0];3:b=seq[15:8];4:b=24;5:b=0;
   30:b=crc[7:0];31:b=crc[15:8];
   default:b=payload[(idx-6)*8 +:8];
  endcase
  m_valid=state!=IDLE;m_last=state==TRAIL;busy=state!=IDLE;
  s_ready=state==IDLE && !flush;
  case(state)
   LEAD,TRAIL:m_data=8'hc0;
   ESC:m_data=b == 8'hc0 ? 8'hdc : 8'hdd;
   default:m_data=(b==8'hc0||b==8'hdb)?8'hdb:b;
  endcase
 end
 function automatic [15:0] update_crc(input [15:0] c,input [7:0] d);
  reg [15:0] v;begin v=c^{d,8'h00};for(integer k=0;k<8;k++)v=v[15]?(v<<1)^16'h1021:v<<1;return v;end
 endfunction
 always_ff @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;payload<=0;seq<=0;idx<=0;crc<=16'hffff;end
  else if(flush)state<=IDLE;
  else case(state)
   IDLE:if(s_valid)begin payload<=s_payload;seq<=s_seq;idx<=0;crc<=16'hffff;state<=LEAD;end
   LEAD:if(m_ready)state<=BODY;
   BODY:if(m_ready)begin
    if(b==8'hc0||b==8'hdb)state<=ESC;
    else begin if(idx<30)crc<=update_crc(crc,b);if(idx==31)state<=TRAIL;else idx<=idx+1'b1;end
   end
   ESC:if(m_ready)begin if(idx<30)crc<=update_crc(crc,b);idx<=idx+1'b1;if(idx==31)state<=TRAIL;else state<=BODY;end
   TRAIL:if(m_ready)state<=IDLE;
   default:state<=IDLE;
  endcase
 end
endmodule
