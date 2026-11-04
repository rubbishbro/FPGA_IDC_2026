"""Stereo audition mix for the Mystery of Love flute excerpt.

The engine is mono and dry by design.  This script does **not** change the engine; it
takes the rendered flute and guitar stems and builds a small stereo presentation mix:

* gentle low/high shelves on each stem (warmth, soften the top),
* guitar highs panned left with a 10 ms Haas copy on the right, guitar lows kept centred
  (bass management, so the mono sum keeps the dry balance),
* the RTL 4-comb reverb, run as a stereo pair (right delays +23 samples), 14% wet and
  low-passed at 4 kHz,
* peak normalisation only -- no compressor or limiter.

The raw engine outputs stay ``mystery_flute*.wav``; this writes
``mystery_flute_stereo.wav`` only.

    python python_monotor/modal_sim/stereo_mix.py
"""

from __future__ import annotations

import json
import os
import sys

import numpy as np
import soundfile as sf
from scipy.signal import butter, sosfilt

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "fft_analysis"))

import paths                                         # noqa: E402

OUT = paths.SIM_SONG
SR = 48_000
COMB = (1116, 1188, 1277, 1356)
FB, DAMP = 0.71875, 0.125


def shelf(x, lo_hz=350.0, lo_db=0.0, hi_hz=5000.0, hi_db=0.0):
    """One-pole low/high shelves (6 dB/oct), gains in dB."""
    if lo_db:
        lp = sosfilt(butter(1, lo_hz / (SR / 2), "low", output="sos"), x)
        x = x + (10.0 ** (lo_db / 20.0) - 1.0) * lp
    if hi_db:
        hp = x - sosfilt(butter(1, hi_hz / (SR / 2), "low", output="sos"), x)
        x = x - (1.0 - 10.0 ** (hi_db / 20.0)) * hp
    return x


def rtl_reverb(x, delays=COMB):
    """The ``history/core_2026-11-01/rtl/core/comb_reverb.sv`` 4-comb equations, sample for sample."""
    n = len(x)
    bufs = [np.zeros(d) for d in delays]
    lps = [0.0] * 4
    pos = [0] * 4
    y = np.zeros(n)
    for i in range(n):
        xi = float(x[i])
        s = 0.0
        for j, d in enumerate(delays):
            b = bufs[j]
            p = pos[j]
            sj = b[p]
            lpj = lps[j]
            s += sj
            b[p] = xi + FB * lpj
            lps[j] = sj + DAMP * (lpj - sj)
            pos[j] = p + 1 if p + 1 < d else 0
        y[i] = 0.25 * s
    return y


def stereo_reverb(x):
    """Same reverb on L/R, right comb delays offset by the Freeverb 23 samples."""
    l = rtl_reverb(x, COMB)
    r = rtl_reverb(x, tuple(d + 23 for d in COMB))
    lp = butter(2, 4000.0 / (SR / 2), "low", output="sos")
    return sosfilt(lp, l), sosfilt(lp, r)


def main():
    flute, sr = sf.read(os.path.join(OUT, "mystery_flute_solo.wav"))
    guitar, _ = sf.read(os.path.join(OUT, "mystery_guitar.wav"))
    assert sr == SR and len(flute) == len(guitar)

    flute = shelf(flute, lo_hz=350.0, lo_db=1.5, hi_hz=6000.0, hi_db=-1.5)
    guitar = shelf(guitar, lo_hz=250.0, lo_db=2.0, hi_hz=5000.0, hi_db=-2.0)

    # keep the dry balance (flute 0.95 / guitar 0.32) and pan only the guitar highs;
    # the guitar lows stay centred so the mono sum is unchanged.
    fl = 0.95 * flute
    gt = 0.32 * guitar
    low = sosfilt(butter(2, 220.0 / (SR / 2), "low", output="sos"), gt)
    high = gt - low
    d = int(0.010 * SR)
    delay = np.concatenate([np.zeros(d), high[:-d]])
    pan_l, pan_r = 0.62, 0.38
    left = 0.50 * fl + pan_l * high + 0.50 * low + 0.06 * delay
    right = 0.50 * fl + pan_r * high + 0.50 * low

    send = 0.5 * (left + right)
    wl, wr = stereo_reverb(send)
    left += 0.14 * wl
    right += 0.14 * wr

    mix = np.stack([left, right], axis=1)
    mix *= 0.95 / max(float(np.max(np.abs(mix))), 1e-12)

    path = os.path.join(OUT, "mystery_flute_stereo.wav")
    sf.write(path, mix, SR, subtype="PCM_16")

    m = mix.mean(axis=1)
    S = np.abs(np.fft.rfft(m * np.hanning(len(m))))
    f = np.fft.rfftfreq(len(m), 1 / SR)
    band = (f >= 80) & (f <= 8000)
    P = S[band] ** 2
    rep = dict(file="mystery_flute_stereo.wav", sr=SR, seconds=round(len(m) / SR, 2),
               peak=round(float(np.max(np.abs(mix))), 3),
               rms=round(float(np.sqrt(np.mean(mix ** 2))), 4),
               finite=bool(np.isfinite(mix).all()),
               centroid_hz=round(float((P * f[band]).sum() / P.sum()), 1),
               hf_4k_8k_ratio=round(float(P[f[band] > 4000].sum() / P.sum()), 5),
               low_mid_200_700=round(float(P[(f[band] > 200) & (f[band] < 700)].sum()
                                       / P.sum()), 4),
               note="presentation audition; raw engine output is mystery_flute*.wav")
    with open(os.path.join(OUT, "mystery_flute_stereo.json"), "w",
              encoding="utf-8") as fh:
        json.dump(rep, fh, indent=2, ensure_ascii=False)
    print("wrote", path)
    print(json.dumps(rep, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
