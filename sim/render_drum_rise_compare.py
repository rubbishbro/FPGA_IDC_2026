#!/usr/bin/env python3
"""Three full-kit auditions changing RISE_SH only; one common gain."""
from pathlib import Path
import sys,json,argparse
from concurrent.futures import ProcessPoolExecutor,as_completed
import numpy as np
import soundfile as sf
ROOT=Path(__file__).resolve().parents[1];sys.path[:0]=[str(ROOT/'sim'),str(ROOT/'python_monotor/modal_sim')]
from render_drum_excitation_compare import render,Q,FS,N
from eng1_audition import Strike
OUT=ROOT/'build/drum_rise_compare'
def variant(config):
 rise,width=config
 base=ROOT/'build/drum_full_compare';m=json.loads((base/'report.json').read_text());u=np.array([int(s,16) for s in (base/'coefficients.mem').read_text().split()],dtype=np.uint32).reshape(6,64,7)
 exc=Strike('guitar',1);exc.rise=rise;exc.width=width;exc.gap=0;exc.pulses=0
 drive=np.array([int(exc.step([204],[True],[n==0],[False])[0]) for n in range(N)],dtype=np.int64)
 fade=np.ones(N);fade[-2400:]=np.linspace(1,0,2400)**2;audio=[];rows=[]
 for i,row in enumerate(m['drums']):
  co=u[i].astype(np.int64);co[:48]=u[i,:48].view(np.int32).astype(np.int64)
  raw,stats=render(co,row['modal_count'],drive);y=raw/Q*row['reference_balance']*(2022/4096)*fade
  audio.extend([y,np.zeros(FS)]);rows.append(dict(drum=row['drum'],start_s=i*4,stats=stats,peak=float(max(abs(y)))))
 return rise,np.concatenate(audio),dict(rise_sh=rise,pw_len=width,drive_peak_q24=int(max(drive)),drive_first_q24=int(drive[1]),rows=rows)
def main():
 global OUT
 parser=argparse.ArgumentParser();parser.add_argument('--fixed-peak',action='store_true');args=parser.parse_args()
 if args.fixed_peak:OUT=ROOT/'build/drum_rise_fixed_peak'
 OUT.mkdir(parents=True,exist_ok=True);arrays={};rows={}
 with ProcessPoolExecutor(max_workers=3) as p:
  for f in as_completed([p.submit(variant,(r,(1<<r) if args.fixed_peak else 32)) for r in [5,4,3]]):
   r,a,meta=f.result();arrays[r]=a;rows[r]=meta;print('rendered RISE_SH',r,flush=True)
 gain=min(1.,.88/max(float(max(abs(a))) for a in arrays.values()))
 if args.fixed_peak:
  gain=json.loads((ROOT/'build/drum_rise_compare/report.json').read_text())['shared_listening_gain']
  assert len({v['drive_peak_q24'] for v in rows.values()})==1
 for r,a in arrays.items():
  assert np.isfinite(a).all();sf.write(OUT/f'rise_sh_{r}.wav',a*gain,FS,subtype='PCM_24')
 report=dict(fs=FS,seconds=24,only_changed_parameter=('RISE_SH and matching PW_LEN for same peak' if args.fixed_peak else 'RISE_SH'),fixed_peak=args.fixed_peak,fixed=dict(pw_len=('2**RISE_SH' if args.fixed_peak else 32),gap_len=0,n_pulse=0,level=204,trim_q12=2022,envelope='bypass',tail_fade_ms=50),shared_listening_gain=gain,independent_normalization=False,variants=rows,scope='integer Python model of current excitation_gen and ENG1; production settings unchanged')
 (OUT/'report.json').write_text(json.dumps(report,indent=2));print('PASS common_gain',gain)
if __name__=='__main__':main()
