#!/usr/bin/env python3
"""One-second driven/free modal stress at the production Q24 state scale.

This checks temporal behaviour in addition to frozen-pole inequalities. It does
not assert stability for arbitrary switching laws or replace board listening.
"""
from pathlib import Path
import sys,json,math
import numpy as np
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'python_monotor/modal_sim'))
import router_eng1 as R
import pitch_linear as P

def main():
    out=ROOT/'build/eng1_pitch';out.mkdir(parents=True,exist_ok=True)
    tables=[R.build_b_table(name,note) for name in ['flute','trumpet','cello','violin'] for note in [36,48,60,72]]
    fields=[P.modulation_words(t) for t in tables]
    base=np.array([[r[1] for r in rows] for rows in fields],dtype=np.int64)
    slope=np.array([[r[5] for r in rows] for rows in fields],dtype=np.int64)
    low=np.array([[r[0] for r in rows] for rows in fields],dtype=np.int64)
    high=-low
    aa2=np.array([np.pad(t.a2,(0,64-t.n_modes)) for t in tables],dtype=np.int64)
    gain=np.array([np.pad(t.G,(0,64-t.n_modes)) for t in tables],dtype=np.int64)
    periods=[t.drive_period for t in tables]
    results=[]
    for driven in [True,False]:
        y1=np.zeros((16,64),dtype=np.int64);y2=y1.copy()
        if not driven:
            r=np.sqrt(aa2/(1<<24));th=np.arccos(np.clip(-base/(1<<24)/np.maximum(2*r,1e-15),-1,1))
            mask=aa2>0
            y1=np.where(mask,np.round((1<<22)/np.maximum(r,1e-15)*np.cos(th)),0).astype(np.int64)
            y2=np.where(mask,np.round((1<<22)/np.maximum(r*r,1e-15)*np.cos(2*th)),0).astype(np.int64)
        phase=[0]*16;previous=[0,0];deltas=[0,0];lfo=0;a1=base.copy();peak=0;saturation=0
        for n in range(48000):
            if n%96==0:
                lfo=(lfo+P.LFO_STEP)&0xffffff
                bend=[16383,0] if n<24000 else [8192,8192]
                wheel=127 if n<40000 else 0
                for s in range(2):previous[s],deltas[s]=P.trajectory(bend[s],wheel,lfo,previous[s])
                delta=np.array([deltas[s%2] for s in range(16)],dtype=np.int64)
                a1=np.clip(base+((slope*delta[:,None]+(1<<21))>>22),low,high)
            x=np.zeros(16,dtype=np.int64)
            if driven:
                for s,T in enumerate(periods):
                    phase[s],pulse=P.advance_phase(phase[s],T,deltas[s%2],n==0)
                    if pulse:x[s]=255<<16
            acc=gain*x[:,None]-a1*y1-aa2*y2
            raw=(acc+(1<<23))>>24
            saturation+=int(np.count_nonzero((raw<-(1<<31)) | (raw>=(1<<31))))
            y2,y1=y1,np.clip(raw,-(1<<31),(1<<31)-1)
            peak=max(peak,int(np.max(np.abs(y1))))
        assert saturation==0, ('feedback saturation',driven,saturation)
        if not driven:assert peak<2*(1<<22), ('free mode growth',peak)
        results.append(dict(driven=driven,samples=48000,slots=16,feedback_saturations=saturation,max_mode_abs_q24=peak,max_mode_abs=peak/(1<<24)))
    (out/'dynamics.json').write_text(json.dumps(results,indent=2)+'\n')
    print('PASS pitch dynamics',results)
if __name__=='__main__':main()
