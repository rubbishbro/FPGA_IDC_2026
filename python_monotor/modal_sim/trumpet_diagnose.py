#!/usr/bin/env python3
"""Current production trumpet versus controlled front-end/ring-up candidates.

Changes are audition-only. Gamma variants recalibrate G to retain target modal
steady amplitude. No deployed coefficients or production RTL are overwritten.
"""
from pathlib import Path
from concurrent.futures import ProcessPoolExecutor,as_completed
from dataclasses import replace
import sys,math,json,hashlib,os
import numpy as np
import soundfile as sf
from scipy.signal import welch
import eng1_rtl as E
import eng1_audition as A
import router_eng1 as R
from sustain_engine import SustainPatch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'fft_analysis'))
import core as C
import sustain as S
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'python_monotor/results/sim/eng1/trumpet_diagnosis'
CONFIGS={
 'baseline':dict(gamma=1,tongue=False,pulse2=False),
 'tongue_adsr':dict(gamma=1,tongue=True,pulse2=False),
 'faster_ringup':dict(gamma=4,tongue=False,pulse2=False),
 'tongue_fast_ringup':dict(gamma=4,tongue=True,pulse2=False),
 'pulse2_only':dict(gamma=1,tongue=False,pulse2=True),
}
class TongueEnvelope(E.Envelope):
 """8ms attack, full sustain (D=0), 40ms release from full amplitude."""
 def __init__(self,slots):super().__init__([math.ceil(0x7fffffff/(.008*48000))]*slots,[math.ceil(0x7fffffff/(.040*48000))]*slots)
 def step(self,gate,trigger,clear):
  old=self.level.copy();holding=(self.state==self.DECAY)&gate&self.previous_gate&~trigger&~clear
  super().step(gate,trigger,clear)
  self.level[holding]=old[holding];self.state[holding]=self.DECAY
  return self.level.copy()
class Pulse2(E.Excitation):
 """Two adjacent samples at half pulse amplitude; no retuning or extra energy."""
 def reset(self):super().reset();self.pending=np.zeros(self.slots,dtype=np.int64)
 def step(self,gate,level,trigger,clear,delta):
  pulse=super().step(gate,level,trigger,clear,delta)
  self.pending[clear|~gate|trigger]=0
  y=(pulse>>1)+self.pending
  self.pending=pulse>>1
  return y

def bank_for(gamma):
 b=E.ResourceBank.build('trumpet',A.NOTES)
 if gamma==1:return b
 notes={}
 for m,row in b.notes.items():
  table=R.build_b_table('trumpet',m,'forte',gamma_scale=gamma).padded(64)
  import pitch_linear
  words=np.array(pitch_linear.modulation_words(table),dtype=np.int64)
  notes[m]=replace(row,coeffs=table,pitch_words=words)
 return E.ResourceBank('trumpet',notes)

def make(bank,cfg):
 s=E.Eng1Synth('trumpet',note_map=A.NOTES,resources=bank,stereo=False)
 if cfg['tongue']:s.envelope=TongueEnvelope(16)
 if cfg['pulse2']:s.excitation=Pulse2([r.period for r in s.rows])
 return s

def run_variant(name):
 cfg=CONFIGS[name];bank=bank_for(cfg['gamma']);events=A.score();outs={};rails=0
 for scene in ['phrase','single']:
  n=533760 if scene=='phrase' else 115200
  ev=events if scene=='phrase' else [dict(time=.12,midi=64,duration=1.5,velocity=100)]
  on={};off={}
  for e in ev:
   on.setdefault(round(e['time']*48000),[]).append(e)
   off.setdefault(round((e['time']+e['duration'])*48000),[]).append(e['midi'])
  s=make(bank,cfg);raw=np.empty(n,dtype=np.int64)
  for i in range(n):
   for m in off.get(i,[]):s.note_off(A.NOTES.index(m))
   for e in on.get(i,[]):s.note_on(e['midi'],e['velocity'])
   f=s.step(committed_delta=np.zeros(16,dtype=np.int64));raw[i]=f.out
   # Replay snapshots use caller-owned one-frame triggers. Do not hold a
   # high-level note helper's trigger across every replay frame (E would stay 0).
   s.trigger[:]=False
   rails+=int(np.count_nonzero((s.core.y1==R.Y_MAX)|(s.core.y1==R.Y_MIN)))
  assert rails==0
  np.save(OUT/f'{name}_{scene}.npy',raw);outs[scene]=raw
 result=dict(name=name,**cfg,state_rail_hits=rails)
 print('RENDER',name,flush=True)
 return result

