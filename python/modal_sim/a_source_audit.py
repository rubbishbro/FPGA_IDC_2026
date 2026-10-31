#!/usr/bin/env python3
"""Inspect raw A4 recordings versus unconstrained experimental ENG1 decay.
No production parameters are changed; no ADSR truncates synthetic natural tails.
"""
from pathlib import Path
import sys,json,math,hashlib,os
import numpy as np
import soundfile as sf
from scipy.signal import resample_poly
import eng1_audition as A
import router_eng1 as R
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'FFT_results/sim/eng1/a_source_audit'

def smooth_rms(y,window=480):return np.sqrt(np.convolve(y*y,np.ones(window)/window,mode='same'))
def main():
 OUT.mkdir(parents=True,exist_ok=True);records=[]
 for inst in ['guitar','piano']:
  manifest=json.loads((ROOT/f'FFT_results/params/{inst}_manifest.json').read_text())
  source=next(r for r in manifest if r['midi']==69 and r['dynamic']=='forte')
  path=Path(source['path']);x,fs=sf.read(path,always_2d=True);x=x[:,0]
  if fs!=48000:
   g=math.gcd(fs,48000);x=resample_poly(x,48000//g,fs//g)
  energy=smooth_rms(x);onset=int(np.flatnonzero(energy>.1*energy.max())[0])
  # One available A4 tone from each source, aligned to the detected onset.
  n=round(2.8*48000);lead=5760;y=np.zeros(n)
  take=x[onset:min(len(x),onset+n-lead)];y[lead:lead+len(take)]=take
  table,row=A.experimental_table(inst,69);table=table.padded(64)
  core=R.Eng1Core(slots=1,n_modes=64);core.load_slot(0,table)
  strike=A.Strike(inst,slots=1)
  if inst=='piano':strike.rise,strike.width,strike.gap=1,2,478
  natural=np.zeros(n,dtype=np.int64);modal=np.zeros((n,table.n_modes),dtype=np.int64)
  # Keep gate held to isolate the modal decay; no ADSR, body or PCM clipping.
  for i in range(n):
   on=i>=lead
   excitation=strike.step([201],[on],[i==lead],[False])
   v,yn=core.step(excitation,[i==lead],active_modes=48)
   natural[i]=v[0];modal[i]=yn[0,:table.n_modes]
  radius=np.sqrt(table.a2[:table.n_modes]/(1<<24));tau=-1/(48000*np.log(radius))
  d=np.load(ROOT/f'FFT_results/params/{inst}_partials.npz',allow_pickle=True)
  idx=np.flatnonzero((d['midi']==69)&(d['dynamic']=='forte'))[0];mask=d['note_id']==idx
  kk=d['k'][mask];fks=d['f_k'][mask];a0=d['a0'][mask];gamma=d['gamma'][mask];gamma2=d['gamma2'][mask]
  fund=int(np.argmin(abs(kk-1)));f=float(fks[fund]);window=4800
  times=np.arange(.05,2.45,.05);amp=[]
  for t in times:
   at=onset+round(t*48000);seg=x[at:at+window]
   if len(seg)!=window:amp.append(float('nan'));continue
   win=np.hanning(window);n0=np.arange(window)
   amp.append(float(2*abs(np.sum(seg*win*np.exp(-2j*np.pi*f*n0/48000)))/sum(win)))
  amp=np.array(amp);fits={}
  for name,lo,hi in [('early',.05,.25),('late',.5,1.5)]:
   use=(times>=lo)&(times<=hi)&np.isfinite(amp)&(amp>0)
   coef=np.polyfit(times[use],np.log(amp[use]),1)
   fits[name]=dict(gamma=float(-coef[0]),tau_s=float(-1/coef[0]) if coef[0]<0 else None)
  source_env=smooth_rms(y);natural_float=natural.astype(float)/(1<<24);synth_env=smooth_rms(natural_float)
  native_stats=[]
  for name,z in [('recording',y),('model_natural',natural_float)]:
   ref=float(np.sqrt(np.mean(z[lead+960:lead+3360]**2)))
   bins={}
   for t in [.1,.25,.5,1,2]:
    seg=z[lead+round(t*48000):lead+round((t+.05)*48000)]
    bins[str(t)]=float(20*np.log10(max(np.sqrt(np.mean(seg**2)),1e-20)/max(ref,1e-20)))
   gain=min(.1/max(np.sqrt(np.mean(z[lead:lead+24000]**2)),1e-20),.88/max(abs(z).max(),1e-20))
   out=z*gain;out[-960:]*=np.linspace(1,0,960)
   file=inst+'_'+name+'_A4.wav';sf.write(OUT/file,np.repeat(out[:,None],2,axis=1),48000,subtype='PCM_24')
   a,rate=sf.read(OUT/file,always_2d=True);assert a.shape==(n,2) and rate==48000 and np.isfinite(a).all() and abs(a).max()<.9
   native_stats.append(dict(name=name,file=file,gain_db=20*np.log10(gain),relative_rms_after_onset_db=bins))
  record=dict(instrument=inst,source_path=str(path.relative_to(ROOT)),source_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
              source_onset_sample=onset,source_channel=0,model_modes=table.n_modes,model_tau_s=tau.tolist(),
              fundamental_source_gamma=float(gamma[fund]),fundamental_source_gamma2=float(gamma2[fund]),
              independently_measured_fundamental=fits,files=native_stats,experimental_table_source=row,
              conditions='synthetic no ADSR/no body, held gate; source unfiltered channel0; per-clip constant gain')
  np.savez_compressed(OUT/(inst+'_analysis.npz'),recording=y,model=natural,source_envelope=source_env,model_envelope=synth_env,
                      fundamental_times=times,fundamental_amplitude=amp)
  records.append(record)
  print(inst,'modes',table.n_modes,'tau',np.quantile(tau,[0,.5,1]),'fund source gamma',gamma[fund],gamma2[fund],'independent fits',fits,flush=True)
 os.environ.setdefault('MPLCONFIGDIR',str(ROOT/'build/a_source_audit/mpl'))
 import matplotlib;matplotlib.use('Agg');import matplotlib.pyplot as plt
 fig,axes=plt.subplots(1,2,figsize=(11,4))
 for ax,r in zip(axes,records):
  d=np.load(OUT/(r['instrument']+'_analysis.npz'));lead=5760;t=(np.arange(len(d['recording']))-lead)/48000
  for name,key in [('recording','source_envelope'),('model: no ADSR/body','model_envelope')]:
   e=d[key];ref=max(float(np.max(e[lead:lead+4800])),1e-20)
   ax.plot(t[::240],20*np.log10(np.maximum(e[::240]/ref,1e-8)),label=name)
  ax.set(xlim=(0,2.5),ylim=(-90,5),xlabel='Time from onset (s)',ylabel='RMS relative to onset peak (dB)',title=r['instrument']+' A4 natural tail');ax.legend(fontsize=8);ax.grid(alpha=.2)
 fig.tight_layout();fig.savefig(OUT/'natural_tails.png',dpi=160)
 (OUT/'results.json').write_text(json.dumps(dict(records=records,production_rtl_modified=False,not_a_new_default=True,
  source_hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(__file__),ROOT/'python/modal_sim/params.py',ROOT/'python/modal_sim/eng1_audition.py']}),indent=2)+'\n')
 print('PASS source and natural-tail clips validated',flush=True)
if __name__=='__main__':main()
