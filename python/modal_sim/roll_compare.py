"""Compare a *performed* roll / continuous percussion sample against the only model we
have: repeated single hits.

Question it answers: does the modal kit reproduce a roll, or does a roll need a
different (continuous-excitation) model? For each pair it estimates the roll rate from
the envelope, renders the single hit at that rate over the performance's length, and
writes a figure (envelope, spectrum, spectrograms) plus a numeric distance.

    python python/modal_sim/roll_compare.py
"""

from __future__ import annotations

import glob
import json
import os
import sys

import numpy as np
import soundfile as sf
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

MUSIC = paths.MUSIC
OUT = paths.SIM_ROLL
FIG = paths.SIM_ROLL

# label -> (performance file, single-hit source)
#   single-hit source is either a kit key or (group, stem) under percussion/
PAIRS = {
    "snare_roll": ("snare drum/snare-drum__very-long_cresc-decresc_roll.mp3", "snare"),
    "cymbal_roll": ("suspended cymbal/suspended-cymbal__very-long_cresc-decresc_roll.mp3",
                    "crash"),
    "triangle_roll": ("triangle/triangle__very-long_mezzo-forte_roll.mp3",
                      ("triangle", "triangle__long_piano_struck-singly")),
    "cabasa_phrase": ("cabasa/cabasa__phrase_mezzo-forte_effect.mp3",
                      ("cabasa", "cabasa__025_mezzo-forte_effect")),
    "chin_rhythm": ("Chinese hand cymbals/Chinese-hand-cymbals__very-long_mezzo-forte_rhythm.mp3",
                    "hat"),
}


def envelope(x, sr, w=0.005):
    k = max(1, int(w * sr))
    e = np.sqrt(np.convolve(x ** 2, np.ones(k) / k, mode="same"))
    return e


def roll_region(x, sr, thr=0.05):
    """Start of a roll = first time the envelope passes 5 % of its max.

    The usual peak-back onset detector is wrong for a roll: a crescendo roll's global
    RMS peak is near the end, so 'onset' lands after most of the performance (the snare
    very-long roll came out 0.31 s of 8.05 s).
    """
    e = envelope(x, sr)
    idx = np.where(e > thr * e.max())[0]
    return int(idx[0]) if idx.size else 0


def estimate_rate(env, sr, lo_hz=4.0, hi_hz=20.0, smooth=0.020):
    """Roll rate from the autocorrelation of the smoothed (mean-removed) envelope.

    The search range is the musically plausible stroke rate; without smoothing the
    autocorrelation latches onto the fine noise, not the strokes.
    """
    k = max(1, int(smooth * sr))
    e = np.convolve(env, np.ones(k) / k, mode="same")
    e = e - e.mean()
    if not np.any(e):
        return 8.0
    ac = np.correlate(e, e, mode="full")[len(e) - 1:]
    ac /= (ac[0] + 1e-30)
    a = max(1, int(sr / hi_hz))
    b = min(len(ac) - 1, int(sr / lo_hz))
    if b <= a + 1:
        return 8.0
    lag = a + int(np.argmax(ac[a:b]))
    return float(sr / lag)


def spectrum(x, sr, n=1 << 15, t0=0.2):
    seg = x[int(t0 * sr):int(t0 * sr) + n]
    if seg.size < 1024:
        seg = x[:n]
    w = np.hanning(len(seg))
    return np.fft.rfftfreq(len(seg), 1 / sr), np.abs(np.fft.rfft(seg * w))


