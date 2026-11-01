#!/usr/bin/env python3
"""Audition-only trumpet body EQ versus envelope and modal ring-up controls.

Runs sequentially (no multiprocessing sockets required). Uses current integer
ENG1 and body models; writes candidates to a separate experiment directory.
"""
from pathlib import Path
import hashlib
import json
import math
import os
import numpy as np
import soundfile as sf
from scipy.signal import sosfreqz, sosfilt, welch
import eng1_rtl as E
import router_eng1 as R
import trumpet_diagnose as D

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'FFT_results/sim/eng1/trumpet_body_experiment'
FS = 48000


def eq(kind, hz, db, q=.8):
    """RBJ high shelf (slope=1) or peaking EQ, normalized SOS."""
    a = 10 ** (db / 40)
    w = 2 * math.pi * hz / FS
    c, s = math.cos(w), math.sin(w)
    if kind == 'shelf':
        alpha = s / 2 * math.sqrt(2)
        v = 2 * math.sqrt(a) * alpha
        b = [a*((a+1)+(a-1)*c+v), -2*a*((a-1)+(a+1)*c), a*((a+1)+(a-1)*c-v)]
        d = [(a+1)-(a-1)*c+v, 2*((a-1)-(a+1)*c), (a+1)-(a-1)*c-v]
    else:
        alpha = s / (2*q)
        b = [1+alpha*a, -2*c, 1-alpha*a]
        d = [1+alpha/a, -2*c, 1-alpha/a]
    row = np.array([*b, *d]) / d[0]
    return row


def body_rows(sos):
    rows = [[int(np.floor(v*(1 << 27)+.5)) for v in row[[0, 1, 2, 4, 5]]] for row in sos]
    return rows + [[1 << 27, 0, 0, 0, 0]] * (5-len(rows))


def filtered(raw, rows):
    body = R.BodyFilter(coeffs=rows)
    y = np.fromiter((body.step(int(v))[0] for v in raw), dtype=np.int64, count=len(raw))
    assert body.sat_total == 0
    return y


