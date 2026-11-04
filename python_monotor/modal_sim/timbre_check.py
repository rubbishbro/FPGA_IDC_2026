"""Per-band error statistics vs the recordings, with each band's share of the energy.

A bare dB error is misleading when a band holds ~0 % of the note's energy (both sides
are then near-silent floors, and the difference can look like tens of dB). So every row
reports the band's **share of the recording's energy** alongside the error, and the
summary is an **energy-weighted** mean |error|.

    python python_monotor/modal_sim/timbre_check.py
"""

from __future__ import annotations

import json
import os
import sys

import numpy as np
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
from engine import ModalSynth                        # noqa: E402

OUT = paths.SIM_CROSSCHECK
SR = 48000
EDGES = np.array([40, 80, 160, 315, 630, 1250, 2500, 5000, 8000, 16000], float)
LABELS = [f"{int(a)}-{int(b)}" for a, b in zip(EDGES[:-1], EDGES[1:])]
WINDOW = (0.02, 0.50)                                # attack + body, one window

def probes_for(inst: str, n: int = 10) -> list[int]:
    """Evenly sample the midis this library actually has (piano is named A/C/D#/F# only,
    so a hand-written probe list silently misses half its notes)."""
    with open(paths.param(inst, "manifest", "json"), encoding="utf-8") as fh:
        manifest = json.load(fh)
    midis = sorted({e["midi"] for e in manifest
                    if e["dynamic"] in ("forte", "piano")})
    if len(midis) <= n:
        return midis
    idx = np.linspace(0, len(midis) - 1, n).round().astype(int)
    return [midis[i] for i in sorted(set(idx))]


def bands(x, t0, t1):
    a, b = int(t0 * SR), min(int(t1 * SR), x.size)
    if b - a < 512:
        return None
    s = x[a:b] * np.hanning(b - a)
    X = np.abs(np.fft.rfft(s))
    f = np.fft.rfftfreq(b - a, 1 / SR)
    e = np.array([(X[(f >= lo) & (f < hi)] ** 2).sum()
                  for lo, hi in zip(EDGES[:-1], EDGES[1:])])
    return e


def analyse(inst, midi):
    cfg = instruments.get(inst)
    patch = P.Patch(inst, band_hz=cfg["band_hz"], max_modes=cfg["max_modes"])
    with open(paths.param(inst, "manifest", "json"), encoding="utf-8") as fh:
        manifest = json.load(fh)
    entry = next((e for e in manifest
                  if e["midi"] == midi and e["dynamic"] in ("forte", "piano")), None)
    if entry is None:
        return None
    x = CORE.load_audio(entry["path"])
    on, off = CORE.analysis_region(x, entry, SR)
    real = x[on:off].copy()
    real /= (np.max(np.abs(real)) + 1e-30)
    synth = ModalSynth(patch, max_poly=4, noise_amp=cfg["noise_amp"],
                       noise_lp_hz=cfg["noise_lp_hz"],
                       release_factor=cfg["release_factor"])
    y = synth.render([(0.0, midi, 2.5, 1.0)], 2.5)
    y /= (np.max(np.abs(y)) + 1e-30)
    er, ey = bands(real, *WINDOW), bands(y, *WINDOW)
    if er is None or ey is None:
        return None
    share_r, share_y = er / er.sum(), ey / ey.sum()
    # A dB error is only meaningful where the band is present on *both* sides: a band
    # holding 0.00 % of the energy is a near-silent floor, and the log-ratio of two
    # floors produces 100+ dB numbers that say nothing.
    usable = (share_r >= 0.005) & (share_y >= 0.0002)
    return share_r, share_y, usable, 10 * np.log10((er + 1e-30) / (ey + 1e-30))


