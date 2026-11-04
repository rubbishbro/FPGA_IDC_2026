#!/usr/bin/env python3
"""Sample-frame Python audition of the current ENG1 PAD synthesis path.

Synthetic 16-pad pressure input, not a recording of a player. No RTL simulator
is required. ADC scan timing, loading and source switching are outside scope;
the fixed bank is loaded and PAD mode is active throughout this experiment.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import soundfile as sf

import eng1_rtl as E
import router_eng1 as R
import trumpet_hinos_excerpt as H

FS = 48000
NOTES = tuple(range(60, 76))
OUT = H.ROOT / 'python_monotor/results/sim/eng1/pad_path_retest'


def board_force_map(raw):
    """instrument_system: invalid sign bit -> 0; raw >=64 ->255; else x4."""
    raw = np.asarray(raw, dtype=np.uint8)
    return np.where(raw & 128, 0, np.where(raw & 64, 255,
                    raw.astype(np.uint16)*4)).astype(np.uint8)


def pressure_fixture(events, frames, gradual, note_map=NOTES):
    """Keep every note-off; finite pressure ramps end at its original note-off."""
    pressure = np.zeros((frames, len(note_map)), dtype=np.uint8)
    for event in events:
        slot = note_map.index(event['midi'])
        start = round(event['time'] * FS)
        end = round((event['time'] + event['duration']) * FS)
        velocity = int(event['velocity'])
        # Match the former velocity's level approximately using realizable ADC
        # bytes, then apply the actual board's x4/saturating force adapter.
        peak = round(((velocity << 1) | (velocity >> 6))/4)
        lane = np.full(end-start, peak, dtype=np.int64)
        if gradual:
            attack = min(round(.008*FS), len(lane)//2)
            release = min(round(.012*FS), len(lane)//2)
            lane[:attack] = np.rint(np.linspace(0, peak, attack))
            lane[-release:] = np.rint(np.linspace(peak, 0, release))
        if np.any(pressure[start:end, slot]):
            raise ValueError('Overlapping events on one pad are not supported')
        pressure[start:end, slot] = lane
    return pressure


def gaps(raw):
    edges = np.diff(np.r_[False, raw == 0, False].astype(np.int8))
    return [dict(start=a/FS, end=b/FS, ms=(b-a)*1000/FS)
            for a, b in zip(np.flatnonzero(edges == 1), np.flatnonzero(edges == -1))
            if b-a >= 48 and a > round(.3*FS) and b < round(13.5*FS)]


def render(instrument):
    out = OUT / instrument
    out.mkdir(parents=True, exist_ok=True)
    events, score_audit = H.score_events()
    frames = round((H.LEAD + 16*60/H.BPM + H.TAIL)*FS)
    bank = E.ResourceBank.build(instrument, NOTES)
    active = slice(round(H.LEAD*FS), round((H.LEAD + 16*60/H.BPM)*FS))
    results = []
    waves = {}
    for name, gradual in [('step_pressure', False), ('ramped_pressure', True)]:
        raw_pressure = pressure_fixture(events, frames, gradual)
        pressure = board_force_map(raw_pressure)
        np.save(out / f'{name}_adc_bytes.npy', raw_pressure)
        np.save(out / f'{name}_pressure.npy', pressure)
        synth = E.Eng1Synth(instrument, note_map=NOTES, resources=bank,
                            stereo=False, reverb='NONE', headroom=3)
        raw = np.empty(frames, dtype=np.int64)
        pcm = np.empty(frames, dtype=np.int16)
        gate_trace = np.empty(frames, dtype=np.uint16)
        weights = 1 << np.arange(16)
        transitions = []
        previous = np.zeros(16, dtype=bool)
        state_rails = 0
        for i, row in enumerate(pressure):
            frame = synth.step_pad(row, on_threshold=64, off_threshold=48)
            gate = synth.pad_gate
            changed = gate != previous
            if changed.any():
                for slot in np.flatnonzero(changed):
                    transitions.append(dict(sample=i, time=i/FS, pad=int(slot),
                        midi=NOTES[slot], gate=bool(gate[slot]), pressure=int(row[slot])))
            # PAD has no independent retrigger: only an actual gate rising edge.
            assert not np.any(synth.trigger)
            assert np.array_equal(frame.zero & gate, gate & ~previous)
            if (gate & ~previous).any():
                assert np.all(frame.emap[gate & ~previous] == 0)
            previous = gate.copy()
            raw[i], pcm[i] = frame.out, frame.pcm[0]
            gate_trace[i] = np.sum(weights[gate])
            state_rails += int(np.count_nonzero((synth.core.y1 == R.Y_MAX) |
                                               (synth.core.y1 == R.Y_MIN)))
            if i and i % (3*FS) == 0:
                print(instrument, name, f'{i/FS:.0f}/{frames/FS:.2f}s', flush=True)
        assert sum(t['gate'] for t in transitions) == len(events)
        assert sum(not t['gate'] for t in transitions) == len(events)
        assert not synth.pad_gate.any()
        np.save(out / f'{name}_raw_q24.npy', raw)
        np.save(out / f'{name}_gate_bits.npy', gate_trace)
        sf.write(out / f'{name}_native.wav', np.repeat(pcm[:, None], 2, axis=1),
                 FS, subtype='PCM_16')
        waves[name] = raw.astype(float)/(1 << 24)/8
        results.append(dict(name=name, gate_transitions=transitions,
            internal_zero_gaps=gaps(raw), state_rail_hits=state_rails,
            native_pcm_rail_samples=int(np.count_nonzero((pcm == -32768) | (pcm == 32767)))))
    rms = lambda x: float(np.sqrt(np.mean(x*x)))
    target = min(.075, *[.88*rms(w[active])/max(np.max(np.abs(w)), 1e-30)
                         for w in waves.values()])
    for result in results:
        name = result['name']
        w = waves[name]
        gain = target/max(rms(w[active]), 1e-30)
        path = out / f'{name}_listen.wav'
        # Listening copy has constant gain only. Native PCM remains unmodified.
        sf.write(path, np.repeat((w*gain)[:, None], 2, axis=1), FS, subtype='PCM_24')
        check, fs = sf.read(path, always_2d=True)
        assert fs == FS and check.shape == (frames, 2) and np.isfinite(check).all()
        assert np.max(np.abs(check)) <= .880001
        result.update(file=path.name, listening_gain_db=20*np.log10(gain),
            active_rms_dbfs=20*np.log10(rms(check[active, 0])),
            peak_dbfs=20*np.log10(np.max(np.abs(check))),
            sha256=hashlib.sha256(path.read_bytes()).hexdigest())
    meta = dict(instrument=instrument, status='RTL-derived Python PAD sample model',
        rtl_simulator_required=False, excerpt_rtl_cosim_performed=False,
        input='Synthetic 16-pad uint8 ADC bytes, not a captured player performance',
        route='ADC byte -> board invalid-bit rejection / saturating x4 force map -> '
              '64/48 hysteresis -> PAD gate/level, retrigger=0 -> '
              'current periodic impulse -> original ADSR -> Q24 48-mode ENG1 -> '
              'body passthrough -> reverb NONE -> mono PCM16 headroom=3',
        sample_rate=FS, frames=frames, note_map=NOTES, events=events, score_audit=score_audit,
        comparison='Same notes, peak pressure and original note-off times. '
                   'Step versus linear 8ms pressure attack / 12ms release ending at note-off.',
        articulation='Original 20.83-25ms gaps and 180ms phrase gaps retained. '
                     'No merged repeated notes, overlap, bow envelope, lip jitter or added noise.',
        boundary='Loaded fixed bank, active PAD source, audio-frame input. '
                 'ADC scanning, core-clock input registers, switching/loading and FIFO excluded. '
                 '48k resource-rate audition; not a measurement of hardware DAC clock.',
        resources=[dict(midi=m, period=bank.notes[m].period,
                        a_step=bank.notes[m].a_step, r_step=bank.notes[m].r_step,
                        coefficient_sha256=hashlib.sha256(bank.notes[m].pitch_words.tobytes()+
                            bank.notes[m].coeffs.G.tobytes()+bank.notes[m].coeffs.a1.tobytes()+
                            bank.notes[m].coeffs.a2.tobytes()).hexdigest()) for m in NOTES],
        renders=results,
        source_hashes={str(p.relative_to(H.ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                       for p in [Path(__file__), Path(E.__file__), Path(R.__file__), H.XML,
                                 H.ROOT/'python_monotor/modal_sim/trumpet_hinos_excerpt.py',
                                 H.ROOT/'rtl/platform/tang_mega_138k_pro/instrument_system.sv',
                                 H.ROOT/'rtl/router/voice_router.sv',
                                 H.ROOT/'rtl/router/routers/exc_router.sv',
                                 H.ROOT/'rtl/router/routers/env_router.sv']})
    (out / 'results.json').write_text(json.dumps(meta, ensure_ascii=False, indent=2)+'\n')
    print('Completed', instrument, [(r['name'], len(r['internal_zero_gaps'])) for r in results], flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--instrument', choices=['trumpet', 'violin'], required=True)
    render(parser.parse_args().instrument)
