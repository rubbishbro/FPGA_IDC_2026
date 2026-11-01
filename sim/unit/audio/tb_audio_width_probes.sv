`timescale 1ns/1ps
module tb_body_width_audit;
 logic clk=0,rst_n=0,clear=0,iv=0,ready,ov;
 always #5 clk=~clk;
 logic signed[63:0] x,y,expected;
 logic signed[24:0][31:0] co;
 body_biquad dut(.clk(clk),.rst_n(rst_n),.clear(clear),.in_valid(iv),.in_ready(ready),.in_sum(x),
  .coef_q(co),.out_valid(ov),.out_sum(y),.out_sat(),.sat_count());
 integer fd,rc,value,count=0;
 initial begin
  fd=$fopen("body_cases.txt","r");if(!fd)$fatal(1,"FAIL missing body vectors");
  repeat(4)@(negedge clk);rst_n=1;
  for(int t=0;t<4;t++)begin
   for(int k=0;k<25;k++)begin rc=$fscanf(fd,"%d",value);co[k]=value;end
   clear=1;@(negedge clk);clear=0;wait(ready);
   for(int n=0;n<128;n++)begin
    rc=$fscanf(fd,"%d %d",x,expected);if(rc!=2)$fatal(1,"FAIL body row");
    @(negedge clk);iv=1;@(negedge clk);iv=0;
    wait(ov);@(negedge clk);
    if(y!==expected)$fatal(1,"FAIL body table=%0d frame=%0d got=%0d expected=%0d",t,n,y,expected);
    count++;wait(ready);
   end
  end
  $display("PASS body wide audit frames=%0d identity/gain8/piano/guitar signed64 extremes",count);$finish;
 end
 initial begin #3000000;$fatal(1,"FAIL body timeout");end
endmodule

module tb_reverb_width_probes;
 import router_pkg::*;
 logic clk=0,rst_n=0,iv=0,ov,cv=0,cov;
 always #5 clk=~clk;
 logic signed[63:0] x=0,y,cx=0,cy;
 reverb_router rev(.clk(clk),.rst_n(rst_n),.clear_req(1'b0),.preset(REVERB_NONE),.in_valid(iv),.x(x),.out_valid(ov),.y(y));
 comb_reverb #(.N(8)) comb(.clk(clk),.rst_n(rst_n),.clr(1'b0),.n1(4'd2),.n2(4'd3),.n3(4'd4),.n4(4'd5),
  .g1(32'd67108864),.g2(32'd67108864),.g3(32'd67108864),.g4(32'd67108864),
  .w1c(32'd33554432),.w2c(32'd33554432),.w3c(32'd33554432),.w4c(32'd33554432),
  .in_valid(cv),.in_data(cx),.out_valid(cov),.wet(cy));
 integer fd;
 function automatic logic signed[63:0] stimulus(input integer phase,n);
  if(n<12)return 0;
  if(phase==7)return {$urandom,$urandom};
  if(n!=12)return 0;
  case(phase)
   0:return 64'sd1<<24;1:return 64'sd1<<38;2:return 64'sd1<<44;
   3:return -(64'sd1<<38);4:return -(64'sd1<<44);
   5:return 64'sh7fffffffffffffff;default:return 64'sh8000000000000000;
  endcase
 endfunction
 task automatic reset_all;
  rst_n=0;iv=0;cv=0;repeat(4)@(negedge clk);rst_n=1;repeat(3)@(negedge clk);
 endtask
 task automatic comb_sample(input integer phase,n,input logic signed[63:0] value);
  cx=value;cv=1;@(negedge clk);cv=0;wait(cov);@(negedge clk);
  $fdisplay(fd,"COMB %0d %0d %0d %0d",phase,n,value,cy);repeat(10)@(negedge clk);
 endtask
 initial begin
  fd=$fopen("reverb_observed.txt","w");reset_all();
  for(int p=24;p<=62;p++)if(p==24 || p==36 || p==40 || p==41 || p==42 || p==62)begin
   for(int sign=0;sign<2;sign++)begin
    x=sign?-(64'sd1<<p):(64'sd1<<p);iv=1;@(negedge clk);iv=0;
    wait(ov);@(negedge clk);$fdisplay(fd,"NONE %0d %0d",x,y);repeat(10)@(negedge clk);
   end
  end
  for(int phase=0;phase<8;phase++)begin
   reset_all();
   for(int n=0;n<128;n++)comb_sample(phase,n,stimulus(phase,n));
  end
  force comb.t1=69'sd4611686018427387904;force comb.t2=69'sd4611686018427387904;force comb.t3=69'sd0;force comb.t4=69'sd0;
  #1;$fdisplay(fd,"SUM 0 %0d",comb.sum_sat);
  force comb.t1=-69'sd4611686018427387905;force comb.t2=-69'sd4611686018427387904;
  #1;$fdisplay(fd,"SUM 1 %0d",comb.sum_sat);
  $fclose(fd);$display("DONE reverb width probes captured; compare against unbounded integer oracle");$finish;
 end
 initial begin #1000000;$fatal(1,"FAIL probe timeout");end
endmodule
