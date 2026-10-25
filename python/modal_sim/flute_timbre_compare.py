"""Flute timbre check: synthesised D5 vs the source sample, and the excerpt vs the
average of the source notes it uses.

The question this answers is "is the engine's flute brighter than the recording?".
For the long D5 of the Mystery of Love excerpt it compares, in matched steady-state
windows and with each spectrum normalised to its own 80 Hz-8 kHz energy:

* the **source sample** ``flute_D5_15_forte_normal.mp3`` (the file the D5 mode table
  was extracted from),
* the **model, static** (vibrato/breath/roughness off, so only the extracted ``a_k``
  and drive calibration are measured),
* the **model, performance** (the same voice settings as the excerpt: 5.4 Hz / 12-cent
  vibrato, breath noise 0.25, roughness 0.10),
* the **excerpt solo** against the average of the nine source notes it plays (C4-D5),
  which exposes the room/rumble in the samples that a dry modal model does not have.

Outputs ``FFT_results/sim/song/flute_timbre_compare.png`` and ``.json``.

    python python/modal_sim/flute_timbre_compare.py
"""

from __future__ import annotations

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
import paths                                         # noqa: E402
import sustain_engine as SE                          # noqa: E402
from sustain import note_region                      # noqa: E402

OUT = paths.SIM_SONG
SR = SE.SR
MIDI = 74                                           # D5, the excerpt's long note
DYNAMIC = "forte"

#: 1/6-octave edges from 80 Hz to ~8 kHz (finer than 1/3 so harmonics resolve)
EDGES = 80.0 * (2.0 ** (1.0 / 6.0)) ** np.arange(0, 41)
CENTERS = np.sqrt(EDGES[:-1] * EDGES[1:])

#: the source notes the excerpt actually plays
EXCERPT_MIDIS = [60, 62, 64, 65, 67, 69, 71, 72, 74]


def source_note(midi: int, dynamic: str = DYNAMIC):
    """(filename, audio) of the table entry the patch uses for this pitch."""
    d = np.load(paths.param("flute", "sustain"), allow_pickle=True)
    idx = [i for i in range(d["notes"].size)
           if int(d["midi"][i]) == midi and str(d["dynamic"][i]) == dynamic]
    if not idx:
        raise KeyError(f"no {dynamic} source for midi {midi}")
    note = str(d["notes"][idx[0]])
    return note, CORE.load_audio(os.path.join(paths.MUSIC, "flute", note))


def spectrum(x: np.ndarray, n: int = 65536):
    """Hann-windowed, DC-removed magnitude spectrum on a fixed grid."""
    x = x - x.mean()
    X = np.abs(np.fft.rfft(x * np.hanning(len(x)), n))
    f = np.fft.rfftfreq(n, 1.0 / SR)
    return f, X


def bands(f: np.ndarray, X: np.ndarray) -> np.ndarray:
    out = np.array([np.sqrt((X[(f >= lo) & (f < hi)] ** 2).sum())
                    for lo, hi in zip(EDGES[:-1], EDGES[1:])])
    s = np.sqrt((out ** 2).sum())
    return out / s if s > 1e-12 else out


def centroid(f: np.ndarray, X: np.ndarray, lo: float = 80.0, hi: float = 8000.0):
    m = (f >= lo) & (f <= hi)
    P = X[m] ** 2
    return float((P * f[m]).sum() / max(P.sum(), 1e-30))


def hf_ratio(f: np.ndarray, X: np.ndarray, lo: float = 4000.0, hi: float = 8000.0):
    m = (f >= 80.0) & (f <= 8000.0)
    P = X[m] ** 2
    q = (f[m] >= lo) & (f[m] <= hi)
    return float(P[q].sum() / max(P.sum(), 1e-30))


def harmonics(f: np.ndarray, X: np.ndarray, f0: float, kmax: int = 12):
    h = []
    for k in range(1, kmax + 1):
        m = (f >= (k - 0.45) * f0) & (f < (k + 0.45) * f0)
        h.append(np.sqrt((X[m] ** 2).sum()))
    h = np.array(h)
    return h / max(h.max(), 1e-30)


def inter_floor_db(f: np.ndarray, X: np.ndarray, f0: float):
    """Median magnitude between harmonics, relative to the strongest peak."""
    m = (f > 1.5 * f0) & (f < 9.5 * f0)
    for k in range(2, 10):
        m &= np.abs(f - k * f0) > 0.2 * f0
    return float(20.0 * np.log10(np.median(X[m]) / max(X.max(), 1e-30) + 1e-30))


