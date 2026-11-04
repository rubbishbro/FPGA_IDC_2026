#!/usr/bin/env python3
"""Guitar ADSR and 2/8/32-sample single pluck controlled auditions."""
from pathlib import Path
from concurrent.futures import ProcessPoolExecutor
import math,json,hashlib
import numpy as np
import soundfile as sf
import eng1_audition as A
import eng1_rtl as E
import router_eng1 as R
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'python_monotor/results/sim/eng1/guitar_diagnosis'
CONFIGS={'gate_2':dict(envelope='gate',rise=1,width=2),
         'adsr_2':dict(envelope='adsr',rise=1,width=2),
         'adsr_8':dict(envelope='adsr',rise=3,width=8),
         'adsr_32':dict(envelope='adsr',rise=5,width=32)}
ENV=0x7fffffff
S_LEVEL=round(.15*ENV)
PARAMS=dict(A_STEP=math.ceil(ENV/24),D_STEP=math.ceil((ENV-S_LEVEL)/(48000*.080)),
            S_LEVEL=S_LEVEL,R_STEP=math.ceil(S_LEVEL/(48000*.120)))
class GuitarEnvelope(E.Envelope):
 def __init__(self):super().__init__([PARAMS['A_STEP']]*16,[PARAMS['R_STEP']]*16)
 def step(self,gate,trigger,clear):
  for i in range(16):
   old,state=int(self.level[i]),int(self.state[i]);a=int(self.attack[i]);r=int(self.release[i])
   if clear[i]:self.level[i]=0;self.state[i]=self.IDLE;self.dead[i]=True
   elif trigger[i] or (gate[i] and not self.previous_gate[i]):self.level[i]=0;self.state[i]=self.ATTACK;self.dead[i]=False
   elif not gate[i]:
    self.level[i]=max(0,old-r);self.dead[i]=old<=r;self.state[i]=self.IDLE if self.dead[i] else self.RELEASE
   else:
    self.dead[i]=False
    if state==self.IDLE:self.state[i]=self.ATTACK
    elif state==self.ATTACK:
     self.level[i]=min(ENV,old+a)
     if old+a>=1<<31:self.state[i]=self.DECAY
    elif state==self.DECAY:
     if old<=S_LEVEL+PARAMS['D_STEP']:self.level[i]=S_LEVEL;self.state[i]=self.SUSTAIN
     else:self.level[i]=old-PARAMS['D_STEP']
    elif state==self.RELEASE:self.state[i]=self.IDLE
  self.previous_gate[:]=gate
  return self.level.copy()
class Guitar(A.ExperimentalA):
 def __init__(self,cfg):
  super().__init__('guitar');self.cfg=cfg;self.env=GuitarEnvelope()
  self.strike.rise=cfg['rise'];self.strike.width=cfg['width'];self.last_mix=0
 def step(self):
  gate=self.gate;trigger=self.trigger
  x=self.strike.step(self.level,gate,trigger,np.zeros(16,dtype=bool))
  if self.cfg['envelope']=='adsr':
   old=self.env.level.copy();self.env.step(gate,trigger,np.zeros(16,dtype=bool))
   emap=np.where(trigger,0,old);dead=self.env.dead.copy()
  else:emap=np.where(gate,ENV,0);dead=~gate
  zero=trigger|(gate&~self.prev_gate)|self.pending_dead
  y,_=self.core.step(x,zero,active_modes=48)
  mix=R.wrap_signed(sum((int(y[s])*int(emap[s]))>>31 for s in range(16)),64)
  self.last_mix=mix
  body,_,_=self.body.step(mix);out=self.reverb.step(body)
  self.rail_hits+=int(np.count_nonzero((self.core.y1==R.Y_MAX)|(self.core.y1==R.Y_MIN)))
  self.pending_dead=dead&~self.previous_dead;self.previous_dead=dead.copy();self.prev_gate=gate.copy();self.trigger[:]=False
  return out

