#!/usr/bin/env python3
"""Production B phrase with actual Q24->stereo PCM gain, no peak normalization.

The historical C experiment is available only with --legacy-c; it has no
production router counterpart and retains its separate normalized demo output.
Use --no-write to validate rendering without generating audio files.
"""

from __future__ import annotations

import argparse
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "fft_analysis"))

import eng1_bc as BC                            # noqa: E402
import paths                                    # noqa: E402
import router_eng1 as R                         # noqa: E402

# ---------------------------------------------------------------------------
# B: a short flute phrase, 8 s
# ---------------------------------------------------------------------------
B_EVENTS = [
    (0.00, 69, 0.55, 0.75, "forte"),
    (0.60, 72, 0.55, 0.78, "forte"),
    (1.20, 74, 0.85, 0.82, "forte"),
    (2.15, 72, 0.55, 0.76, "forte"),
    (2.75, 69, 0.55, 0.72, "forte"),
    (3.35, 67, 0.85, 0.70, "forte"),
    (4.30, 69, 0.55, 0.78, "forte"),
    (4.90, 72, 0.55, 0.80, "forte"),
    (5.50, 76, 0.85, 0.84, "forte"),
    (6.45, 74, 0.55, 0.80, "forte"),
    (7.05, 72, 1.20, 0.78, "forte"),
]

# ---------------------------------------------------------------------------
# C: four bars at 110 BPM
# ---------------------------------------------------------------------------
C_BPM = 110.0
C_BEAT = 60.0 / C_BPM


def c_events(bars: int = 4):
    ev = []
    for b in range(bars):
        t0 = b * 4.0 * C_BEAT
        for beat, key, vel in ((0.0, "kick", 1.0), (2.0, "kick", 0.86),
                               (2.5, "kick", 0.62),
                               (1.0, "snare", 0.90), (3.0, "snare", 0.96)):
            ev.append((t0 + beat * C_BEAT, key, vel))
        for k in range(8):
            ev.append((t0 + k * 0.5 * C_BEAT, "hat",
                       0.55 if k % 2 == 0 else 0.34))
        if b == 0:
            ev.append((t0 + 0.0, "crash", 0.75))
        if b == bars - 1:
            ev.append((t0 + 3.0 * C_BEAT, "tom", 0.80))
            ev.append((t0 + 3.5 * C_BEAT, "tom", 0.92))
        else:
            ev.append((t0 + 3.5 * C_BEAT, "ride", 0.38))
    return ev


def normalize(y: np.ndarray, peak: float = 0.85) -> np.ndarray:
    x = np.asarray(y, dtype=np.float64) / float(R.Y_ONE)
    m = float(np.max(np.abs(x))) if x.size else 0.0
    return x if m <= 1e-12 else x * (peak / m)


def write_wav(path: str, y: np.ndarray, sr: int = R.SR) -> None:
    import soundfile as sf
    sf.write(path, y if y.dtype == np.int16 else normalize(y), sr, subtype="PCM_16")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--seconds", type=float, default=None,
                    help="truncate both renders (default: full phrase/groove)")
    ap.add_argument("--no-write", action="store_true",
                    help="render and print metrics only (write no WAV)")
    ap.add_argument("--legacy-c", action="store_true", help="also render the historical C experiment (not production RTL)")
    args = ap.parse_args(argv)

    out_dir = paths.SIM_ENG1
    if not args.no_write:
        os.makedirs(out_dir, exist_ok=True)

    jobs = [
        ("B/flute", "eng1_b_phrase.wav",
         lambda: BC.BSynth("flute", body="none", reverb="HALL"),
         lambda s: s.render_pcm(B_EVENTS, args.seconds or 9.0)),
    ]
    if args.legacy_c:
        jobs.append(("C/drums", "eng1_c_groove.wav",
         lambda: BC.CSynth(body="none", reverb="NONE"),
         lambda s: s.render(c_events(), args.seconds or 11.7)))
    for name, filename, make, render in jobs:
        t0 = time.time()
        synth = make()
        y = render(synth)
        dt = time.time() - t0
        scale = 32768.0 if y.dtype == np.int16 else R.Y_ONE
        peak = float(np.max(np.abs(y.astype(float)))) / scale if y.size else 0.0
        rms = float(np.sqrt(np.mean(y.astype(np.float64) ** 2))) / scale if y.size else 0.0
        print(f"[{name:8s}] {len(y) / R.SR:5.2f} s audio in {dt:5.1f} s  "
              f"raw peak {peak:8.4f}  rms {rms:8.4f}  engine={'production Q24/PCM' if y.dtype == np.int16 else 'legacy C'}")
        if not args.no_write:
            write_wav(os.path.join(out_dir, filename), y)
            print(f"wrote {out_dir}/{filename}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
