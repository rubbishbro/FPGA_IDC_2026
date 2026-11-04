#!/usr/bin/env python3
"""MIDI70 matrix-reference vs muted ABC audition; shared frontend and gain.

Offline audio-frame model, not a board/RTL simulation. Reference uses the
original 64 ENG0 matrices; ABC uses the production converter's 48 selected
records. Both use the piano ABC strike, ADSR and body, reverb NONE. The original
ABC conversion failed, so the reference is not a runnable 'old ABC' version.
"""
from pathlib import Path
import argparse,json,sys
import numpy as np
import soundfile as sf
from scipy.signal import lfilter,sosfilt
ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'rtl/router/tools'),str(ROOT/'python_monotor/modal_sim')]
import matrix_resources as M
import performance_resources as P
import router_eng1 as R
import eng1_rtl as E
import eng1_audition as A

def render(out,midi=70):
 out=Path(out);out.mkdir(parents=True,exist_ok=True)
 fs=48000;n=fs*5;on=int(.15*fs);off=int(2.15*fs)
 table,meta=M.piano_abc(midi);P.abc_record(table)
 strike=A.Strike('piano',1);strike.rise=2;strike.width=4;strike.gap=476
 env=E.Envelope([16777216],[21845],sustain_level=536870912,decay_step=1048576)
 core=R.Eng1Core(slots=1,n_modes=64);core.load_slot(0,table)
 x=np.zeros(n);envelope=np.zeros(n);abc=np.zeros(n);silent=set(meta['muted_selected_modes'])
 # Even nonzero stale state must vanish at the first computed silent record.
 for mode in silent:core.y1[0,mode]=1234567;core.y2[0,mode]=-7654321
 for i in range(n):
  gate=on<=i<off;trigger=i==on
  drive=int(strike.step([255],[gate],[trigger],[False])[0])
  old=int(env.level[0]);env.step([gate],[trigger],[False])
  envelope[i]=0 if trigger else old/(1<<31)
  x[i]=drive/(1<<24)
  y,yn=core.step([drive],[trigger],active_modes=48)
  if silent:assert all(yn[0,k]==0 for k in silent)
  abc[i]=int(y[0])/(1<<24)*envelope[i]
 data,_=M.matrix_note('piano',midi);words=np.frombuffer(data,dtype='>i4').reshape(64,16)
 reference=np.zeros(n)
 for w in words:
  c=np.array([int(v)/(1<<q) for v,q in zip(w[:7],M.CO_Q)])
  mat=c[:4].reshape(2,2);tr=np.trace(mat);det=np.linalg.det(mat);b=c[4:6];v=np.array([c[6],0.])
  reference+=lfilter([0.,float(v@b),float(v@(mat-np.eye(2)*tr)@b)],[1.,-tr,det],x)
 reference*=envelope
 sos=np.array([[*row[:3],1<<27,*row[3:]] for row in P.PIANO_BODY],dtype=float)/(1<<27)
 reference=sosfilt(sos,reference);abc=sosfilt(sos,abc)
 assert np.isfinite(reference).all() and np.isfinite(abc).all()
 peak=max(float(max(abs(reference))),float(max(abs(abc))));gain=.85/max(peak,1e-30)
 for name,y in [('A_eng0_reference',reference),('B_eng1_muted',abc)]:sf.write(out/(name+'.wav'),y*gain,fs,subtype='PCM_24')
 sf.write(out/'AB_compare.wav',np.concatenate([reference*gain,np.zeros(fs),abc*gain]),fs,subtype='PCM_24')
 report=dict(midi=midi,sample_rate=fs,duration_each_s=5,order='A ENG0 reference; 1s gap; B ENG1 muted',
  frontend='same piano ABC strike, full level255, gate2s, ADSR, piano ABC body, no reverb',
  shared_gain=gain,independent_normalization=False,reference='64 original ENG0 matrix modes, floating point',
  candidate='48 selected ABC records, integer ENG1 recurrence',metadata=meta,
  metrics={name:dict(peak=float(max(abs(y))),rms=float(np.sqrt(np.mean(y*y)))) for name,y in [('reference',reference),('muted',abc)]})
 (out/'report.json').write_text(json.dumps(report,indent=2))
 print(json.dumps(report,ensure_ascii=False),flush=True)
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--out',type=Path,default=ROOT/'build/piano_midi70_muted');p.add_argument('--midi',type=int,default=70);a=p.parse_args();render(a.out,a.midi)
