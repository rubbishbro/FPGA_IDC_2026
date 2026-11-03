#!/usr/bin/env python3
"""Gentler E4 onset: 240ms attack, same soft weights and180ms release."""
from pathlib import Path
from dataclasses import replace
import json
import numpy as np
import soundfile as sf
import eng1_rtl as E
import router_eng1 as R
import flute_air_envelope as F

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'FFT_results/sim/eng1/flute_long_diagnosis_20261103'
FS=48000
ATTACK_STEP=186414


def main():
    data=json.loads((OUT/'E4_soft_weights_release180_coefficients.json').read_text())
    params=dict(data['envelope'],A_STEP=ATTACK_STEP)
    bank=E.ResourceBank.build('flute',F.NOTES)
    row=bank.notes[64];table=row.coeffs.padded(64)
    assert np.array_equal(table.a1,[c['a1'] for c in data['coefficients']])
    assert np.array_equal(table.a2,[c['a2'] for c in data['coefficients']])
    notes=dict(bank.notes)
    notes[64]=replace(row,coeffs=replace(table,G=np.array([c['G'] for c in data['coefficients']],dtype=np.int64)))
    synth=E.Eng1Synth('flute',note_map=F.NOTES,resources=E.ResourceBank('flute',notes),stereo=False,reverb='NONE')
    synth.envelope=E.Envelope([params['A_STEP']]*4,[params['R_STEP']]*4,
                             sustain_level=params['S_LEVEL'],decay_step=params['D_STEP'])
    n=round(2.1*FS);on=round(.12*FS);off=round(1.67*FS)
    old=np.load(OUT/'soft_weights_release180_raw.npy')
    raw=np.empty(n,dtype=np.int64);rails=0
    for i in range(n):
        if i==on:synth.note_on(64,100)
        if i==off:synth.note_off(0)
        f=synth.step();raw[i]=f.out
        rails+=int(np.count_nonzero((synth.core.y1==R.Y_MAX)|(synth.core.y1==R.Y_MIN)))
        if i and i%FS==0:print(f'attack240 {i//FS}/2.1s',flush=True)
    assert np.array_equal(raw[round(.55*FS):],old[round(.55*FS):])
    assert rails==0 and not np.any(raw[:on]) and not np.any(raw[-round(.2*FS):])
    old_wav,sr=sf.read(OUT/'soft_weights_release180.wav',always_2d=True)
    window=slice(round(.57*FS),round(1.17*FS))
    rms=lambda x:float(np.sqrt(np.mean(np.asarray(x,dtype=float)**2)))
    gain=rms(old_wav[window,0])/rms(old[window])
    z=raw.astype(float)*gain
    path=OUT/'soft_weights_attack240_release180.wav'
    sf.write(path,np.repeat(z[:,None],2,axis=1),FS,subtype='PCM_24')
    check,fs=sf.read(path,always_2d=True)
    assert fs==sr==FS and np.isfinite(check).all() and abs(check).max()<1
    assert abs(rms(check[window,0])-rms(old_wav[window,0]))<1e-7
    sf.write(OUT/'attack180_then_240.wav',np.concatenate([old_wav,np.zeros((round(.4*FS),2)),check]),FS,subtype='PCM_24')
    early=slice(on+round(.02*FS),on+round(.1*FS))
    report=dict(parameters=params,attack_ms=0x7fffffff/ATTACK_STEP*1000/FS,
        early_20_100ms_rms_change_db=float(20*np.log10(rms(raw[early])/rms(old[early]))),
        steady_and_release_bit_exact_after_seconds=.55,state_rails=rails,
        method='Only A_STEP changed180ms to240ms; original soft G/poles,85% sustain,120ms decay and180ms release retained. Same playback gain. Production RTL unchanged.')
    (OUT/'attack240_release180.json').write_text(json.dumps(report,indent=2)+'\n')
    data['envelope']=params
    data['description']='E4 soft_weights,240ms attack,85% sustain,180ms release; audition only.'
    (OUT/'E4_soft_weights_attack240_release180_coefficients.json').write_text(json.dumps(data,indent=2)+'\n')
    np.save(OUT/'soft_weights_attack240_release180_raw.npy',raw)
    print(json.dumps(report,indent=2),flush=True)
    print('PASS lighter onset, exact steady/tail parity, silence, rail and peak checks',flush=True)

if __name__=='__main__':main()
