from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'python/modal_sim'))
from eng1_audition import Strike
out=ROOT/'build/excitation_single_check';out.mkdir(parents=True,exist_ok=True);rows=[];idx=0
for rise,pw in [(0,1),(1,2),(3,8),(5,32)]:
 for level in [64,129,204,255]:
  idx+=1;s=Strike('guitar',1);s.rise=rise;s.width=pw;s.gap=0;s.pulses=0
  for n in range(96):
   g=n<40 or 48<=n<80;t=n==48;c=n==70;x=int(s.step([level],[g],[t],[c])[0]);rows.append(f'{idx} {rise} {pw} {level} {int(g)} {int(t)} {int(c)} {x}\n')
(out/'vectors.txt').write_text(''.join(rows))
(out/'tb.sv').write_text('''`timescale 1ns/1ps
module tb_excitation_single;
logic clk=0,rst_n=0,clk_en=0,clear=0;always #5 clk=~clk;
logic[5:0] rise=0;logic[15:0] pw=1;logic[7:0] level=0;
logic[0:0] gate=0,trig=0,clr=0;logic signed[0:0][31:0] x;logic valid;
excitation_gen #(.SLOTS(1)) dut(.clk(clk),.rst_n(rst_n),.clk_en(clk_en),.sustain_mode(1'b0),.attenuate_by_8(1'b0),.slot_period(16'd0),.slot_pitch_delta(24'd0),.SHIFT(6'd16),.RISE_SH(rise),.PW_LEN(pw),.GAP_LEN(16'd0),.N_PULSE(3'd0),.clear(clear),.strike_level(level),.retrigger(trig),.slot_clear(clr),.note_on(gate),.xmap(x),.xmap_valid(valid));
integer f,rc,id,r,p,l,g,t,c,want,last=-1,count=0;
initial begin
f=$fopen("vectors.txt","r");
while(!$feof(f))begin
rc=$fscanf(f,"%d %d %d %d %d %d %d %d\\n",id,r,p,l,g,t,c,want);
if(rc!=8)$fatal(1,"FAIL parse");
if(id!=last)begin rst_n=0;clk_en=0;repeat(3)@(negedge clk);rst_n=1;@(negedge clk);last=id;end
rise=6'(r);pw=16'(p);level=8'(l);gate=1'(g);trig=1'(t);clr=1'(c);clk_en=1;
@(negedge clk);clk_en=0;
if($signed(x[0])!==want)$fatal(1,"FAIL shape id=%0d frame=%0d got=%0d want=%0d",id,count,x[0],want);
count++;repeat(2)@(negedge clk);
end
$display("PASS tb_excitation_single samples=%0d",count);$finish;end
endmodule
''')
