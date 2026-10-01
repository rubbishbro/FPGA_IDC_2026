"""Visualise the filters in the synthesis chain.

    python python/modal_sim/plot_chain.py

Writes FFT_results/sim/figures/filter_chain.png:
  body IIR (guitar/piano) vs measured target, the modal resonator poles for one note,
  the noise-path low-pass, and the excitation pulse (time + spectrum).
"""

from __future__ import annotations

import os
import sys

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt                  # noqa: E402
from scipy.signal import butter, sosfreqz      # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import params as P                              # noqa: E402
import paths                                    # noqa: E402

FIG = paths.SIM_CROSSCHECK


def main():
    os.makedirs(FIG, exist_ok=True)
    f = np.geomspace(40, 20000, 600)
    fig, ax = plt.subplots(2, 2, figsize=(14, 9), constrained_layout=True)

    # --- (0,0)/(0,1): body IIR vs target ---
    for col, name in enumerate(("guitar", "piano")):
        p = P.Patch(name)
        _, h = sosfreqz(p.sos, worN=f, fs=P.SR)
        resp = 20 * np.log10(np.abs(h) + 1e-12)
        # the fit target is the *detrended residual* coloration (a_k already carry the
        # overall tilt), so plot that -- not the full measured curve, which would look
        # like a 60 dB mismatch.
        tgt = np.interp(f, p._bf, p.body_target_db)
        a = ax[0, col]
        a.semilogx(f, resp, "b", lw=1.8, label="body IIR (4 biquad)")
        a.semilogx(f, tgt, "k--", lw=1.0, alpha=0.6, label="design target (detrended)")
        a.set_xlim(40, 20000)
        a.set_title(f"{name} body filter  (fit RMSE {p.body_rmse:.2f} dB)")
        a.set_xlabel("Hz"); a.set_ylabel("dB"); a.grid(alpha=0.3, which="both")
        a.legend(fontsize=8)

    # --- (1,0): modal resonator poles for one note ---
    p = P.Patch("guitar")
    fk, gk, wk = p.modes(57, "forte")
    dt = 1 / P.SR
    r = np.exp(-gk * dt)
    th = 2 * np.pi * fk * dt
    a = ax[1, 0]
    circ = np.linspace(0, 2 * np.pi, 400)
    a.plot(np.cos(circ), np.sin(circ), "k-", lw=0.6)
    a.plot(r * np.cos(th), r * np.sin(th), "o", ms=5, c="crimson")
    a.plot(r * np.cos(-th), r * np.sin(-th), "o", ms=5, c="crimson")
    a.axhline(0, color="gray", lw=0.4); a.axvline(0, color="gray", lw=0.4)
    a.set_aspect("equal"); a.set_title(f"modal bank poles (guitar A3, N={len(fk)})")
    a.set_xlabel("Re"); a.set_ylabel("Im")
    a.text(0.02, 0.02, "|pole| = e^(−γΔt)  →  decay\nangle = 2π f_k Δt  →  pitch",
           transform=a.transAxes, fontsize=8, va="bottom")

    # --- (1,1): noise-path low-pass + excitation pulse spectrum ---
    sr = P.SR
    a = ax[1, 1]
    for lp, label, c in ((3500, "guitar noise LP 3.5 kHz", "crimson"),
                         (4500, "piano noise LP 4.5 kHz", "steelblue")):
        _, h = sosfreqz(butter(2, lp / (sr / 2), "low", output="sos"), worN=f, fs=sr)
        a.semilogx(f, 20 * np.log10(np.abs(h) + 1e-12), c, lw=1.6, label=label)
    # excitation pulse spectrum (raised cosine, tau=0.15 ms)
    tau = 1.5e-4
    n = max(2, int(tau * sr))
    pulse = 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(n) / n)
    fp = np.linspace(0, sr / 2, 4096)
    Hp = np.abs(np.exp(-1j * 2 * np.pi * np.outer(fp, np.arange(n)) / sr).dot(pulse))
    a.semilogx(fp[1:], 20 * np.log10(Hp[1:] / Hp.max() + 1e-12), "g", lw=1.2,
               label="excitation pulse (τ=0.15 ms)")
    a.set_xlim(40, 20000); a.set_ylim(-90, 5)
    a.set_title("noise-path low-pass and excitation pulse")
    a.set_xlabel("Hz"); a.set_ylabel("dB"); a.grid(alpha=0.3, which="both")
    a.legend(fontsize=8)

    out = os.path.join(FIG, "filter_chain.png")
    fig.savefig(out, dpi=110)
    print("wrote", out)


if __name__ == "__main__":
    raise SystemExit(main())