def plot_results():
    os.environ.setdefault('MPLCONFIGDIR', str(OUT/'mpl'))
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    summary = json.loads((OUT/'results.json').read_text())
    for r in summary['variants']:
        if 'body_coeffs_q4_27' in r:
            sos = np.array([[b0, b1, b2, 1 << 27, a1, a2]
                            for b0, b1, b2, a1, a2 in r['body_coeffs_q4_27']], float)/(1 << 27)
            x = np.load(OUT/'baseline_single.npy').astype(float)
            y = np.load(OUT/f'{r["name"]}_single.npy').astype(float)
            ideal = sosfilt(sos, x)
            error = float(np.sqrt(np.mean((y-ideal)**2))/np.sqrt(np.mean(ideal**2)))
            assert error < 1e-5
            r['integer_body_vs_quantized_float_relative_rms_error'] = error
    fig, axes = plt.subplots(1, 3, figsize=(15, 4))
    for name in ['body_shelf', 'body_presence']:
        d = np.load(OUT/f'{name}_response.npz')
        axes[0].semilogx(d['hz'][1:], d['db'][1:], label=name)
    axes[0].axhline(0, color='gray', linestyle='--', label='production passthrough')
    axes[0].set(xlim=(100, 16000), ylim=(-1, 7), xlabel='Frequency (Hz)', ylabel='Gain (dB)', title='Body sensitivity controls')
    period = D.bank_for(1).notes[64].period
    for r in summary['variants']:
        name = r['name']
        y = np.load(OUT/f'{name}_single.npy').astype(float)
        if name in ['baseline', 'tongue_adsr', 'faster_ringup', 'tongue_fast_ringup']:
            env = D.S._envelope(y, FS)
            env /= max(np.median(env[38400:67200]), 1e-20)
            axes[1].plot(np.arange(19200)/48, env[5760:24960], label=name)
        bands = D.bands(y[38400:67200], FS/period)
        axes[2].plot(range(1, 25), 20*np.log10(np.maximum(bands, 1e-7)), '.-', label=name, alpha=.8)
    axes[1].set(xlabel='Time after note-on (ms)', ylabel='RMS / settled RMS', ylim=(0, 4), title='ADSR and modal ring-up')
    axes[2].set(xlabel='Harmonic number', ylabel='Relative amplitude (dB)', ylim=(-60, 3), title='E4 steady harmonic shape')
    for ax in axes:
        ax.grid(alpha=.2); ax.legend(fontsize=7)
    fig.tight_layout(); fig.savefig(OUT/'comparison.png', dpi=150); plt.close(fig)
    original = ROOT/'FFT_results/sim/eng1/mystery_of_love/native/mystery_of_love_trumpet_eng1.wav'
    if original.exists():
        x, fs = sf.read(original, dtype='int16', always_2d=True)
        raw = np.load(OUT/'baseline_phrase.npy')
        expected = np.fromiter((E.pcm16(int(v)*2896*64, 3, 18) for v in raw), dtype=np.int16, count=len(raw))
        assert fs==FS and np.array_equal(x[:, 0], expected) and np.array_equal(x[:, 1], expected)
        summary['baseline_matches_previous_native_pcm_bit_exact'] = True
    summary['source_hashes'][str(Path(__file__).relative_to(ROOT))] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    (OUT/'results.json').write_text(json.dumps(summary, indent=2)+'\n')
    print('PASS plots and prior baseline PCM comparison', flush=True)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    D.OUT = OUT
    # Each candidate changes just one factor, plus the explicit interaction.
    names = ['baseline', 'tongue_adsr', 'faster_ringup', 'tongue_fast_ringup']
    results = [D.run_variant(n) for n in names]
    rows = R.body_coeffs('trumpet')
    assert rows == [[1 << 27, 0, 0, 0, 0]] * 5
    for scene in ['phrase', 'single']:
        raw = np.load(OUT/f'baseline_{scene}.npy')
        assert np.array_equal(raw, filtered(raw, rows)), 'body passthrough must be bit exact'
    eqs = {
        'body_shelf': ('shelf', 1500, 6),
        'body_presence': ('peak', 2000, 6),
    }
    for name, (kind, hz, db) in eqs.items():
        sos = np.array([eq(kind, hz, db)])
        coeffs = body_rows(sos)
        quant_sos = np.array([[b0, b1, b2, 1 << 27, a1, a2] for b0, b1, b2, a1, a2 in coeffs], dtype=float)/(1 << 27)
        assert max(abs(np.roots(quant_sos[0, 3:]))) < 1
        freq, response = sosfreqz(quant_sos, worN=4096, fs=FS)
        np.savez(OUT/f'{name}_response.npz', hz=freq, db=20*np.log10(np.maximum(abs(response), 1e-15)))
        for scene in ['phrase', 'single']:
            raw = np.load(OUT/f'baseline_{scene}.npy')
            np.save(OUT/f'{name}_{scene}.npy', filtered(raw, coeffs))
        results.append(dict(name=name, body_kind=kind, hz=hz, boost_db=db, q=.8 if kind=='peak' else None,
                            body_coeffs_q4_27=coeffs, body_saturations=0))
    # Match body/ADSR variants in active RMS with one common peak-safe target.
    for scene in ['phrase', 'single']:
        signals = {r['name']: np.load(OUT/f'{r["name"]}_{scene}.npy').astype(float)/(1 << 24)/8 for r in results}
        window = slice(5760, 466560 if scene=='phrase' else 77760)
        rms = {n: float(np.sqrt(np.mean(y[window]**2))) for n, y in signals.items()}
        target = min(.075, *[.88*rms[n]/max(abs(y).max(), 1e-20) for n, y in signals.items()])
        for r in results:
            n = r['name']; y = signals[n]; gain = target/rms[n]; z = y*gain
            z[-960:] *= np.linspace(1, 0, 960)
            path = OUT/f'{n}_{scene}.wav'
            sf.write(path, np.repeat(z[:, None], 2, axis=1), FS, subtype='PCM_24')
            check, fs = sf.read(path)
            assert fs==FS and np.isfinite(check).all() and abs(check).max()<.9
            measured_rms = float(np.sqrt(np.mean(check[window]**2)))
            assert abs(20*math.log10(measured_rms/target)) < .001
            native = np.array([E.pcm16(int(v), 3) for v in np.load(OUT/f'{n}_{scene}.npy')])
            r[scene] = dict(file=path.name, seconds=len(y)/FS, gain_db=20*math.log10(gain),
                            active_rms_dbfs=20*math.log10(measured_rms), peak_dbfs=20*math.log10(abs(check).max()),
                            native_mono_pcm_rail_samples=int(np.count_nonzero((native==32767)|(native==-32768))),
                            sha256=hashlib.sha256(path.read_bytes()).hexdigest())
            if scene=='single':
                steady = y[38400:67200]
                f, power = welch(steady, FS, nperseg=8192)
                r['steady_above_2khz_power_fraction'] = float(power[f>=2000].sum()/power.sum())
                early = np.sqrt(np.mean(y[5760:8160]**2))
                late = np.sqrt(np.mean(steady**2))
                r['first_50ms_vs_steady_db'] = float(20*np.log10(max(early, 1e-20)/late))
    # Short local recording reference, aligned by detected note onset.
    patch = D.SustainPatch('trumpet'); source = patch._pick(64, 'forte')
    path = ROOT/'music_resources/trumpet'/source['note']
    recording = D.C.load_audio(str(path), FS)
    on, off = D.S.note_region(recording, FS)
    ref = np.zeros(115200)
    start = max(0, on-5760)
    part = recording[start:start+len(ref)]; ref[:len(part)] = part
    ref *= min(.075/max(np.sqrt(np.mean(ref[5760:77760]**2)), 1e-20), .88/max(abs(ref).max(), 1e-20))
    ref[-960:] *= np.linspace(1, 0, 960)
    sf.write(OUT/'recording_reference_E4.wav', np.repeat(ref[:, None], 2, axis=1), FS, subtype='PCM_24')
    ks, gamma, weights, attack, release, *_ = patch.modes(64)
    target = np.zeros(24)
    for k, weight in zip(ks, weights):
        if int(k)<=24: target[int(k)-1] = weight
    target /= target.max()
    good = target > 10**(-35/20)
    for r in results:
        y = np.load(OUT/f'{r["name"]}_single.npy').astype(float)
        measured = D.bands(y[38400:67200], FS/D.bank_for(1).notes[64].period)
        error = 20*np.log10(np.maximum(measured, 1e-15)/np.maximum(target, 1e-15))
        r['steady_vs_original_target_rms_db'] = float(np.sqrt(np.mean(error[good]**2)))
    summary = dict(body_baseline='five exact passthrough sections; checked bit-for-bit',
                   note='EQ candidates are arbitrary sensitivity controls, not fitted trumpet body measurements.',
                   sample_rate=FS, variants=results, source_recording=str(path.relative_to(ROOT)),
                   source_recording_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                   E4_source_attack_ms=attack*1000, E4_gamma_median=float(np.median(gamma)),
                   normalization='all candidate active RMS matched per scene, peak <= .88; constant gain, no compression',
                   production_files_modified=False,
                   source_hashes={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in
                                  [Path(__file__), Path(D.__file__), Path(E.__file__), Path(R.__file__),
                                   ROOT/'rtl/router/routers/body_router.sv', ROOT/'FFT_results/params/trumpet_sustain.npz']})
    (OUT/'results.json').write_text(json.dumps(summary, indent=2)+'\n')
    plot_results()
    print('PASS', [(r['name'], round(r['first_50ms_vs_steady_db'], 2), round(r['steady_vs_original_target_rms_db'], 3)) for r in results], flush=True)


if __name__ == '__main__':
    main()
