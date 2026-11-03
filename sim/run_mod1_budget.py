#!/usr/bin/env python3
"""Sweep per-slot aftertouch cap on production router/engines with preloaded deployed resources.
Flash transport and physical timing are outside this scheduling experiment.
"""
from pathlib import Path
import argparse,hashlib,json,os,re,shutil,subprocess
ROOT=Path(__file__).resolve().parents[1]
def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--out',type=Path,default=ROOT/'build/mod1_budget')
 p.add_argument('--caps',type=int,nargs='+',default=[1,2,3,4,5,6,7,8,9,10,12,16,24,32,48])
 p.add_argument('--frames',type=int,default=320)
 p.add_argument('--real-flash',action='store_true',help='Also exercise real Flash loading and trumpet maintenance/restart')
 p.add_argument('--model-python',help='Python with NumPy for the real-Flash integer audio parity check')
 p.add_argument('--directory',type=Path,default=ROOT/'rtl/router/tools/performance')
 p.add_argument('--instruments',nargs='+',default=['violin','trumpet'])
 a=p.parse_args();out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
 ini=Path(os.environ.get('QSIM_INI',str(Path.home()/'gowin/simlib_questa/modelsim.ini')))
 work=out/'work';(out/'modelsim.ini').write_text(re.sub(r'^work\s*=.*$',f'work = {work}',ini.read_text(),flags=re.M))
 env=os.environ.copy();env['QSIM_INI']=env['MODELSIM']=str(out/'modelsim.ini')
 def run(name,tool,args):
  exe=shutil.which(tool) or str(Path.home()/'.local/bin'/tool)
  r=subprocess.run([exe,*map(str,args)],cwd=out,env=env,capture_output=True,text=True,timeout=180)
  s=r.stdout+r.stderr;(out/(name+'.log')).write_text(s)
  if r.returncode or re.search(r'\*\* (?:Error|Fatal)|\bFAIL\b',s):raise RuntimeError(s[-5000:])
  return s
 run('vlib','vlib',[work])
 sources=[ROOT/s for s in (ROOT/'sim/router_sources.list').read_text().splitlines() if s.startswith("'") for s in [s.strip("'")] if '/tb/' not in s]
 if a.real_flash:
  sources += [ROOT/'sim/unit/midi/w25q64_read_model.sv',ROOT/'sim/unit/audio/tb_trumpet_deadline.sv']
 run('compile','vlog',['-sv','-work',work,*sources,ROOT/'sim/unit/audio/tb_mod1_budget.sv'])
 directory=a.directory.resolve();manifest=json.loads((directory/'resources.json').read_text());raw=(directory/'resources.bin').read_bytes()
 from run_aftertouch import vectors
 vectors(out)
 rows=[]
 for inst in a.instruments:
  notes=sorted([r for r in manifest['entries'] if r['name']==inst and r['slot']<16],key=lambda r:r['slot'])
  assert len(notes)==16
  records=[];profiles=[]
  for r in notes:
   data=raw[r['offset']:r['offset']+4096]
   records.extend(data[i:i+64].hex() for i in range(0,4096,64))
   profiles.append(f"{r.get('period',0):04x}{r.get('a_step',0):08x}{r.get('r_step',0):08x}")
  (out/f'{inst}_records.mem').write_text('\n'.join(records)+'\n');(out/f'{inst}_profiles.mem').write_text('\n'.join(profiles)+'\n')
  for cap in a.caps:
   s=run(f'{inst}_{cap}','vsim',['-c','-suppress','7061','-lib',work,'tb_mod1_budget',f'-gCAP={cap}',f"-gINSTRUMENT={notes[0]['instrument']}",f'-gTEST_FRAMES={a.frames}',f'+records={inst}_records.mem',f'+profiles={inst}_profiles.mem','-do','run -all; quit -f'])
   line=next((x for x in s.splitlines() if 'RESULT ' in x),None)
   assert line and 'PASS tb_mod1_budget' in s,s[-2000:]
   row={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',line)};row['instrument']=inst;rows.append(row)
   print(line.lstrip('# '),flush=True)
 real_flash={}
 if a.real_flash:
  shutil.copyfile(directory/'resources.mem',out/'resources.mem')
  text=run('real_flash','vsim',['-c','-lib',work,'tb_trumpet_deadline','-do','run -all; quit -f'])
  summary=next(x.lstrip('# ') for x in text.splitlines() if 'PASS tb_trumpet_deadline' in x)
  print(summary,flush=True);real_flash={'passed':True,'summary':summary}
  if a.model_python:
   code="""import sys,json
from pathlib import Path
r=Path(sys.argv[1]);out=Path(sys.argv[2]);sys.path[:0]=[str(r/'sim'),str(r/'python/modal_sim')]
import eng1_rtl as E
from run_eng1_model import compare_wave
p=r/'rtl/router/tools/performance';m=json.loads((p/'resources.json').read_text());raw=(p/'resources.bin').read_bytes()
notes={x['midi']:E.NoteResource.decode(x['midi'],raw[x['offset']:x['offset']+4096],x) for x in m['entries'] if x['name']=='trumpet' and x['slot']<16}
print(json.dumps(compare_wave(out/'trumpet_trace.txt',E.ResourceBank('trumpet',notes),min_checks=640,reverb='HALL')))
"""
   checked=subprocess.run([a.model_python,'-c',code,str(ROOT),str(out)],capture_output=True,text=True,timeout=120,check=True)
   real_flash['parity']=json.loads(checked.stdout);print('PASS real Flash audio parity',real_flash['parity'],flush=True)
 (out/'results.json').write_text(json.dumps({'frame_clocks':1024,'clock_hz':50000000,'preloaded_resources':True,'real_flash':real_flash,'source_sha256':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [ROOT/'rtl/router/voice_router.sv',ROOT/'rtl/router/routers/mod_router.sv',ROOT/'rtl/router/parts/modulation1.sv',ROOT/'sim/unit/audio/tb_mod1_budget.sv']},'rows':rows},indent=2)+'\n')
if __name__=='__main__':main()
