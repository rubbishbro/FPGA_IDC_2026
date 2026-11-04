#!/usr/bin/env python3
"""E4 causal controls: current spectrum, pulse width, ring-up and soft-source weights.

Audition-only current ENG1 integer rerenders; no production RTL/resources changes.
"""
from pathlib import Path
from dataclasses import replace
import os
import sys
import json
import hashlib
import numpy as np
import soundfile as sf
from scipy.signal import welch
import eng1_rtl as E
import router_eng1 as R
import flute_envelope_audition as A
import flute_air_envelope as F
import pitch_linear as P
from sustain_engine import SustainPatch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'fft_analysis'))
import core as C
import sustain as S

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT/'python_monotor/results/sim/eng1/flute_long_diagnosis_20261103'
FS = 48000
N = round(1.9*FS)
ON, OFF = round(.12*FS), round(1.67*FS)
WINDOW = slice(ON+round(.45*FS), ON+round(1.05*FS))


def harmonic_amplitudes(y, f0, minimum=18):
    f,p = welch(y, FS, nperseg=min(16384,len(y)))
    return np.array([np.sqrt(p[abs(f-k*f0)<min(.4*f0,max(minimum,.02*k*f0))].sum())
                     for k in range(1,49)])


def db_relative(a):
    return 20*np.log10(np.maximum(a/max(a[0],1e-30),1e-12))


def source(dynamic):
    path = ROOT/f'music_resources/flute/flute_E4_15_{dynamic}_normal.mp3'
    x = C.load_audio(str(path))
    on,off = S.note_region(x,FS)
    steady = x[on+round(.45*FS):on+round(1.05*FS)]
    assert len(steady)==round(.6*FS) and on+round(1.05*FS)<off
    f,p = welch(steady,FS,nperseg=16384)
    use = (f>310)&(f<345)
    f0 = float(f[use][np.argmax(p[use])])
    aligned = np.zeros(N)
    # Shift by integer samples only; no resynthesis or pitch correction.
    start = ON-on
    dest = max(0,start)
    src = max(0,-start)
    count = min(len(x)-src,N-dest)
    aligned[dest:dest+count] = x[src:src+count]
    return aligned, f0, dict(file=str(path.relative_to(ROOT)),onset_sample=on,
        end_sample=off,f0_hz=f0,alignment='10%-of-peak smoothed RMS crossing aligned to model note-on; not physical blowing onset',
        sha256=hashlib.sha256(path.read_bytes()).hexdigest())


class Pulse2(E.Excitation):
    """Two-sample pulse at half height; same charge; shifts/adds only."""
    def reset(self):
        super().reset()
        self.pending = np.zeros(self.slots,dtype=np.int64)
    def step(self,gate,level,trigger,clear,delta):
        pulse = super().step(gate,level,trigger,clear,delta)
        self.pending[clear|~gate|trigger] = 0
        out = (pulse >> 1)+self.pending
        self.pending = pulse >> 1
        return out


