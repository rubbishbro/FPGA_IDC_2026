`timescale 1ns/1ps
module tb_record_pitch_capture;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,tick=0,start=0,stop=0,snapshot=0;
reg [15:0] gate=0;reg [127:0] levels={16{8'd128}};reg [111:0] notes=0;
wire valid;wire [191:0] payload;integer events=0;
record_capture_probe dut(.clk(clk),.rst_n(rst_n),.tick(tick),.start(start),.stop(stop),.snapshot(snapshot),.gate(gate),.levels(levels),.notes(notes),.valid(valid),.ready(1'b1),.payload(payload));
always @(posedge clk)if(rst_n&&valid)begin
 $display("EVENT kind=%0d slot=%0d pitch=%0d velocity=%0d",payload[7:0],payload[31:24],payload[135:128],payload[143:136]);
 if(payload[7:0]==1 || payload[7:0]==2)begin
 if(payload[135:128]!==8'(44+payload[31:24]))$fatal(1,"FAIL pitch slot=%0d got=%0d",payload[31:24],payload[135:128]);
 events=events+1;
 end
end
initial begin
 for(integer i=0;i<16;i++)notes[i*7+:7]=7'(44+i);
 repeat(4)@(negedge clk);rst_n=1;repeat(5)@(negedge clk);
 start=1;@(negedge clk);start=0;tick=1;@(negedge clk);tick=0;repeat(10)@(negedge clk);
 gate=16'hffff;snapshot=1;@(negedge clk);snapshot=0;repeat(100)@(negedge clk);
 gate=0;notes=0;snapshot=1;@(negedge clk);snapshot=0;repeat(100)@(negedge clk);
 if(events!=32)$fatal(1,"FAIL event count %d",events);
 $display("PASS tb_record_pitch_capture 16 distinct pitches and owned note offs");$finish;
end
initial begin #100000;$fatal(1,"FAIL timeout");end
endmodule
