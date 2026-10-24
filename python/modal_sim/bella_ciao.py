#!/usr/bin/env python3
"""Bella Ciao (trad. Italian) played on the Class-A modal mandolin.

Everything here is the *current* Class-A engine: one raised-cosine force pulse into
the extracted mandolin modal bank, shared body IIR, scheme-C voice kill.  No
samples, no extra DSP -- the only things this file adds are the score and the
player's gestures (tremolo, chop, bass).

Score provenance
----------------
The tune is the Italian resistance song "Bella Ciao" (anonymous, 19th c.).  The
melody table below is a direct transcription of the public-domain MIDI
``File:Bella ciao.mid`` on Wikimedia Commons (setting by Rabanus Flavus, 2023),
read note by note, quantised to the 1/8 grid and re-barred into 4/4.  That reading
agrees with the note-for-note version in the C++ "BellaCiao-CPP" sketch and with
the lyric-aligned staff notation used by the Irish folk-song letter-note sheet:
the verse hook is 5-1-2-3-1 (E A B C A in Am).  The MIDI is in F# minor; the table
is transposed down a major third to **D minor**, which keeps the whole tune in the
mandolin's singing register (A3-G5) instead of the thin top octave.

The score is 16 bars (verse 1-8, "O partigiano" strain 9-16) at 120 BPM, 4/4.

Arrangement (all Class A, three separate voice pools)
-----------------------------------------------------
* **lead**  -- mandolin, the melody.  A plucked mandolin note dies in ~0.25 s
  (measured median gamma ~4.2 1/s), so sustained notes are *tremolo*: the same
  pitch is re-struck every 80 ms with jittered timing/velocity, which is exactly
  how the instrument sustains a note.
* **chop**  -- mandolin backbeat chords on beats 2 and 4, damped 100 ms after the
  attack (``release_factor``), i.e. the bluegrass "chop".
* **bass**  -- guitar (the other Class-A plucked patch), root-fifth march.

Pass 1 is the bare lead, pass 2 adds chop + bass, then a Dm cadence.

    python python/modal_sim/bella_ciao.py            # full render (~68 s audio)
    python python/modal_sim/bella_ciao.py --bars 4   # smoke test
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

import numpy as np
import soundfile as sf
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt                     # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))            # python/ -> paths, instruments
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "fft_analysis"))

import params as P                                  # noqa: E402
import paths                                        # noqa: E402
from engine import ModalSynth                       # noqa: E402

OUT = paths.SIM_SONG
BPM = 120.0
BEAT = 60.0 / BPM                                   # 0.5 s
BAR = 4.0 * BEAT                                    # 2.0 s
PASSES = 2
TAIL = 3.0

# Mandolin settings from instruments.REGISTRY["mandolin"]
MANDO = dict(noise_amp=0.16, noise_lp_hz=4000.0)

# MIDI shorthand, D minor:  D3=50  A3=57  C4=60  D4=62  E4=64  F4=65  G4=67
#                           A4=69  Bb4=70  C5=72  C#5=73  D5=74  E5=76  F5=77  G5=79
# (bar, beat, midi, length in beats) -- beats measured from the bar line
SCORE = [
    # --- verse, line 1: "Una mattina mi son svegliato" (A D E F D x2) ---------
    (1, 0.0, 57, 0.5), (1, 0.5, 62, 0.5), (1, 1.0, 64, 0.5), (1, 1.5, 65, 0.5),
    (1, 2.0, 62, 2.0),
    (2, 0.0, 57, 0.5), (2, 0.5, 62, 0.5), (2, 1.0, 64, 0.5), (2, 1.5, 65, 0.5),
    (2, 2.0, 62, 1.5),
    # --- line 2: "o bella ciao, bella ciao, bella ciao ciao ciao" ------------
    (3, 0.0, 57, 0.5), (3, 0.5, 62, 0.5), (3, 1.0, 64, 0.5), (3, 1.5, 65, 1.0),
    (3, 2.5, 64, 0.5), (3, 3.0, 62, 0.5), (3, 3.5, 65, 1.0),
    (4, 0.5, 64, 0.5), (4, 1.0, 62, 0.5), (4, 1.5, 69, 0.5),
    (4, 2.5, 69, 0.5), (4, 3.5, 69, 0.5),
    # --- line 3: "Una mattina mi son svegliato" (an octave up) ---------------
    (5, 0.0, 69, 0.5), (5, 0.5, 67, 0.5), (5, 1.0, 69, 0.5), (5, 1.5, 70, 0.5),
    (5, 2.0, 70, 2.0),
    (6, 0.0, 70, 0.5), (6, 0.5, 69, 0.5), (6, 1.0, 67, 0.5), (6, 1.5, 70, 0.5),
    (6, 2.0, 69, 1.5),
    # --- line 4: "e ho trovato l'invasor" ------------------------------------
    (7, 0.0, 69, 0.5), (7, 0.5, 67, 0.5), (7, 1.0, 65, 0.5), (7, 1.5, 64, 1.0),
    (7, 2.5, 69, 1.0), (7, 3.5, 65, 1.0),
    (8, 0.5, 64, 1.0), (8, 1.5, 62, 2.0),
    # --- "O partigiano, portami via" -----------------------------------------
    (9, 0.0, 65, 0.5), (9, 0.5, 69, 0.5), (9, 1.0, 73, 0.5), (9, 1.5, 74, 0.5),
    (9, 2.0, 69, 2.0),
    (10, 0.0, 65, 0.5), (10, 0.5, 69, 0.5), (10, 1.0, 72, 0.5), (10, 1.5, 74, 0.5),
    (10, 2.0, 70, 1.5),
    (11, 0.0, 64, 0.5), (11, 0.5, 69, 0.5), (11, 1.0, 72, 0.5), (11, 1.5, 74, 1.0),
    (11, 3.5, 74, 1.0),
    (12, 1.5, 77, 0.5), (12, 2.5, 74, 0.5), (12, 3.5, 76, 0.5),
    # --- "o bella ciao, bella ciao, bella ciao ciao ciao" (climax) -----------
    (13, 0.0, 77, 0.5), (13, 0.5, 76, 0.5), (13, 1.0, 77, 0.5), (13, 1.5, 79, 0.5),
    (13, 2.0, 79, 2.0),
    (14, 0.0, 79, 0.5), (14, 0.5, 77, 0.5), (14, 1.0, 76, 0.5), (14, 1.5, 79, 0.5),
    (14, 2.0, 77, 1.5),
    (15, 0.0, 77, 0.5), (15, 0.5, 76, 0.5), (15, 1.0, 74, 0.5), (15, 1.5, 73, 1.0),
    (15, 2.5, 74, 1.0), (15, 3.5, 73, 1.0),
    (16, 0.5, 69, 1.0), (16, 1.5, 69, 2.0),
]

# one chord + one bass root per bar; the voicings sit on real mandolin strings
CHORDS = {
    1: [57, 62, 65], 2: [57, 62, 65], 3: [57, 62, 65], 4: [57, 62, 65],
    5: [55, 62, 67], 6: [55, 62, 67], 7: [57, 62, 65], 8: [57, 64, 67],
    9: [57, 62, 65], 10: [58, 65, 70], 11: [57, 62, 65], 12: [57, 62, 65],
    13: [55, 62, 67], 14: [55, 62, 67], 15: [57, 64, 67], 16: [57, 62, 65],
}
BASS = {1: 38, 2: 38, 3: 38, 4: 38, 5: 43, 6: 43, 7: 38, 8: 45,
        9: 38, 10: 46, 11: 38, 12: 38, 13: 43, 14: 43, 15: 45, 16: 38}
FIFTH = {38: 45, 43: 50, 45: 52, 46: 53}          # root -> fifth, same register


# ---------------------------------------------------------------------------
def tremolo(events, period=0.080, rng=None):
    """Expand long notes into mandolin tremolo strokes.

    A stroke every `period` seconds with +-4 ms timing jitter and a little
    velocity wobble.  Notes up to an 8th (0.45 s at 120 BPM) stay single plucks:
    the pick only becomes a roll when the note outlives the string (~0.25 s here).
    """
    rng = rng or np.random.default_rng(11)
    out = []
    for t, midi, dur, vel in events:
        if dur < 0.45:          # an 8th note or shorter: a single pluck, not a roll
            out.append((t, midi, dur, vel))
            continue
        n = int(dur / period)
        for i in range(n):
            jt = t + i * period + rng.uniform(-0.004, 0.004)
            dt = min(period * 1.15, dur - i * period)
            v = vel * rng.uniform(0.82, 1.0)
            out.append((max(t, jt), midi, dt, v))
    return out


def melody(t0=0.0, lead_vel=0.95):
    return [(t0 + (b - 1) * BAR + beat * BEAT, midi, dur * BEAT, lead_vel)
            for b, beat, midi, dur in SCORE]


def accompaniment(t0=0.0):
    """Chop on beats 2 and 4 + root-fifth bass; returns (chop, bass)."""
    chop, bass = [], []
    for b in range(1, 17):
        b0 = t0 + (b - 1) * BAR
        for beat in (1.0, 3.0):                    # beats 2 and 4 (1-based)
            for n in CHORDS[b]:
                # attack + short damp: ModalSynth.note_off is keyed by midi, so the
                # chop lives in its own voice pool and cannot damp the melody
                chop.append((b0 + beat * BEAT, n, 0.10, 0.55))
        root = BASS[b]
        bass.append((b0, root, 1.7 * BEAT, 0.85))
        bass.append((b0 + 2 * BEAT, FIFTH[root], 1.7 * BEAT, 0.70))
    return chop, bass


def coda(t0):
    """Final Dm cadence: lead plucks (durations are one attack; the modal bank
    rings on by itself) plus a low guitar D."""
    lead = [(t0, 69, 0.2, 0.90), (t0, 65, 0.2, 0.70),
            (t0, 62, 0.2, 0.70), (t0, 50, 0.2, 0.80)]
    bass = [(t0, 38, 0.2, 0.90)]
    return lead, bass


# ---------------------------------------------------------------------------
def render(bars=16, verbose=True):
    paths.makedirs()
    t_start = time.time()
    total = PASSES * bars * BAR + TAIL

    mando = P.Patch("mandolin", band_hz=16_000.0, max_modes=64)
    guitar = P.Patch("guitar", band_hz=16_000.0)

    rng = np.random.default_rng(5)
    lead = ModalSynth(mando, max_poly=40, high_water=36, seed=3, **MANDO)
    chop = ModalSynth(mando, max_poly=24, high_water=20, release_factor=4.0,
                      seed=4, **MANDO)
    bass = ModalSynth(guitar, max_poly=12, high_water=10, release_factor=1.0,
                      noise_amp=0.18, noise_lp_hz=3500.0, seed=5)

    # pass 1: bare lead.  pass 2: lead + chop + bass.
    lead_ev = melody(0.0) if bars < 16 else melody(0.0) + melody(bars * BAR)
    lead_ev = tremolo(lead_ev, rng=rng)
    tail_lead, tail_bass = coda(PASSES * bars * BAR)
    lead_ev += tail_lead
    yl = lead.render(lead_ev, total)

    ev_chop, ev_bass = accompaniment(bars * BAR)
    ev_bass += tail_bass
    yc = chop.render(ev_chop, total)
    yb = bass.render(ev_bass, total)

    # level-match the parts, then a gentle bus saturation (as in song.py)
    yl /= max(float(np.max(np.abs(yl))), 1e-12)
    yc /= max(float(np.max(np.abs(yc))), 1e-12)
    yb /= max(float(np.max(np.abs(yb))), 1e-12)
    mix = 1.00 * yl + 0.42 * yc + 0.55 * yb
    mix = np.tanh(mix * 0.8) / np.tanh(0.8)
    mix *= 0.9 / max(np.max(np.abs(mix)), 1e-12)

    report = dict(
        song="Bella Ciao (trad. Italian)", instrument="mandolin (Class A)",
        key="Dm", tempo_bpm=BPM, bars=16 * PASSES, beats_per_bar=4,
        seconds=round(total, 2), render_s=round(time.time() - t_start, 1),
        arrangement="pass 1 lead only; pass 2 lead + mandolin chop + guitar bass",
        lead=dict(notes=len(lead_ev), kills=lead.kill_count, hard=lead.hard_count,
                  max_active=int(max(lead.active_hist))),
        chop=dict(notes=len(ev_chop), kills=chop.kill_count, hard=chop.hard_count,
                  max_active=int(max(chop.active_hist))),
        bass=dict(notes=len(ev_bass), kills=bass.kill_count, hard=bass.hard_count,
                  max_active=int(max(bass.active_hist))),
        mix_peak=round(float(np.max(np.abs(mix))), 3),
        finite=bool(np.isfinite(mix).all()),
        body_rmse_db=round(mando.body_rmse, 2),
    )
    return mix, report


def fig(mix, path, report):
    t = np.arange(len(mix)) / P.SR
    fig_, ax = plt.subplots(3, 1, figsize=(13, 9), constrained_layout=True)

    ax[0].plot(t, mix, lw=0.25, color="0.25")
    ax[0].set_title("Bella Ciao -- Class-A modal mandolin "
                    f"(Dm, {BPM:.0f} BPM, {report['bars']} bars)")
    ax[0].set_ylabel("amp"); ax[0].grid(alpha=0.3)
    for p in range(PASSES):
        ax[0].axvline(p * 16 * BAR, color="crimson", lw=0.8, alpha=0.6)
    ax[0].text(PASSES // 2 * 16 * BAR + 0.3, 0.84, "chop + bass enter",
               fontsize=8, color="crimson")
    ax[0].text(0.3, 0.84, "solo mandolin", fontsize=8, color="crimson")

    ax[1].specgram(mix, NFFT=2048, Fs=P.SR, noverlap=1024, cmap="magma",
                   vmin=-120, vmax=-20)
    ax[1].set_ylim(0, 6000); ax[1].set_ylabel("Hz"); ax[1].set_xlabel("s")

    win = int(0.05 * P.SR)
    rms = np.sqrt(np.convolve(mix ** 2, np.ones(win) / win, mode="same"))
    ax[2].plot(t, 20 * np.log10(rms + 1e-9), lw=0.7, color="seagreen")
    ax[2].set_ylabel("dB"); ax[2].set_xlabel("s"); ax[2].grid(alpha=0.3)
    ax[2].set_title("short-time RMS")

    fig_.savefig(path, dpi=110); plt.close(fig_)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--bars", type=int, default=16, help="bars per pass (smoke test)")
    ap.add_argument("--tag", default="bella_ciao_mandolin")
    args = ap.parse_args(argv)

    mix, report = render(bars=args.bars)
    wav = os.path.join(OUT, f"{args.tag}.wav")
    sf.write(wav, mix, P.SR, subtype="PCM_16")
    if args.bars >= 16:
        fig(mix, os.path.join(OUT, f"{args.tag}.png"), report)
    with open(os.path.join(OUT, f"{args.tag}.json"), "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2, ensure_ascii=False)
    print(f"wrote {wav}  ({report['seconds']}s audio, render "
          f"{report['render_s']}s, peak {report['mix_peak']}, "
          f"kills lead/chop/bass = {report['lead']['kills']}/"
          f"{report['chop']['kills']}/{report['bass']['kills']})")
    return report


if __name__ == "__main__":
    raise SystemExit(0 if main() else 1)
