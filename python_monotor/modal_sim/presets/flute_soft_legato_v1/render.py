#!/usr/bin/env python3
"""Reproduce frozen flute_soft_legato_v1 without rerunning timbre extraction."""
from pathlib import Path
import argparse
import hashlib
import json
import sys
import numpy as np
import soundfile as sf

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[3]
sys.path.insert(0,str(ROOT/'python_monotor/modal_sim'))
import eng1_rtl as E
import router_eng1 as R
import pitch_linear as P


def blend(a,b,w):
    if w>=256:return int(b)
    delta=int(b)-int(a)
    return R.wrap_signed(int(a)+sum(delta>>(8-bit) for bit in range(8) if (w>>bit)&1),32)


class FrozenExcitation(E.Excitation):
    def reset(self):
        super().reset()
        self.age=np.zeros(self.slots,dtype=np.int64)
        self.lp1=np.zeros(self.slots,dtype=np.int64)
        self.lp2=np.zeros(self.slots,dtype=np.int64)
    def step(self,gate,level,trigger,clear,delta):
        start=(gate&~self.previous_gate)|trigger
        pulse=super().step(gate,level,trigger,clear,delta)
        out=np.zeros(self.slots,dtype=np.int64)
        for s in range(self.slots):
            if clear[s] or not gate[s]:
                self.age[s]=self.lp1[s]=self.lp2[s]=0
                continue
            if start[s]:self.age[s]=self.lp1[s]=self.lp2[s]=0
            old1=int(self.lp1[s]);old2=int(self.lp2[s])
            self.lp1[s]=R.wrap_signed(old1+((int(pulse[s])-old1)>>5),32)
            self.lp2[s]=R.wrap_signed(old2+((old1-old2)>>5),32)
            w=min(256,max(0,int(self.age[s])-1536)>>4)
            out[s]=blend(int(self.lp2[s]),int(pulse[s]),w)
            self.age[s]=min(5632,int(self.age[s])+1)
        return out


def resources(preset):
    entries=json.loads((HERE/'note_resources.json').read_text())
    notes={}
    for item in entries:
        table=R.Eng1Coeffs(G=np.array(item['G'],dtype=np.int64),
            a1=np.array(item['a1'],dtype=np.int64),a2=np.array(item['a2'],dtype=np.int64),
            n_modes=48,label=f"flute_soft_legato_v1:{item['midi']}")
        words=np.asarray(P.modulation_words(table),dtype=np.int64)
        notes[item['midi']]=E.NoteResource(item['midi'],table,item['period'],
            preset['envelope']['A_STEP'],preset['envelope']['R_STEP'],words)
    return E.ResourceBank('flute',notes)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,default=ROOT/'python_monotor/results/sim/eng1/flute_soft_legato_v1/reproduced.wav')
    args=parser.parse_args()
    preset=json.loads((HERE/'preset.json').read_text())
    for name,digest in preset['pinned_model_sha256'].items():
        assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest,f'Model changed: {name}; keep v1 immutable or create v2.'
    for name,digest in preset['asset_sha256'].items():
        assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest,f'Frozen asset changed: {name}'
    fixture=np.load(ROOT/preset['reference']['fixture'])
    gates,pressure,triggers=(fixture[k] for k in ['gates','pressure','retrigger'])
    notes=tuple(preset['validated_midi_notes']);params=preset['envelope']
    synth=E.Eng1Synth('flute',note_map=notes,resources=resources(preset),stereo=False,reverb='NONE')
    synth.envelope=E.Envelope([params['A_STEP']]*len(notes),[params['R_STEP']]*len(notes),sustain_level=params['S_LEVEL'],decay_step=params['D_STEP'])
    synth.excitation=FrozenExcitation([r.period for r in synth.rows])
    ratios=P.ratio_table();delta=np.zeros(len(notes),dtype=np.int64)
    raw=np.empty(len(gates),dtype=np.int64);rails=0
    for i in range(len(gates)):
        if i%96==0:
            for s in range(len(notes)):
                if gates[i,s]:
                    diff=max(0,int(pressure[i,s])-102)
                    cents=(diff*40265472+104858)>>18
                    index,frac=divmod(cents+56320,256)
                    delta[s]=ratios[index]+(((ratios[index+1]-ratios[index])*frac+128)>>8)-(1<<24)
        frame=synth.step(gate=gates[i],level=pressure[i],retrigger=triggers[i],committed_delta=delta)
        raw[i]=frame.out
        rails+=int(np.count_nonzero((synth.core.y1==R.Y_MAX)|(synth.core.y1==R.Y_MIN)))
        if i and i%96000==0:print(f'frozen v1 {i/48000:.0f}/{len(raw)/48000:.2f}s',flush=True)
    assert rails==0
    digest=hashlib.sha256(raw.astype('<i8').tobytes()).hexdigest()
    assert digest==preset['reference']['raw_int64le_sha256'],'Frozen output mismatch'
    args.out.parent.mkdir(parents=True,exist_ok=True)
    wave=np.repeat((raw.astype(float)*preset['reference']['playback_gain'])[:,None],2,axis=1)
    sf.write(args.out,wave,48000,subtype='PCM_24')
    check,sr=sf.read(args.out,always_2d=True)
    reference,refsr=sf.read(ROOT/preset['reference']['audio'],always_2d=True)
    assert sr==refsr==48000 and np.array_equal(check,reference)
    assert np.isfinite(check).all() and abs(check).max()<1
    report=dict(preset='flute_soft_legato_v1',status='PASS',frames=len(raw),raw_sha256=digest,
                reference_pcm_bit_exact=True,state_rail_hits=rails)
    args.out.with_suffix('.json').write_text(json.dumps(report,indent=2)+'\n')
    print('PASS frozen reference: raw and PCM bit exact',flush=True)

if __name__=='__main__':main()