def render(name):
 cfg=CONFIGS[name];stats=dict(name=name,**cfg)
 for scene in ['phrase','single']:
  events=A.score() if scene=='phrase' else [dict(time=.12,midi=64,duration=.28,velocity=100)]
  n=533760 if scene=='phrase' else 96000
  on={};off={}
  for e in events:
   on.setdefault(round(e['time']*48000),[]).append(e)
   off.setdefault(round((e['time']+e['duration'])*48000),[]).append(e['midi'])
  s=Guitar(cfg);raw=np.empty(n,dtype=np.int64)
  for i in range(n):
   for m in off.get(i,[]):s.note_off(m)
   for e in on.get(i,[]):s.note_on(e['midi'],e['velocity'])
   raw[i]=s.step()
  assert s.rail_hits==s.body.sat_total==0
  np.save(OUT/(name+'_'+scene+'.npy'),raw)
 print('RENDER',name,flush=True)
 return stats

def main():
 OUT.mkdir(parents=True,exist_ok=True)
 with ProcessPoolExecutor(max_workers=4) as p:results=list(p.map(render,CONFIGS))
 for scene in ['phrase','single']:
  waves={r['name']:np.load(OUT/(r['name']+'_'+scene+'.npy')).astype(float)/(1<<24)*(2896/4096)/8 for r in results}
  window=slice(5760,466560) if scene=='phrase' else slice(5760,19200)
  rms={n:np.sqrt(np.mean(y[window]**2)) for n,y in waves.items()}
  target=min(.075,*[.88*rms[n]/max(abs(y).max(),1e-20) for n,y in waves.items()])
  for r in results:
   name=r['name'];y=waves[name];gain=target/max(rms[name],1e-20);z=y*gain;z[-960:]*=np.linspace(1,0,960)
   file=name+'_'+scene+'.wav';sf.write(OUT/file,np.repeat(z[:,None],2,axis=1),48000,subtype='PCM_24')
   a,fs=sf.read(OUT/file,always_2d=True);assert fs==48000 and a.shape==(len(y),2) and np.isfinite(a).all() and abs(a).max()<.9
   native=np.array([E.pcm16(int(round(v*(1<<24)*8/(2896/4096)))*2896*64,3,18) for v in y],dtype=np.int16)
   assert not np.any((native==32767)|(native==-32768))
   r[scene]=dict(file=file,gain_db=20*math.log10(gain),active_rms_dbfs=20*math.log10(target),native_rails=0,sha256=hashlib.sha256((OUT/file).read_bytes()).hexdigest())
 # Baseline must match the previously approved guitar raw output.
 old,fs=sf.read(ROOT/'python_monotor/results/sim/eng1/mystery_of_love/native/mystery_of_love_guitar_eng1.wav',always_2d=True,dtype='int16')
 raw=np.load(OUT/'gate_2_phrase.npy')
 native=np.array([E.pcm16(int(v)*2896*64,3,18) for v in raw],dtype=np.int16)
 assert np.array_equal(old[:,0],native)
 (OUT/'results.json').write_text(json.dumps(dict(variants=results,adsr=PARAMS,baseline_matches_delivered_guitar=True,
  gamma_G_a1_a2_and_body_frozen=True,production_rtl_modified=False,sample_rate=48000,
  attack_ms=math.ceil(ENV/PARAMS['A_STEP'])/48,decay_ms=math.ceil((ENV-S_LEVEL)/PARAMS['D_STEP'])/48,
  release_from_sustain_ms=math.ceil(S_LEVEL/PARAMS['R_STEP'])/48,
  release_from_fullscale_ms=math.ceil(ENV/PARAMS['R_STEP'])/48,
  gain_policy='constant gain per clip, equal active-window RMS across variants; no compressor',
  source_hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(__file__),ROOT/'python_monotor/modal_sim/eng1_audition.py']}),indent=2)+'\n')
 print('PASS baseline exact; 8 clips clip-free, coefficients frozen',flush=True)
if __name__=='__main__':main()
