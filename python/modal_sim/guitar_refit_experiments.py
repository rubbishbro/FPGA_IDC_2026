#!/usr/bin/env python3
"""Source-backed guitar coefficient/ADSR experiments; no production defaults.
All variants retain the 2-sample single pluck, 48 active/64 stored modes and body.
"""
from pathlib import Path
from concurrent.futures import ProcessPoolExecutor,as_completed
import sys,math,json,hashlib,os,argparse
from functools import lru_cache
import numpy as np
import soundfile as sf
from scipy.signal import resample_poly,lfilter,sosfreqz,welch
from scipy.stats import theilslopes
import eng1_audition as A
import eng1_rtl as E
import router_eng1 as R
import guitar_diagnose as GD
import params as P
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'FFT_results/sim/eng1/guitar_refit'
CONFIGS={
 'baseline':dict(gamma='current',gain='preserve_peak',envelope=False),
 'envelope_only':dict(gamma='current',gain='preserve_peak',envelope=True),
 'undo_old_scale':dict(gamma='unscaled',gain='preserve_peak',envelope=False),
 'fit_decay':dict(gamma='measured',gain='preserve_peak',envelope=False),
 'fit_decay_envelope':dict(gamma='measured',gain='preserve_peak',envelope=True),
 'refit_amplitude_envelope':dict(gamma='measured',gain='source_amplitude',envelope=True),
}
ENV=0x7fffffff
A_STEP=math.ceil(ENV/24)
R_STEP=math.ceil(ENV/(48000*.600))

class GentleEnvelope(E.Envelope):
 """A=0.5ms, D=0, S=1, R=600ms from full scale. No duplicate held-note fade."""
 def __init__(self):super().__init__([A_STEP]*16,[R_STEP]*16)
 def step(self,gate,trigger,clear):
  old=self.level.copy();hold=(self.state==self.DECAY)&gate&self.previous_gate&~trigger&~clear
  super().step(gate,trigger,clear)
  self.level[hold]=old[hold];self.state[hold]=self.DECAY
  return self.level.copy()

