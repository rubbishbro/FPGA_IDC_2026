#!/usr/bin/env python3
"""Original versus prior timbre candidates, with identical PAD pressure and gate.

Trumpet: LipExcitation(shape=True, unstable=True, air=True), original ADSR.
Violin: BowEnvelope only; original excitation and every original note-off kept.
These are explicit Python synthesis candidates, not changes to production RTL.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.signal import butter, sosfilt

import eng1_pad_audition as A
import eng1_rtl as E
import router_eng1 as R
from trumpet_excitation_experiment import LipExcitation, SEED
from violin_continuity_experiment import BowEnvelope

OUT = A.H.ROOT/'FFT_results/sim/eng1/pad_config_experiment'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def render(instrument):
    base = A.OUT/instrument
    out = OUT/instrument
    out.mkdir(parents=True, exist_ok=True)
    meta = json.loads((base/'results.json').read_text())
    original = next(r for r in meta['renders'] if r['name'] == 'ramped_pressure')
    pressure = np.load(base/'ramped_pressure_pressure.npy')
    adc = np.load(base/'ramped_pressure_adc_bytes.npy')
    gates = np.load(base/'ramped_pressure_gate_bits.npy')
    baseline_raw = np.load(base/'ramped_pressure_raw_q24.npy')
    assert np.array_equal(A.board_force_map(adc), pressure)
    assert meta['note_map'] == list(A.NOTES)
    frames = meta['frames']
    assert pressure.shape == (frames, 16) and len(gates) == len(baseline_raw) == frames
    bank = E.ResourceBank.build(instrument, A.NOTES)
    for row in meta['resources']:
        resource = bank.notes[row['midi']]
        digest = hashlib.sha256(resource.pitch_words.tobytes()+resource.coeffs.G.tobytes()+
                                resource.coeffs.a1.tobytes()+resource.coeffs.a2.tobytes()).hexdigest()
        assert digest == row['coefficient_sha256']
        assert (resource.a_step, resource.r_step) == (row['a_step'], row['r_step'])
    synth = E.Eng1Synth(instrument, note_map=A.NOTES, resources=bank,
                        stereo=False, reverb='NONE', headroom=3)
    if instrument == 'trumpet':
        random = np.random.default_rng(SEED).standard_normal((frames, 16))
        noise = sosfilt(butter(2, [500, 10000], btype='bandpass', fs=A.FS, output='sos'),
                        random, axis=0)
        noise /= np.sqrt(np.mean(noise**2, axis=0))[None, :]
        del random
        synth.excitation = LipExcitation([r.period for r in synth.rows],
            shape=True, unstable=True, air=True, noise=noise)
        config = dict(excitation='LipExcitation(shape=True, unstable=True, air=True)',
            pulse='Zero-DC bipolar opening 12%, gap 2%, closing 3% of period; '
                  'fundamental drive matched to impulse',
            onset='Cycle rate std 0.6%, cap 1.8%; amplitude std 8%; decay tau30ms',
            air='500..10000Hz before modal bank, strength=0.040*exp(-age/40ms)+0.005',
            envelope='Unchanged original ADSR', extra_parallel_breath=False,
            extra_modal_harmonic_boost=False, seed=SEED)
    else:
        synth.envelope = BowEnvelope(16)
        config = dict(excitation='Unchanged periodic impulse',
            envelope='BowEnvelope: 20ms attack, full sustain, no decay, 80ms release',
            automatic_legato=False, merged_repeated_notes=False)
    raw = np.empty(frames, dtype=np.int64)
    pcm = np.empty(frames, dtype=np.int16)
    envelope_peak = np.zeros(16, dtype=np.int64)
    weights = 1 << np.arange(16)
    state_rails = 0
    previous = np.zeros(16, dtype=bool)
    for i, row in enumerate(pressure):
        f = synth.step_pad(row, on_threshold=64, off_threshold=48)
        gate = synth.pad_gate
        assert int(np.sum(weights[gate])) == int(gates[i]), (i, 'input gate changed')
        assert not synth.trigger.any()
        assert np.array_equal(f.zero & gate, gate & ~previous)
        assert np.all(f.emap[gate & ~previous] == 0)
        previous = gate.copy()
        envelope_peak = np.maximum(envelope_peak, f.emap)
        raw[i], pcm[i] = f.out, f.pcm[0]
        state_rails += int(np.count_nonzero((synth.core.y1 == R.Y_MAX) |
                                           (synth.core.y1 == R.Y_MIN)))
        if i and i % (3*A.FS) == 0:
            print(instrument, 'experiment', f'{i/A.FS:.0f}/{frames/A.FS:.2f}s', flush=True)
    rails = int(np.count_nonzero((pcm == -32768) | (pcm == 32767)))
    assert state_rails == 0 and rails == 0
    assert not np.array_equal(raw, baseline_raw), 'candidate did not change output'
    np.save(out/'experimental_raw_q24.npy', raw)
    sf.write(out/'experimental_native.wav', np.repeat(pcm[:, None], 2, axis=1),
             A.FS, subtype='PCM_16')
    active = slice(round(A.H.LEAD*A.FS), round((A.H.LEAD+16*60/A.H.BPM)*A.FS))
    waves = dict(original=baseline_raw.astype(float)/(1 << 27),
                 experimental=raw.astype(float)/(1 << 27))
    rms = lambda y: float(np.sqrt(np.mean(y*y)))
    target = min(.075, *[.88*rms(w[active])/max(np.max(np.abs(w)), 1e-30)
                         for w in waves.values()])
    results = []
    for name, w in waves.items():
        gain = target/rms(w[active])
        path = out/f'{name}_listen.wav'
        sf.write(path, np.repeat((w*gain)[:, None], 2, axis=1), A.FS, subtype='PCM_24')
        check, fs = sf.read(path, always_2d=True)
        assert fs == A.FS and check.shape == (frames, 2) and np.isfinite(check).all()
        assert abs(check).max() <= .880001
        assert abs(20*np.log10(rms(check[active, 0])/target)) < .00003
        results.append(dict(name=name, file=path.name, sha256=sha(path),
            listening_gain_db=20*np.log10(gain),
            active_rms_dbfs=20*np.log10(rms(check[active, 0])),
            peak_dbfs=20*np.log10(abs(check).max()),
            internal_zero_gaps=A.gaps(baseline_raw if name == 'original' else raw)))
    summary = dict(instrument=instrument, status='Python timbre candidate enabled',
        config=config, pressure_fixture='Identical ramped ADC/force matrix as prior PAD baseline',
        sample_rate=A.FS, frames=frames, seconds=frames/A.FS, note_map=A.NOTES,
        gate_comparison=dict(frames_checked=frames, identical=True,
                            note_ons=15, note_offs=15, automatic_event_edits=False),
        native_output=dict(state_rail_hits=state_rails, pcm_rail_samples=rails,
                           headroom=3, envelope_peak=envelope_peak.tolist()),
        excitation_metrics=synth.excitation.metrics() if instrument == 'trumpet' else None,
        normalization='Pair matched active RMS by constant gain only; no fade/compression/EQ',
        modal_coefficients='Unchanged and checked against baseline hashes',
        implementation='PAD input path preserved; candidate excitation/envelope is Python-only, '
                       'not implemented in current production RTL. No RTL simulator used.',
        renders=results,
        input_hashes={str(p.relative_to(A.H.ROOT)):sha(p) for p in [
            base/'results.json', base/'ramped_pressure_adc_bytes.npy',
            base/'ramped_pressure_pressure.npy', base/'ramped_pressure_gate_bits.npy',
            base/'ramped_pressure_raw_q24.npy']},
        source_hashes={str(p.relative_to(A.H.ROOT)):sha(p) for p in [Path(__file__),
            Path(A.__file__), Path(E.__file__), Path(R.__file__),
            A.H.ROOT/'python/modal_sim/trumpet_excitation_experiment.py',
            A.H.ROOT/'python/modal_sim/violin_continuity_experiment.py']})
    (out/'results.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2)+'\n')
    print('Completed', instrument, [(r['name'], len(r['internal_zero_gaps'])) for r in results], flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--instrument', choices=['trumpet', 'violin'], required=True)
    render(parser.parse_args().instrument)
