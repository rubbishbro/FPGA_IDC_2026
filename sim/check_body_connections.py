#!/usr/bin/env python3
"""Verify measured body quantization/stability, GM lookup, and actual RTL samples."""
from pathlib import Path
import sys,os,re,shutil,subprocess,json
import numpy as np
from scipy.signal import sosfreqz
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'python/modal_sim'))
from params import Patch
import router_eng1 as R
from drum_coefficients import DRUM_INDEX_BY_GM

def main():
 out=ROOT/'build/body_connections';out.mkdir(parents=True,exist_ok=True)
 cases=[];report={};rng=np.random.default_rng(20261103)
 for name in ('banjo','mandolin'):
  sos=Patch(name).sos;expected=np.floor(sos[:,[0,1,2,4,5]]/sos[:,3,None]*2**27+.5).astype(np.int64).tolist()+[[2**27,0,0,0,0]]
  rows=R.body_coeffs(name);assert rows==expected
  quant=np.array([[*r[:3],2**27,*r[3:]] for r in rows],dtype=float)/2**27
  radius=max(abs(p) for sec in quant for p in np.roots(sec[3:]));assert radius<1
  w=np.linspace(0,np.pi,16384);_,a=sosfreqz(sos,worN=w);_,b=sosfreqz(quant,worN=w)
  error=float(np.max(np.abs(20*np.log10(np.maximum(abs(a),1e-15)/np.maximum(abs(b),1e-15)))))
  assert error<.001
  model=R.BodyFilter(instrument=name)
  samples=[2**24]+[0]*255+list(map(int,rng.integers(-2**28,2**28,256)))+[0]*512
  vectors=[]
  for x in samples:
   y,mask,sat=model.step(x);assert not sat;vectors.append((x,y))
  (out/(name+'.txt')).write_text(''.join(f'{x} {y}\n' for x,y in vectors))
  report[name]=dict(samples=len(samples),max_pole_radius=radius,max_response_error_db=error,saturations=model.sat_total)
  cases.append(f'''inst=router_pkg::INST_{name.upper()}; repeat(4) @(negedge clk); wait(ready); fd=$fopen("{name}.txt","r");
 while (!$feof(fd)) begin
 rc=$fscanf(fd,"%d %d\\n",sx,expected); if(rc!=2) $fatal(1,"vector read");
 @(negedge clk); wait(ready); x=sx; valid=1;
 @(negedge clk); valid=0; wait(ov); #1;
 if(y!==expected) $fatal(1,"{name} mismatch got=%0d expected=%0d",y,expected);
 count=count+1; @(negedge clk);
 end $fclose(fd);''')
 gm='\n'.join(f"if(router_pkg::drum_index_of(8'd{n})!==3'd{DRUM_INDEX_BY_GM.get(n,7)}) $fatal(1,\"GM {n}\");" for n in range(256))
 (out/'tb.sv').write_text('''`timescale 1ns/1ps
module tb_body_connections;
 logic clk=0;always #5 clk=~clk;
 logic rst_n=0,valid=0,ready,ov,busy;logic signed[63:0] x=0,y,sx,expected;
 router_pkg::instrument_e inst=router_pkg::INST_NONE;integer fd,rc,count=0;
 body_router dut(.clk(clk),.rst_n(rst_n),.clear_req(1'b0),.clear_busy(busy),.inst(inst),.in_valid(valid),.in_ready(ready),.x(x),.out_valid(ov),.y(y));
 initial begin #10000000;$fatal(1,"timeout");end
 initial begin
'''+gm+'''\nrepeat(4) @(negedge clk);rst_n=1;\n'''+ '\n'.join(cases)+'''\n$display("PASS tb_body_connections samples=%0d GM=256",count);$finish;end
endmodule
''')
 ini=Path(os.environ.get('QSIM_INI',str(Path.home()/'gowin/simlib_questa/modelsim.ini')));work=out/'work'
 (out/'modelsim.ini').write_text(re.sub(r'^work\s*=.*$',f'work = {work}',ini.read_text(),flags=re.M));env=os.environ.copy();env['QSIM_INI']=env['MODELSIM']=str(out/'modelsim.ini')
 def run(name,tool,args):
  r=subprocess.run([shutil.which(tool) or str(Path.home()/'.local/bin'/tool),*map(str,args)],cwd=out,env=env,capture_output=True,text=True,timeout=90);text=r.stdout+r.stderr;(out/(name+'.log')).write_text(text)
  if r.returncode or re.search(r'\*\* (?:Error|Fatal)|\bFAIL\b',text):raise RuntimeError(text[-3500:])
  return text
 run('vlib','vlib',[work]);run('compile','vlog',['-sv','-work',work,ROOT/'rtl/router/pkg/router_pkg.sv',ROOT/'rtl/math/pkg/fxp_pkg.sv',ROOT/'rtl/router/parts/body_biquad.sv',ROOT/'rtl/router/routers/body_router.sv',out/'tb.sv'])
 text=run('run','vsim',['-c','-lib',work,'tb_body_connections','-do','run -all; quit -f']);assert 'PASS tb_body_connections samples=2048 GM=256' in text
 (out/'results.json').write_text(json.dumps(report,indent=2));print('PASS body connections: 2048 RTL samples, 256 GM inputs, measured SOS quantization/stability',report)
if __name__=='__main__':main()
