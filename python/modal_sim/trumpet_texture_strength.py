#!/usr/bin/env python3
"""Increase audition-only trumpet air and harmonic movement, matched in RMS."""
from pathlib import Path
import hashlib
import json
import math
import numpy as np
import soundfile as sf
import trumpet_texture_experiment as T

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT/'FFT_results/sim/eng1/trumpet_texture_strength'


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    records = {}
    for scene in ['phrase', 'single']:
        raw, base, active, old, components, generation = T.build_scene(scene, 48000/146)
        noise = components['noise_lo']
        am = components['am_pert']
        # Reuse the same random realizations so only strength changes.
        signals = {
            'baseline': (base, None, 0),
            'previous_combo': (old['air_harm'][0], -36, .04),
            'air_strong': (base+noise*10**(18/20), -18, 0),
            'harmonic_strong': (base+am*3, None, .12),
            'medium_combo': (base+noise*10**(12/20)+am*2, -24, .08),
            'strong_combo': (base+noise*10**(18/20)+am*3, -18, .12),
        }
        target = min(.075, *[.88*T.rms(y[active])/max(abs(y).max(), 1e-30) for y, _, _ in signals.values()])
        rows = {}
        for name, (y, noise_db, am_std) in signals.items():
            gain = target/T.rms(y[active])
            z = y*gain; z[-960:] *= np.linspace(1,0,960)
            path = OUT/f'{name}_{scene}.wav'
            sf.write(path, np.repeat(z[:,None],2,axis=1), 48000, subtype='PCM_24')
            check, fs = sf.read(path, always_2d=True)
            assert fs==48000 and check.shape==(len(raw),2) and np.isfinite(check).all()
            assert abs(check).max()<=.880001
            level = 20*math.log10(T.rms(check[active,0]))
            assert abs(level-20*math.log10(target))<.00002
            assert not np.any(check[:4800])
            assert T.rms(check[int((10 if scene=='phrase' else 2.05)*48000):,0])<1e-4
            addition=y-base
            rows[name] = dict(file=path.name, noise_rms_db_rel_base=noise_db,
                highband_am_nominal_std=am_std, am_rate_hz=[2.5,12],
                active_rms_dbfs=level, peak_dbfs=20*math.log10(abs(check).max()),
                gain_db=20*math.log10(gain), frames=len(raw),
                combined_addition_rms_db_rel_base=None if name=='baseline' else float(T.db20(T.rms(addition[active])/T.rms(base[active]))),
                sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        records[scene]=dict(active_samples=[active.start,active.stop],variants=rows)
    summary=dict(sample_rate=48000,scenes=records,noise_seed=T.MASTER_SEED,
        method='Reuse prior colored-noise realization and 2.5..12Hz highband AM. Strength only; no pitch, release or body changes. Offline additions, not production RTL.',
        normalization='Constant gain, all variants active RMS matched per scene, common peak limit .88, no compression, terminal20ms fade.',
        source_hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in
            [Path(__file__),Path(T.__file__),T.BODY/'baseline_phrase.npy',T.BODY/'baseline_single.npy']})
    (OUT/'results.json').write_text(json.dumps(summary,indent=2)+'\n')
    lines=['# Increased trumpet texture','','Offline audition candidates; original ENG1 release and body are retained.','','| Candidate | Noise RMS/base | HF AM std | Phrase | Single |','|---|---:|---:|---|---|']
    for name,row in records['phrase']['variants'].items():
        lines.append(f'| {name} | {row["noise_rms_db_rel_base"]} dB | {row["highband_am_nominal_std"]*100:.0f}% | [play]({name}_phrase.wav) | [play]({name}_single.wav) |')
    lines+=['','Noise levels are sensitivity controls, not estimates of physical airflow.','', '[Results](results.json)', '', 'Run: `python python/modal_sim/trumpet_texture_strength.py`']
    (OUT/'README.md').write_text('\n'.join(lines)+'\n')
    print('PASS12 RMS-matched WAVs, peaks, pre-roll and tail checks')
    for name,row in records['phrase']['variants'].items():
        print(name,'RMS',round(row['active_rms_dbfs'],3),'peak',round(row['peak_dbfs'],3))


if __name__=='__main__': main()
