"""Sustained-instrument demo (Class B) + per-instrument verification.

Renders a short chord/melody passage with **flute** (lead), **trumpet** (harmony) and
**cello** (bass) through ``SustainSynth`` -- the periodic-drive engine -- and writes a
verification figure per instrument that puts the recording next to the model
(steady-state spectrum and the note's amplitude envelope).

    python python_monotor/modal_sim/sustain_demo.py
"""

from __future__ import annotations

import json
import os
import sys
import time

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

OUT = paths.SIM_SUSTAIN
BPM = 84.0
BEAT = 60.0 / BPM
BAR = 4.0 * BEAT

#: per-instrument expression. Vibrato rates/depths are typical wind/string values;
#: the noise band comes from the instrument's own breath/bow character.
#: `noise_gain` is the residual between the reference band (2-8 kHz, where the level is
#: measured) and the instrument's actual noise shape; trumpet/cello land within 1 dB of
#: unity, the flute's breath noise is concentrated higher and needs ~8 dB more.
# Per-instrument expression.  Decision (2026-10-16, user): bow/breath noise is OFF by
# default.  A no-noise render is perceptually close, and dropping it saves RTL resources
# (the shared 257-tap noise FIR + gain path).  The noise implementation and the tuned
# parameters are KEPT so it can be re-enabled by setting `noise_gain > 0`.
# See rtl/DECISIONS.md (G6) and python_monotor/results/sim/README.md.
VOICE = {
    "flute": dict(vibrato_hz=5.4, vibrato_cents=13, vibrato_am=0.08,
                  noise_gain=0.0, noise_hp_hz=600.0, noise_lp_hz=12000.0,
                  noise_db_cap=-70.0, roughness=0.12, rough_hz=6.0),
    "trumpet": dict(vibrato_hz=4.8, vibrato_cents=9, vibrato_am=0.06,
                    noise_gain=0.0, noise_hp_hz=800.0, noise_lp_hz=9000.0,
                    noise_db_cap=-70.0, roughness=0.15, rough_hz=6.0),
    "cello": dict(vibrato_hz=5.8, vibrato_cents=12, vibrato_am=0.06,
                  noise_gain=0.0, noise_hp_hz=250.0, noise_lp_hz=8000.0,
                  noise_db_cap=-74.0, roughness=0.30, rough_hz=6.0),
}


def nm(name: str) -> int:
    return CORE.note_to_midi(name)


# 4 bars, one chord each: Am - F - C - G (classic)
CHORDS = [("Am", ["A3", "C4", "E4"], "A2"),
          ("F", ["A3", "C4", "F4"], "F2"),
          ("C", ["G3", "C4", "E4"], "C3"),
          ("G", ["G3", "B3", "D4"], "G2")]
# a simple chant-like lead over the top
MELODY = [("E4", 2.0), ("A4", 1.0), ("G4", 1.0), ("F4", 2.0), ("C4", 1.0), ("F4", 1.0),
          ("E4", 2.0), ("G4", 1.0), ("C5", 1.0), ("B4", 2.0), ("D4", 1.0), ("G4", 1.0)]


def events():
    flute, trumpet, cello = [], [], []
    t = 0.0
    for note, beats in MELODY:
        flute.append((t, nm(note), beats * BEAT * 0.92, 1.0))
        t += beats * BEAT
    for i, (name, tones, root) in enumerate(CHORDS):
        t0 = i * BAR
        cello.append((t0, nm(root), BAR * 1.6, 0.95))
        for j, tone in enumerate(tones):
            trumpet.append((t0 + j * 0.02, nm(tone), BAR * 0.95, 0.6))
    return flute, trumpet, cello, t + 2.0


