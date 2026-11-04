"""Body-only sensitivity audition; quantized coefficients, float SOS processing.
Uses the existing production render, not a new RTL or excitation simulation.
"""
from pathlib import Path
import json
import numpy as np
import soundfile as sf
from scipy.signal import sosfilt, sosfreqz
import router_eng1 as R
from trumpet_body_experiment import eq, body_rows

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT/'python_monotor/results/sim/eng1/flute_body_probe_20261102'
SOURCE = ROOT/'python_monotor/results/sim/eng1/flute_retest_20261102/mystery_of_love_flute_eng1.wav'


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    x, sr = sf.read(SOURCE, always_2d=True)
    assert sr == 48000
    x = x[:, 0]
    identity = [[1 << 27, 0, 0, 0, 0]]*5
    assert R.body_coeffs('flute') == identity
    # Verify the actual integer cascade is an exact bypass for nonzero samples.
    b = R.BodyFilter(instrument='flute')
    for v in [0, 1, -1, 12345678, -12345678, (1 << 48), -(1 << 48)]:
        assert b.step(v)[0] == v
    configs = {
        'baseline': [],
        'body_air_shelf': [eq('shelf', 3500, 6)],
        'body_presence_air': [eq('peak', 1800, -3, .7), eq('shelf', 3500, 9)],
    }
    signals, rows, responses = {}, {}, {}
    for name, sections in configs.items():
        coeffs = body_rows(np.array(sections)) if sections else identity
        sos = np.array([[b0,b1,b2,1 << 27,a1,a2] for b0,b1,b2,a1,a2 in coeffs], float)/(1 << 27)
        assert all(max(abs(np.roots(s[3:]))) < 1 for s in sos)
        signals[name] = sosfilt(sos, x)
        rows[name] = coeffs
        f, h = sosfreqz(sos, worN=[500,1000,2000,4000,8000,12000], fs=sr)
        responses[name] = dict(zip(map(str, f), (20*np.log10(abs(h))).tolist()))
    active = slice(round(.12*sr), round(9.72*sr))
    rms = lambda y: float(np.sqrt(np.mean(y[active]**2)))
    target = min(.09, *[.88*rms(y)/max(abs(y).max(),1e-30) for y in signals.values()])
    report = {}
    for name, y in signals.items():
        gain = target/rms(y)
        z = y*gain
        path = OUT/f'{name}.wav'
        sf.write(path, np.repeat(z[:,None],2,axis=1), sr, subtype='PCM_24')
        check, fs = sf.read(path)
        assert fs == sr and np.isfinite(check).all() and abs(check).max() < .881
        assert abs(rms(check[:,0])-target) < 1e-6
        report[name] = dict(file=path.name, gain_db=float(20*np.log10(gain)),
                            body_q4_27=rows[name], response_db=responses[name], peak=float(abs(check).max()))
    (OUT/'results.json').write_text(json.dumps(dict(source=str(SOURCE),
        method='Body-only sensitivity, Q4.27 quantized SOS processed in float; no added noise, reverb, or excitation changes. Not RTL verification.',
        production_flute_body='five exact identity sections; integer bypass checked',
        active_rms=target, variants=report), indent=2)+'\n')
    print('PASS: three RMS-matched body-only WAVs; identity, stability, finite and peak checks')
    print(OUT)

if __name__ == '__main__':
    main()
