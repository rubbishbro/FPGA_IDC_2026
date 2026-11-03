#!/usr/bin/env python3
"""Full-force calibration of six accepted drums with current selected excitation.
Build-only results; caller decides whether to apply the resulting common trim.
"""
from pathlib import Path
import sys,json,re,hashlib,math
import numpy as np
ROOT=Path(__file__).resolve().parents[1];sys.path[:0]=[str(ROOT/'sim'),str(ROOT/'python/modal_sim')]
from eng1_audition import Strike
from drum_coefficients import DRUM_EXCITATION
from render_drum_excitation_compare import render,N
from calibrate_reference_gains import metrics
OUT=ROOT/'build/drum_current_excitation_gain'
def main():
 OUT.mkdir(parents=True,exist_ok=True);base=ROOT/'build/drum_full_compare';m=json.loads((base/'report.json').read_text());u=np.array([int(v,16) for v in (base/'coefficients.mem').read_text().split()],dtype=np.uint32).reshape(6,64,7)
 cfg=DRUM_EXCITATION;s=Strike('guitar',1);s.rise=cfg['rise_sh'];s.width=cfg['pw_len'];s.gap=cfg['gap_len'];s.pulses=cfg['n_pulse']
 drive=np.array([int(s.step([255],[True],[n==0],[False])[0]) for n in range(N)],dtype=np.int64)
 assert cfg==dict(shift=16,rise_sh=3,pw_len=8,gap_len=0,n_pulse=0)
 assert int(max(drive))==255<<16 and np.count_nonzero(drive)==8
 results={}
 for i,row in enumerate(m['drums']):
  co=u[i].astype(np.int64);co[:48]=u[i,:48].view(np.int32).astype(np.int64);raw,stats=render(co,row['modal_count'],drive)
  balanced=raw.astype(float)*row['reference_balance'];r=metrics(balanced);r.update(stats,reference_balance=row['reference_balance']);results[row['drum']]=r;np.save(OUT/(row['drum']+'_raw_q24.npy'),balanced)
  print(row['drum'],json.dumps(r),flush=True)
 key=max(results,key=lambda k:results[k]['max20ms_rms']);q=results[key]['gain_q12']
 old=int(re.search(r"INST_DRUMS:\s*return 16'sd(\d+)",(ROOT/'rtl/router/pkg/router_pkg.sv').read_text())[1])
 report=dict(fs=48000,full_scale_q24=1.,target_dbfs=-12,force=255,window='sliding960 samples,hop1',excitation=cfg,drive_peak_q24=int(max(drive)),results=results,common_reference=key,common_gain_q12=q,common_gain_linear=results[key]['gain_linear'],old_gain_q12=old,delta_db_vs_previous=20*math.log10(q/old),existing_gain_removed=True,metadata='piece balance retained; no body/reverb/modulation/listening normalization',source_hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [ROOT/'rtl/router/routers/exc_router.sv',ROOT/'python/modal_sim/drum_coefficients.py',base/'coefficients.mem']})
 (OUT/'results.json').write_text(json.dumps(report,indent=2));print('COMMON',key,q,report['delta_db_vs_previous'],flush=True)
if __name__=='__main__':main()
