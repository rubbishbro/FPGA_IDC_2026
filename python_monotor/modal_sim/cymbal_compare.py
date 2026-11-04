"""Cymbal comparison: our modal+noise model against the real recording.

Cymbals are the hardest percussion case -- a real cymbal is a dense field of thousands
of closely spaced modes, while the model has at most 64 modes plus a noise branch. This
figure is meant to show *how* it differs, not just that it does:

* long-window spectrum      -- dense continuous vs discrete peaks,
* 1/3-octave bands + error  -- where the energy actually is,
* spectral centroid vs time -- brightness of the attack,
* spectrograms              -- the texture,
* broadband decay envelope  -- how the wash dies away.

    python python_monotor/modal_sim/cymbal_compare.py
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
import drumkit as DK                                 # noqa: E402
import paths                                         # noqa: E402
import percussion as PC                              # noqa: E402

OUT = paths.SIM_DRUMS
CYMBALS = ("crash", "hat", "ride")
SR = 48000


def envelope(x, w=0.005):
    k = max(1, int(w * SR))
    return np.sqrt(np.convolve(x ** 2, np.ones(k) / k, mode="same"))


def band_db(x, edges, t0, t1):
    b = min(int(t1 * SR), x.size)
    a = min(int(t0 * SR), max(0, b - 256))
    s = x[a:b]
    X = np.abs(np.fft.rfft(s * np.hanning(len(s))))
    f = np.fft.rfftfreq(len(s), 1 / SR)
    out = []
    for lo, hi in zip(edges[:-1], edges[1:]):
        m = (f >= lo) & (f < hi)
        out.append(10 * np.log10((X[m] ** 2).sum() + 1e-30))
    return np.array(out)


def centroid(x, t0, t1):
    b = min(int(t1 * SR), x.size)
    a = min(int(t0 * SR), max(0, b - 256))
    s = x[a:b]
    if s.size < 64:
        return float("nan")
    X = np.abs(np.fft.rfft(s * np.hanning(len(s))))
    f = np.fft.rfftfreq(len(s), 1 / SR)
    return float((f * X).sum() / (X.sum() + 1e-30))


def t60(x):
    """Broadband decay time to -60 dB from the envelope peak (capped at the sample)."""
    e = envelope(x)
    if e.max() <= 0:
        return np.nan
    i0 = int(np.argmax(e))
    e = e[i0:] / e[i0]
    below = np.where(e < 10 ** (-60 / 20))[0]
    return float(below[0] / SR) if below.size else float(len(e) / SR)


def main(argv=None):
    paths.makedirs()
    kit = PC.load_kit(os.path.join(paths.PARAMS, "drums.npz"))
    edges = np.geomspace(60.0, 16000.0, 25)
    summary = {}
    for key in CYMBALS:
        stem = os.path.basename(PC.KIT[key]["path"])
        x = PC.load_hit(key)
        on = CORE.detect_onset(x)
        real = x[on:on + int(2.5 * SR)].copy()
        if real.size < 1024:
            real = x[:int(2.5 * SR)]
        real = real / (np.max(np.abs(real)) + 1e-30)
        secs = len(real) / SR
        rng = np.random.default_rng(1)
        model = DK.render_kit_hit(kit, key, secs, 1.0, rng, 1.0)
        model = model / (np.max(np.abs(model)) + 1e-30)

        # long-window spectrum over the first 0.8 s (short hits use what they have)
        n = min(int(0.8 * SR), min(real.size, model.size))
        n = n - (n % 2)
        Xr = np.abs(np.fft.rfft(real[:n] * np.hanning(n)))
        Xm = np.abs(np.fft.rfft(model[:n] * np.hanning(n)))
        fr = np.fft.rfftfreq(n, 1 / SR)
        # spectral density: fraction of 1/3-octave bands within 10 dB of the loudest
        dens_r = float(np.mean(20 * np.log10(Xr / Xr.max() + 1e-12) > -30))
        dens_m = float(np.mean(20 * np.log10(Xm / Xm.max() + 1e-12) > -30))

        er = band_db(real, edges, 0.0, 0.8)
        em = band_db(model, edges, 0.0, 0.8)
        er -= er.max(); em -= em.max()
        err = er - em
        cr, cm = centroid(real, 0, 0.4), centroid(model, 0, 0.4)
        tr, tm = t60(real), t60(model)
        summary[key] = dict(file=stem, seconds=round(secs, 2),
                            band_err_median_db=round(float(np.median(np.abs(err))), 1),
                            band_err_max_db=round(float(np.max(np.abs(err))), 1),
                            centroid_hz=[round(cr), round(cm)],
                            decay_t60_s=[round(tr, 2), round(tm, 2)],
                            dense_fraction=[round(dens_r, 3), round(dens_m, 3)])
        print(f"{key:6s} {stem:44s} 1/3-oct err 中位 {np.median(np.abs(err)):5.1f} "
              f"最大 {np.max(np.abs(err)):5.1f} dB | 谱心 真{cr:6.0f}/模型{cm:6.0f} Hz | "
              f"T60 真{tr:4.2f}/模型{tm:4.2f}s | 谱密度(>−30dB 占比) 真{dens_r:.2f}/模型{dens_m:.2f}")
        figure(key, real, model, fr, Xr, Xm, edges, er, em, err)

    with open(os.path.join(OUT, "cymbal_compare.json"), "w", encoding="utf-8") as fh:
        json.dump(summary, fh, indent=2, ensure_ascii=False)
    print("wrote", os.path.join(OUT, "cymbal_compare.json"))
    return 0


def figure(key, real, model, fr, Xr, Xm, edges, er, em, err):
    t = np.arange(len(real)) / SR
    fig = plt.figure(figsize=(14, 8), constrained_layout=True)
    gs = fig.add_gridspec(2, 3, height_ratios=[1.0, 1.15])

    ax = fig.add_subplot(gs[0, 0])
    ax.semilogy(fr, Xr / Xr.max(), lw=0.5, label="real")
    ax.semilogy(fr, Xm / Xm.max(), lw=0.5, alpha=0.85, label="model")
    ax.set_xlim(0, 16000); ax.set_ylim(1e-6, 2)
    ax.set_title(f"{key}: long-window spectrum (0-0.8 s)")
    ax.set_xlabel("Hz"); ax.legend(fontsize=8); ax.grid(alpha=0.3, which="both")

    ax = fig.add_subplot(gs[0, 1])
    fc = np.sqrt(edges[:-1] * edges[1:])
    ax.semilogx(fc, er, "b", lw=1.4, label="real")
    ax.semilogx(fc, em, "r", lw=1.4, label="model")
    ax.set_xlim(60, 16000); ax.set_ylim(-70, 3)
    ax.set_title("1/3-octave energy"); ax.set_xlabel("Hz"); ax.set_ylabel("dB")
    ax.legend(fontsize=8); ax.grid(alpha=0.3, which="both")
    ax2 = ax.twinx(); ax2.plot(fc, err, "k--", lw=1.0)
    ax2.set_ylabel("error (real - model) dB"); ax2.set_ylim(-40, 40)

    ax = fig.add_subplot(gs[0, 2])
    tt = np.arange(int(1.2 * SR)) / SR
    cr = np.array([centroid(real, x, x + 0.05) for x in np.arange(0, 1.15, 0.05)])
    cm = np.array([centroid(model, x, x + 0.05) for x in np.arange(0, 1.15, 0.05)])
    ax.plot(np.arange(len(cr)) * 0.05, cr, "-o", ms=3, label="real")
    ax.plot(np.arange(len(cm)) * 0.05, cm, "-o", ms=3, label="model")
    ax.set_title("spectral centroid vs time"); ax.set_xlabel("s")
    ax.set_ylabel("Hz"); ax.legend(fontsize=8); ax.grid(alpha=0.3)

    for col, (sig, name) in enumerate(((real, "real"), (model, "model"))):
        ax = fig.add_subplot(gs[1, col])
        ax.specgram(sig, NFFT=512, Fs=SR, noverlap=384, cmap="magma",
                    vmin=-100, vmax=-15)
        ax.set_ylim(0, 12000); ax.set_title(f"{name}: spectrogram")
        ax.set_xlabel("s"); ax.set_ylabel("Hz")

    ax = fig.add_subplot(gs[1, 2])
    ax.semilogy(t, envelope(real), lw=0.7, label="real")
    ax.semilogy(np.arange(len(model)) / SR, envelope(model), lw=0.7, label="model")
    ax.set_xlim(0, min(2.5, t[-1])); ax.set_ylim(1e-5, 2)
    ax.set_title("broadband decay"); ax.set_xlabel("s")
    ax.legend(fontsize=8); ax.grid(alpha=0.3, which="both")

    fig.savefig(os.path.join(OUT, f"cymbal_{key}.png"), dpi=110)
    plt.close(fig)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
