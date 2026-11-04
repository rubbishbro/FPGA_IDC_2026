"""Render a real song excerpt through the modal engine.

Chorus of Beyond《不可一世》(1992), key **Cm**, 4/4, ≈150 BPM.

Provenance of the data
----------------------
* **Chords / key / tempo**: the chorus progression
  ``Cm | Ab | Eb | Bb | Cm | Ab | Fm | Bb | Cm``, key Cm and ~150 BPM come from two
  independent public chord charts (guitarians #66859, 520mus #21) that agree.
* **Melody**: transcribed from public jianpu charts (生产队 / 刘传 arrangements, marked
  ``1=Eb`` with ``6=C`` as the Cm tonic and ``♩=150`` — which independently confirms the
  key and tempo). The repeated-note hook ``3̇ 1̇ 1̇ 1̇ 2̇ | 2̇ - 3̇ 3̇ 3̇ 3̇`` and the
  ``#4 -> 6`` (A -> C) cadence are common to both sheets. Free versions of those sheets
  are partial/pay-walled, so exact syllable alignment may differ in a note or two.

The point is the engine, not a cover: the guitar, piano and bass are all synthesised
from the FFT-extracted modal parameters in ``python_monotor/results/``, with the same code path as
the melody/stress demos.

    python python_monotor/modal_sim/song.py
"""

from __future__ import annotations

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
sys.path.insert(0, os.path.dirname(HERE))            # python_monotor/ -> paths, instruments
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "fft_analysis"))

import drumkit as DK                                 # noqa: E402
import params as P                                  # noqa: E402
import paths                                        # noqa: E402
import percussion as PC                             # noqa: E402
from engine import ModalSynth                       # noqa: E402

OUT = paths.SIM_SONG
FIG = paths.SIM_SONG

BPM = 150.0
BEAT = 60.0 / BPM
BAR = 4.0 * BEAT
REPEAT = 2

# chord voicings stay inside each patch's recorded range
GUITAR_CHORDS = {                 # Cm, Ab, Eb, Bb, Fm (triads + a few doublings)
    "Cm": [48, 51, 55, 60],
    "Ab": [48, 51, 56],
    "Eb": [51, 55, 58, 63],
    "Bb": [46, 50, 53, 58],
    "Fm": [53, 56, 60],
}
PIANO_CHORDS = {
    "Cm": [60, 63, 67],
    "Ab": [56, 60, 63],
    "Eb": [63, 67, 70],
    "Bb": [58, 62, 65],
    "Fm": [65, 68, 72],
}
BASS = {"Cm": 36, "Ab": 32, "Eb": 39, "Bb": 34, "Fm": 41}

PROG = ["Cm", "Ab", "Eb", "Bb", "Cm", "Ab", "Fm", "Bb", "Cm"]

# Chorus vocal melody, transcribed from public jianpu charts (生产队 / 刘传 编配, 1=Eb,
# 6=C is the Cm tonic; ♩=150 confirms the key/tempo). Each bar is a list of
# (midi, beats) summing to 4.  The hook is the repeated-note shout
# "3̇ 1̇ 1̇ 1̇ 2̇ | 2̇ - 3̇ 3̇ 3̇ 3̇" and the #4->6 (A->C) cadence.  Verbatim syllable
# alignment across sources varies, so treat this as a good-faith transcription.
LEAD_BARS = [
    [(67, 1), (67, 1), (67, 1), (67, 1)],                   # Cm  今天的他
    [(67, 2), (67, .5), (67, .5), (67, .5), (65, .5)],      # Ab  呼风可改雨
    [(63, 3), (67, .5), (67, .5)],                          # Eb  不可一世
    [(67, 1), (63, 1), (63, .5), (63, .5), (65, 1)],        # Bb  太嚣张
    [(65, 2), (67, .5), (67, .5), (67, .5), (67, .5)],      # Cm  乜哥乜哥
    [(67, 2), (67, .5), (67, .5), (67, .5), (65, .5)],      # Ab  多么的讨厌
    [(69, 2), (69, 2)],                                     # Fm  We don't need you any
    [(72, 2), (72, 2)],                                     # Bb  more
    [(72, 4)],                                              # Cm  Go to Hell
]