def main(argv=None):
    paths.makedirs()
    summary = {}
    for inst in ("guitar", "piano"):
        probes = probes_for(inst)
        shares, errs, usable = [], [], []
        for m in probes:
            r = analyse(inst, m)
            if r:
                shares.append(r[0]); usable.append(r[2]); errs.append(r[3])
        if not errs:
            continue
        shares = np.array(shares); errs = np.array(errs); usable = np.array(usable)
        share_med = np.median(shares, axis=0)
        n = len(errs)
        err_med = np.full(len(LABELS), np.nan)
        err_p90 = np.full(len(LABELS), np.nan)
        n_use = np.zeros(len(LABELS), int)
        for i in range(len(LABELS)):
            v = errs[usable[:, i], i]
            n_use[i] = v.size
            if v.size:
                err_med[i] = np.median(v)
                err_p90[i] = np.percentile(np.abs(v), 90)
        core = slice(2, 7)                            # 160 Hz - 5 kHz
        core_share = 100 * share_med[core].sum()
        core_err = float(np.nansum(np.abs(err_med[core]) * share_med[core])
                         / max(np.nansum(share_med[core]), 1e-12))
        weighted = float(np.nansum(np.abs(err_med) * share_med))
        summary[inst] = dict(notes=n,
                             window_s=list(WINDOW),
                             band_share_pct=[round(100 * s, 2) for s in share_med],
                             band_err_median_db=[None if np.isnan(e) else round(e, 1)
                                                 for e in err_med],
                             band_err_p90_db=[None if np.isnan(e) else round(e, 1)
                                              for e in err_p90],
                             band_notes_used=n_use.tolist(),
                             core_share_pct=round(core_share, 1),
                             core_weighted_abs_err_db=round(core_err, 2),
                             energy_weighted_mean_abs_err_db=round(weighted, 2))
        print(f"\n=== {inst} ({n} 音, 窗 {WINDOW[0]}-{WINDOW[1]}s) ===")
        print(f"{'频带':>12}{'能量占比':>10}{'误差中位':>10}{'误差p90':>9}{'可比音数':>9}")
        for i, lab in enumerate(LABELS):
            m_ = "—" if np.isnan(err_med[i]) else f"{err_med[i]:.1f}"
            p_ = "—" if np.isnan(err_p90[i]) else f"{err_p90[i]:.1f}"
            print(f"{lab:>12}{100 * share_med[i]:9.2f}%{m_:>10}{p_:>9}{n_use[i]:>6}/{n}")
        print(f"  → 谐波核心 160 Hz–5 kHz: 占能量 {core_share:.1f}%, "
              f"能量加权平均|误差| {core_err:.2f} dB")
        print(f"  → 全带能量加权平均|误差| {weighted:.2f} dB")
        figure(inst, err_med, err_p90, share_med, n_use, n)

    with open(os.path.join(OUT, "timbre_check.json"), "w", encoding="utf-8") as fh:
        json.dump(summary, fh, indent=2, ensure_ascii=False)
    print("\nwrote", os.path.join(OUT, "timbre_check.json"))
    return 0


def figure(inst, err_med, err_p90, share, n_use, n):
    fig, ax = plt.subplots(2, 1, figsize=(11, 7), constrained_layout=True,
                           sharex=True)
    x = np.arange(len(LABELS))
    ax[0].bar(x, share * 100, color="seagreen", alpha=0.85)
    ax[0].set_ylabel("% of energy"); ax[0].set_yscale("log")
    ax[0].set_title(f"{inst}: where the energy is vs where the error is "
                    f"({n} notes)")
    ax[0].grid(alpha=0.3, axis="y")
    for i, s in enumerate(share * 100):
        ax[0].text(i, max(s, 0.02), f"{s:.2f}\n({n_use[i]})", ha="center", fontsize=6)
    ax[1].bar(x, np.nan_to_num(err_med, nan=0.0), color="steelblue", alpha=0.85,
              label="median (real - synth)")
    ax[1].plot(x, err_p90, "r.-", label="p90 |error|")
    ax[1].plot(x, -err_p90, "r.-")
    ax[1].axhline(0, color="k", lw=0.8)
    ax[1].set_xticks(x); ax[1].set_xticklabels(LABELS, rotation=45, fontsize=8)
    ax[1].set_ylim(-60, 60); ax[1].set_ylabel("dB")
    ax[1].grid(alpha=0.3, axis="y"); ax[1].legend(fontsize=8)
    fig.savefig(os.path.join(OUT, f"timbre_{inst}.png"), dpi=110)
    plt.close(fig)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
