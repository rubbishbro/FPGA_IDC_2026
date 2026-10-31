#!/usr/bin/env python3
"""Piano ENG1 audition ablation; no production defaults/RTL are changed."""
from pathlib import Path
from concurrent.futures import ProcessPoolExecutor,as_completed
import argparse,hashlib,json,math,time,os
import numpy as np
import soundfile as sf
from scipy.signal import sosfreqz,welch
import eng1_audition as A
import eng1_rtl as E
import router_eng1 as R

ROOT=Path(__file__).resolve().parents[2]
CONFIGS={
 'baseline':dict(label='基线',attack=16777216,body=True,rise=5,width=32,gap=448),
 'fast_attack':dict(label='仅加快attack',attack=0x7fffffff,body=True,rise=5,width=32,gap=448),
 'no_decay':dict(label='仅D_STEP=0',attack=16777216,decay=0,body=True,rise=5,width=32,gap=448),
 'no_body':dict(label='仅旁路腔体',attack=16777216,body=False,rise=5,width=32,gap=448),
 'sharp_strike':dict(label='仅缩短锤击上升',attack=16777216,body=True,rise=1,width=2,gap=478),
 'fast_attack_no_body':dict(label='快attack＋旁路腔体',attack=0x7fffffff,body=False,rise=5,width=32,gap=448),
}

class TapBody:
 def __init__(self,body,bypass):self.body=body;self.bypass=bypass;self.x=0
 def step(self,x):
  self.x=int(x)
  return (x,0,0) if self.bypass else self.body.step(x)


class NoDecayEnvelope(E.Envelope):
 """D_STEP=0: remain in DEC at full level while held; A/R stay unchanged."""
 def step(self,gate,trigger,clear):
  old=self.level.copy()
  hold=(self.state==self.DECAY)&gate&self.previous_gate&~trigger&~clear
  super().step(gate,trigger,clear)
  self.level[hold]=old[hold];self.state[hold]=self.DECAY
  return self.level.copy()


def metrics(y,events):
 f,p=welch(y,fs=48000,nperseg=4096,noverlap=2048)
 total=float(np.sum(p[(f>=80)&(f<12000)]))
 hi=float(np.sum(p[(f>=3000)&(f<12000)]))
 lo=float(np.sum(p[(f>=80)&(f<3000)]))
 centroid=float(np.sum(f*p)/max(np.sum(p),1e-30))
 start=round(events[0]['time']*48000)
 onset=y[start:start+round(.1*48000)]
 early=float(np.sum(onset[:round(.003*48000)]**2))
 rest=float(np.sum(onset**2))
 return dict(high_3k_12k_fraction=hi/max(total,1e-30),high_low_db=10*math.log10(max(hi,1e-30)/max(lo,1e-30)),
             spectral_centroid_hz=centroid,onset_first_3ms_energy_fraction=early/max(rest,1e-30))


def render_variant(name,out):
 started=time.time();cfg=CONFIGS[name];events=A.score();n=round((A.LEAD+9.6+A.TAIL)*48000)
 s=A.ExperimentalA('piano');s.env.attack[:]=cfg['attack']
 if cfg.get('decay')==0:s.env=NoDecayEnvelope([cfg['attack']]*16,[1048576]*16)
 s.strike.rise,s.strike.width,s.strike.gap=cfg['rise'],cfg['width'],cfg['gap']
 s.body=TapBody(s.body,not cfg['body'])
 ons={};offs={}
 for e in events:
  ons.setdefault(round(e['time']*48000),[]).append(e)
  offs.setdefault(round((e['time']+e['duration'])*48000),[]).append(e['midi'])
 raw=np.empty(n,dtype=np.int64);pre_body=np.empty(n,dtype=np.int64);env=np.empty(n,dtype=np.int64)
 pcm=np.empty((n,2),dtype=np.int16)
 for i in range(n):
  for key in offs.get(i,[]):s.note_off(key)
  for e in ons.get(i,[]):s.note_on(e['midi'],e['velocity'])
  raw[i],pcm[i]=s.step();pre_body[i]=s.body.x;env[i]=s.env.level[0]
 np.savez_compressed(Path(out)/(name+'.npz'),raw=raw,pre_body=pre_body,env=env,pcm=pcm)
 native_dir=Path(out)/'native';native_dir.mkdir(exist_ok=True)
 sf.write(native_dir/(name+'.wav'),pcm,48000,subtype='PCM_16')
 wide=raw.astype(float)/(1<<24)*(2896/4096)/8
 active=wide[round(A.LEAD*48000):round((A.LEAD+9.6)*48000)]
 result=dict(name=name,**cfg,active_rms=float(np.sqrt(np.mean(active**2))),peak=float(np.max(np.abs(wide))),
             pcm_rail_samples=int(np.count_nonzero((pcm==32767)|(pcm==-32768))),state_rail_hits=s.rail_hits,
             body_saturations=s.body.body.sat_total,metrics=metrics(wide,events),pre_body_metrics=metrics(pre_body.astype(float),events),
             render_seconds=time.time()-started)
 print('RENDER',name,result['metrics'],flush=True)
 return result


