"""Closed-loop decay calibration for the plucked/struck instruments.

Symptom: the synthesised note carries ~3 dB more energy in 0.02-0.5 s than the
recording, i.e. it decays too slowly. Cause: a handful of the guitar's low partials
came out with gamma *below* the fundamental's (8 of 37 forte notes have gamma2 < gamma1),
and those slow modes dominate the tail.

Rather than patching the extractor heuristically, this measures the defect and corrects
it: render the note, compare the **broadband envelope decay rate** of the synthesis and
the recording, and store a per-note gamma scale. `params.Patch` multiplies gamma by it.

    python python_monotor/modal_sim/calibrate_decay.py            # guitar piano banjo mandolin
"""

from __future__ import annotations

import json
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "fft_analysis"))

import core as CORE                                  # noqa: E402
import instruments                                   # noqa: E402
import params as P                                   # noqa: E402
import paths                                         # noqa: E402
from engine import ModalSynth                        # noqa: E402

SR = 48000
T0, T1 = 0.05, 0.60                                  # the decay region that matters


def eff_gamma(x, t0=T0, t1=T1):
    k = max(1, int(0.01 * SR))
    e = np.sqrt(np.convolve(x ** 2, np.ones(k) / k, mode="same"))
    e /= (e.max() + 1e-30)
    t = np.arange(len(e)) / SR
    m = (t > t0) & (t < t1) & (e > 0.02)
    if m.sum() < 50:
        return np.nan
    return float(-np.polyfit(t[m], np.log(e[m] + 1e-30), 1)[0])


def energy_ratio(real, y, a, b):
    return float(10 * np.log10(((y[a:b] ** 2).sum() + 1e-30)
                               / ((real[a:b] ** 2).sum() + 1e-30)))


def calibrate(inst: str, iters: int = 2, lo=0.6, hi=1.8, damp=0.8):
    """Solve for a per-note gamma scale that makes the synthesised **energy in the
    decay window** match the recording.

    The first version targeted the effective decay *rate*; that fixed the guitar
    (-1.2 dB) but pushed the already-good piano the wrong way (+0.9 dB), because a rate
    match is not an energy match. Energy is the quantity the ear sums, so it is the
    target, with damping to keep the iteration stable.
    """
    cfg = instruments.get(inst)
    full = P.Patch(inst, band_hz=cfg["band_hz"], max_modes=cfg["max_modes"])
    with open(paths.param(inst, "manifest", "json"), encoding="utf-8") as fh:
        manifest = json.load(fh)
    a, b = int(0.02 * SR), int(0.50 * SR)
    rows = []
    for midi in full.midis:
        for dyn in ("forte", "piano"):
            ent = next((e for e in manifest if e["midi"] == midi
                        and e["dynamic"] == dyn), None)
            if ent is None:
                continue
            x = CORE.load_audio(ent["path"])
            on, off = CORE.analysis_region(x, ent, SR)
            real = x[on:off].copy()
            if real.size < int(1.0 * SR):
                continue
            real /= (np.max(np.abs(real)) + 1e-30)
            s = 1.0
            for _ in range(iters):
                patch = P.Patch(inst, band_hz=cfg["band_hz"],
                                max_modes=cfg["max_modes"])
                # inject the trial scale for this one note
                patch.gamma_scale = {(midi, dyn): s}
                synth = ModalSynth(patch, max_poly=2, noise_amp=cfg["noise_amp"],
                                   noise_lp_hz=cfg["noise_lp_hz"],
                                   release_factor=cfg["release_factor"])
                y = synth.render([(0.0, midi, 2.5, 1.0)], 2.5)
                y /= (np.max(np.abs(y)) + 1e-30)
                r_db = energy_ratio(real, y, a, b)
                # energy ~ 1/gamma, so the factor that removes the mismatch is the
                # linear energy ratio; damped to keep the two iterations stable.
                s = float(np.clip(s * (10.0 ** (r_db / 10.0)) ** damp, lo, hi))
            rows.append((midi, dyn, s))
    return rows


def main(argv=None):
    paths.makedirs()
    names = list(argv) if argv else ["guitar", "piano", "banjo", "mandolin"]
    summary = {}
    for inst in names:
        t0 = time.time()
        rows = calibrate(inst)
        if not rows:
            continue
        midi = np.array([r[0] for r in rows])
        dyn = np.array([r[1] for r in rows])
        sc = np.array([r[2] for r in rows])
        np.savez_compressed(os.path.join(paths.PARAMS, f"{inst}_gammascale.npz"),
                            midi=midi, dynamic=dyn, scale=sc)
        summary[inst] = dict(notes=len(rows), median=round(float(np.median(sc)), 3),
                             p90=round(float(np.percentile(sc, 90)), 3),
                             n_clipped=int(np.sum((sc <= 0.5501) | (sc >= 1.8999))),
                             seconds=round(time.time() - t0, 1))
        print(f"{inst:9s} {len(rows):3d} 音  γ 缩放 中位 {np.median(sc):.3f} "
              f"p90 {np.percentile(sc, 90):.3f}  被限幅 {summary[inst]['n_clipped']} "
              f"({summary[inst]['seconds']}s)")
    with open(os.path.join(paths.PARAMS, "gammascale_summary.json"), "w",
              encoding="utf-8") as fh:
        json.dump(summary, fh, indent=2, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
