#!/usr/bin/env python3
"""Check calibrated levels and fixed-gain/count-gain chord fixtures at headroom 3.

Uses raw post-body traces produced by calibrate_performance_gain.py. This is a
linear body measurement, not a substitute for the integer router regression.
"""
from pathlib import Path
import json,math,sys
import numpy as np
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'python/modal_sim'))
import eng1_rtl as E
def smooth(count):
    g=4096;out=np.empty(len(count))
    for i,n in enumerate(count):
        target=g if n==0 else round(4096/math.sqrt(n))
        if target<g:g-=max(1,(g-target)>>3)
        elif target>g:g+=max(1,(target-g)>>12)
        out[i]=g/4096
    return out
def main():
    d=ROOT/'rtl/router/tools/performance';m=json.loads((d/'resources.json').read_text());meta=json.loads((d/'gain.json').read_text())
    rng=np.random.default_rng(11012026);report={}
    for name,row in meta['instruments'].items():
        raw=np.load(ROOT/f'build/performance_gain_calibration/{name}_raw_q24.npy')/(1<<27)
        q=np.array([row['note_gain_q12'][str(n)] for n in m['note_map']]);audio=raw*(q/4096)
        profiles=sorted((r for r in m['entries'] if r['name']==name),key=lambda r:r['slot'])
        cfg=m['frontends'][name]
        if name=='trumpet':env=E.Envelope([r['a_step'] for r in profiles],[r['r_step'] for r in profiles])
        else:env=E.Envelope([cfg['a_step']]*16,[cfg['r_step']]*16,sustain_level=cfg['s_level'],decay_step=cfg['d_step'])
        active=np.zeros(raw.shape,dtype=bool)
        for i in range(len(raw)):
            old=env.level.copy();level=env.step(np.full(16,i<28000),np.zeros(16,dtype=bool),np.zeros(16,dtype=bool))
            if name in ('piano','guitar','piano_abc','guitar_abc'):level=old
            active[i]=(level>0)&~env.dead
        cases=[]
        for n in (1,2,4,8,16):
            for trial in range(12):
                selected=rng.choice(16,n,replace=False);starts=np.zeros(n,dtype=int) if trial<6 else rng.integers(0,4000,n)
                size=len(audio)+int(max(starts));mix=np.zeros(size);count=np.zeros(size,dtype=int)
                for slot,start in zip(selected,starts):
                    mix[start:start+len(audio)]+=audio[:,slot];count[start:start+len(audio)]+=active[:,slot]
                y=mix*smooth(count);cases.append(dict(voices=n,staggered=trial>=6,peak_dbfs=20*math.log10(max(float(abs(y).max()),1e-30)),clipped=int(np.count_nonzero(abs(y)>=1))))
        report[name]=dict(calibrated_max20ms_rms_dbfs=row['calibrated_median_max20ms_rms_dbfs'],
                         single_note_peak_dbfs=row['calibrated_single_note_peak_dbfs'],
                         worst_peak_dbfs=max(c['peak_dbfs'] for c in cases),clipped_samples=sum(c['clipped'] for c in cases),cases=cases)
        print(name,report[name]['calibrated_max20ms_rms_dbfs'],report[name]['worst_peak_dbfs'],report[name]['clipped_samples'])
    out=ROOT/'build/performance_gain_calibration/stress.json';out.write_text(json.dumps(report,indent=2)+'\n')
    if any(r['clipped_samples'] for r in report.values()):raise SystemExit('FAIL chord fixture clipping; adjust calibration margin')
    print('PASS 360 chord fixtures, shared headroom3, center unity, no listening normalization')
if __name__=='__main__':main()
