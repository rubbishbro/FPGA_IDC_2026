#!/usr/bin/env python3
"""Offline trumpet texture sensitivity tests, separate from the ENG1 RTL model.

Noise and HF amplitude modulation are artificial diagnostic additions. Spectral
energy outside tracked harmonics also includes leakage/drift, not just air noise.
"""
from pathlib import Path
import hashlib
import json
import math
import os
import numpy as np
import soundfile as sf
from scipy.signal import butter, sosfilt, lfilter, stft, welch
import trumpet_diagnose as D

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT/'FFT_results/sim/eng1/trumpet_texture_probe'
BASE = ROOT/'FFT_results/sim/eng1/trumpet_body_experiment'
FS = 48000
SEED = 20261031
NAMES = ['baseline', 'noise_low', 'noise_high', 'harmonic_am', 'combined', 'static_brightness']


def rms(x):
    return float(np.sqrt(np.mean(np.asarray(x)**2)))


def analyze(x):
    f, t, z = stft(x, FS, nperseg=8192, noverlap=8192-256, boundary=None, padded=False)
    p = abs(z)**2
    candidates = np.flatnonzero((f>295)&(f<370))
    bins = candidates[np.argmax(p[candidates], axis=0)]
    logp = np.log(np.maximum(p, 1e-30))
    col = np.arange(len(t))
    left, mid, right = logp[bins-1, col], logp[bins, col], logp[bins+1, col]
    offset = np.clip(.5*(left-right)/(left-2*mid+right), -.5, .5)
    f0 = (bins+offset)*FS/8192
    valid = (f>=150)&(f<=10000)
    residual = {}
    ratio = None
    for width in [8, 16, 32]:
        mask = np.zeros(p.shape, bool)
        lo = np.zeros(len(t)); hi = lo.copy()
        for k in range(1, 31):
            # Width grows with harmonic order to allow small pitch tracking error.
            inside = abs(f[:, None]-k*f0[None, :]) <= np.maximum(width, .005*k*f0)[None, :]
            mask |= inside
            if k<=4: lo += np.sum(p*inside, axis=0)
            elif k<=20: hi += np.sum(p*inside, axis=0)
        residual[str(width)] = float(np.sum(p*valid[:, None]*~mask)/np.sum(p*valid[:, None]))
        if width==16:
            ratio = 10*np.log10(np.maximum(hi, 1e-30)/np.maximum(lo, 1e-30))
    # A short band-energy follower captures faster AM which the 170ms STFT
    # and narrow harmonic masks intentionally smooth/exclude.
    hp = sosfilt(butter(2, 1500, btype='highpass', fs=FS, output='sos'), x)
    lp = sosfilt(butter(2, [200,1300], btype='bandpass', fs=FS, output='sos'), x)
    window = max(1, round(8*FS/np.median(f0)))
    kernel = np.ones(window)/window
    eh = lfilter(kernel,[1.],hp**2); el = lfilter(kernel,[1.],lp**2)
    times = np.arange(round(.08*FS),len(x),240)
    fast = 10*np.log10(np.maximum(eh[times],1e-30)/np.maximum(el[times],1e-30))
    return dict(f0_median_hz=float(np.median(f0)), f0_5_95_hz=np.quantile(f0,[.05,.95]).tolist(),
                inter_harmonic_power_fraction_by_exclusion_hz=residual,
                high_k5_20_vs_low_k1_4_db_mean=float(np.mean(ratio)),
                high_low_ratio_std_db=float(np.std(ratio)),
                fast_highpass_vs_lowband_std_db=float(np.std(fast)),
                fast_follower_window_ms=window/48), (t, ratio, times/FS, fast)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    patch = D.SustainPatch('trumpet'); source = patch._pick(64, 'forte')
    source_path = ROOT/'music_resources/trumpet'/source['note']
    recording = D.C.load_audio(str(source_path), FS)
    on, off = D.S.note_region(recording, FS)
    # Three equal 0.6s recording windows versus one equal synthesis window.
    measurements = {}; traces = {}
    source_windows = []
    for fraction in [.3, .5, .7]:
        center = on+round((off-on)*fraction)
        start, end = center-14400, center+14400
        assert on <= start < end <= off
        name = f'recording_{fraction:.1f}'
        measurements[name], traces[name] = analyze(recording[start:end])
        measurements[name]['window_seconds'] = [start/FS, end/FS]
        source_windows.append((start, end))
    fir = patch.noise_fir(FS)
    if fir is None: fir = np.array([1.])
    np.save(OUT/'noise_fir.npy', fir)
    noise_sos = butter(2, [600, 10000], btype='bandpass', fs=FS, output='sos')
    hf_sos = butter(2, 1500, btype='highpass', fs=FS, output='sos')
    results = {name: dict(name=name) for name in NAMES}
    for scene in ['phrase', 'single']:
        raw = np.load(BASE/f'baseline_{scene}.npy')
        base = raw.astype(float)/(1 << 24)/8
        n = len(base); window = slice(5760, 466560 if scene=='phrase' else 77760)
        # Causal 10ms RMS follower. Exact-zero raw samples gate all additions.
        env = np.sqrt(np.maximum(lfilter(np.ones(480)/480, [1.], base**2), 0))
        active = raw!=0
        rng = np.random.default_rng(SEED+(scene=='single'))
        noise = lfilter(fir, [1.], rng.standard_normal(n))
        noise = sosfilt(noise_sos, noise)*env*active
        noise *= rms(base[window])/max(rms(noise[window]), 1e-30)
        time = np.arange(n)/FS
        mod = .15*(np.sin(2*np.pi*23*time)+.6*np.sin(2*np.pi*37*time+.7)+.4*np.sin(2*np.pi*61*time+1.3))/math.sqrt(.76)
        hf = sosfilt(hf_sos, base)*active
        low = noise*10**(-36/20); high = noise*10**(-30/20); movement = hf*mod
        additions = dict(baseline=np.zeros(n), noise_low=low, noise_high=high,
                         harmonic_am=movement, combined=high+movement, static_brightness=.3*hf)
        signals = {name: base+addition for name, addition in additions.items()}
        assert np.array_equal(signals['baseline'], base)
        target = min(.075, *[.88*rms(y[window])/max(abs(y).max(),1e-30) for y in signals.values()])
        for name, y in signals.items():
            addition = additions[name]
            assert np.count_nonzero(addition[~active])==0
            gain = target/max(rms(y[window]), 1e-30)
            output = y*gain; output[-960:] *= np.linspace(1,0,960)
            path = OUT/f'{name}_{scene}.wav'
            sf.write(path, np.repeat(output[:, None],2,axis=1), FS, subtype='PCM_24')
            read, fs = sf.read(path, always_2d=True)
            assert fs==FS and read.shape==(n,2) and np.isfinite(read).all() and abs(read).max()<.9
            assert abs(20*np.log10(rms(read[window,0])/target))<.001
            assert not np.any(read[~active])
            results[name][scene] = dict(file=path.name, frames=n, active_rms_dbfs=20*np.log10(rms(read[window,0])),
                peak_dbfs=20*np.log10(abs(read).max()), gain_db=20*np.log10(gain),
                before_gain_active_rms_dbfs=20*np.log10(rms(y[window])),
                addition_to_base_active_rms_db=None if name=='baseline' else 20*np.log10(rms(addition[window])/rms(base[window])),
                zero_input_output_nonzero_samples=int(np.count_nonzero(read[~active])),
                sha256=hashlib.sha256(path.read_bytes()).hexdigest())
            if scene=='single':
                measurements[name], traces[name] = analyze(y[38400:67200])
                measurements[name]['window_seconds'] = [.8,1.4]
    # A local reference excerpt, not pasted into generated phrases.
    start=max(0,on-5760); ref=np.zeros(115200);part=recording[start:start+len(ref)];ref[:len(part)]=part
    ref *= min(.075/max(rms(ref[5760:77760]),1e-30),.88/max(abs(ref).max(),1e-30))
    ref[-960:]*=np.linspace(1,0,960)
    sf.write(OUT/'recording_reference_E4.wav',np.repeat(ref[:,None],2,axis=1),FS,subtype='PCM_24')
    summary=dict(sample_rate=FS, seed=SEED, variants=list(results.values()), measurements=measurements,
        additions='Offline postprocessing of unchanged production baseline raw; not RTL output. Synthetic noise, not copied recording residual.',
        noise='Instrument-average stored residual-shape FIR plus 600..10000Hz bandpass; -36/-30dB active RMS relative to base; causal 10ms envelope; exact-zero gate.',
        harmonic_am='1500Hz highpass component with continuous 23/37/61Hz sinusoidal AM, nominal 15% RMS; no pitch change; artificial sensitivity test.',
        static_brightness='Add 0.3 times the same highpass component as a static spectral control.',
        residual_warning='Inter-harmonic energy includes window leakage, pitch drift, vibrato/AM sidebands. Not an estimate of true air-noise level or perceived roughness.',
        source_file=str(source_path.relative_to(ROOT)), source_on_off_seconds=[on/FS,off/FS],
        normalization='Matched active RMS per scene, common peak-safe target <=.88, constant gain, no compressor; terminal20ms fade.',
        hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in
                [Path(__file__),source_path,ROOT/'FFT_results/params/trumpet_sustain.npz',BASE/'baseline_single.npy',BASE/'baseline_phrase.npy']},
        deepseek='Original delegated task timed out after300s. This is the separate Codex fallback experiment. Read-only DeepSeek retry tracked separately.')
    (OUT/'results.json').write_text(json.dumps(summary,indent=2)+'\n')
    os.environ.setdefault('MPLCONFIGDIR',str(OUT/'mpl'))
    import matplotlib;matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    fig,axes=plt.subplots(1,3,figsize=(16,4))
    signals=[('recording',recording[slice(*source_windows[1])])]
    for name in ['baseline','noise_high','harmonic_am','combined']:
        x,fs=sf.read(OUT/f'{name}_single.wav');signals.append((name,x[38400:67200,0]))
    for name,x in signals:
        f,p=welch(x/max(rms(x),1e-30),FS,nperseg=8192)
        axes[0].semilogx(f[1:],10*np.log10(np.maximum(p[1:],1e-20)),label=name,alpha=.8)
    for name in ['recording_0.5','baseline','harmonic_am','combined']:
        t,v,tf,vf=traces[name];axes[1].plot(t,v,label=name)
        axes[2].plot(tf,vf-np.mean(vf),label=name)
    axes[0].set(xlim=(200,12000),ylim=(-100,-10),xlabel='Hz',ylabel='PSD after RMS matching (dB/Hz)',title='Reference and texture controls')
    axes[1].set(xlabel='Time inside 0.6s steady window (s)',ylabel='Harmonic power ratio (dB)',title='Harmonics5..20 / harmonics1..4')
    axes[2].set(xlabel='Time inside 0.6s steady window (s)',ylabel='HF/LF ratio minus mean (dB)',title='Fast band-energy follower (~24ms)')
    for ax in axes:ax.grid(alpha=.2);ax.legend(fontsize=8)
    fig.tight_layout();fig.savefig(OUT/'texture_comparison.png',dpi=150);plt.close(fig)
    lines=['# Trumpet texture sensitivity experiment','','Offline additions to production baseline. No production RTL or deployment resources changed.',
           '',summary['noise'],'',summary['harmonic_am'],'',summary['residual_warning'],'',summary['normalization'],'',
           '| Candidate | Phrase | E4 single |','|---|---|---|']
    for name in NAMES:lines.append(f'| {name} | [play]({name}_phrase.wav) | [play]({name}_single.wav) |')
    lines += ['', '[Recording reference](recording_reference_E4.wav)', '', '[Measurements and hashes](results.json)', '',
              '![Spectrum and time variation](texture_comparison.png)', '', 'Run: `python python/modal_sim/trumpet_texture_probe.py`']
    (OUT/'README.md').write_text('\n'.join(lines)+'\n')
    print('PASS12 candidate WAVs, reference, RMS/peak/silence checks',flush=True)
    for name in ['recording_0.3','recording_0.5','recording_0.7','baseline','noise_high','harmonic_am','combined']:
        print(name,json.dumps(measurements[name]),flush=True)


if __name__=='__main__':main()
