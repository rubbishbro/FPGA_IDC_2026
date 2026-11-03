#!/usr/bin/env python3
"""Same accepted drum coefficients: one-shot vs current excitation_gen strike.
No production RTL changes. Same force, balance, output trim and listening gain.
"""
from pathlib import Path
import json,sys,math
import numpy as np
import soundfile as sf
ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'python/modal_sim'),str(ROOT/'sim')]
import router_eng1 as R
from eng1_audition import Strike
from render_drum_full_compare import sat
OUT=ROOT/'build/drum_excitation_compare';Q=1<<24;FS=48000;N=144000

def render(co,nm,drive):
 core=R.Eng1Core(slots=1,n_modes=64);core.load_slot(0,R.Eng1Coeffs(co[:48,0],co[:48,1],co[:48,2],nm))
 states=[[0,0,0,0] for _ in range(2)];out=np.empty(N,dtype=np.int64);rail=0;noise_rail=0;env_initial=[]
 for n in range(N):
  x=int(drive[n]);y,ym=core.step([x],[False],active_modes=48);total=int(y[0]);rail+=int(np.count_nonzero((ym==-(1<<31))|(ym==(1<<31)-1)))
  for k in range(2):
   seed,initial,decay,al,ah,gain,_=map(int,co[48+2*k]);s,env,lo,hi=states[k]
   if not seed:continue
   if s==0:
    if x<=0:continue
    s=seed;env=(initial*min(x,Q)+(Q>>1))>>24;lo=hi=0;env_initial.append(dict(branch=k,sample=n,envelope_q24=env))
   white=Q if s&1 else -Q
   lo=sat(lo+(((white-lo)*al+(Q>>1))>>24));hi=sat(hi+(((white-hi)*ah+(Q>>1))>>24))
   shaped=sat(((hi-lo)*env+(Q>>1))>>24);raw=(shaped*gain+32768)>>16;noise_rail+=int(raw!=sat(raw));total+=sat(raw)
   states[k]=[(s>>1)^(0x80200003 if s&1 else 0),(env*decay+(Q>>1))>>24,lo,hi]
  out[n]=total
 return out,dict(modal_rail_hits=rail,noise_saturations=noise_rail,noise_initialization=env_initial)

def main():
 OUT.mkdir(parents=True,exist_ok=True);base=ROOT/'build/drum_full_compare';meta=json.loads((base/'report.json').read_text());u=np.array([int(s,16) for s in (base/'coefficients.mem').read_text().split()],dtype=np.uint32).reshape(6,64,7)
 impulse=Strike('guitar',1);impulse.rise=0;impulse.width=1;impulse.gap=0;impulse.pulses=0
 one=np.array([int(impulse.step([204],[True],[n==0],[False])[0]) for n in range(N)],dtype=np.int64)
 strike=Strike('guitar',1);strike.rise=5;strike.width=32;strike.gap=0;strike.pulses=0
 shaped=np.array([int(strike.step([204],[True],[n==0],[False])[0]) for n in range(N)],dtype=np.int64)
 np.save(OUT/'one_shot_drive.npy',one);np.save(OUT/'excitation_gen_drive.npy',shaped)
 assert np.count_nonzero(one)==1 and np.count_nonzero(shaped)==32
 fade=np.ones(N);fade[-2400:]=np.linspace(1,0,2400)**2;audio={'one_shot':[],'excitation_gen':[]};rows=[]
 for i,row in enumerate(meta['drums']):
  co=u[i].astype(np.int64);co[:48]=u[i,:48].view(np.int32).astype(np.int64);record=dict(drum=row['drum'],start_s=i*4,variants={})
  for name,drive in [('one_shot',one),('excitation_gen',shaped)]:
   raw,stats=render(co,row['modal_count'],drive)
   y=raw/Q*row['reference_balance']*(2022/4096)*fade
   audio[name].extend([y,np.zeros(FS)]);record['variants'][name]=dict(stats,peak=float(max(abs(y))),rms=float(np.sqrt(np.mean(y*y))))
  rows.append(record);print('rendered',row['drum'],json.dumps(record['variants']),flush=True)
 arrays={k:np.concatenate(v) for k,v in audio.items()};gain=min(1.,.88/max(max(abs(x)) for x in arrays.values()))
 for name,y in arrays.items():sf.write(OUT/(name+'.wav'),y*gain,FS,subtype='PCM_24')
 report=dict(fs=FS,seconds=24,force_level=204,one_shot_amplitude_q24=int(one[1]),excitation_gen=dict(rise=5,pw=32,gap=0,n_pulse=0,nonzero_samples=32),drum_trim_q12=2022,shared_listening_gain=gain,same_coefficients=True,envelope='bypass; common final50ms fade for clip boundary',rows=rows,scope='integer Python model; existing excitation_gen shape checked separately; not a deployed board drum path')
 (OUT/'report.json').write_text(json.dumps(report,indent=2));print('PASS audio',OUT,'shared_gain',gain)
if __name__=='__main__':main()
