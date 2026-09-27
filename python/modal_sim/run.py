"""Render demos and verification figures from the modal engine.

    python python/modal_sim/run.py

Outputs (audio + figures + report) go to music_resources/FFT_results/sim/.
"""

from __future__ import annotations

import os
import sys
import time
import json

import numpy as np
import soundfile as sf
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt                 # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import params as P                               # noqa: E402
from engine import ModalSynth                    # noqa: E402

OUT = os.path.join(P.FFT_DIR, "sim")
FIG = os.path.join(OUT, "figures")


def normalize(x, peak=0.9):
    m = np.max(np.abs(x))
    return x * (peak / m) if m > 0 else x


def save(name, x, sr=P.SR):
    path = os.path.join(OUT, name)
    sf.write(path, normalize(x), sr, subtype="PCM_16")
    return path


# a short, recognisable line (C major): (time, midi, dur, vel)
def melody():
    seq = [(64, 0.45), (62, 0.45), (60, 0.45), (62, 0.45), (64, 0.45), (64, 0.45),
           (64, 0.9), (62, 0.45), (62, 0.45), (62, 0.9), (64, 0.45), (67, 0.45),
           (67, 0.9), (64, 0.45), (62, 0.45), (60, 0.45), (62, 0.45), (64, 0.45),
           (64, 0.45), (64, 0.45), (64, 0.45), (62, 0.45), (62, 0.45), (64, 0.45),
           (62, 0.45), (60, 1.2)]
    out, t = [], 0.15
    for midi, dur in seq:
        out.append((t, midi, dur * 0.95, 1.0))
        t += dur
    return out, t + 1.5


def stress():
    """Fast same-key retrigger to exercise scheme-C kill."""
    ev = []
    t = 0.10
    for _ in range(12):
        ev.append((t, 57, 0.08, 1.0))
        t += 0.15
    return ev, t + 4.0


def spectrum(x, sr=P.SR, n=1 << 16):
    seg = x[int(0.02 * sr):int(0.02 * sr) + n]
    w = np.hanning(len(seg))
    return np.fft.rfftfreq(len(seg), 1 / sr), np.abs(np.fft.rfft(seg * w))


def fig_note_vs_sample(synth, patch, midi, out_png):
    y = synth.render([(0.0, midi, 2.0, 1.0)], 2.5)
    fr, X = spectrum(y)
    X /= X.max()

    src = patch._pick(midi, "forte")           # nearest recorded note
    d = np.load(os.path.join(P.FFT_DIR, f"{patch.name}_partials.npz"), allow_pickle=True)
    m = d["note_id"] == 0
    for nid in range(d["f0"].size):
        if int(d["midi"][nid]) == midi:
            m = d["note_id"] == nid
            break
    fk = d["f_k"][m]
    ak = d["a0"][m]
    ak = ak / (ak.max() + 1e-30)

    fig, ax = plt.subplots(figsize=(10, 5), constrained_layout=True)
    ax.semilogy(fr, X, lw=0.5, label="synthesised")
    ax.semilogy(fk, ak, "r.", ms=6, label="extracted a_k")
    ax.set_xlim(0, 6000)
    ax.set_ylim(1e-4, 2)
    ax.set_xlabel("Hz"); ax.set_ylabel("rel. amplitude")
    ax.set_title(f"{patch.name} midi {midi}: synthesised spectrum vs extracted partials")
    ax.grid(alpha=0.3, which="both"); ax.legend()
    fig.savefig(out_png, dpi=110); plt.close(fig)


def fig_stress(y, hist, out_png):
    fig, ax = plt.subplots(3, 1, figsize=(11, 9), constrained_layout=True)
    t = np.arange(len(y)) / P.SR
    ax[0].plot(t, y, lw=0.4); ax[0].set_title("stress: output"); ax[0].grid(alpha=0.3)
    ax[1].plot(np.arange(len(hist)) / P.SR, hist, lw=1.0, color="g")
    ax[1].set_title("active voices"); ax[1].set_ylabel("voices"); ax[1].grid(alpha=0.3)
    z = (t >= 0.50) & (t <= 0.75)
    ax[2].plot(t[z], y[z], lw=0.8)
    ax[2].set_title("zoom 0.50-0.75 s (retriggers; no hard cut)")
    ax[2].set_xlabel("s"); ax[2].grid(alpha=0.3)
    fig.savefig(out_png, dpi=110); plt.close(fig)


def main():
    os.makedirs(FIG, exist_ok=True)
    report = {}
    for name, band in (("guitar", 16_000.0), ("piano", 20_000.0)):
        noise = 0.18 if name == "guitar" else 0.08
        patch = P.Patch(name, band_hz=band)
        report[name] = dict(body_rmse_db=round(patch.body_rmse, 2),
                            max_modes=patch.max_modes, band_hz=band, noise_amp=noise)

        # melody
        ev, sec = melody()
        synth = ModalSynth(patch, max_poly=24, noise_amp=noise)
        t0 = time.time()
        y = synth.render(ev, sec)
        save(f"{name}_melody.wav", y)
        report[name]["melody"] = dict(seconds=round(sec, 2),
                                      render_s=round(time.time() - t0, 1),
                                      kills=synth.kill_count, hard=synth.hard_count)

        # note vs extracted partials figure
        fig_note_vs_sample(ModalSynth(patch, max_poly=4, noise_amp=noise),
                           patch, 57 if name == "guitar" else 60,
                           os.path.join(FIG, f"{name}_synth_vs_table.png"))

        # stress test (small pool to force scheme-C kill)
        ev, sec = stress()
        synth = ModalSynth(patch, max_poly=6, high_water=4, noise_amp=noise)
        y = synth.render(ev, sec)
        save(f"{name}_stress.wav", y)
        fig_stress(y, synth.active_hist, os.path.join(FIG, f"{name}_stress.png"))
        report[name]["stress"] = dict(kills=synth.kill_count, hard=synth.hard_count,
                                      max_active=int(max(synth.active_hist)))
        print(f"[{name}] melody+stress done  kills={report[name]['melody']['kills']} "
              f"stress_kills={synth.kill_count} hard={synth.hard_count}")

    with open(os.path.join(OUT, "report.json"), "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2)
    print("wrote", OUT)


if __name__ == "__main__":
    raise SystemExit(main())
