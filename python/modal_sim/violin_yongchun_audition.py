#!/usr/bin/env python3
"""Yong Chun chorus excerpt, prior violin envelope candidate, PAD input path."""
import hashlib
import json
from pathlib import Path

import numpy as np
import soundfile as sf

import eng1_pad_audition as A
import eng1_rtl as E
import router_eng1 as R
from violin_continuity_experiment import BowEnvelope

OUT = A.H.ROOT/'FFT_results/sim/eng1/yongchun_violin'
FS, BPM, LEAD, TAIL = 48000, 75, .20, 1.0
NOTES = tuple(range(56, 72))
SCORE_URL = 'https://www.xinyuepu.com/jianpu/20194/9857.html'
IMAGE_URL = 'https://www.xinyuepu.com/uploadfile/Public/Uploads/e/5/503e0c273c251.gif'
# Hand-read eight chorus bars in 1=C. None denotes a printed rest.
# Printed same-pitch ties in bars4/8 are each one three-beat note.
# The final parenthesized instrumental pickup is omitted (rest instead).
BARS = [
    [(67,.5),(69,.5),(64,.5),(67,.5),(62,1),(62,.5),(64,.5)],
    [(62,1),(62,.5),(64,.5),(62,.5),(64,.25),(62,.25),(60,1)],
    [(None,.5),(57,.5),(67,.5),(64,.5),(62,.5),(64,.5),(64,.5),(67,.5)],
    [(64,3),(None,1)],
    [(67,1),(67,.5),(69,.5),(64,1),(64,.5),(67,.5)],
    [(62,.5),(64,.5),(67,.5),(64,.5),(62,.5),(64,.25),(62,.25),(60,1)],
    [(None,.5),(57,.5),(60,.5),(64,.5),(62,.5),(60,.5),(60,.5),(62,.5)],
    [(60,3),(None,1)],
]


