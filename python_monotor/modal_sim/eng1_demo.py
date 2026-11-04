#!/usr/bin/env python3
"""Render real audio through the router-level eng1 model.

Two deliberately different patches exercise the two halves of the model:

* **guitar / Class A** -- the frozen 72-bit table in ``python_monotor/results/params``,
  the 2-sample guitar pulse from ``exc_router``, the pressure envelope
  (``envelope_dyn0``) and the 5-section Q4.27 guitar body.
* **flute / Class B** -- a table generated from ``flute_sustain.npz``, an
  impulse every ``round(sr/f0)`` samples (what ``excitation_gen`` emits when
  ``PW_LEN=1, GAP_LEN=T-1, N_PULSE=7``), the ADSR envelope and the HALL comb
  reverb.

Everything downstream of the score is integer; only the WAV writer scales.
This script deliberately writes **audio only** -- no figures, no JSON.  The
per-render peak/RMS/saturation numbers are printed to stdout.

    python python_monotor/modal_sim/eng1_demo.py
    python python_monotor/modal_sim/eng1_demo.py --no-write --seconds 1

Outputs (under ``python_monotor/results/sim/eng1/``):

    eng1_guitar_dry.wav     Class A, body guitar, reverb NONE
    eng1_flute_hall.wav     Class B, body passthrough, reverb HALL
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

import paths                                    # noqa: E402
import router_eng1 as R                         # noqa: E402

# ---------------------------------------------------------------------------
# scores
# ---------------------------------------------------------------------------
#: one bar = 1.5 s; a D-minor / Bb / Gm / A fingerpicked loop.
GUITAR_BAR = 1.5
GUITAR_SCORE = [
    (0.00, 50, 1.10, 0.85), (0.37, 57, 1.10, 0.62),
    (0.75, 62, 1.10, 0.55), (1.12, 65, 1.10, 0.50),
    (1.50, 46, 1.10, 0.82), (1.87, 53, 1.10, 0.60),
    (2.25, 58, 1.10, 0.55), (2.62, 62, 1.10, 0.50),
    (3.00, 43, 1.10, 0.84), (3.37, 50, 1.10, 0.62),
    (3.75, 55, 1.10, 0.56), (4.12, 58, 1.10, 0.50),
    (4.50, 45, 1.10, 0.84), (4.87, 52, 1.10, 0.62),
    (5.25, 57, 1.10, 0.56), (5.62, 61, 1.10, 0.50),
]

#: a short D-minor flute phrase; each note leaves a 50 ms gap so the slot gets
#: a real gate edge (the router has no retrigger-without-release path).
FLUTE_SCORE = [
    (0.00, 74, 0.42, 0.80), (0.50, 76, 0.42, 0.82),
    (1.00, 77, 0.42, 0.84), (1.50, 79, 0.42, 0.86),
    (2.00, 81, 0.82, 0.90), (2.90, 79, 0.42, 0.84),
    (3.40, 77, 0.42, 0.82), (3.90, 76, 0.42, 0.80),
    (4.40, 74, 1.10, 0.78),
]


def notes(score, *, dyn="forte"):
    return [R.NoteEvent(t, midi, dur, vel, dyn) for t, midi, dur, vel in score]


# ---------------------------------------------------------------------------
# audio helpers
# ---------------------------------------------------------------------------
def to_float(y: np.ndarray) -> np.ndarray:
    """Q2.30 integer -> float in [-1, 1] (the RTL ``y_data`` scale)."""
    return np.asarray(y, dtype=np.float64) / float(R.Y_ONE)


def normalize(y: np.ndarray, peak: float = 0.85) -> np.ndarray:
    x = to_float(y)
    m = float(np.max(np.abs(x))) if x.size else 0.0
    return x if m <= 1e-12 else x * (peak / m)


def write_wav(path: str, y: np.ndarray, sr: int = R.SR) -> None:
    import soundfile as sf
    sf.write(path, normalize(y), sr, subtype="PCM_16")


# ---------------------------------------------------------------------------
# render
# ---------------------------------------------------------------------------
def render_guitar(args) -> tuple[np.ndarray, R.RenderMeta]:
    renderer = R.ScoreRenderer(
        R.ATable(args.guitar_inst),
        body="guitar", reverb="NONE", envelope="dyn", tail_s=1.0)
    return renderer.render(notes(GUITAR_SCORE), seconds=args.seconds)


def render_flute(args) -> tuple[np.ndarray, R.RenderMeta]:
    renderer = R.ScoreRenderer(
        R.BTable(args.flute_inst),
        body="none", reverb="HALL", envelope="adsr", tail_s=1.5)
    return renderer.render(notes(FLUTE_SCORE), seconds=args.seconds)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--guitar-inst", default="guitar")
    ap.add_argument("--flute-inst", default="flute")
    ap.add_argument("--seconds", type=float, default=None,
                    help="truncate the render (default: score length + tail)")
    ap.add_argument("--no-write", action="store_true",
                    help="render and print metrics only (write no WAV)")
    args = ap.parse_args(argv)

    out_dir = paths.SIM_ENG1
    if not args.no_write:
        os.makedirs(out_dir, exist_ok=True)

    renders: dict[str, np.ndarray] = {}
    for name, fn in (("guitar", render_guitar), ("flute", render_flute)):
        t0 = time.time()
        y, meta = fn(args)
        dt = time.time() - t0
        renders[name] = y
        print(f"[{name:6s}] {y.size / R.SR:5.2f} s audio in {dt:5.1f} s  "
              f"raw peak {meta.raw_peak / R.Y_ONE:8.4f}  "
              f"rms {meta.raw_rms / R.Y_ONE:8.4f}  "
              f"body_sat {meta.body_sat}  reverb {meta.reverb}")
        if meta.warnings:
            for w in meta.warnings:
                print(f"           WARNING: {w}")

    if args.no_write:
        return 0

    write_wav(os.path.join(out_dir, "eng1_guitar_dry.wav"), renders["guitar"])
    write_wav(os.path.join(out_dir, "eng1_flute_hall.wav"), renders["flute"])
    print(f"wrote {out_dir}/eng1_guitar_dry.wav")
    print(f"wrote {out_dir}/eng1_flute_hall.wav")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