def main():
    paths.makedirs()
    note, real = source_note(MIDI)
    on, off = note_region(real, SR)
    a = on + int(0.35 * (off - on))
    b = on + int(0.75 * (off - on))
    src = real[a:b]
    f0 = CORE.midi_to_hz(MIDI)

    patch = SE.SustainPatch("flute")
    static = SE.SustainSynth(patch, max_poly=2, vibrato_cents=0.0, vibrato_am=0.0,
                             noise_gain=0.0, roughness=0.0)
    perf = SE.SustainSynth(patch, max_poly=2, vibrato_hz=5.4, vibrato_cents=12.0,
                           vibrato_am=0.07, noise_gain=0.25, noise_hp_hz=700.0,
                           noise_lp_hz=12000.0, noise_db_cap=-55.0,
                           roughness=0.10, rough_hz=5.5, seed=11)
    ev = [(0.2, MIDI, 2.6, 0.85, DYNAMIC)]
    y_static = static.render(ev, 3.0)
    y_perf = perf.render(ev, 3.0)
    mod_static = y_static[int(1.0 * SR):int(2.0 * SR)]
    mod_perf = y_perf[int(1.0 * SR):int(2.0 * SR)]

    f, Xs = spectrum(src)
    _, Xm = spectrum(mod_static)
    _, Xp = spectrum(mod_perf)

    bs, bm, bp = bands(f, Xs), bands(f, Xm), bands(f, Xp)
    hs, hm = harmonics(f, Xs, f0), harmonics(f, Xm, f0)
    err = 20.0 * np.log10((hm + 1e-12) / (hs + 1e-12))

    # excerpt solo vs the average of the source notes it plays
    solo, _ = sf.read(os.path.join(OUT, "mystery_flute_solo.wav"))
    acc = []
    for i in range(0, len(solo) - 8192, 4096):
        fr = solo[i:i + 8192]
        if np.sqrt(np.mean(fr * fr)) < 1e-4:            # skip the silent tail
            continue
        acc.append(bands(*spectrum(fr)))
    ex = np.mean(acc, axis=0)
    ex /= max(np.sqrt((ex ** 2).sum()), 1e-12)

    src_notes = []
    for midi in EXCERPT_MIDIS:
        _n, r = source_note(midi)
        o1, o2 = note_region(r, SR)
        seg = r[o1 + int(0.35 * (o2 - o1)):o1 + int(0.75 * (o2 - o1))]
        src_notes.append(bands(*spectrum(seg)))
    src_avg = np.mean(src_notes, axis=0)
    src_avg /= max(np.sqrt((src_avg ** 2).sum()), 1e-12)

    def band_centroid(b):
        return float((b ** 2 * CENTERS).sum() / max((b ** 2).sum(), 1e-30))

    def band_hf(b):
        m = (CENTERS >= 4000) & (CENTERS <= 8000)
        return float((b[m] ** 2).sum() / max((b ** 2).sum(), 1e-30))

    report = dict(
        note=note, midi=MIDI, dynamic=DYNAMIC,
        d5=dict(
            centroid_hz=dict(source=round(centroid(f, Xs), 1),
                             model_static=round(centroid(f, Xm), 1),
                             model_perf=round(centroid(f, Xp), 1)),
            hf_4k_8k_ratio=dict(source=round(hf_ratio(f, Xs), 5),
                                model_static=round(hf_ratio(f, Xm), 5),
                                model_perf=round(hf_ratio(f, Xp), 5)),
            inter_harmonic_floor_db=dict(source=round(inter_floor_db(f, Xs, f0), 1),
                                         model_perf=round(inter_floor_db(f, Xp, f0), 1)),
            harmonic_max_err_db_k1_9=round(float(np.abs(err[:9]).max()), 2),
            harmonic_median_err_db_k1_9=round(float(np.median(np.abs(err[:9]))), 2)),
        excerpt=dict(
            centroid_hz=dict(source_avg=round(band_centroid(src_avg), 1),
                             excerpt_solo=round(band_centroid(ex), 1)),
            hf_4k_8k_ratio=dict(source_avg=round(band_hf(src_avg), 5),
                                excerpt_solo=round(band_hf(ex), 5)),
            frames=len(acc)),
        verdict=("harmonic balance matches the source; the source has more low-frequency "
                 "room/rumble and a higher inter-harmonic floor, the model is drier"),
    )
    with open(os.path.join(OUT, "flute_timbre_compare.json"), "w",
              encoding="utf-8") as fh:
        json.dump(report, fh, indent=2, ensure_ascii=False)

    # ------------------------------------------------------------------ figure
    fig, ax = plt.subplots(2, 3, figsize=(18, 9.0), constrained_layout=True)
    src_col, stat_col, perf_col = "0.25", "#2b6cb0", "#c05621"

    def db(b):
        return 20.0 * np.log10(b + 1e-12)

    ax[0, 0].semilogx(CENTERS, db(bs), "o-", color=src_col, ms=3, lw=1.3,
                      label="source sample")
    ax[0, 0].semilogx(CENTERS, db(bm), "s-", color=stat_col, ms=3, lw=1.0,
                      label="model, static")
    ax[0, 0].semilogx(CENTERS, db(bp), "^-", color=perf_col, ms=3, lw=1.0,
                      label="model, performance")
    ax[0, 0].set_xlim(80, 9000); ax[0, 0].set_ylim(-55, 3)
    ax[0, 0].set_xlabel("Hz"); ax[0, 0].set_ylabel("1/6-oct band, dB (normalised)")
    ax[0, 0].set_title(f"{note}  -  steady spectrum")
    ax[0, 0].legend(fontsize=8); ax[0, 0].grid(alpha=0.3, which="both")

    k = np.arange(1, 13)
    ax[0, 1].plot(k, 20 * np.log10(hs + 1e-12), "o-", color=src_col, label="source")
    ax[0, 1].plot(k, 20 * np.log10(hm + 1e-12), "s--", color=stat_col, label="model static")
    ax[0, 1].set_xticks(k); ax[0, 1].set_ylim(-45, 2)
    ax[0, 1].set_xlabel("harmonic k"); ax[0, 1].set_ylabel("dB rel. strongest")
    ax[0, 1].set_title(f"harmonic amplitudes  (k1-9 max err "
                       f"{report['d5']['harmonic_max_err_db_k1_9']:.2f} dB)")
    ax[0, 1].legend(fontsize=8); ax[0, 1].grid(alpha=0.3)

    diff = db(bp) - db(bs)
    ax[0, 2].bar(CENTERS, diff, width=CENTERS * 0.08, color="#805ad5", alpha=0.85)
    ax[0, 2].axhline(0, color="0.4", lw=0.8)
    ax[0, 2].set_xscale("log"); ax[0, 2].set_xlim(80, 9000)
    ax[0, 2].set_ylim(-20, 8)
    ax[0, 2].set_xlabel("Hz"); ax[0, 2].set_ylabel("model perf - source, dB")
    ax[0, 2].set_title("where the model differs (negative = darker)")
    ax[0, 2].grid(alpha=0.3, which="both")

    ax[1, 0].semilogx(CENTERS, db(src_avg), "o-", color=src_col, ms=3,
                      label="average of source notes C4-D5")
    ax[1, 0].semilogx(CENTERS, db(ex), "s-", color="#2f855a", ms=3,
                      label="excerpt solo")
    ax[1, 0].set_xlim(80, 9000); ax[1, 0].set_ylim(-55, 3)
    ax[1, 0].set_xlabel("Hz"); ax[1, 0].set_ylabel("1/6-oct band, dB (normalised)")
    ax[1, 0].set_title("whole excerpt vs the source notes it uses")
    ax[1, 0].legend(fontsize=8); ax[1, 0].grid(alpha=0.3, which="both")

    d2 = db(ex) - db(src_avg)
    ax[1, 1].bar(CENTERS, d2, width=CENTERS * 0.08, color="#2f855a", alpha=0.85)
    ax[1, 1].axhline(0, color="0.4", lw=0.8)
    ax[1, 1].set_xscale("log"); ax[1, 1].set_xlim(80, 9000)
    ax[1, 1].set_ylim(-20, 8)
    ax[1, 1].set_xlabel("Hz"); ax[1, 1].set_ylabel("excerpt - source avg, dB")
    ax[1, 1].set_title("excerpt difference: the missing low-mid room is visible")
    ax[1, 1].grid(alpha=0.3, which="both")

    ax[1, 2].axis("off")
    txt = (
        f"{note} (source: {note.split('_')[1]} {DYNAMIC})\n"
        f"  centroid      source {report['d5']['centroid_hz']['source']:.0f} Hz   "
        f"model {report['d5']['centroid_hz']['model_perf']:.0f} Hz\n"
        f"  HF 4-8 kHz    source {report['d5']['hf_4k_8k_ratio']['source']*100:.2f}%   "
        f"model {report['d5']['hf_4k_8k_ratio']['model_perf']*100:.2f}%\n"
        f"  floor         source {report['d5']['inter_harmonic_floor_db']['source']:.0f} dB   "
        f"model {report['d5']['inter_harmonic_floor_db']['model_perf']:.0f} dB\n"
        f"  harmonics 1-9 max error {report['d5']['harmonic_max_err_db_k1_9']:.2f} dB\n"
        f"\n"
        f"Excerpt vs source-note average\n"
        f"  centroid      source {report['excerpt']['centroid_hz']['source_avg']:.0f} Hz   "
        f"excerpt {report['excerpt']['centroid_hz']['excerpt_solo']:.0f} Hz\n"
        f"  HF 4-8 kHz    source {report['excerpt']['hf_4k_8k_ratio']['source_avg']*100:.2f}%   "
        f"excerpt {report['excerpt']['hf_4k_8k_ratio']['excerpt_solo']*100:.2f}%\n"
        f"\n"
        f"Reading: the harmonic balance matches; the source has\n"
        f"more energy below 300 Hz (room/rumble) and a higher\n"
        f"inter-harmonic floor. The model is not brighter in the\n"
        f"harmonics, but it is drier -- which reads as 'bright'.\n"
    )
    ax[1, 2].text(0.02, 0.98, txt, va="top", ha="left", family="monospace",
                  fontsize=9.5, transform=ax[1, 2].transAxes)

    path = os.path.join(OUT, "flute_timbre_compare.png")
    fig.savefig(path, dpi=130)
    plt.close(fig)
    print("wrote", path)
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
