#!/usr/bin/env python3
"""Read-only gain calculation: one reference note, sliding20ms, FS=1.0 Q24.

Uses current Flash coefficients, integer engines/frontends, body, no existing
instrument trim, no reverb, no aftertouch, no polyphony gain. Writes build-only
results; never updates gain_q12_of or production resources.
"""
from pathlib import Path
import sys,json,re,math,hashlib,argparse,copy
import numpy as np
ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'python_monotor/modal_sim'),str(ROOT/'sim')]
import eng1_rtl as E
import eng1_audition as A
import router_eng1 as R
from performance_chain import RawPerformance
STRIKES=('piano','guitar','piano_abc','guitar_abc','banjo','mandolin')
REFS={name:69 for name in ['piano','guitar','flute','trumpet','cello','violin','oboe','banjo','mandolin','piano_abc','guitar_abc']}

class ReferencePerformance(RawPerformance):
 def __init__(self,name,manifest,image,note):
  m=copy.deepcopy(manifest);row=next(r for r in m['entries'] if r['name']==name and r['midi']==note)
  m['entries']=[row];cfg=m['frontends'][name]
  if name in ('flute','cello','oboe'):
   cfg.update(a_step=row['a_step'],r_step=row['r_step'],s_level=0x1fffffff,d_step=1048576)
  if name in ('banjo','mandolin'):
   # Initialize through a plucked branch with the same copied coefficients;
   # the original six-timbre model assumes all other names have a period.
   row['period']=2
  super().__init__(name,m,image)
  if name in ('banjo','mandolin'):
   self.exc=A.Strike('guitar',1);self.exc.rise=cfg['rise_sh'];self.exc.width=cfg['pw_len'];self.exc.gap=cfg['gap_len'];self.exc.pulses=cfg['n_pulse']
  self.body=R.BodyFilter(instrument=name)
  self.rails=0
 def sample(self,n,hold):
  gate=np.array([n<hold]);level=np.array([255]);trigger=np.array([n==0]);clear=np.array([False])
  old=self.env.level.copy();env=self.env.step(gate,trigger,clear)
  if self.name in STRIKES:env=np.where(trigger,0,old)
  zero=trigger|(gate&~self.previous_gate)|self.pending_dead
  if self.name in STRIKES:x=self.exc.step(level,gate,trigger,clear)
  else:x=self.exc.step(gate,level,trigger,clear,np.zeros(1,dtype=np.int64))
  if self.matrix:
   nm=64 if self.name=='piano' else 20;w=self.words[:,:nm,:7];q=self.q[:,:nm].copy();v=self.v[:,:nm].copy();q[zero]=0;v[zero]=0
   def term(a,b,s):return (a*b+(1<<(s-1)))>>s
   qn=term(q,w[:,:,0],28)+term(v,w[:,:,1],30)+term(x[:,None],w[:,:,4],32)
   vn=term(q,w[:,:,2],23)+term(v,w[:,:,3],28)+term(x[:,None],w[:,:,5],34)
   self.rails+=int(np.count_nonzero((qn<-(1<<31))|(qn>=(1<<31))))+int(np.count_nonzero((vn<-(1<<31))|(vn>=(1<<31))))
   y=np.sum(term(q,w[:,:,6],29),axis=1);self.q[:,:nm]=np.clip(qn,-(1<<31),(1<<31)-1);self.v[:,:nm]=np.clip(vn,-(1<<31),(1<<31)-1)
  else:
   y,yn=self.core.step(x,zero,active_modes=48);self.rails+=int(np.count_nonzero((yn==-(1<<31))|(yn==(1<<31)-1)))
  dead=self.env.dead.copy()
  self.pending_dead=dead&~self.previous_dead;self.previous_dead=dead;self.previous_gate=gate.copy()
  return self.body.step((int(y[0])*int(env[0]))>>31)[0]