def bars():
    for r in range(REPEAT):
        for i, name in enumerate(PROG):
            yield r * len(PROG) + i, (r * len(PROG) + i) * BAR, name


def guitar_events(strum=0.012, dur=0.34):
    ev = []
    for _, t0, name in bars():
        for beat in range(4):
            t = t0 + beat * BEAT
            vel = 0.9 if beat % 2 == 0 else 0.62      # accent beats 1 & 3
            for i, n in enumerate(GUITAR_CHORDS[name]):
                ev.append((t + i * strum, n, dur, vel))
    return ev


def lead_events(vel=0.9):
    ev = []
    for idx, t0, _name in bars():
        t = t0
        for n, beats in LEAD_BARS[idx % len(LEAD_BARS)]:
            dur = beats * BEAT
            ev.append((t, n, dur * 0.92, vel))
            t += dur
    return ev


def piano_events(vel=0.5):
    ev = []
    for _, t0, name in bars():
        for n in PIANO_CHORDS[name]:
            ev.append((t0, n, BAR * 0.92, vel))
    return ev


def bass_events(vel=0.9):
    ev = []
    for _, t0, name in bars():
        for beat in (0, 2):
            ev.append((t0 + beat * BEAT, BASS[name], BEAT * 1.7, vel))
    return ev


def drum_events(bars_n=None):
    """Rock chorus groove, in beats (the drumkit renderer takes its own beat length).

    kick on 1 and 3 (plus an 8th pickup), snare on 2 and 4, hats on 8ths, crash on the
    first beat of each 9-bar chorus, and a tom fill in the last bar of each chorus.
    """
    total_bars = bars_n if bars_n is not None else REPEAT * len(PROG)
    ev = []
    for b in range(total_bars):
        t0 = b * 4.0
        ev += [(t0 + 0.0, "kick", 1.0), (t0 + 2.0, "kick", 0.85),
               (t0 + 2.5, "kick", 0.55)]
        ev += [(t0 + 1.0, "snare", 0.9), (t0 + 3.0, "snare", 0.95)]
        for k in range(8):
            ev.append((t0 + k * 0.5, "hat", 0.5 if k % 2 == 0 else 0.32))
        if b % len(PROG) == 0:
            ev.append((t0 + 0.0, "crash", 0.75))
        if b % len(PROG) == len(PROG) - 1:
            ev += [(t0 + 3.0, "tom", 0.8), (t0 + 3.5, "tom", 0.9)]
        else:
            ev.append((t0 + 3.5, "ride", 0.35))
    return ev


