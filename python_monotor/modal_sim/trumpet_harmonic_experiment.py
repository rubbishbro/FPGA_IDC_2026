#!/usr/bin/env python3
"""No-added-noise trumpet tests: modal-order gain, onset gain, waveshaping.

Modal candidates run through the integer ENG1 core. Time-varying G and output
waveshaping are audition experiments, not implemented production controls.
"""
from dataclasses import replace
from pathlib import Path
import hashlib
import json
import math
import os
import numpy as np
import soundfile as sf
from scipy.signal import resample_poly, welch
import eng1_audition as A
import eng1_rtl as E
import router_eng1 as R
from sustain_engine import SustainPatch

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT/'python_monotor/results/sim/eng1/trumpet_harmonic_experiment'
BASE = ROOT/'python_monotor/results/sim/eng1/trumpet_body_experiment'
NOTES = (64,66,67,69,72,74,76,77)
FS = 48000


def rms(x): return float(np.sqrt(np.mean(np.asarray(x)**2)))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    bank = E.ResourceBank.build('trumpet', NOTES)
    patch = SustainPatch('trumpet')
    ramps = {}
    for m in NOTES:
        k, *_ = patch.modes(m)
        ramp = np.zeros(64)
        ramp[:len(k)] = np.clip((k.astype(float)-4)/6,0,1)
        ramps[m] = ramp
    sources = []
    for scene in ['phrase','single']:
        reference = np.load(BASE/f'baseline_{scene}.npy')
        n = len(reference)
        events = A.score() if scene=='phrase' else [dict(time=.12,midi=64,duration=1.5,velocity=100)]
        ons, offs = {}, {}
        for e in events:
            ons.setdefault(round(e['time']*FS),[]).append(e)
            offs.setdefault(round((e['time']+e['duration'])*FS),[]).append(e['midi'])
        synths = {}; outputs = {}
        for name, boost in [('baseline_check',0),('upper_6db',6),('upper_12db',12),('onset_12_to_6db',6)]:
            notes = {}
            for m,row in bank.notes.items():
                gains = np.floor(row.coeffs.G*10**(boost*ramps[m]/20)+.5).astype(np.int64)
                assert np.all((gains>=-(1<<25))&(gains<(1<<25)))
                co = R.Eng1Coeffs(gains,row.coeffs.a1.copy(),row.coeffs.a2.copy(),row.coeffs.n_modes)
                notes[m] = replace(row,coeffs=co)
            s = E.Eng1Synth('trumpet',note_map=NOTES,resources=E.ResourceBank('trumpet',notes),stereo=False)
            synths[name] = s
            outputs[name] = np.empty(n,dtype=np.int64)
        onset = np.full(8,-1000000,dtype=np.int64)
        dynamic = synths['onset_12_to_6db']
        original_g = np.stack([bank.notes[m].coeffs.G for m in NOTES])
        ramp = np.stack([ramps[m] for m in NOTES])
        zero_delta = np.zeros(8,dtype=np.int64)
        rails = {name:0 for name in synths}
        for i in range(n):
            for m in offs.get(i,[]):
                for s in synths.values(): s.note_off(NOTES.index(m))
            for e in ons.get(i,[]):
                onset[NOTES.index(e['midi'])] = i
                for s in synths.values(): s.note_on(e['midi'],e['velocity'])
            # A 30ms exponential transition in excitation gain of high modes.
            # Update every32 samples; each update is accepted before core.step.
            if i%32==0 or i in ons:
                db = 6+6*np.exp(-np.maximum(i-onset,0)/(FS*.030))
                dynamic.core.G[:] = np.floor(original_g*10**(db[:,None]*ramp/20)+.5).astype(np.int64)
                assert np.max(abs(dynamic.core.G)) < 1<<25
            for name,s in synths.items():
                frame = s.step(committed_delta=zero_delta)
                outputs[name][i] = frame.out
                s.trigger[:] = False
                rails[name] += int(np.count_nonzero((s.core.y1==R.Y_MAX)|(s.core.y1==R.Y_MIN)))
            if i and i%(FS*3)==0: print(scene,f'{i/FS:.0f}/{n/FS:.2f}s',flush=True)
        assert np.array_equal(outputs.pop('baseline_check'),reference), '8-slot baseline must match prior16-slot raw exactly'
        assert not any(rails.values()), rails
        outputs['baseline'] = reference
        base = reference.astype(float)/(1<<24)/8
        active = slice(5760,466560 if scene=='phrase' else 77760)
        # Independent nonlinear control, oversampled4x before anti-alias filtering.
        scale = max(float(np.max(abs(base[active]))),1e-30)
        highrate = resample_poly(base/scale,4,1)
        shaped = np.tanh(2.5*highrate)/math.tanh(2.5)
        nonlinear = resample_poly(shaped,1,4)[:n]*scale
        # Restrict resampling tails to the original sample activity.
        nonlinear[reference==0] = 0
        signals = {name:raw.astype(float)/(1<<24)/8 for name,raw in outputs.items()}
        signals['nonlinear'] = nonlinear
        target = min(.075,*[.88*rms(y[active])/max(abs(y).max(),1e-30) for y in signals.values()])
        rows = {}
        for name,y in signals.items():
            gain = target/rms(y[active]); z = y*gain; z[-960:]*=np.linspace(1,0,960)
            path = OUT/f'{name}_{scene}.wav'
            sf.write(path,np.repeat(z[:,None],2,axis=1),FS,subtype='PCM_24')
            check,fs = sf.read(path,always_2d=True)
            assert fs==FS and check.shape==(n,2) and np.isfinite(check).all() and abs(check).max()<=.880001
            assert abs(20*math.log10(rms(check[active,0])/target))<.00002
            assert not np.any(check[:4800])
            row = dict(file=path.name,frames=n,gain_db=20*math.log10(gain),active_rms_dbfs=20*math.log10(rms(check[active,0])),
                       peak_dbfs=20*math.log10(abs(check).max()),added_noise=False,
                       state_rail_hits=rails.get(name,0) if name!='nonlinear' else None,
                       sha256=hashlib.sha256(path.read_bytes()).hexdigest())
            if scene=='single':
                f,p = welch(y[38400:67200],FS,nperseg=16384)
                f0 = FS/bank.notes[64].period
                row['power_fraction_order_8_plus'] = float(p[f>=7.5*f0].sum()/p.sum())
                amps=[]
                for k in range(1,25):
                    amps.append(np.sqrt(p[abs(f-k*f0)<min(.4*f0,max(12,.015*k*f0))].sum()))
                a = np.array(amps);row['harmonic_relative_db']=(20*np.log10(np.maximum(a/a.max(),1e-15))).tolist()
            rows[name] = row
            np.save(OUT/f'{name}_{scene}.npy',y)
        sources.append(dict(scene=scene,active_samples=[active.start,active.stop],baseline_raw_bit_exact=True,variants=rows))
        print('PASS',scene,'integer baseline exact, no state rails, matched listening RMS',flush=True)
    summary=dict(sample_rate=FS,scenes=sources,noise_added=False,
        modal_gain='k<=4 unchanged; dB gain ramps linearly with harmonic order4..10, then holds at+6/+12dB. a1/a2 and original envelope unchanged.',
        onset='Same+6dB sustain gain; starts+12dB, extra6dB falls exponentially with30ms time constant. G updates32-sample cadence and note-on.',
        nonlinear='tanh(2.5*x)/tanh(2.5), peak-normalized input,4x oversampling. Output processing control, not a physical lip model or RTL implementation.',
        normalization='Constant RMS-matched gain per scene, peak<=.88, no output compressor;20ms file-end fade.',
        sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in
            [Path(__file__),ROOT/'python_monotor/modal_sim/eng1_rtl.py',ROOT/'python_monotor/results/params/trumpet_sustain.npz',BASE/'baseline_phrase.npy',BASE/'baseline_single.npy']})
    (OUT/'results.json').write_text(json.dumps(summary,indent=2)+'\n')
    os.environ.setdefault('MPLCONFIGDIR',str(OUT/'mpl'))
    import matplotlib;matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    fig,ax=plt.subplots(figsize=(9,4))
    for name,row in sources[1]['variants'].items():
        ax.plot(range(1,25),row['harmonic_relative_db'],'.-',label=name)
    ax.set(xlabel='Harmonic order',ylabel='Relative amplitude(dB)',ylim=(-60,3),title='E4, no added noise: steady harmonics')
    ax.legend();ax.grid(alpha=.2);fig.tight_layout();fig.savefig(OUT/'harmonics.png',dpi=150);plt.close(fig)
    lines=['# Trumpet harmonic-only experiment','','No added noise. Modal G candidates use the integer ENG1 core; time-varying G and nonlinear postprocessing are experimental.',
           '',summary['modal_gain'],'',summary['onset'],'',summary['nonlinear'],'',summary['normalization'],'',
           '| Candidate | Phrase | Single |','|---|---|---|']
    for name in sources[1]['variants']:lines.append(f'| {name} | [play]({name}_phrase.wav) | [play]({name}_single.wav) |')
    lines+=['','[Results](results.json)','','![Steady harmonic shape](harmonics.png)','','Run: `python python_monotor/modal_sim/trumpet_harmonic_experiment.py`']
    (OUT/'README.md').write_text('\n'.join(lines)+'\n')
    print('PASS all harmonic-only candidates',flush=True)


if __name__=='__main__': main()
