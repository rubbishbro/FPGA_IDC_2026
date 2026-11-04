"""Diagnostic figures for the FFT analysis (matplotlib, Agg backend)."""

from __future__ import annotations

import os

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt          # noqa: E402
from scipy.signal import spectrogram     # noqa: E402

import core                              # noqa: E402


def _db(x):
    return 20.0 * np.log10(np.abs(x) + 1e-12)


def fig_note(res: dict, x: np.ndarray, sr: int, out_png: str) -> str:
    start, end = res["region"]
    seg = x[start:end] / (res["peak"] + 1e-30)
    t = np.arange(len(seg)) / sr

    fig, ax = plt.subplots(4, 1, figsize=(11, 12), constrained_layout=True)
    title = f"{os.path.basename(res['path'])}  |  f0={res['f0']:.2f} Hz  B={res['B']:.2e}"
    fig.suptitle(title)

    ax[0].plot(t, seg, lw=0.3)
    ax[0].set_title("waveform (analysis region, normalised)")
    ax[0].set_xlabel("s"); ax[0].grid(alpha=0.3)

    f, tt, S = spectrogram(seg, fs=sr, nperseg=4096, noverlap=3072,
                           mode="magnitude")
    S_db = 20.0 * np.log10(S / (S.max() + 1e-30) + 1e-12)
    ax[1].pcolormesh(tt, f / 1000.0, S_db, shading="auto", cmap="magma",
                     vmin=-100, vmax=0)
    ax[1].set_ylim(0, 12)
    ax[1].set_title("spectrogram (dB)")
    ax[1].set_ylabel("kHz"); ax[1].set_xlabel("s")

    fr, X = core._spectrum(seg, sr)
    ax[2].semilogy(fr, X / (X.max() + 1e-30), lw=0.5)
    if res["f_k"].size:
        ax[2].plot(res["f_k"], res["amp_k"] / (X.max() + 1e-30), "r.", ms=4,
                   label="detected partials")
    ax[2].set_xlim(0, 12_000); ax[2].set_ylim(1e-5, 2)
    ax[2].set_title("spectrum + detected partials")
    ax[2].set_xlabel("Hz"); ax[2].legend(loc="upper right", fontsize=8)
    ax[2].grid(alpha=0.3, which="both")

    envs = res.get("envs")
    if envs is not None and len(envs):
        dt = res["env_dt"]
        for i in range(len(envs)):
            e = envs[i]
            te = np.arange(len(e)) * dt
            ax[3].plot(te, _db(e), lw=1.0, label=f"k={res['k'][i]} (γ={res['gamma'][i]:.1f})")
        ax[3].set_ylim(-90, 5)
        ax[3].set_title("per-partial envelopes (first 8)")
        ax[3].set_xlabel("s"); ax[3].set_ylabel("dB")
        ax[3].legend(fontsize=7, ncol=2); ax[3].grid(alpha=0.3)

    fig.savefig(out_png, dpi=110)
    plt.close(fig)
    return out_png


def fig_body(grid, mean_db, std_db, n_notes, out_png, title="body coloration"):
    fig, ax = plt.subplots(figsize=(10, 5), constrained_layout=True)
    ax.plot(grid, mean_db, "b", lw=1.6, label=f"mean (n={n_notes})")
    ax.fill_between(grid, mean_db - std_db, mean_db + std_db, color="b", alpha=0.15,
                    label="±1σ")
    ax.set_xscale("log")
    ax.set_xlim(grid[0], grid[-1])
    ax.set_xlabel("Hz (absolute)"); ax.set_ylabel("dB (per-note median removed)")
    ax.set_title(title); ax.grid(alpha=0.3, which="both"); ax.legend()
    fig.savefig(out_png, dpi=110)
    plt.close(fig)
    return out_png


def fig_decay_summary(notes: list[dict], out_png, title="γ vs frequency"):
    fig, ax = plt.subplots(figsize=(10, 5), constrained_layout=True)
    for n in notes:
        fk, g = n["f_k"], n["gamma"]
        good = np.isfinite(g) & (g > 0)
        if good.sum():
            ax.semilogy(fk[good], g[good], ".", ms=3, alpha=0.5)
    ax.set_xlabel("partial frequency (Hz)"); ax.set_ylabel("γ (1/s)")
    ax.set_title(title); ax.grid(alpha=0.3, which="both")
    fig.savefig(out_png, dpi=110)
    plt.close(fig)
    return out_png
