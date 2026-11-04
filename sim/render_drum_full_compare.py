#!/usr/bin/env python3
"""Six drums: current Python standard vs accepted ENG1 impulse/IIR method.

Accepted coefficient method; drum bank not yet deployed. Generates actual ENG1 stimulus and full expected output
for sim/run_drum_audio_rtl.py. Same standard-reference piece balance and one
shared listening gain; no separate normalization of the two versions.
"""
from pathlib import Path
import sys,json,math,zlib,hashlib,subprocess
import numpy as np
import soundfile as sf
ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'python_monotor/modal_sim'),str(ROOT/'python_monotor/fft_analysis')]
import drumkit as DK
import percussion as PC
import router_eng1 as R
from eng1_bc import build_c_table
OUT=ROOT/'build/drum_full_compare';FS=48000;Q=1<<24
KEYS=['kick','snare','tom','hat','ride','crash'];SECONDS=3;N=FS*SECONDS;VELOCITY=.8

def sat(v):return max(-(1<<31),min((1<<31)-1,int(v)))

from drum_coefficients import build_coefficients as coefficients


def integer_render(table,co):
 core=R.Eng1Core(slots=1,n_modes=64);core.load_slot(0,table)
 states=[[0,0,0,0] for _ in range(2)];out=np.zeros(N,dtype=np.int64);clips=0
 for n in range(N):
  x=round(VELOCITY*Q) if n==0 else 0
  ym,_=core.step([x],[False],active_modes=48);total=int(ym[0])
  for k in range(2):
   seed,initial,decay,al,ah,gain,_=map(int,co[48+2*k]);s,env,lo,hi=states[k]
   if not seed:continue
   if s==0:
    if x<=0:continue
    s=seed;env=(initial*min(x,Q)+(Q>>1))>>24;lo=hi=0
   white=Q if s&1 else -Q
   lo=sat(lo+(((white-lo)*al+(Q>>1))>>24));hi=sat(hi+(((white-hi)*ah+(Q>>1))>>24))
   raw=((hi-lo)*env+(Q>>1))>>24;shaped=sat(raw);raw2=(shaped*gain+32768)>>16
   clips+=int(raw!=shaped)+int(raw2!=sat(raw2));total+=sat(raw2)
   states[k]=[(s>>1)^(0x80200003 if s&1 else 0),(env*decay+(Q>>1))>>24,lo,hi]
  out[n]=total
 return out,clips

def main():
 OUT.mkdir(parents=True,exist_ok=True)
 if not (ROOT/'build/drum_filter_fit/results.json').exists():
  subprocess.run([sys.executable,str(ROOT/'sim/fit_drum_noise.py')],cwd=ROOT,check=True)
 fits=json.loads((ROOT/'build/drum_filter_fit/results.json').read_text())['rows'];kit=PC.load_kit(str(ROOT/'python_monotor/results/params/drums.npz'))
 py=[];rt=[];allco=[];expected=[];rows=[];fade=np.ones(N);fade[-2400:]=np.linspace(1,0,2400)**2
 for key in KEYS:
  spec=kit[key];table,co,branches=coefficients(key,spec,fits)
  standard=DK.render_kit_hit(kit,key,SECONDS,VELOCITY,np.random.default_rng(zlib.crc32(key.encode())),1.,True)
  samples,clips=integer_render(table,co)
  balance=DK._piece_norm(kit,key,1.,3.)*DK.KIT_GAIN[key]
  actual=samples.astype(float)/Q*balance*fade
  py.extend([standard,np.zeros(FS)]);rt.extend([actual,np.zeros(FS)])
  allco.extend(co.ravel());expected.extend(samples)
  rows.append(dict(drum=key,start_s=4*len(rows),duration_s=3,modal_count=table.n_modes,reference_balance=balance,branches=branches,noise_saturations=clips))
  print('rendered',key,'noise_saturations',clips,flush=True)
 a=np.concatenate(py);b=np.concatenate(rt);gain=.88/max(np.max(abs(a)),np.max(abs(b)))
 sf.write(OUT/'python_standard.wav',a*gain,FS,subtype='PCM_24')
 sf.write(OUT/'rtl_model_preview.wav',b*gain,FS,subtype='PCM_24')
 (OUT/'coefficients.mem').write_text(''.join(f'{int(v)&0xffffffff:08x}\n' for v in allco))
 (OUT/'expected.mem').write_text(''.join(f'{int(v)&((1<<64)-1):016x}\n' for v in expected))
 report=dict(fs=FS,samples_per_drum=N,drums=rows,velocity=VELOCITY,shared_listening_gain=float(gain),
  standard='drumkit.render_kit_hit: original float modes + Gaussian noise/current257tap FIR',
  rtl='48 impulse-driven ABC + fitted single/two-LP LFSR branches, Q24/Q16; current ENG1 arithmetic; drum bank not deployed',
  shared_processing='same Python reference piece balance for both versions; same50ms end fade; 1s gaps; no body/reverb/polyphonic gain',
  source_hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(__file__),ROOT/'python_monotor/results/params/drums.npz',ROOT/'rtl/router/engines/eng1.sv',ROOT/'build/drum_filter_fit/results.json']})
 (OUT/'report.json').write_text(json.dumps(report,indent=2))
 print('PASS preview',OUT,flush=True)
if __name__=='__main__':main()