def main(argv=None):
    paths.makedirs()
    flute, trumpet, cello, total = events()
    report = {}
    t0 = time.time()
    tracks = {}
    for inst, ev in (("flute", flute), ("trumpet", trumpet), ("cello", cello)):
        patch = SE.SustainPatch(inst)
        synth = SE.SustainSynth(patch, max_poly=24, **VOICE[inst])
        y = synth.render(ev, total)
        y = y / max(float(np.max(np.abs(y))), 1e-12)
        tracks[inst] = y
        report[inst] = dict(notes=len(ev), peak=round(float(np.max(np.abs(y))), 3),
                            hard=synth.hard_count)
    mix = 1.0 * tracks["flute"] + 0.55 * tracks["trumpet"] + 0.7 * tracks["cello"]
    mix = np.tanh(mix * 0.9) / np.tanh(0.9)
    mix *= 0.9 / max(float(np.max(np.abs(mix))), 1e-12)
    path = os.path.join(OUT, "sustained_trio.wav")
    sf.write(path, mix, SE.SR, subtype="PCM_16")
    report["render_s"] = round(time.time() - t0, 1)
    report["peak"] = round(float(np.max(np.abs(mix))), 3)
    report["finite"] = bool(np.isfinite(mix).all())
    with open(os.path.join(OUT, "sustained_trio.json"), "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2, ensure_ascii=False)

    for inst in ("flute", "trumpet", "cello"):
        verify_fig(inst, 69 if inst != "cello" else 57)
    print(f"wrote {path}  ({total:.1f}s, render {report['render_s']}s, "
          f"peak {report['peak']}, finite {report['finite']})")
    return 0


# ---------------------------------------------------------------------------
def verify_fig(inst, midi):
    """Recording vs model: steady spectrum, spectrograms (vibrato) and envelope."""
    patch = SE.SustainPatch(inst)
    synth = SE.SustainSynth(patch, max_poly=2, **VOICE[inst])
    kk, g, w, atk, rel, ndb, nwin = patch.modes(midi)
    sr = SE.SR
    period = max(2, int(round(sr / CORE.midi_to_hz(midi))))
    f = kk * (sr / period)
    y = synth.render([(0.3, midi, 2.4, 1.0)], 3.0)

    # the recording this patch was built from
    d = np.load(paths.param(inst, "sustain"), allow_pickle=True)
    j = int(np.argmin([abs(midi - CORE.note_to_midi(
        (__import__('re').search(r"_([A-G]s?\d)_", str(n)).group(1)).replace("s", "#")))
        for n in d["notes"]]))
    note = str(d["notes"][j])
    src = os.path.join(paths.MUSIC, inst,
                       note if note.endswith(".mp3") else note + ".mp3")
    real = CORE.load_audio(src) if os.path.exists(src) else None

    fig, ax = plt.subplots(2, 3, figsize=(15, 7.5), constrained_layout=True)
    # (a) steady spectrum
    seg = y[int(1.6 * sr):int(2.8 * sr)]
    Y = np.abs(np.fft.rfft(seg * np.hanning(len(seg))))
    fr = np.fft.rfftfreq(len(seg), 1 / sr)
    ax[0, 0].semilogy(fr, Y / Y.max(), lw=0.6, label="model")
    rs = None
    if real is not None:
        on, off = __import__("sustain").note_region(real, sr)
        rs = real[on + int(0.3 * (off - on)):on + int(0.7 * (off - on))]
        R = np.abs(np.fft.rfft(rs * np.hanning(len(rs))))
        rfr = np.fft.rfftfreq(len(rs), 1 / sr)
        ax[0, 0].semilogy(rfr, R / R.max(), lw=0.6, alpha=0.7, label="recording")
    ax[0, 0].set_xlim(0, 6000); ax[0, 0].set_ylim(1e-4, 2)
    ax[0, 0].set_title(f"{inst} steady spectrum"); ax[0, 0].set_xlabel("Hz")
    ax[0, 0].legend(fontsize=8); ax[0, 0].grid(alpha=0.3, which="both")

    # (b) a_k / gamma
    ax[0, 1].stem(f, w / w.max(), basefmt=" ", label="extracted a_k")
    ax[0, 1].set_xlim(0, 6000); ax[0, 1].set_ylim(0, 1.05)
    ax[0, 1].set_title("extracted a_k and gamma"); ax[0, 1].set_xlabel("Hz")
    ax2 = ax[0, 1].twinx(); ax2.plot(f, g, "r.-", ms=4, lw=0.8, label="gamma")
    ax2.set_ylabel("gamma 1/s", color="r"); ax2.set_ylim(0, max(30, g.max() * 1.2))
    ax[0, 1].grid(alpha=0.3)

    # (c) envelope -- vibrato shows up here
    env = np.sqrt(np.convolve(y ** 2, np.ones(480) / 480, mode="same"))
    t = np.arange(len(y)) / sr
    ax[0, 2].plot(t, env / env.max(), lw=0.7, label="model")
    if real is not None:
        re_ = np.sqrt(np.convolve(real ** 2, np.ones(480) / 480, mode="same"))
        ax[0, 2].plot(np.arange(len(re_)) / sr, re_ / re_.max(), alpha=0.7, lw=0.7,
                      label="recording")
    ax[0, 2].set_xlim(0, 3.0); ax[0, 2].set_ylim(0, 1.05)
    ax[0, 2].set_title(f"envelope (attack {atk * 1e3:.0f} ms, "
                       f"vibrato {synth.vibrato_hz:.1f} Hz / "
                       f"{synth.vibrato_cents:.0f} cents)")
    ax[0, 2].set_xlabel("s"); ax[0, 2].legend(fontsize=8); ax[0, 2].grid(alpha=0.3)

    # (d)/(e) spectrograms -- vibrato sidebands
    from scipy.signal import spectrogram
    for col, (sig, name) in enumerate(((y, "model"),
                                       (real if real is not None else y,
                                        "recording"))):
        s = sig[int(0.4 * sr):int(2.6 * sr)]
        fq, tt, S = spectrogram(s, fs=sr, nperseg=4096, noverlap=3584,
                                mode="magnitude")
        Sdb = 20 * np.log10(S / (S.max() + 1e-30) + 1e-12)
        ax[1, col].pcolormesh(tt, fq, Sdb, shading="auto", cmap="magma",
                              vmin=-80, vmax=0)
        ax[1, col].set_ylim(0, 6000); ax[1, col].set_title(f"{name}: spectrogram")
        ax[1, col].set_xlabel("s"); ax[1, col].set_ylabel("Hz")
    # (f) noise floor: spectrum between partials
    for lab, sig, col in (("model", y, "b"), ("recording", real, "orange")):
        if sig is None:
            continue
        s = sig[int(1.0 * sr):int(2.4 * sr)]
        X = np.abs(np.fft.rfft(s * np.hanning(len(s))))
        fq = np.fft.rfftfreq(len(s), 1 / sr)
        mask = np.ones(len(fq), bool)
        for fk in f:
            mask &= np.abs(fq - fk) > max(8.0, 0.03 * fk)
        ax[1, 2].semilogy(fq[mask], X[mask] / X.max(), ".", ms=2, alpha=0.4, label=lab)
    ax[1, 2].set_xlim(200, 12000); ax[1, 2].set_ylim(1e-5, 1)
    ax[1, 2].set_title("noise floor between partials")
    ax[1, 2].set_xlabel("Hz"); ax[1, 2].legend(fontsize=8); ax[1, 2].grid(alpha=0.3)

    out = os.path.join(OUT, f"verify_{inst}.png")
    fig.savefig(out, dpi=105); plt.close(fig)
    return out


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