def metrics(raw,fs=48000):
 x=np.asarray(raw,dtype=float)/(1<<24);power=x*x;window=round(fs*.020)
 c=np.r_[0.,np.cumsum(power)];ms=(c[window:]-c[:-window])/window;k=int(np.argmax(ms))
 rms=math.sqrt(max(float(ms[k]),0));g=10**(-12/20)/rms;q=round(g*4096)
 return dict(max20ms_rms=rms,raw_max20ms_dbfs=20*math.log10(rms),max_window_start_s=k/fs,
  raw_peak=float(np.max(abs(x))),gain_linear=g,gain_q12=q,gain_db=20*math.log10(g),
  q12_representable=0<q<=32767,predicted_peak_dbfs=20*math.log10(max(np.max(abs(x))*g,1e-30)),
  achieved_rms_dbfs_q12=20*math.log10(rms*q/4096))

def render_note(args):
 name,m,image,out=args;synth=ReferencePerformance(name,m,image,69)
 sustained=name in ('flute','trumpet','cello','violin','oboe');hold=384000 if sustained else 192000;raw=np.empty(hold+48000,dtype=np.int64)
 for n in range(len(raw)):raw[n]=synth.sample(n,hold)
 np.save(Path(out)/(name+'_raw_q24.npy'),raw);r=metrics(raw)
 r.update(reference_midi=69,hold_s=hold/48000,render_s=len(raw)/48000,state_saturations=synth.rails,body_saturations=synth.body.sat_total)
 return name,r

def main():
 from concurrent.futures import ProcessPoolExecutor,as_completed
 p=argparse.ArgumentParser();p.add_argument('--out',type=Path,default=ROOT/'build/reference_gain_calibration');p.add_argument('--workers',type=int,default=4);a=p.parse_args();a.out.mkdir(parents=True,exist_ok=True)
 directory=ROOT/'rtl/router/tools/performance';m=json.loads((directory/'resources.json').read_text());image=(directory/'resources.bin').read_bytes()
 pkg=(ROOT/'rtl/router/pkg/router_pkg.sv').read_text();values={k:int(v) for k,v in re.findall(r"INST_(\w+):\s*return 16'sd(\d+)",pkg)};old={n:values.get(n.upper(),4096) for n in REFS};results={}
 with ProcessPoolExecutor(max_workers=a.workers) as pool:
  jobs=[pool.submit(render_note,(name,m,image,str(a.out))) for name in REFS]
  for job in as_completed(jobs):
   name,r=job.result();r.update(old_q12=old[name],old_linear=old[name]/4096,delta_db=20*math.log10(r['gain_linear']/(old[name]/4096)));results[name]=r
   print(name,json.dumps(r),flush=True)
 # Full-force production strike/ADSR and actual Flash records. Piece balance
 # is already embedded in modal/noise gains; do not apply it a second time.
 from render_drum_excitation_compare import production_bank
 for row,engine,raw,drive,levels,stats in production_bank(m,image):
  r=metrics(raw);old_drum=values.get('DRUMS',4096)
  key='drum_'+row['drum'];r.update(stats,reference_drum=row['drum'],old_q12=old_drum,old_linear=old_drum/4096,delta_db=20*math.log10(r['gain_linear']/(old_drum/4096)),reference_balance=row['reference_balance'])
  results[key]=r;np.save(a.out/(key+'_raw_q24.npy'),raw);print(key,json.dumps(r),flush=True)
 reference=max((k for k in results if k.startswith('drum_')),key=lambda k:results[k]['max20ms_rms'])
 result=dict(drum_group_reference=reference,drum_group_gain_q12=results[reference]['gain_q12'],drum_group_gain_linear=results[reference]['gain_linear'],target_dbfs=-12,full_scale_q24=1.,fs=48000,window='960-sample sliding window, one-sample hop',hold_s='8s sustained /4s struck-plucked',render_s='hold+1s',drum_render_s=3,trim_removed=True,modulation='disabled baseline',reverb='NONE',polyphony=1,results=results,
  gain_config_modified=False,production_image_sha256=hashlib.sha256(image).hexdigest())
 (a.out/'results.json').write_text(json.dumps(result,indent=2))
if __name__=='__main__':main()
