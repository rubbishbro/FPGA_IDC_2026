"""Drum kit: render percussion hits and a groove, alone or with guitar/piano.

Percussion is Class C. A hit is rendered as
    modal part : sum_k  a_k * exp(-gamma_k t) * sin(2*pi f_k t)
    noise part : white noise -> FIR shaped to the hit's residual 1/3-octave curve,
                 times exp(-gamma_noise t)
The modal part carries the resonances (kick, toms, cowbell, woodblock, cymbal metal);
the noise part carries what the modes do not explain (snare wires, cymbal wash).

    python python_monotor/modal_sim/drumkit.py            # groove + guitar + piano
    python python_monotor/modal_sim/drumkit.py --drums    # drums only

.. note::
   As of 2026-10-27 the additive C renderer here is legacy.  New C synthesis
   uses ``eng1_bc.CSynth`` (seed + timer + choke on the shared ``Eng1Core``).
   This file is still the reference for the extracted kit data and the old
   additive/noise comparison.

Kit data comes from ``python_monotor/results/drums.npz`` (run
``python python_monotor/fft_analysis/percussion.py`` first).
"""

from __future__ import annotations

import json
import os
import sys
import time

import numpy as np
import soundfile as sf
from scipy.signal import firwin2
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt                     # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "fft_analysis"))

import core as CORE                                  # noqa: E402
import instruments                                   # noqa: E402
import params as P                                   # noqa: E402
import paths                                         # noqa: E402
import percussion as PC                              # noqa: E402
from engine import ModalSynth                        # noqa: E402

OUT = paths.SIM_DRUMS
FIG = paths.SIM_DRUMS
SR = P.SR

BPM = 120.0
BEAT = 60.0 / BPM
BAR = 4.0 * BEAT
DRUMS = os.path.join(paths.PARAMS, "drums.npz")


# ---------------------------------------------------------------------------
# rendering one hit
# ---------------------------------------------------------------------------

def render_modal(hit, seconds, vel=1.0, rng=None):
    """Additive modal render. Per-mode phases matter: with all phases equal the 64
    modes start perfectly in phase and produce one broadband spike instead of a hit."""
    n = int(seconds * SR)
    if n <= 0:
        return np.zeros(0)
    t = np.arange(n) / SR
    y = np.zeros(n)
    ph = (rng.uniform(0.0, 2.0 * np.pi, size=hit["f"].size) if rng is not None
          else np.zeros(hit["f"].size))
    for a, g, f, p in zip(hit["a"], hit["gamma"], hit["f"], ph):
        y += a * np.exp(-g * t) * np.sin(2.0 * np.pi * f * t + p)
    return vel * y


def _noise_filter(hit):
    # One implementation only: percussion.noise_filters is what the extractor also
    # measures its render-domain calibration against.
    return PC.noise_filters(hit, sr=SR)


_FILT_CACHE: dict = {}


def render_noise(hit, seconds, vel, rng, scale):
    n = int(seconds * SR)
    if n <= 0 or hit["noise_gain"] <= 0:
        return np.zeros(max(n, 0))
    if id(hit) not in _FILT_CACHE:
        _FILT_CACHE[id(hit)] = _noise_filter(hit)
    # Same function the extractor calibrated against (LF/HF split, optional contact
    # transient), so the two branches cannot drift apart.
    y = PC.noise_signal(hit, n, SR, rng, filters=_FILT_CACHE[id(hit)])
    return vel * scale * hit["noise_gain"] * y


#: kit balance -- the library's own recorded levels make the cymbals dominate the
#: mix (a sizzle ride rings for seconds), so each piece is peak-normalised and the
#: balance is set here, before velocity.
KIT_GAIN = {"kick": 1.0, "snare": 0.8, "hat": 0.30, "tom": 0.8, "crash": 0.45,
            "ride": 0.28}
_NORM_CACHE: dict = {}
_LEN_CACHE: dict = {}