def score_events():
    events = []
    for bar, notes in enumerate(BARS):
        assert sum(duration for _, duration in notes) == 4
        beat = 4*bar
        for midi, duration in notes:
            if midi is not None:
                events.append(dict(midi=midi, time=LEAD+beat*60/BPM,
                    duration=duration*60/BPM-.015, score_beats=duration,
                    beat=beat, bar=bar+1, velocity=94 if beat % 4 == 0 else 86))
            beat += duration
    assert len(events) == 44 and min(e['midi'] for e in events) == 57
    return events


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    events = score_events()
    frames = round((LEAD+32*60/BPM+TAIL)*FS)
    adc = A.pressure_fixture(events, frames, True, note_map=NOTES)
    pressure = A.board_force_map(adc)
    np.save(OUT/'adc_bytes.npy', adc)
    np.save(OUT/'force_pressure.npy', pressure)
    (OUT/'events.json').write_text(json.dumps(events, ensure_ascii=False, indent=2)+'\n')
    bank = E.ResourceBank.build('violin', NOTES)
    synth = E.Eng1Synth('violin', note_map=NOTES, resources=bank,
                        stereo=False, reverb='NONE', headroom=3)
    synth.envelope = BowEnvelope(16)
    raw = np.empty(frames, dtype=np.int64)
    pcm = np.empty(frames, dtype=np.int16)
    gates = np.empty(frames, dtype=np.uint16)
    weights = 1 << np.arange(16)
    previous = np.zeros(16, dtype=bool)
    transitions = []
    rails = 0
    for i, row in enumerate(pressure):
        f = synth.step_pad(row, on_threshold=64, off_threshold=48)
        gate = synth.pad_gate
        assert not synth.trigger.any()
        assert np.array_equal(f.zero & gate, gate & ~previous)
        for slot in np.flatnonzero(gate != previous):
            transitions.append(dict(sample=i, time=i/FS, pad=int(slot),
                midi=NOTES[slot], gate=bool(gate[slot]), force=int(row[slot])))
        previous = gate.copy()
        raw[i], pcm[i] = f.out, f.pcm[0]
        gates[i] = np.sum(weights[gate])
        rails += int(np.count_nonzero((synth.core.y1 == R.Y_MAX) |
                                      (synth.core.y1 == R.Y_MIN)))
        if i and i % (FS*4) == 0:
            print('violin yongchun', f'{i/FS:.0f}/{frames/FS:.2f}s', flush=True)
    assert sum(t['gate'] for t in transitions) == len(events)
    assert sum(not t['gate'] for t in transitions) == len(events)
    pcm_rails = int(np.count_nonzero((pcm == -32768) | (pcm == 32767)))
    assert rails == pcm_rails == 0
    np.save(OUT/'raw_q24.npy', raw)
    np.save(OUT/'gate_bits.npy', gates)
    sf.write(OUT/'yongchun_violin_native.wav', np.repeat(pcm[:,None], 2, axis=1),
             FS, subtype='PCM_16')
    wave = raw.astype(float)/(1 << 27)
    active = slice(round(LEAD*FS), round((LEAD+32*60/BPM)*FS))
    rms = lambda y: float(np.sqrt(np.mean(y*y)))
    gain = min(.075/rms(wave[active]), .88/max(abs(wave).max(), 1e-30))
    path = OUT/'yongchun_chorus_violin_experimental.wav'
    sf.write(path, np.repeat((wave*gain)[:,None], 2, axis=1), FS, subtype='PCM_24')
    check, fs = sf.read(path, always_2d=True)
    assert fs == FS and check.shape == (frames,2) and np.isfinite(check).all()
    assert abs(check).max() <= .880001
    from sustain_engine import SustainPatch
    patch = SustainPatch('violin')
    meta = dict(title='咏春', artist='七朵组合', composer='何亮',
        excerpt='Eight chorus bars beginning at the chorus repeat sign; solo melody in C',
        source=dict(page=SCORE_URL, image=IMAGE_URL, transcriber='桃李醉春风',
                    method='Manually read pitch/duration and octave dots from public score image'),
        bpm=BPM, tempo_note='75 BPM audition tempo, not a measurement of the studio recording',
        sample_rate=FS, frames=frames, seconds=frames/FS, note_map=NOTES,
        score_bars=BARS, events=events, gate_transitions=transitions,
        interpretation='Printed same-pitch ties held; other repeated notes released and re-pressed. '
                       'Final instrumental pickup omitted. No unmarked pitch slides or vibrato.',
        input='Synthetic ADC pressure: 8ms attack / 12ms release ending at nominal note-off; '
              '15ms note separations. Board force map, 64/48 hysteresis, PAD retrigger=0.',
        synthesis='Original periodic impulse and Q24 48-mode violin coefficients; '
                  'BowEnvelope 20ms attack/full sustain/no decay/80ms release; '
                  'body passthrough, reverb NONE, mono headroom=3',
        implementation='Python candidate envelope enabled; not production RTL envelope',
        resources=[dict(midi=m, source_midi=patch._pick_key(m,'forte')[0],
                        period=bank.notes[m].period) for m in NOTES],
        state_rail_hits=rails, native_pcm_rail_samples=pcm_rails,
        listening_gain_db=20*np.log10(gain), active_rms_dbfs=20*np.log10(rms(check[active,0])),
        peak_dbfs=20*np.log10(abs(check).max()), file=path.name,
        sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
        source_hashes={str(p.relative_to(A.H.ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                       for p in [Path(__file__), Path(A.__file__), Path(E.__file__),
                                 Path(R.__file__), A.H.ROOT/'python/modal_sim/violin_continuity_experiment.py']})
    (OUT/'results.json').write_text(json.dumps(meta, ensure_ascii=False, indent=2)+'\n')
    print('Completed:', path, 'events', len(events), 'rails', rails, pcm_rails, flush=True)


if __name__ == '__main__':
    main()