def main():
    paths.makedirs()
    total = REPEAT * len(PROG) * BAR + 3.0

    guitar = P.Patch("guitar", band_hz=16_000.0)
    keys = P.Patch("piano", band_hz=20_000.0)

    t0 = time.time()
    # Rhythm guitar: a short release makes each stab a palm-muted chunk. With the
    # strings' natural 1-2 s ring, four strums per bar pile up past the pool and the
    # scheme-C kill would chop the part (308 steals in the first attempt).
    r = ModalSynth(guitar, max_poly=32, high_water=28, noise_amp=0.18,
                   noise_lp_hz=3500.0, release_factor=5.0)
    yr = r.render(guitar_events(), total)
    # Lead (illustrative): separate voice so it keeps the string's natural ring.
    l = ModalSynth(guitar, max_poly=16, high_water=13, noise_amp=0.18,
                   noise_lp_hz=3500.0, release_factor=3.0)
    yl = l.render(lead_events(), total)
    # Keys + bass: damper so the pad re-articulates each bar instead of smearing.
    k = ModalSynth(keys, max_poly=32, high_water=28, noise_amp=0.08,
                   noise_lp_hz=4500.0, release_factor=6.0)
    yk = k.render(piano_events() + bass_events(), total)

    # Drums (Class C): each hit is modal + noise, rendered by the drumkit renderer.
    kit = PC.load_kit(os.path.join(paths.PARAMS, "drums.npz"))
    drng = np.random.default_rng(7)
    yd = DK.render_drums(kit, drum_events(), total, drng, cap=3.0, beat_s=BEAT)

    # level-match the parts first, then saturate *gently*: driving tanh with the raw
    # track peaks (5-6) turned the whole chorus into a flat wall with no dynamics.
    yr /= max(float(np.max(np.abs(yr))), 1e-12)
    yl /= max(float(np.max(np.abs(yl))), 1e-12)
    yk /= max(float(np.max(np.abs(yk))), 1e-12)
    yd /= max(float(np.max(np.abs(yd))), 1e-12)
    mix = 0.42 * yr + 0.26 * yl + 0.40 * yk + 0.95 * yd
    mix = np.tanh(mix * 0.9) / np.tanh(0.9)          # gentle bus saturation
    mix *= 0.9 / max(np.max(np.abs(mix)), 1e-12)

    path = os.path.join(OUT, "beyond_chorus.wav")
    sf.write(path, mix, P.SR, subtype="PCM_16")

    report = dict(song="Beyond - Bu Ke Yi Shi (chorus)", key="Cm", bpm=BPM,
                  bars=REPEAT * len(PROG), seconds=round(total, 2),
                  render_s=round(time.time() - t0, 1),
                  rhythm=dict(kills=r.kill_count, hard=r.hard_count,
                              max_active=int(max(r.active_hist)),
                              peak=round(float(np.max(np.abs(yr))), 3)),
                  lead=dict(kills=l.kill_count, hard=l.hard_count,
                            max_active=int(max(l.active_hist)),
                            peak=round(float(np.max(np.abs(yl))), 3)),
                  keys=dict(kills=k.kill_count, hard=k.hard_count,
                            max_active=int(max(k.active_hist)),
                            peak=round(float(np.max(np.abs(yk))), 3)),
                  drums=dict(hits=len(drum_events()),
                             rms=round(float(np.sqrt((yd ** 2).mean())), 4)),
                  mix_peak=round(float(np.max(np.abs(mix))), 3),
                  finite=bool(np.isfinite(mix).all()))
    with open(os.path.join(OUT, "beyond_chorus.json"), "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2, ensure_ascii=False)

    fig_song(mix, path)
    print(f"wrote {path}  ({total:.1f}s, render {report['render_s']}s, "
          f"kills rhythm/lead/keys = {r.kill_count}/{l.kill_count}/{k.kill_count}, "
          f"hard={r.hard_count + l.hard_count + k.hard_count}, "
          f"drums hits={report['drums']['hits']})")
    return report


def fig_song(mix, wav_path):
    t = np.arange(len(mix)) / P.SR
    fig, ax = plt.subplots(3, 1, figsize=(13, 9), constrained_layout=True)

    ax[0].plot(t, mix, lw=0.3)
    ax[0].set_title("Beyond 'Bu Ke Yi Shi' chorus - modal-synth mix "
                    "(drums + rhythm/lead guitar + piano + bass)")
    ax[0].set_ylabel("amp"); ax[0].grid(alpha=0.3)
    for _k, (_, t0, name) in enumerate(bars()):
        ax[0].axvline(t0, color="0.85", lw=0.6)
        ax[0].text(t0 + 0.05, 0.82, name, fontsize=7, color="crimson")

    ax[1].specgram(mix, NFFT=2048, Fs=P.SR, noverlap=1024, cmap="magma",
                   vmin=-120, vmax=-20)
    ax[1].set_ylim(0, 6000); ax[1].set_ylabel("Hz"); ax[1].set_xlabel("s")

    win = int(0.05 * P.SR)
    rms = np.sqrt(np.convolve(mix ** 2, np.ones(win) / win, mode="same"))
    ax[2].plot(t, 20 * np.log10(rms + 1e-9), lw=0.8)
    ax[2].set_ylabel("dB"); ax[2].set_xlabel("s"); ax[2].grid(alpha=0.3)
    ax[2].set_title("short-time RMS")

    out = os.path.join(FIG, "beyond_chorus.png")
    fig.savefig(out, dpi=110); plt.close(fig)
    return out


if __name__ == "__main__":
    raise SystemExit(0 if main() else 1)
