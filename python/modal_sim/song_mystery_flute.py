"""Mystery of Love (Sufjan Stevens) -- flute excerpt through the Class-B engine.

What this is
------------
A short, instrumental excerpt (intro + first verse) played by the **flute** patch of
``SustainSynth`` (the periodic-drive modal engine), with a quiet fingerpicked-guitar
accompaniment from the Class-A engine.  It exists to listen to the engine, not to
release a cover: audio is written under ``FFT_results/sim/song/`` only.

Transcription provenance / caveat
---------------------------------
* **Chords**: the verse loop ``F | Am | Dm | Am | C`` is the public chord chart
  (Ultimate Guitar tab 2225633, "Mystery of Love", verse 1,
  https://tabs.ultimate-guitar.com/tab/sufjan-stevens/mystery-of-love-chords-2225633).
* **Melody**: a good-faith reading of a public AutoPiano keyboard transcription
  (https://www.autopiano.cn/post/10683), whose lead line is
  ``p o p o i u | y r | t y u o u y`` -- i.e. ``A G A G F E | D B | C D E G E D`` in
  A minor.  The rhythm and the octave are adapted for the flute; syllable alignment in
  free charts varies, so this is **not** claimed to be note-for-note the record.  The
  point is the engine.
* **Key / register**: the record's key is reported inconsistently (the chart is written
  in F, streaming metadata says G/E minor); this demo reads the chart's loop and the
  keyboard-score lead in A minor, then plays the whole excerpt a perfect fourth lower in
  **D minor**.  That is as low as the full arrangement can go without falling below the
  flute table's C4 bottom (the intro's low G becomes C4); the first render at A5..B4 was
  an octave too bright.  It is an engine demo, not a claim about the record's key.

Engine settings are the same defaults as ``sustain_demo.py`` except:
* breath noise is **on** at a low gain (the RTL path omits it; here it is audible
  flute character, see ``sustain_engine`` / ``rtl/DECISIONS.md`` G6);
* the guitar is only a backdrop (level-matched, then attenuated).

    python python/modal_sim/song_mystery_flute.py

Writes ``mystery_flute_solo.wav`` (engine only), ``mystery_flute.wav`` (with guitar),
``mystery_flute.png`` and ``mystery_flute.json``.
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
sys.path.insert(0, os.path.dirname(HERE))            # python/ -> paths, instruments
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "fft_analysis"))

import core as CORE                                  # noqa: E402
import params as P                                   # noqa: E402
import paths                                         # noqa: E402
import sustain_engine as SE                          # noqa: E402
from engine import ModalSynth                        # noqa: E402

OUT = paths.SIM_SONG
BPM = 100.0
BEAT = 60.0 / BPM
BAR = 4.0 * BEAT

#: The transcription is written in A minor.  A perfect fourth down puts the excerpt in
#: D minor and keeps the lowest intro note at C4 (the flute table's bottom); 0 would
#: restore the original (too bright) A-minor register.  Change both together if you
#: experiment: the chord names/voicings below are already in the sounding key.
TRANSPOSE = -7
KEY_NAME = "D minor"

#: One chord per bar in the sounding key; ``("Dm", "F")`` means Dm for beats 1-2, F for
#: 3-4.  This is the A-minor loop ``F Am Dm Am C`` transposed down a fourth.
CHORDS = ["Bb", "Dm",
          "Bb", "Dm", "Gm", "Dm", "Bb", "Dm", "Gm", ("Dm", "F"),
          "Bb", "Bb"]

#: Flute voice.  Values follow ``sustain_demo.VOICE['flute']``; noise is enabled
#: (that demo ships it off for the RTL budget) and the cap tames the few notes
#: whose extracted breath level is an outlier.
VOICE = dict(vibrato_hz=5.4, vibrato_cents=12.0, vibrato_am=0.07,
             noise_gain=0.25, noise_hp_hz=700.0, noise_lp_hz=12_000.0,
             noise_db_cap=-55.0, roughness=0.10, rough_hz=5.5, seed=11)


def nm(name: str) -> int:
    """Concert MIDI for a written note, including the D-minor transposition."""
    return CORE.note_to_midi(name) + TRANSPOSE


#: (start beat, note, duration in beats, velocity).  Intro = 2 bars, verse = 8 bars,
#: cadence = 2 bars.  Note names are the A-minor keyboard-score line; nm() applies
#: TRANSPOSE when they are turned into MIDI.
#: The velocity arch (softer intro, a small crescendo into each G5, a tapered phrase
#: end) is the only expression added on top of the engine's own vibrato/attack/release.
FLUTE = [
    # intro riff (score: u-t-uyte-w | w-e-rt-ou-y), 2 bars
    (0.0, "E5", 0.5, 0.72), (0.5, "C5", 0.5, 0.70), (1.0, "E5", 0.5, 0.74),
    (1.5, "D5", 0.5, 0.72), (2.0, "C5", 0.5, 0.70), (2.5, "A4", 0.5, 0.68),
    (3.0, "G4", 1.0, 0.66),
    (4.0, "G4", 0.5, 0.68), (4.5, "A4", 0.5, 0.70), (5.0, "B4", 0.5, 0.72),
    (5.5, "C5", 0.5, 0.74), (6.0, "G4", 1.0, 0.70), (7.0, "E5", 0.5, 0.76),
    (7.5, "D5", 0.35, 0.72),
    # verse phrase 1 ("Oh, to see without my eyes ...")
    (8.0, "A5", 1.0, 0.80), (9.0, "G5", 0.5, 0.76), (9.5, "A5", 0.5, 0.82),
    (10.0, "G5", 1.0, 0.78), (11.0, "F5", 1.0, 0.76),
    (12.0, "E5", 1.5, 0.74), (13.5, "D5", 1.0, 0.72), (14.5, "B4", 1.4, 0.70),
    (16.0, "C5", 1.0, 0.74), (17.0, "D5", 0.5, 0.78), (17.5, "E5", 0.5, 0.82),
    (18.0, "G5", 2.0, 0.90),
    (20.0, "E5", 1.0, 0.82), (21.0, "D5", 1.0, 0.78), (22.0, "C5", 1.6, 0.74),
    # verse phrase 2 (same line, repeated with a little more push)
    (24.0, "A5", 1.0, 0.84), (25.0, "G5", 0.5, 0.80), (25.5, "A5", 0.5, 0.86),
    (26.0, "G5", 1.0, 0.82), (27.0, "F5", 1.0, 0.80),
    (28.0, "E5", 1.5, 0.78), (29.5, "D5", 1.0, 0.76), (30.5, "B4", 1.4, 0.74),
    (32.0, "C5", 1.0, 0.78), (33.0, "D5", 0.5, 0.82), (33.5, "E5", 0.5, 0.86),
    (34.0, "G5", 2.0, 0.94),
    (36.0, "E5", 1.0, 0.86), (37.0, "D5", 1.0, 0.82), (38.0, "C5", 1.6, 0.78),
    # cadence: settle on the Bb chord (the chorus' "mystery of love" landing, transposed)
    (40.0, "A5", 2.0, 0.82), (42.0, "G5", 1.0, 0.78), (43.0, "F5", 1.0, 0.76),
    (44.0, "F5", 3.8, 0.72),
]

#: fingerpicked voicings in D minor, low to high (MIDI); the first note is the root.
VOICING = {
    "Bb": [46, 53, 58, 62, 65],     # Bb2 F3 Bb3 D4 F4
    "Dm": [50, 57, 62, 65, 69],     # D3  A3 D4  F4 A4
    "Gm": [43, 50, 55, 58, 62],     # G2  D3 G3  Bb3 D4
    "F":  [41, 48, 53, 57, 60],     # F2  C3 F3  A3 C4
}
#: arpeggio order over 8 eighths, indices into VOICING
ARP = [0, 2, 3, 4, 3, 2, 4, 3]


def chord_at(bar: int, beat: float):
    c = CHORDS[bar]
    if isinstance(c, tuple):
        return c[0] if beat < 2.0 else c[1]
    return c


def flute_events():
    ev = []
    for t0, name, dur, vel in FLUTE:
        # small gap -> the next attack is clean, while the modes ring through it
        ev.append((t0 * BEAT, nm(name), dur * BEAT * 0.96, vel, "forte"))
    end = max(t0 + dur for t0, _name, dur, _vel in FLUTE) * BEAT
    return ev, end + 3.0


def guitar_events():
    """Eighth-note arpeggios, one bar at a time, with the chord held by the ring."""
    ev = []
    for bar in range(len(CHORDS)):
        for k in range(8):
            beat = k * 0.5
            name = chord_at(bar, beat)
            tone = VOICING[name][ARP[k]]
            t = bar * BAR + beat * BEAT
            vel = 0.55 if k in (0, 4) else 0.34          # accent beats 1 and 3
            ev.append((t, tone, 0.75, vel))
    return ev


def render():
    paths.makedirs()
    t_start = time.time()
    ev_f, total = flute_events()

    flute = SE.SustainSynth(SE.SustainPatch("flute"), max_poly=8, high_water=6,
                            **VOICE)
    yf = flute.render(ev_f, total)
    yf = yf / max(float(np.max(np.abs(yf))), 1e-12)
    print(f"flute rendered: {total:.1f}s in {time.time() - t_start:.1f}s")

    guitar = P.Patch("guitar", band_hz=16_000.0)
    g = ModalSynth(guitar, max_poly=10, high_water=8, noise_amp=0.10,
                   noise_lp_hz=4000.0, release_factor=2.0, seed=5)
    yg = g.render(guitar_events(), total)
    yg = yg / max(float(np.max(np.abs(yg))), 1e-12)
    print(f"guitar rendered: {time.time() - t_start:.1f}s elapsed")

    mix = 0.95 * yf + 0.32 * yg
    mix = np.tanh(mix * 0.85) / np.tanh(0.85)       # gentle bus saturation
    mix *= 0.9 / max(float(np.max(np.abs(mix))), 1e-12)

    sf.write(os.path.join(OUT, "mystery_flute_solo.wav"), yf, SE.SR,
             subtype="PCM_16")
    sf.write(os.path.join(OUT, "mystery_flute.wav"), mix, SE.SR,
             subtype="PCM_16")

    def stats(y):
        return dict(peak=round(float(np.max(np.abs(y))), 4),
                    rms=round(float(np.sqrt(np.mean(y * y))), 4),
                    finite=bool(np.isfinite(y).all()))

    rep = dict(title="Mystery of Love (Sufjan Stevens) -- flute excerpt",
               engine="SustainSynth (Class B periodic drive) + ModalSynth guitar",
               bpm=BPM, key=f"{KEY_NAME} (transcription in A minor, {TRANSPOSE:+d} st)",
               transpose_semitones=TRANSPOSE, bars=len(CHORDS),
               seconds=round(total, 2), sr=SE.SR,
               flute_notes=len(ev_f), flute=stats(yf), mix=stats(mix),
               flute_hard_steals=flute.hard_count, guitar_hard_steals=g.hard_count,
               render_s=round(time.time() - t_start, 1))
    with open(os.path.join(OUT, "mystery_flute.json"), "w", encoding="utf-8") as fh:
        json.dump(rep, fh, indent=2, ensure_ascii=False)
    print(f"wrote mystery_flute_solo.wav / mystery_flute.wav  "
          f"({total:.1f}s, render {rep['render_s']}s, "
          f"peak {rep['mix']['peak']}, finite {rep['mix']['finite']})")
    return yf, mix, rep


# ---------------------------------------------------------------------------
def figure(yf, mix, rep):
    sr, total = SE.SR, rep["seconds"]
    t = np.arange(len(mix)) / sr
    fig, ax = plt.subplots(2, 2, figsize=(14, 8.0), constrained_layout=True)

    # (a) the transcribed notes, so the excerpt can be checked against the score
    sounding = [nm(name) for _t0, name, _dur, _vel in FLUTE]
    lo, hi = min(sounding), max(sounding)
    for t0, name, dur, _vel in FLUTE:
        m = nm(name)
        ax[0, 0].add_patch(plt.Rectangle((t0 * BEAT, m - 0.32), dur * BEAT * 0.92,
                                         0.64, color="#2b6cb0", alpha=0.85))
    for bar, c in enumerate(CHORDS):
        ax[0, 0].text(bar * BAR + 0.04, hi + 2.0,
                      c[0] if isinstance(c, tuple) else c,
                      fontsize=8, color="#c05621")
        ax[0, 0].axvline(bar * BAR, color="0.85", lw=0.6, zorder=0)
    ax[0, 0].set_xlim(0, total); ax[0, 0].set_ylim(lo - 3, hi + 6)
    ax[0, 0].set_xlabel("s"); ax[0, 0].set_ylabel("MIDI note")
    ax[0, 0].set_title(f"transcribed flute line ({KEY_NAME}) and chord per bar")

    # (b) waveform + RMS envelopes
    env = np.sqrt(np.convolve(mix * mix, np.ones(2400) / 2400, mode="same"))
    envf = np.sqrt(np.convolve(yf * yf, np.ones(2400) / 2400, mode="same"))
    ax[0, 1].plot(t, mix, color="0.75", lw=0.35, label="mix")
    ax[0, 1].plot(t, env / env.max(), color="#2f855a", lw=1.6, label="mix env")
    ax[0, 1].plot(t, envf / envf.max(), color="#c53030", lw=1.0, alpha=0.8,
                  label="flute env")
    ax[0, 1].set_xlim(0, total); ax[0, 1].set_ylim(-1.05, 1.05)
    ax[0, 1].set_xlabel("s"); ax[0, 1].legend(loc="lower right", fontsize=8)
    ax[0, 1].set_title(f"waveform / envelope  (peak {rep['mix']['peak']:.2f}, "
                       f"rms {rep['mix']['rms']:.2f})")
    ax[0, 1].grid(alpha=0.25)

    # (c) spectrogram of the flute only -- harmonics + vibrato sidebands
    from scipy.signal import spectrogram
    fq, tt, Sx = spectrogram(yf, fs=sr, nperseg=4096, noverlap=3584,
                             mode="magnitude")
    Sdb = 20 * np.log10(Sx / (Sx.max() + 1e-30) + 1e-12)
    ax[1, 0].pcolormesh(tt, fq, Sdb, shading="auto", cmap="magma",
                        vmin=-100, vmax=0)
    ax[1, 0].set_ylim(0, 8000); ax[1, 0].set_xlim(0, total)
    ax[1, 0].set_xlabel("s"); ax[1, 0].set_ylabel("Hz")
    ax[1, 0].set_title("flute spectrogram (engine only)")

    # (d) average spectrum in a held verse note, with the harmonic series marked
    seg = yf[int(24.1 * sr):int(25.1 * sr)]
    from scipy.signal.windows import blackmanharris
    win = blackmanharris(seg.size)        # low sidelobes: the floor is noise, not leakage
    S = np.abs(np.fft.rfft(seg * win))
    f = np.fft.rfftfreq(seg.size, 1 / sr)
    S = S / (S.max() + 1e-30)
    ax[1, 1].semilogy(f, S + 1e-12, lw=0.7, color="#2b6cb0")
    f0 = CORE.midi_to_hz(nm("A5"))
    for k in range(1, 9):
        ax[1, 1].axvline(k * f0, color="#c05621", ls=":", lw=0.8, alpha=0.7)
    ax[1, 1].set_xlim(0, 7500); ax[1, 1].set_ylim(1e-5, 2)
    ax[1, 1].set_xlabel("Hz"); ax[1, 1].set_ylabel("normalised magnitude")
    ax[1, 1].set_title("held verse note: harmonic series (dots) and inter-partial floor")
    ax[1, 1].grid(alpha=0.25, which="both")

    path = os.path.join(OUT, "mystery_flute.png")
    fig.savefig(path, dpi=130)
    plt.close(fig)
    print("wrote", path)


def main():
    yf, mix, rep = render()
    figure(yf, mix, rep)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
