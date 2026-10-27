#!/usr/bin/env python3
"""Two new short pieces through the refactored router-level eng1 engine.

Both pieces are original (not transcriptions) and are rendered by the same
integer model as ``eng1_demo.py``:

* **guitar / "Estudio in D minor"** -- Dm | Bb | Gm | A | Dm | A, 84 BPM, 4/4,
  five-note fingerstyle arpeggios.  The RTL guitar path is used as-is:
  ``body_router`` guitar coefficients, ``envelope_dyn0`` (pressure envelope)
  and the 2-sample guitar excitation pulse.
* **piano / "Prelude in C diminished"** -- Cdim | F#dim | Cdim | Bm7(no3) |
  Cdim | Cdim, 60 BPM, 4/4.  The extracted piano table only has the pitch
  classes C, Eb, F#, A and B, so the piece is written inside that collection
  instead of pretending missing notes exist.  The RTL piano path is
  ``body_router`` passthrough + ``envelope_ADSR`` + the default 1-sample
  excitation pulse.

Audio only -- this script writes no figures and no JSON; peak/RMS/saturation
are printed to stdout.

    python python/modal_sim/eng1_pieces.py
    python python/modal_sim/eng1_pieces.py --no-write --seconds 2

Outputs (under ``FFT_results/sim/eng1/``):

    eng1_guitar_estudio.wav
    eng1_piano_prelude.wav
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
# guitar: original D-minor study, 84 BPM, 4/4
# ---------------------------------------------------------------------------
GUITAR_BPM = 84.0
GUITAR_BEAT = 60.0 / GUITAR_BPM
GUITAR_BAR = 4.0 * GUITAR_BEAT

#: (bar, beat, midi, duration in beats, velocity)
#: The top note of each arpeggio carries the melodic line.
GUITAR_BARS = [
    # Dm: D3 A3 D4 F4 A4
    [(0, 0.0, 50, 2.0, 0.85), (0, 1.0, 57, 2.0, 0.65),
     (0, 2.0, 62, 2.0, 0.60), (0, 3.0, 65, 2.0, 0.55),
     (0, 3.5, 69, 1.0, 0.50)],
    # Bb: Bb2 F3 Bb3 D4 F4
    [(1, 0.0, 46, 2.0, 0.85), (1, 1.0, 53, 2.0, 0.65),
     (1, 2.0, 58, 2.0, 0.60), (1, 3.0, 62, 2.0, 0.55),
     (1, 3.5, 65, 1.0, 0.50)],
    # Gm: G2 D3 G3 Bb3 D4
    [(2, 0.0, 43, 2.0, 0.85), (2, 1.0, 50, 2.0, 0.65),
     (2, 2.0, 55, 2.0, 0.60), (2, 3.0, 58, 2.0, 0.55),
     (2, 3.5, 62, 1.0, 0.50)],
    # A: A2 E3 A3 C#4 E4
    [(3, 0.0, 45, 2.0, 0.85), (3, 1.0, 52, 2.0, 0.65),
     (3, 2.0, 57, 2.0, 0.60), (3, 3.0, 61, 2.0, 0.55),
     (3, 3.5, 64, 1.0, 0.50)],
    # Dm
    [(4, 0.0, 50, 2.0, 0.85), (4, 1.0, 57, 2.0, 0.65),
     (4, 2.0, 62, 2.0, 0.60), (4, 3.0, 65, 2.0, 0.55),
     (4, 3.5, 69, 1.0, 0.50)],
    # A: half cadence
    [(5, 0.0, 45, 2.0, 0.85), (5, 1.0, 52, 2.0, 0.65),
     (5, 2.0, 57, 2.0, 0.60), (5, 3.0, 61, 2.0, 0.55),
     (5, 3.5, 64, 1.0, 0.50)],
]

# ---------------------------------------------------------------------------
# piano: original C-diminished prelude, 60 BPM, 4/4
# ---------------------------------------------------------------------------
PIANO_BPM = 60.0
PIANO_BEAT = 60.0 / PIANO_BPM
PIANO_BAR = 4.0 * PIANO_BEAT

#: (bar, beat, midi, duration in beats, velocity).  All notes use the "piano"
#: row; the provider falls back to "forte" for the few pitch classes that only
#: have a forte table (B, in particular).
PIANO_BARS = [
    # Cdim: C2 Eb2 A2 Eb2 | C5 B4 A4
    [(0, 0.0, 36, 3.5, 0.75), (0, 1.0, 39, 3.5, 0.60),
     (0, 2.0, 45, 3.5, 0.55), (0, 3.0, 39, 1.5, 0.50),
     (0, 0.0, 72, 3.0, 0.80), (0, 1.5, 71, 1.0, 0.65),
     (0, 2.5, 69, 1.5, 0.60)],
    # F#dim: F#2 A2 C3 A2 | F#5 Eb5 C5
    [(1, 0.0, 42, 3.5, 0.75), (1, 1.0, 45, 3.5, 0.60),
     (1, 2.0, 48, 3.5, 0.55), (1, 3.0, 45, 1.5, 0.50),
     (1, 0.0, 78, 3.0, 0.80), (1, 1.5, 75, 1.0, 0.65),
     (1, 2.5, 72, 1.5, 0.60)],
    # Cdim (higher): C3 Eb3 A3 Eb3 | A5 F#5 Eb5
    [(2, 0.0, 48, 3.5, 0.75), (2, 1.0, 51, 3.5, 0.60),
     (2, 2.0, 57, 3.5, 0.55), (2, 3.0, 51, 1.5, 0.50),
     (2, 0.0, 81, 3.0, 0.80), (2, 1.5, 78, 1.0, 0.65),
     (2, 2.5, 75, 1.5, 0.60)],
    # Bm7(no3): B2 F#2 A2 F#2 | B4 A4 F#4
    [(3, 0.0, 47, 3.5, 0.75), (3, 1.0, 42, 3.5, 0.60),
     (3, 2.0, 45, 3.5, 0.55), (3, 3.0, 42, 1.5, 0.50),
     (3, 0.0, 71, 3.0, 0.80), (3, 1.5, 69, 1.0, 0.65),
     (3, 2.5, 66, 1.5, 0.60)],
    # Cdim: C2 Eb2 A2 Eb2 | C5 Eb5 F#5
    [(4, 0.0, 36, 3.5, 0.75), (4, 1.0, 39, 3.5, 0.60),
     (4, 2.0, 45, 3.5, 0.55), (4, 3.0, 39, 1.5, 0.50),
     (4, 0.0, 72, 3.0, 0.80), (4, 1.5, 75, 1.0, 0.65),
     (4, 2.5, 78, 1.5, 0.60)],
    # Cdim cadence: C2 Eb2 A2 C3 | C5 A4 F#4 Eb4
    [(5, 0.0, 36, 3.5, 0.75), (5, 1.0, 39, 3.5, 0.60),
     (5, 2.0, 45, 3.5, 0.55), (5, 3.0, 48, 1.5, 0.50),
     (5, 0.0, 72, 4.0, 0.80), (5, 1.5, 69, 1.0, 0.65),
     (5, 2.5, 66, 1.5, 0.60), (5, 3.5, 63, 1.0, 0.55)],
]


def guitar_notes() -> list[R.NoteEvent]:
    return [R.NoteEvent(bar * GUITAR_BAR + beat * GUITAR_BEAT,
                        midi, dur * GUITAR_BEAT, vel, "forte")
            for bars in GUITAR_BARS for bar, beat, midi, dur, vel in bars]


def piano_notes() -> list[R.NoteEvent]:
    return [R.NoteEvent(bar * PIANO_BAR + beat * PIANO_BEAT,
                        midi, dur * PIANO_BEAT, vel, "piano")
            for bars in PIANO_BARS for bar, beat, midi, dur, vel in bars]


class PianoTable:
    """Piano table loader with a dynamic fallback.

    The extracted piano index is sparse: a handful of notes only have a
    ``forte`` row (B, for example) and a couple only have ``piano``.  The
    hardware loader must reject a missing key; this renderer is allowed to fall
    back so the piece can use the pitch classes that actually exist.
    """

    def __call__(self, midi: int, dynamic: str = "forte") -> R.Eng1Coeffs:
        for dyn in (str(dynamic), "forte", "piano"):
            try:
                return R.load_a_table("piano", int(midi), dyn)
            except KeyError:
                continue
        raise KeyError(f"piano: no coefficient row for midi {midi}")


def guitar_excitation(_table: R.Eng1Coeffs) -> R.ExcitationConfig:
    # exc_router: GUITAR -> SHIFT=18, PW_LEN=2, one pulse
    return R.ExcitationConfig.guitar()


def piano_excitation(_table: R.Eng1Coeffs) -> R.ExcitationConfig:
    # exc_router default (PIANO falls through): SHIFT=20, PW_LEN=1, one pulse
    return R.ExcitationConfig(shift=20, pw_len=1, gap_len=0, n_pulse=0)


def normalize(y: np.ndarray, peak: float = 0.85) -> np.ndarray:
    x = np.asarray(y, dtype=np.float64) / float(R.Y_ONE)
    m = float(np.max(np.abs(x))) if x.size else 0.0
    return x if m <= 1e-12 else x * (peak / m)


def write_wav(path: str, y: np.ndarray, sr: int = R.SR) -> None:
    import soundfile as sf
    sf.write(path, normalize(y), sr, subtype="PCM_16")


def render_guitar(args):
    renderer = R.ScoreRenderer(
        R.ATable("guitar"), body="guitar", reverb="NONE",
        envelope="dyn", excitation_fn=guitar_excitation, tail_s=1.5)
    return renderer.render(guitar_notes(), seconds=args.seconds)


def render_piano(args):
    renderer = R.ScoreRenderer(
        PianoTable(), body="none", reverb="HALL",
        envelope="adsr", excitation_fn=piano_excitation, tail_s=2.0)
    return renderer.render(piano_notes(), seconds=args.seconds)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--seconds", type=float, default=None,
                    help="truncate the render (default: score length + tail)")
    ap.add_argument("--no-write", action="store_true",
                    help="render and print metrics only (write no WAV)")
    args = ap.parse_args(argv)

    out_dir = paths.SIM_ENG1
    if not args.no_write:
        os.makedirs(out_dir, exist_ok=True)

    pieces = (
        ("guitar", "eng1_guitar_estudio.wav", "Estudio in D minor", render_guitar),
        ("piano", "eng1_piano_prelude.wav", "Prelude in C diminished", render_piano),
    )
    for name, filename, title, fn in pieces:
        t0 = time.time()
        y, meta = fn(args)
        dt = time.time() - t0
        print(f"[{name:6s}] {title}: {y.size / R.SR:5.2f} s audio "
              f"in {dt:5.1f} s  raw peak {meta.raw_peak / R.Y_ONE:8.4f}  "
              f"rms {meta.raw_rms / R.Y_ONE:8.4f}  "
              f"body_sat {meta.body_sat}  reverb {meta.reverb}")
        if meta.warnings:
            for w in meta.warnings:
                print(f"           WARNING: {w}")
        if not args.no_write:
            write_wav(os.path.join(out_dir, filename), y)
            print(f"wrote {out_dir}/{filename}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