def hit_length(kit, key, cap=3.0, floor_db=-45.0):
    """Length until the RENDERED hit falls below `floor_db` relative to its peak.

    Deliberately not ``6/env_gamma``: that used a single broadband number for both
    the noise decay and the note length, and the modal tail can outlast the noise
    tail (advisor, 2026-09-29). Render once, take the last sample still above the
    threshold, and keep a hard `cap` plus the tail fade so overlapping hits cannot
    pile up into a wash.
    """
    hit = kit[key]
    ck = (id(hit), round(float(cap), 2), float(floor_db))
    if ck in _LEN_CACHE:
        return _LEN_CACHE[ck]
    rng = np.random.default_rng(0)
    y = np.abs(render_modal(hit, cap, 1.0, rng)
               + render_noise(hit, cap, 1.0, rng, 1.0))
    k = max(1, int(0.005 * SR))
    env = np.convolve(y, np.ones(k) / k, mode="same")
    pk = float(env.max()) if env.size else 0.0
    length = 0.12
    if pk > 0:
        above = np.nonzero(env > pk * 10.0 ** (floor_db / 20.0))[0]
        if above.size:
            length = float(above[-1]) / SR + 0.05
    length = float(min(cap, max(0.12, length)))
    _LEN_CACHE[ck] = length
    return length


def _piece_norm(kit, key, noise_scale, cap):
    hit = kit[key]
    ck = (id(hit), round(float(noise_scale), 3), round(float(cap), 2))
    if ck not in _NORM_CACHE:
        L = hit_length(kit, key, cap)
        y = (render_modal(hit, L, 1.0, np.random.default_rng(0))
             + render_noise(hit, L, 1.0, np.random.default_rng(0), noise_scale))
        _NORM_CACHE[ck] = 1.0 / max(float(np.max(np.abs(y))), 1e-9)
    return _NORM_CACHE[ck]


def render_kit_hit(kit, key, seconds, vel, rng, noise_scale, gain=True, cap=3.0):
    hit = kit[key]
    y = (render_modal(hit, seconds, vel, rng)
         + render_noise(hit, seconds, vel, rng, noise_scale))
    if gain:
        y = y * _piece_norm(kit, key, noise_scale, cap) * KIT_GAIN.get(key, 1.0)
    n = y.size
    f = min(n, int(0.05 * SR))                     # fade the tail, never cut it
    if f > 2:
        y[-f:] *= np.linspace(1.0, 0.0, f) ** 2
    return y


# ---------------------------------------------------------------------------
# groove
# ---------------------------------------------------------------------------

# (beat, drum, velocity) over 4 bars; 1 = beat 1 of bar 1
def groove(bars=4):
    ev = []
    for b in range(bars):
        t0 = b * 4.0
        ev += [(t0 + 0.0, "kick", 1.0), (t0 + 2.0, "kick", 0.85),
               (t0 + 2.5, "kick", 0.6)]
        ev += [(t0 + 1.0, "snare", 0.9), (t0 + 3.0, "snare", 0.95)]
        for k in range(8):
            ev.append((t0 + k * 0.5, "hat", 0.55 if k % 2 == 0 else 0.35))
        if b == 0:
            ev.append((t0 + 0.0, "crash", 0.8))
        if b == bars - 1:
            ev += [(t0 + 3.0, "tom", 0.8), (t0 + 3.5, "tom", 0.9)]
        else:
            ev.append((t0 + 3.5, "ride", 0.4))
    return ev


def render_drums(kit, ev, seconds, rng, noise_scale=1.0, cap=3.0, beat_s=None):
    """`ev` is a list of (beat, key, velocity); `beat_s` lets another tempo drive it
    (the drumkit's own default is 120 BPM)."""
    b = BEAT if beat_s is None else float(beat_s)
    y = np.zeros(int(seconds * SR))
    for beat, key, vel in ev:
        t0 = int(round(beat * b * SR))
        seg = render_kit_hit(kit, key, hit_length(kit, key, cap), vel, rng,
                             noise_scale, cap=cap)
        n = min(len(seg), len(y) - t0)
        if n > 0:
            y[t0:t0 + n] += seg[:n]
    return y