def main():
 ap=argparse.ArgumentParser(description=__doc__)
 ap.add_argument('--out',type=Path,default=ROOT/'FFT_results/sim/eng1/piano_diagnosis')
 ap.add_argument('--workers',type=int,default=5)
 ap.add_argument('--reuse',action='store_true',help='reuse unchanged existing render traces/configurations')
 a=ap.parse_args();out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
 cached={}
 if a.reuse and (out/'results.json').exists():
  previous=json.loads((out/'results.json').read_text())
  # Changes to the source experiment/RTL cannot be hidden by cached waveforms.
  for p,v in previous['source_hashes'].items():
   if p!='python/modal_sim/piano_diagnose.py':assert hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==v,p
  cached={r['name']:r for r in previous['variants'] if r['name'] in CONFIGS and
          all(r.get(k)==v for k,v in CONFIGS[r['name']].items()) and (out/(r['name']+'.npz')).exists()}
 with ProcessPoolExecutor(max_workers=a.workers) as pool:
  results=list(cached.values())+[f.result() for f in as_completed([pool.submit(render_variant,n,out) for n in CONFIGS if n not in cached])]
 results.sort(key=lambda r:list(CONFIGS).index(r['name']))
 # All listening files have exactly the same active RMS. Select one target low
 # enough that none needs limiting/compression. This prevents volume bias.
 target=min(.1,*[10**(-1/20)*r['active_rms']/r['peak']*.98 for r in results])
 for r in results:
  d=np.load(out/(r['name']+'.npz'));wide=d['raw'].astype(float)/(1<<24)*(2896/4096)/8
  gain=target/r['active_rms'];listen=wide*gain;fade=960;listen[-fade:]*=np.linspace(1,0,fade)
  sf.write(out/(r['name']+'.wav'),np.repeat(listen[:,None],2,axis=1),48000,subtype='PCM_24')
  y,fs=sf.read(out/(r['name']+'.wav'),always_2d=True)
  assert y.shape==(533760,2) and fs==48000 and np.isfinite(y).all() and np.max(np.abs(y))<1
  r.update(listening_gain_db=20*math.log10(gain),listening_active_rms_dbfs=20*math.log10(target),
           listening_peak_dbfs=20*math.log10(np.max(np.abs(y))),sha256=hashlib.sha256((out/(r['name']+'.wav')).read_bytes()).hexdigest())
 # Verify baseline simulation against the already delivered native audio.
 reference=ROOT/'FFT_results/sim/eng1/mystery_of_love/native/mystery_of_love_piano_eng1.wav'
 old,fs=sf.read(reference,dtype='int16',always_2d=True)
 baseline=np.load(out/'baseline.npz')
 assert np.array_equal(old,baseline['pcm']),'baseline no longer matches delivered piano'
 # Changes to attack/body must not silently regenerate G/poles/excitation.
 for name in ['fast_attack','no_body','fast_attack_no_body']:
  if name=='no_body':
   d=np.load(out/(name+'.npz'))
   assert np.array_equal(d['pre_body'],baseline['pre_body'])
   assert np.array_equal(d['env'],baseline['env'])

 rows=np.array(R.body_coeffs('piano'),dtype=float)/(1<<27)
 sos=np.array([[*r[:3],1.,*r[3:]] for r in rows])
 f=np.geomspace(50,18000,1200);_,h=sosfreqz(sos,worN=f,fs=48000)
 probes=np.array([329.63,1000,2000,3000,4000,6000,8000,12000]);_,hp=sosfreqz(sos,worN=probes,fs=48000)
 body_response=[dict(hz=float(x),gain_db=float(20*np.log10(abs(y)))) for x,y in zip(probes,hp)]
 import params
 legacy=params.Patch('piano')
 legacy_h=legacy.body.magnitude(f)
 legacy_probes=legacy.body.magnitude(probes)
 for row,v in zip(body_response,legacy_probes):row['legacy_residual_gain_db']=float(20*np.log10(v))

 mpl_cache=ROOT/'build/piano_diagnosis/mpl';mpl_cache.mkdir(parents=True,exist_ok=True)
 os.environ.setdefault('MPLCONFIGDIR',str(mpl_cache))
 import matplotlib
 matplotlib.use('Agg')
 import matplotlib.pyplot as plt
 fig,ax=plt.subplots(1,3,figsize=(14,4.3))
 ax[0].semilogx(f,20*np.log10(abs(h)),label='Current 3-section body')
 ax[0].semilogx(f,20*np.log10(legacy_h),label='Legacy mild residual body',linestyle='--')
 ax[0].axhline(0,color='gray',lw=.7);ax[0].set(xlabel='Frequency (Hz)',ylabel='Gain (dB)',title='Body response',ylim=(-40,10));ax[0].grid(alpha=.25);ax[0].legend(fontsize=8)
 for name in ['baseline','fast_attack']:
  e=np.load(out/(name+'.npz'))['env'];start=round(A.LEAD*48000)
  ax[1].plot(np.arange(240)/48,e[start:start+240]/0x7fffffff,label=name)
 ax[1].set(xlabel='Time after note-on (ms)',ylabel='Envelope level',title='Attack state (old-level output adds 1 sample)');ax[1].legend(fontsize=8);ax[1].grid(alpha=.25)
 for r in results:
  d=np.load(out/(r['name']+'.npz'));y=d['raw'].astype(float);ff,pp=welch(y,fs=48000,nperseg=4096,noverlap=2048)
  pp=pp/max(float(np.sum(pp)),1e-30)
  ax[2].semilogx(ff[1:],10*np.log10(np.maximum(pp[1:],1e-15)),label=r['name'],lw=.9)
 ax[2].set(xlabel='Frequency (Hz)',ylabel='Normalized PSD (dB/bin)',title='Same score, relative spectral shape',xlim=(100,12000),ylim=(-100,0));ax[2].legend(fontsize=7);ax[2].grid(alpha=.25)
 fig.tight_layout();fig.savefig(out/'diagnosis.png',dpi=170);plt.close(fig)
 summary=dict(sample_rate=48000,seconds=11.12,common_active_rms_dbfs=20*math.log10(target),
              baseline_matches_delivered_pcm=True,production_rtl_modified=False,
              frozen_coefficients_across_variants=True,body_response=body_response,variants=results,
              score='same previously delivered four-bar excerpt',
              source_hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in
                            [ROOT/'python/modal_sim/piano_diagnose.py',ROOT/'python/modal_sim/eng1_audition.py',
                             ROOT/'rtl/router/routers/body_router.sv',ROOT/'rtl/router/routers/env_router.sv']})
 (out/'results.json').write_text(json.dumps(summary,indent=2,ensure_ascii=False)+'\n')
 print('PASS baseline exact; all listening clips RMS-matched:',summary['common_active_rms_dbfs'],'dBFS',flush=True)
 print('BODY',body_response,flush=True)
 print('WROTE',out,flush=True)
if __name__=='__main__':main()
