#!/usr/bin/env python3
"""Check tuned RT60 constants and real RTL impulse/random responses and UI IDs."""
from pathlib import Path
import sys,os,re,shutil,subprocess,json,math,random
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'python/modal_sim'))
import router_eng1 as R

def main():
 out=ROOT/'build/reverb_tuning';out.mkdir(parents=True,exist_ok=True);work=out/'work';cases=[];rng=random.Random(20261103);results={}
 hall=R.REVERB_PRESETS['HALL'];assert (hall.lengths,hall.feedback,hall.weight,hall.dry,hall.wet)==((1214,1293,1390,1476),(120795955,)*4,(33554432,)*4,93952410,67108864)
 for ident,name in enumerate(['NONE','HALL','BATHROOM','CHAMBER']):
  model=R.ReverbRouter(name);p=model.params
  times=[-3*n/(48000*math.log10(g/(1<<27))) for n,g in zip(p.lengths,p.feedback)] if ident else []
  if name in ('CHAMBER','BATHROOM'):assert max(abs(t-({'CHAMBER':.6,'BATHROOM':1.1}[name])) for t in times)<1e-6
  xs=[0]*2048+[1<<40]+[0]*8192+[rng.randrange(-(1<<30),1<<30) for _ in range(256)]
  (out/(name+'.txt')).write_text(''.join(f'{x} {model.step(x)}\n' for x in xs))
  results[name]=dict(samples=len(xs),rt60_s=times)
  cases.append(f'''preset=router_pkg::REVERB_{name};clear=1;@(negedge clk);clear=0;repeat(3)@(negedge clk);
 fd=$fopen("{name}.txt","r");while(!$feof(fd))begin
 rc=$fscanf(fd,"%d %d\\n",sx,expected);if(rc!=2)$fatal(1,"vector read");
 x=sx;iv=1;@(negedge clk);iv=0;wait(ov);#1;
 if(y!==expected)$fatal(1,"FAIL {name} sample=%0d y=%0d expected=%0d",count,y,expected);
 count++;repeat(3)@(negedge clk);end $fclose(fd);''')
 (out/'tb.sv').write_text('''`timescale 1ns/1ps
 module tb_reverb_tuning;
 logic clk=0,rst_n=0,iv=0,ov,clear=0;always #5 clk=~clk;
 logic signed[63:0] x=0,y,sx,expected;integer fd,rc,count=0;
 router_pkg::reverb_preset preset=router_pkg::REVERB_NONE;
 reverb_router dut(.clk(clk),.rst_n(rst_n),.clear_req(clear),.preset(preset),.in_valid(iv),.x(x),.out_valid(ov),.y(y));
 initial begin repeat(4)@(negedge clk);rst_n=1;
'''+ '\n'.join(cases)+'''\n$display("PASS tb_reverb_tuning samples=%0d",count);$finish;end
 initial begin #100000000;$fatal(1,"FAIL timeout");end
 endmodule
''')
 ini=Path.home()/'gowin/simlib_questa/modelsim.ini';(out/'modelsim.ini').write_text(re.sub(r'^work\s*=.*$',f'work = {work}',ini.read_text(),flags=re.M));env=os.environ.copy();env['QSIM_INI']=env['MODELSIM']=str(out/'modelsim.ini')
 def run(name,tool,args):
  r=subprocess.run([shutil.which(tool) or str(Path.home()/'.local/bin'/tool),*map(str,args)],cwd=out,env=env,capture_output=True,text=True,timeout=180);text=r.stdout+r.stderr;(out/(name+'.log')).write_text(text)
  if r.returncode or re.search(r'\*\* (?:Error|Fatal)|\bFAIL\b',text):raise RuntimeError(text[-3500:])
  return text
 sources=[ROOT/s for s in (ROOT/'sim/ui_sources.f').read_text().splitlines() if s and not s.startswith('#')]
 sources += [ROOT/s for s in ['rtl/router/parts/comb_reverb.sv','rtl/router/routers/reverb_router.sv','sim/unit/audio/tb_reverb_presets.sv']]+[out/'tb.sv']
 run('vlib','vlib',[work]);run('compile','vlog',['-sv','-work',work,*sources])
 for top in ['tb_reverb_presets','tb_reverb_tuning']:
  text=run(top,'vsim',['-c','-lib',work,top,'-do','run -all; quit -f']);assert 'PASS '+top in text
  print('\n'.join(s.lstrip('# ') for s in text.splitlines() if 'PASS ' in s),flush=True)
 (out/'results.json').write_text(json.dumps(dict(passed=True,presets=results),indent=2))
if __name__=='__main__':main()