def main(argv=None):
    paths.makedirs()
    kit = PC.load_kit(os.path.join(paths.PARAMS, "drums.npz"))
    summary = {}
    for label, (rel, src) in PAIRS.items():
        path = os.path.join(MUSIC, "percussion", rel)
        if not os.path.exists(path):
            print("missing", path); continue
        x = CORE.load_audio(path)
        sr = 48000
        on = roll_region(x, sr)
        real = x[on:].copy()
        real = real / (np.max(np.abs(real)) + 1e-30)
        dur = len(real) / sr
        envr = envelope(real, sr)
        rate = estimate_rate(envr, sr)
        period = 1.0 / rate

        # single hit
        if isinstance(src, str):
            hit_rng = np.random.default_rng(5)
            hit = lambda L, rng: DK.render_kit_hit(kit, src, L, 1.0, rng, 1.0)
            L = DK.hit_length(kit, src, 3.0)
        else:
            h = PC.analyze_hit(os.path.join(MUSIC, "percussion", src[0], src[1] + ".mp3"))
            hit = lambda L, rng: DK.render_modal(h, L, 1.0, rng) \
                + DK.render_noise(h, L, 1.0, rng, 1.0)
            L = float(min(3.0, max(0.2, 6.0 / max(h["env_gamma"], 0.7))))

        # render the roll as repeated single hits; velocity follows the real envelope so
        # the comparison is about *timbre*, not about a missing crescendo
        synth = np.zeros_like(real)
        rng = np.random.default_rng(5)
        n_strokes = int(dur * rate) + 1
        for i in range(n_strokes):
            t0 = int(i * period * sr)
            if t0 >= len(synth):
                break
            velr = float(np.interp(t0 / sr, np.arange(len(envr)) / sr, envr))
            seg = hit(L, rng)
            n = min(len(seg), len(synth) - t0)
            synth[t0:t0 + n] += seg[:n] * (0.3 + 0.7 * velr)
        synth /= (np.max(np.abs(synth)) + 1e-30)

        envs = envelope(synth, sr)
        fr, Xr = spectrum(real, sr)
        _, Xs = spectrum(synth, sr)
        bands = 25.0 * 2.0 ** (np.arange(0, 31) / 3.0)
        def band_db(X):
            return np.array([10 * np.log10((X[(fr >= lo) & (fr < hi)] ** 2).sum() + 1e-30)
                             for lo, hi in zip(bands[:-1], bands[1:])])
        br, bs = band_db(Xr), band_db(Xs)
        br -= br.max(); bs -= bs.max()
        err = br - bs
        # envelope error over the performance
        n = min(len(envr), len(envs))
        eerr = 20 * np.log10((envr[:n] + 1e-6) / (envs[:n] + 1e-6))
        summary[label] = dict(file=rel, seconds=round(dur, 2),
                              roll_rate_hz=round(rate, 2),
                              strokes=n_strokes,
                              band_err_median_db=round(float(np.median(np.abs(err))), 1),
                              band_err_max_db=round(float(np.max(np.abs(err))), 1),
                              env_err_median_db=round(float(np.median(np.abs(eerr))), 1))
        print(f"{label:15s} {dur:5.2f}s rate {rate:5.1f} Hz strokes {n_strokes:3d} | "
              f"1/3-oct err 中位 {summary[label]['band_err_median_db']:5.1f} dB | "
              f"包络 err 中位 {summary[label]['env_err_median_db']:5.1f} dB")
        figure(label, real, synth, sr, fr, Xr, Xs, err, bands, rate)

    with open(os.path.join(OUT, "roll_compare.json"), "w", encoding="utf-8") as fh:
        json.dump(summary, fh, indent=2)
    print("wrote", os.path.join(OUT, "roll_compare.json"))
    return 0


def figure(label, real, synth, sr, fr, Xr, Xs, err, bands, rate):
    t = np.arange(len(real)) / sr
    fig = plt.figure(figsize=(13, 9), constrained_layout=True)
    gs = fig.add_gridspec(3, 2, height_ratios=[1.0, 1.1, 1.3])

    ax = fig.add_subplot(gs[0, :])
    ax.plot(t, envelope(real, sr), lw=0.8, label="real performance")
    ax.plot(np.arange(len(synth)) / sr, envelope(synth, sr), lw=0.8,
            label=f"repeated single hit @ {rate:.1f} Hz")
    ax.set_xlim(0, t[-1]); ax.set_title(f"{label}: envelope")
    ax.legend(fontsize=8); ax.grid(alpha=0.3)

    ax = fig.add_subplot(gs[1, 0])
    fc = 0.5 * (bands[:-1] + bands[1:])
    Xrr = np.array([10 * np.log10((Xr[(fr >= lo) & (fr < hi)] ** 2).sum() + 1e-30)
                    for lo, hi in zip(bands[:-1], bands[1:])])
    Xss = np.array([10 * np.log10((Xs[(fr >= lo) & (fr < hi)] ** 2).sum() + 1e-30)
                    for lo, hi in zip(bands[:-1], bands[1:])])
    ax.plot(fc, Xrr - Xrr.max(), "b", lw=1.4, label="real")
    ax.plot(fc, Xss - Xss.max(), "r", lw=1.4, label="repeated hit")
    ax.set_xlim(25, 16000); ax.set_ylim(-70, 3)
    ax.set_title("1/3-octave spectrum"); ax.set_xlabel("Hz"); ax.set_ylabel("dB")
    ax.legend(fontsize=8); ax.grid(alpha=0.3, which="both")

    ax = fig.add_subplot(gs[1, 1])
    ax.semilogx(fc, err, "k", lw=1.2)
    ax.axhline(0, color="gray", lw=0.6)
    ax.set_xlim(25, 16000); ax.set_ylim(-40, 40)
    ax.set_title("band error (real - repeated hit)"); ax.set_xlabel("Hz")
    ax.grid(alpha=0.3, which="both")

    for col, (sig, nm) in enumerate(((real, "real"), (synth, "repeated hit"))):
        ax = fig.add_subplot(gs[2, col])
        ax.specgram(sig, NFFT=1024, Fs=sr, noverlap=512, cmap="magma",
                    vmin=-110, vmax=-15)
        ax.set_ylim(0, 8000); ax.set_title(f"{nm}: spectrogram")
        ax.set_xlabel("s"); ax.set_ylabel("Hz")

    fig.savefig(os.path.join(FIG, f"rollcmp_{label}.png"), dpi=105)
    plt.close(fig)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
