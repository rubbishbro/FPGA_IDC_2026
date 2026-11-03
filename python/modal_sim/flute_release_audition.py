#!/usr/bin/env python3
"""Rerender selected E4 soft weights with a longer release; production unchanged."""
from pathlib import Path
from dataclasses import replace
import json
import numpy as np
import soundfile as sf
from scipy.ndimage import uniform_filter1d
import eng1_rtl as E
import router_eng1 as R
import flute_envelope_audition as A
import flute_air_envelope as F

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'FFT_results/sim/eng1/flute_long_diagnosis_20261103'
FS=48000
RELEASE_STEP=211269  # 85% of Q1.31 over approximately 180ms.


def main():
    data=json.loads((OUT/'E4_soft_weights_coefficients.json').read_text())
    bank=E.ResourceBank.build('flute',F.NOTES)
    row=bank.notes[64]
    coeff=row.coeffs.padded(64)
    g=np.array([c['G'] for c in data['coefficients']],dtype=np.int64)
    assert np.array_equal(coeff.a1,[c['a1'] for c in data['coefficients']])
    assert np.array_equal(coeff.a2,[c['a2'] for c in data['coefficients']])
    notes=dict(bank.notes)
    notes[64]=replace(row,coeffs=replace(coeff,G=g))
    synth=E.Eng1Synth('flute',note_map=F.NOTES,resources=E.ResourceBank('flute',notes),stereo=False,reverb='NONE')
    synth.envelope=E.Envelope([A.A]*4,[RELEASE_STEP]*4,sustain_level=A.S,decay_step=A.D)
    n=round(2.1*FS);on=round(.12*FS);off=round(1.67*FS)
    raw=np.empty(n,dtype=np.int64)
    rails=0
    for i in range(n):
        if i==on:synth.note_on(64,100)
        if i==off:synth.note_off(0)
        f=synth.step();raw[i]=f.out
        rails+=int(np.count_nonzero((synth.core.y1==R.Y_MAX)|(synth.core.y1==R.Y_MIN)))
        if i and i%FS==0:print(f'release180 {i//FS}/2.1s',flush=True)
    old=np.load(OUT/'raw_traces.npz')['soft_weights']
    assert np.array_equal(raw[:off],old[:off])
    assert rails==0 and not np.any(raw[-round(.2*FS):])
    # Exact fixed playback gain from the previous soft_weights file.
    metrics=json.loads((OUT/'results.json').read_text())['metrics']['soft_weights']
    window=slice(round(.57*FS),round(1.17*FS))
    rms=lambda x:float(np.sqrt(np.mean(np.asarray(x,dtype=float)[window]**2)))
    gain=10**(metrics['steady_rms_dbfs']/20)/rms(old)
    z=raw.astype(float)*gain
    sf.write(OUT/'soft_weights_release180.wav',np.repeat(z[:,None],2,axis=1),FS,subtype='PCM_24')
    check,sr=sf.read(OUT/'soft_weights_release180.wav',always_2d=True)
    assert sr==FS and np.isfinite(check).all() and abs(check).max()<1
    env=np.sqrt(np.maximum(uniform_filter1d(raw.astype(float)**2,size=480),0))
    ref=np.sqrt(np.mean(raw[round(1.35*FS):round(1.6*FS)].astype(float)**2))
    crossings={str(t):float(np.flatnonzero(env[off:]<=ref*t)[0]*1000/FS) for t in [.5,.1,.01]}
    nz=np.flatnonzero(raw[off:]!=0)
    # Tail comparison: 370ms of stable tone before note-off, then the release.
    previous,_=sf.read(OUT/'soft_weights.wav',always_2d=True)
    old_tail=np.zeros((round(.8*FS),2))
    begin=round(1.3*FS)
    old_tail[:len(previous)-begin]=previous[begin:]
    new_tail=check[begin:round(2.1*FS)].copy()
    # Fade in only the cut boundaries; release tails remain untouched.
    for tail in [old_tail,new_tail]:tail[:240]*=np.linspace(0,1,240)[:,None]
    sf.write(OUT/'release100_then_180.wav',np.concatenate([old_tail,np.zeros((round(.4*FS),2)),new_tail]),FS,subtype='PCM_24')
    report=dict(R_STEP=RELEASE_STEP,release_from_sustain_ms=A.S/RELEASE_STEP*1000/FS,
        actual_level_crossing_ms_after_note_off=crossings,last_nonzero_ms=(nz[-1]+1)*1000/FS,
        note_off_seconds=1.67,pre_note_off_bit_exact=True,state_rails=rails,
        method='Selected E4 soft G weights; only R_STEP changed,100ms to180ms. Same steady playback gain. No noise/body/reverb changes. Production RTL unchanged.')
    (OUT/'release180.json').write_text(json.dumps(report,indent=2)+'\n')
    np.save(OUT/'soft_weights_release180_raw.npy',raw)
    longer=dict(data)
    longer['envelope']=dict(data['envelope'],R_STEP=RELEASE_STEP)
    longer['description']='E4 soft_weights with180ms release; isolated audition, not production deployed.'
    (OUT/'E4_soft_weights_release180_coefficients.json').write_text(json.dumps(longer,indent=2)+'\n')
    print(json.dumps(report,indent=2),flush=True)
    print('PASS pre-release parity, tail silence, no rails or clipping',flush=True)

if __name__=='__main__':main()