def bands(y,f0):
 f,p=welch(y,48000,nperseg=min(32768,len(y)),noverlap=min(16384,len(y)//2))
 amplitudes=[]
 for k in range(1,25):
  width=min(.4*f0,max(12,.015*k*f0));mask=abs(f-k*f0)<width
  amplitudes.append(float(np.sqrt(np.sum(p[mask]))))
 a=np.array(amplitudes);return a/max(a.max(),1e-30)

def main():
 OUT.mkdir(parents=True,exist_ok=True)
 with ProcessPoolExecutor(max_workers=5) as p:results=[f.result() for f in as_completed([p.submit(run_variant,n) for n in CONFIGS])]
 results.sort(key=lambda r:list(CONFIGS).index(r['name']))
 patch=SustainPatch('trumpet');src=patch._pick(64,'forte');path=ROOT/'music_resources/trumpet'/src['note']
 recording=C.load_audio(str(path),48000);on,off=S.note_region(recording,48000);span=off-on
 source_steady=recording[on+round(.3*span):on+round(.7*span)]
 source_band=bands(source_steady,src['f0']);ks,g,w,atk,rel,ndb,nwin=patch.modes(64)
 target=np.zeros(24)
 for k,amp in zip(ks,w):
  if int(k)<=24:target[int(k)-1]=amp
 target/=max(target.max(),1e-30)
 good=target>10**(-35/20)
 # Waveform integration/FFT analysis does not assume a subjective brass score.
 synth_band=None
 for r in results:
  single=np.load(OUT/(r['name']+'_single.npy')).astype(float)/(1<<24)
  period=E.ResourceBank.build('trumpet',[64]).notes[64].period
  steady=bands(single[round(.8*48000):round(1.4*48000)],48000/period)
  err=20*np.log10(np.maximum(steady,1e-15))-20*np.log10(np.maximum(target,1e-15))
  r['steady_harmonic_rms_error_db']=float(np.sqrt(np.mean(err[good]**2)))
  r['steady_harmonics']=steady.tolist()
  if r['name']=='baseline':synth_band=steady
 # All phrase listening clips RMS-matched; singles separately RMS-matched to
 # avoid giving the louder full-sustain envelope a free perceptual advantage.
 for scene in ['phrase','single']:
  signals={r['name']:np.load(OUT/(r['name']+'_'+scene+'.npy')).astype(float)/(1<<24)/8 for r in results}
  window=slice(5760,466560) if scene=='phrase' else slice(5760,77760)
  rms={n:float(np.sqrt(np.mean(y[window]**2))) for n,y in signals.items()}
  target_rms=min(.075,*[.88*rms[n]/max(abs(y).max(),1e-20) for n,y in signals.items()])
  for r in results:
   name=r['name'];y=signals[name];gain=target_rms/max(rms[name],1e-20);z=y*gain;z[-960:]*=np.linspace(1,0,960)
   file=name+'_'+scene+'.wav';sf.write(OUT/file,np.repeat(z[:,None],2,axis=1),48000,subtype='PCM_24')
   a,fs=sf.read(OUT/file,always_2d=True);assert fs==48000 and len(a)==len(y) and abs(a).max()<.9 and np.isfinite(a).all()
   r[scene]=dict(file=file,seconds=len(y)/48000,gain_db=20*math.log10(gain),active_rms_dbfs=20*math.log10(target_rms),sha256=hashlib.sha256((OUT/file).read_bytes()).hexdigest())
   # Onset envelope by 10ms RMS, report first crossing relative to settled RMS.
   if scene=='single':
    e=S._envelope(y,48000);ref=float(np.median(e[38400:67200]));start=5760
    times=[]
    for fraction in [.1,.9]:
     hits=np.flatnonzero(e[start:77760]>=fraction*ref);times.append(float(hits[0]/48) if len(hits) else None)
    r['onset_10_90_ms']=None if None in times else times[1]-times[0]
 # Detect actual pulse train rather than infer a pluck from the perceived timbre.
 e=E.Excitation([round(48000/(440*2**((64-69)/12)))])
 x=np.array([e.step(np.array([True]),np.array([201]),np.array([n==0]),np.array([False]),np.array([0]))[0] for n in range(24000)])
 pulses=np.flatnonzero(x);assert len(pulses)>150
 # Local reference excerpt at note onset, not a redistributed complete sample.
 source_clip=np.zeros(115200);part=recording[max(0,on-5760):min(len(recording),max(0,on-5760)+115200)]
 source_clip[:len(part)]=part
 gain=min(.075/max(np.sqrt(np.mean(source_clip[5760:77760]**2)),1e-20),.88/max(abs(source_clip).max(),1e-20))
 source_clip*=gain;source_clip[-960:]*=np.linspace(1,0,960)
 sf.write(OUT/'recording_reference_E4.wav',np.repeat(source_clip[:,None],2,axis=1),48000,subtype='PCM_24')
 os.environ.setdefault('MPLCONFIGDIR',str(ROOT/'build/trumpet_diagnosis/mpl'))
 import matplotlib;matplotlib.use('Agg');import matplotlib.pyplot as plt
 fig,ax=plt.subplots(1,2,figsize=(12,4))
 for name,v in [('recording',source_band),('stored weights',target),('baseline steady',synth_band)]:ax[0].plot(range(1,25),20*np.log10(np.maximum(v,1e-7)),'.-',label=name)
 ax[0].set(xlabel='Harmonic',ylabel='Relative amplitude (dB)',title='E4 sustained spectral shape',ylim=(-60,3));ax[0].legend();ax[0].grid(alpha=.2)
 for r in results:
  y=np.load(OUT/(r['name']+'_single.npy')).astype(float);e=S._envelope(y,48000);e/=max(np.median(e[38400:67200]),1e-20)
  ax[1].plot(np.arange(19200)/48,e[5760:24960],label=r['name'])
 ax[1].set(xlabel='Time after note-on (ms)',ylabel='RMS / settled RMS',title='Onset includes ADSR and resonator ring-up',ylim=(0,4));ax[1].legend(fontsize=8);ax[1].grid(alpha=.2)
 fig.tight_layout();fig.savefig(OUT/'diagnosis.png',dpi=160)
 summary=dict(variants=results,source_file=str(path.relative_to(ROOT)),source_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),source_f0=src['f0'],
  source_attack_s=atk,source_release_s=rel,source_k=ks.tolist(),source_weights=w.tolist(),
  modal_gamma_quantiles=np.quantile(g,[0,.5,1]).tolist(),gamma_interpretation='ring-up/linewidth under sustained drive; not plucked note lifetime',
  production_attack_ms=atk*1000,production_sustain_level=.25,production_fullscale_release_min_s=.02,
  periodic_pulses_first_half_second=len(pulses),pulse_intervals=np.unique(np.diff(pulses)).tolist(),
  target_harmonics=target.tolist(),recording_harmonics=source_band.tolist(),production_rtl_modified=False,
  body='production trumpet body is passthrough',noise='none in current production; not added in candidates',
  source_hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(__file__),ROOT/'python_monotor/modal_sim/eng1_rtl.py',ROOT/'python_monotor/modal_sim/router_eng1.py']})
 (OUT/'results.json').write_text(json.dumps(summary,indent=2)+'\n')
 print('PASS pulse train',len(pulses),'pulses; stats',[(r['name'],r['onset_10_90_ms'],r['steady_harmonic_rms_error_db']) for r in results],flush=True)
if __name__=='__main__':main()
