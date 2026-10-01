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
sys.path.insert(0, os.path.dirname(HERE))               # python/ -> instruments.py
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "fft_analysis"))

import core as CORE                              # noqa: E402
import instruments                               # noqa: E402
import params as P                               # noqa: E402
import paths                                     # noqa: E402
from engine import ModalSynth                    # noqa: E402

OUT = paths.SIM
#: One folder per topic: the pitched instrument's audio and its comparison figures
#: live together under sim/pitched/ (cross-instrument checks are in sim/crosscheck/).
FIG = paths.SIM_PITCHED
PITCHED = paths.SIM_PITCHED


def normalize(x, peak=0.9):
    m = np.max(np.abs(x))
    return x * (peak / m) if m > 0 else x


def save(name, x, sr=P.SR):
    path = os.path.join(PITCHED, name)
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


def spectrum(x, sr=P.SR, n=1 << 13, t0=0.015):
    """Early short-time spectrum.

    A long window over a decaying note under-weights the fast partials, so a plot made
    from it appears to show a *level* error where there is only a decay bias. Keeping
    the window short and early makes the comparison against `a_k` (an onset amplitude)
    meaningful.
    """
    seg = x[int(t0 * sr):int(t0 * sr) + n]
    w = np.hanning(len(seg))
    return np.fft.rfftfreq(len(seg), 1 / sr), np.abs(np.fft.rfft(seg * w))


def fig_note_vs_sample(synth, patch, midi, out_png):
    """Plot synth spectrum vs a_k *and* return numeric synthesis-fidelity metrics.

    Fidelity is measured with the **same per-partial decay fit used for extraction**
    (envelope by time-domain demodulation + log-linear fit), so a0 (an onset intercept)
    is compared to a0 and gamma to gamma. A short raw window would read a fast partial's
    decay as a level error -- the mistake that made the old claim unverifiable.
    """
    y = synth.render([(0.0, midi, 2.0, 1.0)], 2.5)
    fr, X = spectrum(y)
    X = X / X.max()

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
    tr = (d["trusted"][m].astype(bool) if "trusted" in d.files
          else np.ones(fk.size, bool))

    fig, ax = plt.subplots(figsize=(10, 5), constrained_layout=True)
    ax.semilogy(fr, X, lw=0.5, label="synthesised (early window)")
    ax.semilogy(fk[~tr], ak[~tr], ".", color="0.75", ms=5, label="a_k (not used)")
    ax.semilogy(fk[tr], ak[tr], "r.", ms=6, label="a_k (used)")
    ax.set_xlim(0, 6000)
    ax.set_ylim(1e-4, 2)
    ax.set_xlabel("Hz"); ax.set_ylabel("rel. amplitude")
    ax.set_title(f"{patch.name} midi {midi}: synthesised spectrum vs extracted partials")
    ax.grid(alpha=0.3, which="both"); ax.legend()
    fig.savefig(out_png, dpi=110); plt.close(fig)

    # --- numeric synthesis fidelity, on the retained modes, method-matched ---
    f_modes, g_modes, w_modes = patch.modes(midi, "forte")
    if f_modes.size == 0:
        return dict(midi=int(midi), n_modes=0)
    f0 = P.midi_to_hz(midi)
    dec = max(1, int(round(P.SR / 2000.0)))
    a_s, g_s = [], []
    for fk_i in f_modes:
        env = CORE.partial_envelope(y, P.SR, float(fk_i),
                                    float(min(0.40 * f0, 0.30 * fk_i)))
        fit = CORE.fit_decay(env[::dec], P.SR / dec)
        a_s.append(fit["a0"])
        g_s.append(fit["gamma"])
    a_s = np.asarray(a_s, float)
    g_s = np.asarray(g_s, float)
    # scale a_k to the best-fit level, then the residual is pure *shape* error
    scale = float((a_s @ w_modes) / max(w_modes @ w_modes, 1e-30))
    err = 20.0 * np.log10((a_s + 1e-30) / (scale * w_modes + 1e-30))
    strong = w_modes > 0.05 * w_modes.max()
    valid = np.isfinite(g_s) & (g_s > 0.02) & (g_modes > 0.02)
    g_err = 20.0 * np.log10((g_s[valid] + 1e-6) / (g_modes[valid] + 1e-6))
    return dict(
        midi=int(midi), n_modes=int(f_modes.size),
        partial_err_median_db=(round(float(np.median(np.abs(err[strong]))), 2)
                               if strong.any() else None),
        partial_err_p90_db=(round(float(np.percentile(np.abs(err[strong]), 90)), 2)
                            if strong.any() else None),
        gamma_err_median_db=(round(float(np.median(np.abs(g_err))), 2)
                             if g_err.size else None),
    )


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


def main(argv=None):
    os.makedirs(FIG, exist_ok=True)
    report = {}
    wanted = list(argv) if argv else instruments.names()
    for name in wanted:
        cfg = instruments.get(name)
        if cfg["model"] not in ("plucked", "struck"):
            print(f"[{name}] model={cfg['model']!r} not wired into the engine yet; skip")
            continue
        band = cfg["band_hz"]
        noise = cfg["noise_amp"]
        noise_lp = cfg["noise_lp_hz"]
        rel = cfg["release_factor"]
        patch = P.Patch(name, band_hz=band, max_modes=cfg["max_modes"])
        probe = patch.midis[len(patch.midis) // 2]      # a representative note
        fq = np.geomspace(100.0, min(band, 16_000.0), 200)
        bmag = 20.0 * np.log10(patch.body.magnitude(fq) + 1e-12)
        report[name] = dict(body_rmse_db=round(patch.body_rmse, 2),
                            body_range_db=[round(float(bmag.min()), 2),
                                           round(float(bmag.max()), 2)],
                            max_modes=patch.max_modes, band_hz=band,
                            noise_amp=noise, noise_lp_hz=noise_lp,
                            release_factor=rel)

        # melody
        ev, sec = melody()
        synth = ModalSynth(patch, max_poly=24, noise_amp=noise, noise_lp_hz=noise_lp,
                           release_factor=rel)
        t0 = time.time()
        y = synth.render(ev, sec)
        save(f"{name}_melody.wav", y)
        report[name]["melody"] = dict(seconds=round(sec, 2),
                                      render_s=round(time.time() - t0, 1),
                                      kills=synth.kill_count, hard=synth.hard_count)

        # note vs extracted partials figure + numeric synthesis-fidelity check
        report[name]["synthesis"] = fig_note_vs_sample(
            ModalSynth(patch, max_poly=4, noise_amp=noise,
                       noise_lp_hz=noise_lp, release_factor=rel),
            patch, probe,
            os.path.join(FIG, f"{name}_synth_vs_table.png"))

        # stress test (small pool to force scheme-C kill)
        ev, sec = stress()
        synth = ModalSynth(patch, max_poly=6, high_water=4, noise_amp=noise,
                           noise_lp_hz=noise_lp, release_factor=rel)
        y = synth.render(ev, sec)
        save(f"{name}_stress.wav", y)
        fig_stress(y, synth.active_hist, os.path.join(FIG, f"{name}_stress.png"))
        report[name]["stress"] = dict(kills=synth.kill_count, hard=synth.hard_count,
                                      max_active=int(max(synth.active_hist)),
                                      kill_jump=synth.kill_jump)
        print(f"[{name}] melody+stress done  kills={report[name]['melody']['kills']} "
              f"stress_kills={synth.kill_count} hard={synth.hard_count}")

    with open(os.path.join(OUT, "report.json"), "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2)
    print("wrote", OUT)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
