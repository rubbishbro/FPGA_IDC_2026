"""Presentation-only warm mix for the Mystery of Love flute excerpt.

The timbre check (``flute_timbre_compare.py``) shows the engine is not brighter than
the source sample in the harmonics; it is *drier*.  This script keeps the engine audio
untouched and applies a small, documented presentation chain to the already-rendered
WAVs:

    low shelf  +3 dB @ 350 Hz   (body / low-mid)
    high shelf -3 dB @ 5 kHz    (soften the top)
    RTL 4-comb reverb, 12% wet, wet low-passed at 4 kHz (space, not sizzle)

The reverb is the same 4-comb topology as ``history/core_2026-11-01/rtl/core/comb_reverb.sv`` (delays 1116 /
1188 / 1277 / 1356, feedback 0.71875, damping 1/8); the extra 4 kHz low-pass on the wet
is a mixing choice, not in the RTL.

    python python_monotor/modal_sim/flute_warm_mix.py

Writes ``mystery_flute_warm.wav`` and ``mystery_flute_warm_solo.wav`` next to the dry
renders.  These are audition files; the engine output remains ``mystery_flute*.wav``.
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

LOW_SHELF_HZ, LOW_SHELF_DB = 350.0, 3.0
HIGH_SHELF_HZ, HIGH_SHELF_DB = 5000.0, -3.0
REVERB_WET, REVERB_LP_HZ = 0.12, 4000.0
COMB_DELAYS = (1116, 1188, 1277, 1356)
COMB_FB, COMB_DAMP = 0.71875, 0.125


def shelves(x: np.ndarray) -> np.ndarray:
    """One-pole low shelf + one-pole high shelf (gentle 6 dB/oct slopes)."""
    lp = sosfilt(butter(1, LOW_SHELF_HZ / (SR / 2), "low", output="sos"), x)
    y = x + (10.0 ** (LOW_SHELF_DB / 20.0) - 1.0) * lp
    hp = y - sosfilt(butter(1, HIGH_SHELF_HZ / (SR / 2), "low", output="sos"), y)
    return y - (1.0 - 10.0 ** (HIGH_SHELF_DB / 20.0)) * hp


def rtl_comb_reverb(x: np.ndarray) -> np.ndarray:
    """The RTL ``comb_reverb`` difference equations, sample for sample.

    ``s = c[p]; lp' = s + (lp - s)/8; c[p] = x + 0.71875*lp`` (the old ``lp``,
    matching the register read-before-write in the SV), output = mean of the four
    comb taps.
    """
    n = len(x)
    bufs = [np.zeros(d) for d in COMB_DELAYS]
    lps = [0.0] * 4
    pos = [0] * 4
    y = np.zeros(n)
    for i in range(n):
        xi = float(x[i])
        s = 0.0
        for j, d in enumerate(COMB_DELAYS):
            b = bufs[j]
            p = pos[j]
            sj = b[p]
            lpj = lps[j]
            s += sj
            b[p] = xi + COMB_FB * lpj
            lps[j] = sj + COMB_DAMP * (lpj - sj)
            pos[j] = p + 1 if p + 1 < d else 0
        y[i] = 0.25 * s
    return y


def metrics(x: np.ndarray) -> dict:
    S = np.abs(np.fft.rfft(x * np.hanning(len(x))))
    f = np.fft.rfftfreq(len(x), 1 / SR)
    m = (f >= 80) & (f <= 8000)
    P = S[m] ** 2
    ff = f[m]
    return dict(centroid_hz=round(float((P * ff).sum() / P.sum()), 1),
                hf_4k_8k_ratio=round(float(P[ff > 4000].sum() / P.sum()), 5),
                low_mid_200_700=round(float(P[(ff > 200) & (ff < 700)].sum() / P.sum()), 4))


def main():
    paths.makedirs()
    rep = dict(eq=dict(low_shelf_hz=LOW_SHELF_HZ, low_shelf_db=LOW_SHELF_DB,
                       high_shelf_hz=HIGH_SHELF_HZ, high_shelf_db=HIGH_SHELF_DB),
               reverb=dict(delays=list(COMB_DELAYS), feedback=COMB_FB,
                           damping=COMB_DAMP, wet=REVERB_WET,
                           wet_lowpass_hz=REVERB_LP_HZ,
                           topology="history/core_2026-11-01/rtl/core/comb_reverb.sv 4-comb"),
               note="presentation audition only; raw engine output is mystery_flute*.wav")
    for name in ("mystery_flute", "mystery_flute_solo"):
        y, sr = sf.read(os.path.join(OUT, name + ".wav"))
        assert sr == SR
        x = shelves(y)
        wet = sosfilt(butter(2, REVERB_LP_HZ / (SR / 2), "low", output="sos"),
                      rtl_comb_reverb(x))
        z = x + REVERB_WET * wet
        z *= 0.9 / max(float(np.max(np.abs(z))), 1e-12)
        sf.write(os.path.join(OUT, name + "_warm.wav"), z, SR, subtype="PCM_16")
        rep[name] = dict(dry=metrics(y), warm=metrics(z),
                         peak=round(float(np.max(np.abs(z))), 3),
                         finite=bool(np.isfinite(z).all()))
        print(f"wrote {name}_warm.wav  dry {rep[name]['dry']}  warm {rep[name]['warm']}")
    with open(os.path.join(OUT, "flute_warm_mix.json"), "w", encoding="utf-8") as fh:
        json.dump(rep, fh, indent=2, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