def render_band(kit_events_seconds, seconds):
    """A simple guitar (power chords) + piano bed, same engine as the other demos."""
    prog = ["Am", "F", "C", "G"]
    gch = {"Am": [45, 52, 57], "F": [41, 48, 53], "C": [48, 55, 60], "G": [43, 50, 55]}
    pch = {"Am": [57, 60, 64], "F": [53, 57, 60], "C": [60, 64, 67], "G": [55, 59, 62]}
    bass = {"Am": 33, "F": 29, "C": 36, "G": 31}
    ge, pe = [], []
    for bar in range(4):
        name = prog[bar]
        t0 = bar * BAR
        for beat in range(4):
            t = t0 + beat * BEAT
            v = 0.85 if beat % 2 == 0 else 0.6
            for i, n in enumerate(gch[name]):
                ge.append((t + i * 0.012, n, 0.32, v))
        for n in pch[name]:
            pe.append((t0, n, BAR * 0.9, 0.5))
        for beat in (0, 2):
            pe.append((t0 + beat * BEAT, bass[name], BEAT * 1.6, 0.9))
    g = ModalSynth(P.Patch("guitar", band_hz=16_000.0), max_poly=32, high_water=28,
                   noise_amp=0.18, noise_lp_hz=3500.0, release_factor=5.0)
    k = ModalSynth(P.Patch("piano", band_hz=20_000.0), max_poly=32, high_water=28,
                   noise_amp=0.08, noise_lp_hz=4500.0, release_factor=6.0)
    return g.render(ge, seconds), k.render(pe, seconds)


def main(argv=None):
    argv = list(argv or [])
    drums_only = "--drums" in argv
    cap = float(argv[argv.index("--cap") + 1]) if "--cap" in argv else 3.0
    tag = ("_" + argv[argv.index("--tag") + 1]) if "--tag" in argv else ""
    paths.makedirs()
    if not os.path.exists(DRUMS):
        print(f"missing {DRUMS}; run: python python_monotor/fft_analysis/percussion.py")
        return 1
    kit = PC.load_kit(DRUMS)
    print("kit:", ", ".join(sorted(kit)))

    bars = 4
    seconds = bars * BAR + 2.0
    rng = np.random.default_rng(3)
    ev = groove(bars)
    t0 = time.time()
    yd = render_drums(kit, ev, seconds, rng, cap=cap)
    if drums_only:
        mix = yd
        rep = {}
    else:
        yg, yk = render_band(ev, seconds)
        # level-match the parts first: the engine renders a note at unit velocity to a
        # peak of 5-6, which buried the drums by ~20 dB.
        yg = yg / max(float(np.max(np.abs(yg))), 1e-12)
        yk = yk / max(float(np.max(np.abs(yk))), 1e-12)
        mix = 1.2 * yd + 0.42 * yg + 0.42 * yk
        rep = dict(guitar_peak=round(float(np.max(np.abs(yg))), 3),
                   piano_peak=round(float(np.max(np.abs(yk))), 3),
                   drums_rms=round(float(np.sqrt((yd ** 2).mean())), 4),
                   band_rms=round(float(np.sqrt((0.42 * yg + 0.42 * yk) ** 2).mean()), 4))
    mix = np.tanh(mix * 0.9) / np.tanh(0.9)
    mix *= 0.9 / max(float(np.max(np.abs(mix))), 1e-12)

    name = ("drums_only" if drums_only else "drums_band") + tag
    path = os.path.join(OUT, f"{name}.wav")
    sf.write(path, mix, SR, subtype="PCM_16")
    report = dict(bpm=BPM, bars=bars, tail_cap_s=cap, seconds=round(seconds, 2),
                  render_s=round(time.time() - t0, 1),
                  hits=len(ev), peak=round(float(np.max(np.abs(mix))), 3),
                  finite=bool(np.isfinite(mix).all()), **rep)
    with open(os.path.join(OUT, f"{name}.json"), "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2)
    fig(mix, name)
    print(f"wrote {path}  ({seconds:.1f}s, render {report['render_s']}s, "
          f"peak {report['peak']})")
    return 0


def fig(mix, name):
    t = np.arange(len(mix)) / SR
    fig, ax = plt.subplots(2, 1, figsize=(12, 7), constrained_layout=True)
    ax[0].plot(t, mix, lw=0.3)
    ax[0].set_title(f"{name}: drum groove{' + guitar + piano' if name.endswith('band') else ''}")
    ax[0].set_ylabel("amp"); ax[0].grid(alpha=0.3)
    for b in range(int(t[-1] // BAR) + 1):
        ax[0].axvline(b * BAR, color="0.85", lw=0.6)
    ax[1].specgram(mix, NFFT=1024, Fs=SR, noverlap=512, cmap="magma",
                   vmin=-120, vmax=-20)
    ax[1].set_ylim(0, 8000); ax[1].set_ylabel("Hz"); ax[1].set_xlabel("s")
    fig.savefig(os.path.join(FIG, f"{name}.png"), dpi=110); plt.close(fig)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