def render(name, bank, pulse2=False):
    synth = E.Eng1Synth('flute', note_map=F.NOTES, resources=bank,stereo=False,reverb='NONE')
    synth.envelope = E.Envelope([A.A]*4,[A.RELEASE]*4,sustain_level=A.S,decay_step=A.D)
    if pulse2: synth.excitation = Pulse2([r.period for r in synth.rows])
    y = np.empty(N,dtype=np.int64)
    rails = 0
    for i in range(N):
        if i==ON: synth.note_on(64,100)
        if i==OFF: synth.note_off(0)
        frame = synth.step()
        y[i] = frame.out
        rails += int(np.count_nonzero((synth.core.y1==R.Y_MAX)|(synth.core.y1==R.Y_MIN)))
        if i and i%FS==0: print(name,f'{i/FS:.0f}/1.9s',flush=True)
    assert rails==0 and not np.any(y[-round(.1*FS):])
    print('rendered',name,flush=True)
    return y.astype(float)


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    bank = E.ResourceBank.build('flute',F.NOTES)
    # Rerender baseline as well: an exact cache parity test catches scope drift.
    baseline = render('baseline',bank)
    cached = np.load(ROOT/'python_monotor/results/sim/eng1/flute_envelope_85_20261103/candidate_trace.npz')['raw'][:N]
    assert np.array_equal(baseline,cached)
    forte,fsrc,forte_info = source('forte')
    soft,fsoft,soft_info = source('mezzo-piano')
    fdrive = FS/bank.notes[64].period
    hb = harmonic_amplitudes(baseline[WINDOW],fdrive)
    hf = harmonic_amplitudes(forte[WINDOW],fsrc)
    hs = harmonic_amplitudes(soft[WINDOW],fsoft)
    # Controlled modal weighting: same poles, period, envelope and excitation.
    # Measure relative-to-fundamental targets; cap ill-conditioned high-order bands.
    correction = (hs/max(hs[0],1e-30))/np.maximum(hb/max(hb[0],1e-30),1e-12)
    correction = np.clip(correction,.02,4)
    kk,*_ = SustainPatch('flute').modes(64,'forte')
    row = bank.notes[64]
    table = row.coeffs.padded(64)
    g = table.G.copy()
    for i,k in enumerate(kk[:48]):
        g[i] = round(int(g[i])*correction[int(k)-1])
    weighted = replace(table,G=g,label='E4 measured mezzo-piano weights, original poles')
    assert np.array_equal(weighted.a1,table.a1) and np.array_equal(weighted.a2,table.a2)
    assert np.all((g >= -(1<<25)) & (g < (1<<25)))
    # Keep pitch metadata: only G changes; pitch words contain pole coefficients.
    soft_notes = dict(bank.notes)
    soft_notes[64] = replace(row,coeffs=weighted)
    soft_bank = E.ResourceBank('flute',soft_notes)
    # Gamma control changes ring-up while recalibrating G to keep extracted
    # per-mode steady amplitudes. It is not an excitation-only control.
    fast_table = R.build_b_table('flute',64,'forte',gamma_scale=4).padded(64)
    fast_notes = dict(bank.notes)
    fast_notes[64] = replace(row,coeffs=fast_table,
                            pitch_words=np.asarray(P.modulation_words(fast_table),dtype=np.int64))
    fast_bank = E.ResourceBank('flute',fast_notes)
    signals = dict(source_forte=forte,source_mezzo_piano=soft,baseline=baseline,
        pulse2=render('pulse2',bank,True),
        faster_ringup=render('faster_ringup',fast_bank),
        soft_weights=render('soft_weights',soft_bank))
    fundamental = dict(source_forte=fsrc,source_mezzo_piano=fsoft,
                       **{k:fdrive for k in ['baseline','pulse2','faster_ringup','soft_weights']})
    rms = lambda x: float(np.sqrt(np.mean(x[WINDOW]**2)))
    target = min(.075,*[.88*rms(y)/max(abs(y).max(),1e-30) for y in signals.values()])
    metrics, listened, harmonic = {}, {}, {}
    for name,y in signals.items():
        gain = target/rms(y)
        z = y*gain
        # File boundary fade applies only to last 10ms, outside analysis windows.
        z[-480:] *= np.linspace(1,0,480)
        path = OUT/f'{name}.wav'
        sf.write(path,np.repeat(z[:,None],2,axis=1),FS,subtype='PCM_24')
        check, sr = sf.read(path,always_2d=True)
        assert sr==FS and np.isfinite(check).all() and abs(check).max()<=.880001
        assert abs(rms(check[:,0])-target)<1e-6
        listened[name] = check
        amp = harmonic_amplitudes(y[WINDOW],fundamental[name])
        h = db_relative(amp)
        harmonic[name] = h
        early = harmonic_amplitudes(y[ON+round(.04*FS):ON+round(.16*FS)],fundamental[name])
        early_db = db_relative(early)
        env = S._envelope(y,FS)
        ref = rms(y)
        times = []
        for fraction in [.1,.9]:
            hits = np.flatnonzero(env[ON:ON+round(.45*FS)]>=fraction*ref)
            times.append(None if not len(hits) else float(hits[0]*1000/FS))
        metrics[name] = dict(file=path.name,steady_harmonics_db_relative_H1=h[:24].tolist(),
            early_40_160ms_harmonics_db_relative_H1=early_db[:12].tolist(),
            onset_10_90_ms=None if None in times else times[1]-times[0],
            peak_dbfs=float(20*np.log10(abs(check).max())),steady_rms_dbfs=float(20*np.log10(rms(check[:,0]))))
    errors = {}
    for name in ['baseline','pulse2','faster_ringup','soft_weights']:
        delta = harmonic[name]-harmonic['source_forte']
        errors[name] = dict(median_abs_H2_H8_db=float(np.median(abs(delta[1:8]))),
                            H4_relative_H1_db=float(harmonic[name][3]))
    soft_error = float(np.median(abs((harmonic['soft_weights']-harmonic['source_mezzo_piano'])[1:8])))
    sensitivity = {}
    for width in [12,25,40]:
        hreal = db_relative(harmonic_amplitudes(forte[WINDOW],fsrc,width))
        hmod = db_relative(harmonic_amplitudes(baseline[WINDOW],fdrive,width))
        sensitivity[str(width)] = float(np.median(abs((hmod-hreal)[1:8])))
    # Standalone steady clips remove onset as a listening confound.
    names = ['source_forte','baseline','source_mezzo_piano','soft_weights']
    clip = slice(ON+round(.35*FS),ON+round(1.15*FS))
    clips = []
    for name in names:
        z = listened[name][clip].copy()
        z[:240] *= np.linspace(0,1,240)[:,None]
        z[-240:] *= np.linspace(1,0,240)[:,None]
        sf.write(OUT/f'{name}_steady.wav',z,FS,subtype='PCM_24')
        clips += [z,np.zeros((round(.35*FS),2))]
    sf.write(OUT/'steady_comparison.wav',np.concatenate(clips),FS,subtype='PCM_24')
    os.environ.setdefault('MPLCONFIGDIR',str(OUT/'mpl'))
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    fig,axes = plt.subplots(1,3,figsize=(16,4.5))
    for name in ['source_forte','source_mezzo_piano','baseline','soft_weights']:
        axes[0].plot(range(1,13),harmonic[name][:12],'.-',label=name)
    axes[0].set(xlabel='Harmonic number',ylabel='dB relative to H1',ylim=(-55,15),title='Steady spectrum (0.45..1.05s after onset)')
    for name in ['baseline','pulse2','faster_ringup']:
        axes[1].plot(range(1,13),harmonic[name][:12]-harmonic['baseline'][:12],'.-',label=name)
    axes[1].set(xlabel='Harmonic number',ylabel='dB relative to baseline',title='Controls: steady spectral change')
    for name in ['source_forte','source_mezzo_piano','baseline','pulse2','faster_ringup']:
        env = S._envelope(signals[name],FS)/rms(signals[name])
        axes[2].plot(np.arange(round(.45*FS))/48,env[ON:ON+round(.45*FS)],label=name)
    axes[2].set(xlabel='Time from aligned onset (ms)',ylabel='RMS / settled RMS',title='Onset: envelope plus modal ring-up')
    for ax in axes:
        ax.grid(alpha=.2);ax.legend(fontsize=7)
    fig.tight_layout();fig.savefig(OUT/'diagnosis.png',dpi=160);plt.close(fig)
    summary = dict(note='E4',sample_rate=FS,source_forte=forte_info,source_soft=soft_info,
        steady_window_after_onset_seconds=[.45,1.05], metrics=metrics,errors_vs_forte=errors,
        soft_weight_median_abs_H2_H8_error_vs_soft_source_db=soft_error,
        band_width_sensitivity_median_abs_H2_H8_db=sensitivity,weight_multipliers=correction.tolist(),
        cached_baseline_bit_exact=True, gamma_scale=4,
        controls=dict(pulse2='Same tables, same ADSR; split each pulse over two samples at half height, area conserved. Not a test of all possible flute excitations.',
          faster_ringup='Same extracted steady modal amplitude targets, gamma x4; G recalibrated. Changes poles, not only excitation.',
          soft_weights='Same production poles/period/excitation/ADSR; G scaled by measured mezzo-piano/production harmonic ratios, relative to H1; factors clamped .02..4. No new module.'),
        limitations=['One E4 note, not all registers.','Harmonic output alone cannot uniquely identify G and excitation: they multiply in steady state.',
          'Recording has room/breath and frequency modulation; source residual is not calibrated airflow noise.',
          '10%-RMS onset alignment and broadband onset times are not physical blowing-onset measurements.',
          'Soft-weight target derived and evaluated on same source: sensitivity audition, not held-out validation.',
          'Sample-frame model and experimental resources only; production RTL unchanged; no full RTL cycle/PnR verification.'],
        source_hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
             for p in [Path(__file__),Path(E.__file__),Path(R.__file__),ROOT/'python_monotor/results/params/flute_sustain.npz']})
    (OUT/'results.json').write_text(json.dumps(summary,indent=2)+'\n')
    np.savez_compressed(OUT/'raw_traces.npz',**signals)
    print(json.dumps(dict(errors_vs_forte=errors,sensitivity=sensitivity,
        H4_forte=float(harmonic['source_forte'][3]),H4_soft=float(harmonic['source_mezzo_piano'][3]),
        onsets={k:v['onset_10_90_ms'] for k,v in metrics.items()}),indent=2),flush=True)
    print('PASS baseline cache parity, no modal rails, finite/peak/tail and steady loudness checks',flush=True)

if __name__=='__main__':main()