@lru_cache(maxsize=None)
def patch():return P.Patch('guitar')
@lru_cache(maxsize=None)
def source_data(midi,dyn):
 manifest=json.loads((ROOT/'FFT_results/params/guitar_manifest.json').read_text())
 row=next(r for r in manifest if r['midi']==midi and r['dynamic']==dyn and r['variation']=='normal')
 path=Path(row['path'])
 if not path.is_file():
  # Historical extraction manifests can name another checkout. Resolve only
  # the recorded music_resources-relative path, never a different recording.
  parts=path.parts
  if 'music_resources' in parts:path=ROOT.joinpath(*parts[parts.index('music_resources'):])
 if not path.is_file():raise FileNotFoundError(path)
 row=dict(row,path=str(path))
 x,fs=sf.read(path,always_2d=True);x=x[:,0].astype(float)
 if fs!=48000:
  gcd=math.gcd(fs,48000);x=resample_poly(x,48000//gcd,fs//gcd)
 win=np.ones(480)/480;env=np.sqrt(np.convolve(x*x,win,mode='same'))
 onset=int(np.flatnonzero(env>.1*env.max())[0])
 return x,onset,row

@lru_cache(maxsize=None)
def fit_source(midi,dyn):
 p=patch();src=p._pick(midi,dyn);x,onset,manifest=source_data(midi,dyn)
 good=np.isfinite(src['gamma'])&(src['a0']>0)&(src['f_k']<p.band_hz)&src['trusted']
 fks=src['f_k'][good][:48];ks=src['k'][good][:48]
 records=[];window=4096;w=np.hanning(window);t=np.arange(window)/48000
 times=np.arange(.015,.725,.035)
 for fk,k,old in zip(fks,ks,src['gamma'][good][:48]):
  demod=np.exp(-2j*np.pi*fk*t)*w;amps=[]
  for moment in times:
   at=onset+round(moment*48000);seg=x[at:at+window]
   amps.append(2*abs(np.sum(seg*demod))/w.sum() if len(seg)==window else np.nan)
  amps=np.array(amps);usable=np.isfinite(amps)&(amps>0)
  # Estimate per-partial late recording floor; omit amplitudes within 12dB of it.
  floors=[]
  for at in np.linspace(max(onset,len(x)-24000),max(onset,len(x)-window),5).astype(int):
   seg=x[at:at+window]
   if len(seg)==window:floors.append(2*abs(np.sum(seg*demod))/w.sum())
  noise=float(np.median(floors)) if floors else 0
  maximum=float(np.nanmax(amps))
  use=usable&(amps>max(maximum*10**(-28/20),noise*4))
  accepted=False;gamma=float(np.clip(old,.05,200));intercept=None;r2=None
  if use.sum()>=5:
   tt=times[use]+(window-1)/96000;yy=np.log(amps[use])
   slope,inter,_,_=theilslopes(yy,tt)
   prediction=inter+slope*tt;den=np.sum((yy-yy.mean())**2)
   r2=float(1-np.sum((yy-prediction)**2)/den) if den>1e-15 else 0
   if slope<0 and .05<=-slope<=200 and r2>=.65:
    gamma=float(-slope);intercept=float(inter);accepted=True
  # Raw amplitude from the observed early window, extrapolated with selected decay.
  if intercept is None:
   ids=np.flatnonzero(usable)[:3]
   intercept=float(np.median(np.log(amps[ids])+gamma*(times[ids]+(window-1)/96000)))
  records.append(dict(k=float(k),source_hz=float(fk),original_gamma=float(old),gamma=gamma,
                      amplitude_t0=float(math.exp(intercept)),fit_accepted=accepted,fit_r2=r2,
                      fit_points=int(use.sum()),floor_amplitude=noise))
 return records,manifest

@lru_cache(maxsize=None)
def table_for(midi,gamma_kind,gain_kind):
 old,row=A.experimental_table('guitar',midi);src_midi=row['source_midi'];dyn=row['source_dynamic']
 fits,manifest=fit_source(src_midi,dyn);assert len(fits)==old.n_modes
 radius=np.sqrt(old.a2/(1<<24));theta=np.arccos(np.clip(-old.a1/(1<<24)/(2*radius),-1,1))
 old_gamma=-np.log(radius)*48000
 scale=float(patch()._scale((src_midi,dyn),src_midi,dyn))
 gamma=old_gamma if gamma_kind=='current' else old_gamma/scale if gamma_kind=='unscaled' else np.array([f['gamma'] for f in fits])
 if gamma_kind=='current':return old,dict(**row,old_gamma_scale=scale,fits=fits,source_file=str(Path(manifest['path']).relative_to(ROOT)))
 r=np.exp(-gamma/48000);aa1=R.quant(-2*r*np.cos(theta),24,26);aa2=R.quant(r*r,24,24,signed=False)
 pulse=np.zeros(8192);pulse[1:3]=[.5,1.]
 sos=np.array([[*np.array(c[:3])/(1<<27),1.,*np.array(c[3:])/(1<<27)] for c in R.body_coeffs('guitar')])
 _,h=sosfreqz(sos,worN=theta)
 targets=np.array([f['amplitude_t0'] for f in fits]);targets/=max(targets.max(),1e-20)
 gain=[];peak_errors=[]
 for i in range(old.n_modes):
  unit=lfilter([1.],[1.,aa1[i]/(1<<24),aa2[i]/(1<<24)],pulse)
  prev=lfilter([old.G[i]/(1<<24)],[1.,old.a1[i]/(1<<24),old.a2[i]/(1<<24)],pulse)
  target=float(np.max(abs(prev))) if gain_kind=='preserve_peak' else float(targets[i]/max(abs(h[i]),.126))
  g=target/max(np.max(abs(unit)),1e-20);gain.append(g)
  q=round(g*(1<<24));achieved=q/(1<<24)*np.max(abs(unit))
  peak_errors.append(float(20*np.log10(max(achieved,1e-20)/max(target,1e-20))))
 # Absolute source normalization is arbitrary; keep the relative modal shape
 # and use one common per-note gain if it exceeds signed26 Q2.24 headroom.
 # Never clamp individual modal gains, which would silently change timbre.
 common_scale=min(1.,1.8/max(max(gain),1e-20))
 if gain_kind=='preserve_peak':assert common_scale==1.
 G=R.quant(np.array(gain)*common_scale,24,26)
 assert np.all((G>-(1<<25))&(G<(1<<25)-1))
 table=R.Eng1Coeffs(G,aa1,aa2,old.n_modes,label=f'guitar:{midi}:{gamma_kind}:{gain_kind}')
 return table,dict(**row,old_gamma_scale=scale,gamma_method=gamma_kind,gain_method=gain_kind,
                   fits=fits,source_file=str(Path(manifest['path']).relative_to(ROOT)),gamma_used=gamma.tolist(),
                   peak_calibration_errors_db=peak_errors,common_per_note_gain_scale=common_scale,
                   source_body_inverse_boost_cap_db=18.0 if gain_kind=='source_amplitude' else None)

class Synth(GD.Guitar):
 def __init__(self,cfg,natural=False):
  env=cfg['envelope'] and not natural
  super().__init__(dict(envelope='adsr' if env else 'gate',rise=1,width=2))
  if env:self.env=GentleEnvelope()
  self.metadata=[]
  for midi in sorted({e['midi'] for e in A.score()}):
   table,meta=table_for(midi,cfg['gamma'],cfg['gain']);self.core.load_slot(A.NOTES.index(midi),table);self.metadata.append(meta)
  self.natural=natural

def run(name,reuse=False):
 cfg=CONFIGS[name];meta=None;result=dict(name=name,**cfg)
 for scene in ['phrase','release','natural']:
  cached=OUT/(name+'_'+scene+'.npy')
  # Only reuse the completed, already range-checked traces from this run's
  # unchanged preserve-peak variants. The source-amplitude experiment is new.
  if reuse and cfg['gain']=='preserve_peak' and cached.exists():
   raw=np.load(cached)
   assert raw.shape==((533760 if scene=='phrase' else 134400),)
   result[scene]=dict(native_rail_samples=0,feedback_rail_hits=0,body_saturations=0)
   meta=Synth(cfg,natural=scene=='natural').metadata
   continue
  events=A.score() if scene=='phrase' else [dict(time=.12,midi=69,duration=.4 if scene=='release' else 2.7,velocity=100)]
  n=533760 if scene=='phrase' else 134400
  on={};off={}
  for e in events:
   on.setdefault(round(e['time']*48000),[]).append(e);off.setdefault(round((e['time']+e['duration'])*48000),[]).append(e['midi'])
  s=Synth(cfg,natural=scene=='natural');raw=np.empty(n,dtype=np.int64)
  for i in range(n):
   for key in off.get(i,[]):s.note_off(key)
   for e in on.get(i,[]):s.note_on(e['midi'],e['velocity'])
   raw[i]=s.step()
  assert s.rail_hits==s.body.sat_total==0
  native=np.array([E.pcm16(int(v)*2896*64,3,18) for v in raw],dtype=np.int16)
  assert not np.any((native==32767)|(native==-32768))
  np.save(OUT/(name+'_'+scene+'.npy'),raw)
  result[scene]=dict(native_rail_samples=0,feedback_rail_hits=0,body_saturations=0)
  meta=s.metadata
 result['coefficients']=meta
 print('RENDER',name,flush=True)
 return result

def rms_curve(y):
 return np.sqrt(np.convolve(y*y,np.ones(480)/480,mode='same'))

def main():
 ap=argparse.ArgumentParser(description=__doc__)
 ap.add_argument('--reuse-generated',action='store_true',help='reuse completed preserve-peak traces from this same experiment; default fully rerenders')
 args=ap.parse_args()
 OUT.mkdir(parents=True,exist_ok=True)
 with ProcessPoolExecutor(max_workers=6) as pool:results=[f.result() for f in as_completed([pool.submit(run,n,args.reuse_generated) for n in CONFIGS])]
 results.sort(key=lambda r:list(CONFIGS).index(r['name']))
 # Each variant gets a fixed gain from the FIRST 100ms of a held A4, reused
 # for natural and release. Thus longer decay is not normalized away.
 onset_gains={}
 for r in results:
  y=np.load(OUT/(r['name']+'_natural.npy')).astype(float)/(1<<24)*(2896/4096)/8
  onset_gains[r['name']]=.08/max(np.sqrt(np.mean(y[5760:10560]**2)),1e-20)
 peak=max(float(np.max(np.abs(np.load(OUT/(r['name']+'_'+scene+'.npy')).astype(float)/(1<<24)*(2896/4096)/8*onset_gains[r['name']]))) for r in results for scene in ['natural','release'])
 factor=min(1,.88/max(peak,1e-20))
 # Phrases use whole active-window RMS-matching so volume is not a timbre clue.
 phrase_rms={r['name']:float(np.sqrt(np.mean((np.load(OUT/(r['name']+'_phrase.npy'))[5760:466560].astype(float)/(1<<24)*(2896/4096)/8)**2))) for r in results}
 target=min(.075,*[.88*phrase_rms[r['name']]/max(np.max(abs(np.load(OUT/(r['name']+'_phrase.npy')).astype(float)/(1<<24)*(2896/4096)/8)),1e-20) for r in results])
 for r in results:
  for scene in ['phrase','natural','release']:
   name=r['name'];y=np.load(OUT/(name+'_'+scene+'.npy')).astype(float)/(1<<24)*(2896/4096)/8
   gain=target/max(phrase_rms[name],1e-20) if scene=='phrase' else onset_gains[name]*factor
   z=y*gain;z[-960:]*=np.linspace(1,0,960)
   file=name+'_'+scene+'.wav';sf.write(OUT/file,np.repeat(z[:,None],2,axis=1),48000,subtype='PCM_24')
   data,fs=sf.read(OUT/file,always_2d=True);assert fs==48000 and data.shape==(len(z),2) and abs(data).max()<.9 and np.isfinite(data).all()
   r[scene].update(file=file,seconds=len(z)/48000,gain_db=float(20*np.log10(gain)),sha256=hashlib.sha256((OUT/file).read_bytes()).hexdigest())
   if scene=='natural':
    ref=np.sqrt(np.mean(z[6720:9120]**2));r['natural']['tail_db_relative_early']={}
    for t in [.25,.5,1,2]:
     seg=z[5760+round(t*48000):5760+round((t+.05)*48000)]
     r['natural']['tail_db_relative_early'][str(t)]=float(20*np.log10(max(np.sqrt(np.mean(seg**2)),1e-20)/max(ref,1e-20)))
  rows=r['coefficients'];r['accepted_decay_fits']=sum(sum(f['fit_accepted'] for f in row['fits']) for row in rows)
  r['decay_fit_count']=sum(len(row['fits']) for row in rows)
 # Baseline phase/clear/gating must equal earlier validated guitar experiment.
 old=np.load(ROOT/'FFT_results/sim/eng1/guitar_diagnosis/gate_2_phrase.npy');new=np.load(OUT/'baseline_phrase.npy')
 assert np.array_equal(old,new)
 # Natural scene deliberately removes the new envelope; matching pairs must be exact.
 for one,two in [('baseline','envelope_only'),('fit_decay','fit_decay_envelope')]:
  assert np.array_equal(np.load(OUT/(one+'_natural.npy')),np.load(OUT/(two+'_natural.npy')))
 # Export all actual ABC arrays, not only the hashes/summary.
 arrays={}
 for r in results:
  cfg=CONFIGS[r['name']]
  for row in r['coefficients']:
   midi=row['midi'];table,_=table_for(midi,cfg['gamma'],cfg['gain'])
   for field in ['G','a1','a2']:arrays[f'{r["name"]}_midi{midi}_{field}']=getattr(table,field)
 np.savez_compressed(OUT/'coefficients.npz',**arrays)
 os.environ.setdefault('MPLCONFIGDIR',str(ROOT/'build/guitar_refit/mpl'))
 import matplotlib;matplotlib.use('Agg');import matplotlib.pyplot as plt
 fig,ax=plt.subplots(figsize=(8,4))
 for name in ['baseline','undo_old_scale','fit_decay','refit_amplitude_envelope']:
  raw=np.load(OUT/(name+'_natural.npy')).astype(float);e=rms_curve(raw);ref=max(np.max(e[5760:10560]),1e-20)
  ax.plot((np.arange(len(e))[::240]-5760)/48000,20*np.log10(np.maximum(e[::240]/ref,1e-8)),label=name)
 source=np.load(ROOT/'FFT_results/sim/eng1/a_source_audit/guitar_analysis.npz');e=source['source_envelope'];ref=max(np.max(e[5760:10560]),1e-20)
 ax.plot((np.arange(len(e))[::240]-5760)/48000,20*np.log10(np.maximum(e[::240]/ref,1e-8)),color='black',linestyle='--',label='recording reference')
 ax.set(xlim=(0,2.5),ylim=(-85,5),xlabel='Time since onset (s)',ylabel='RMS / onset peak (dB)',title='A4 natural decay, same pluck/body; no ADSR truncation')
 ax.grid(alpha=.2);ax.legend(fontsize=8);fig.tight_layout();fig.savefig(OUT/'natural_decay.png',dpi=160)
 summary=dict(configs=CONFIGS,variants=results,adsr=dict(A_STEP=A_STEP,D_STEP=0,S_LEVEL=ENV,R_STEP=R_STEP,A_ms=.5,R_from_full_ms=math.ceil(ENV/R_STEP)/48),
  baseline_exact=True,experimental_only=True,production_rtl_modified=False,all_sources='same existing guitar recordings; no new sound library',
  fit_policy='Theil-Sen on 85ms demodulation windows; >=5 above-floor points; R2>=.65; otherwise original unscaled gamma; clipped to .05..200/s',
  unchanged='pluck 0,A/2,A,0; one pluck; old guitar five-section body; original source note selection and pitches',
  gain_policy='phrases equal active RMS; singles matched first100ms, fixed gain reused across natural/release scenes; common peak safety gain',
  source_hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(__file__),ROOT/'python/modal_sim/eng1_audition.py',ROOT/'python/modal_sim/guitar_diagnose.py',ROOT/'FFT_results/params/guitar_gammascale.npz',ROOT/'FFT_results/params/guitar_partials.npz']})
 (OUT/'results.json').write_text(json.dumps(summary,indent=2)+'\n')
 print('PASS baseline exact, natural pairs exact; 18 clips validated',flush=True)
if __name__=='__main__':main()
