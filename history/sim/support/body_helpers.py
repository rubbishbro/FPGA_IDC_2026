"""Shared helpers for the body-filter tests (no cocotb import).

The modal-song reference here is the same integer recurrence the existing
``sim/archive/bringup_mock/test_audio_demo._song_reference`` verifies against the 2C RTL: the
song_player cyclic note allocation, the 7-sample raised-cosine pulse and the
per-mode Q2.30/Q24 recurrence, summed to the signed64/Q30 ``mix_sum``.  This
module extends that by optionally running the mix through the integer body
filter, so the body integration can be checked sample-by-sample.
"""

from __future__ import annotations

import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = _HERE
while not (os.path.isdir(os.path.join(ROOT, "rtl"))
           and os.path.isdir(os.path.join(ROOT, "sim"))):
    ROOT = os.path.dirname(ROOT)
sys.path.insert(0, os.path.join(ROOT, "sim", "support"))
from _sim_paths import bootstrap as _sim_bootstrap  # noqa: E402
ROOT = str(_sim_bootstrap(__file__))
sys.path.insert(0, os.path.join(ROOT, "python", "modal_sim"))

SR = 48000
PULSE = [0, 40427475, 131267186, 204114978, 204114978, 131267186, 40427475]
SONG = [60, 60, 67, 67, 69, 69, 67, 65, 65, 64, 64, 62, 62, 60,
        67, 67, 65, 65, 64, 64, 62, 67, 67, 65, 65, 64, 64, 62,
        60, 60, 67, 67, 69, 69, 67, 65, 65, 64, 64, 62, 62, 60]
NUM_EVENTS = len(SONG)
Y_MIN32, Y_MAX32 = -(1 << 31), (1 << 31) - 1
MAX_MODES = 48


def sum_to_i16(s: int) -> int:
    """The documented Q30 -> int16 output adaptation (SUM_ATT=3)."""
    t = s >> 3
    t = (t + 16384) >> 15
    return max(-32768, min(32767, t))


def unpack_word(w: int):
    """72-bit ROM word -> (a1 Q2.20, a2 UQ0.24, G Q2.24) as signed ints."""
    a1 = w & ((1 << 22) - 1)
    if a1 & (1 << 21):
        a1 -= 1 << 22
    a2 = (w >> 22) & ((1 << 24) - 1)
    g = (w >> 46) & ((1 << 26) - 1)
    if g & (1 << 25):
        g -= 1 << 26
    return a1, a2, g


def song_coeffs(rom_dir: str | None = None, song=None) -> dict:
    """(a1,a2,G) per guitar-forte MIDI used by the score, from the modal ROM."""
    rom_dir = rom_dir or os.path.join(ROOT, "rtl", "rom")
    with open(os.path.join(rom_dir, "modal_manifest.json"), encoding="utf-8") as fh:
        man = json.load(fh)
    with open(os.path.join(rom_dir, "modal_coeff.mem"), encoding="utf-8") as fh:
        rom = [int(line, 16) for line in fh if line.strip()]
    want = set(SONG if song is None else song)
    out = {}
    for e in man["entries"]:
        if (e["instrument"] == "guitar" and e["dyn"] == "forte"
                and e["midi"] in want):
            words = rom[e["offset"]:e["offset"] + e["n_modes"]]
            out[e["midi"]] = [unpack_word(w) for w in words]
    missing = want - set(out)
    if missing:
        raise AssertionError(f"missing guitar-forte notes {missing}")
    return out


def song_chain(nsamp: int, coeffs: dict, song=None, num_voices: int = 8,
               note_gap: int = 512, body=None, return_mix: bool = False):
    """Bit-exact song_player + 2C recurrence (+ optional body), one sample/tick.

    Returns the int16 output list, or ``(mix_q30, out_i16)`` with
    ``return_mix=True`` (the body, when given, is applied to the Q30 mix before
    the adapter, exactly like the audio_demo_core integration).
    """
    song = SONG if song is None else song
    gv = [None] * num_voices
    av = [None] * num_voices
    a2v = [None] * num_voices
    y1 = [[0] * MAX_MODES for _ in range(num_voices)]
    y2 = [[0] * MAX_MODES for _ in range(num_voices)]
    nm = [0] * num_voices
    active = [False] * num_voices
    pos = [7] * num_voices
    out, mix_seq = [], []
    ev, samp = 0, 0
    for _ in range(nsamp):
        if samp == 0:
            v = ev % num_voices
            words = coeffs[song[ev % len(song)]]
            for k in range(len(words)):
                y1[v][k] = 0
                y2[v][k] = 0
            av[v] = [w[0] for w in words]
            a2v[v] = [w[1] for w in words]
            gv[v] = [w[2] for w in words]
            nm[v] = len(words)
            active[v] = True
            pos[v] = 0
            ev = (ev + 1) % len(song)
        mix = 0
        for v in range(num_voices):
            if not active[v]:
                continue
            x = PULSE[pos[v]] if pos[v] < 7 else 0
            ny1 = [0] * MAX_MODES
            ny2 = [0] * MAX_MODES
            for k in range(nm[v]):
                acc = (gv[v][k] * x - (av[v][k] << 4) * y1[v][k]
                       - a2v[v][k] * y2[v][k])
                yn = (acc + (1 << 23)) >> 24
                if yn > Y_MAX32:
                    yn = Y_MAX32
                elif yn < Y_MIN32:
                    yn = Y_MIN32
                ny1[k] = yn
                ny2[k] = y1[v][k]
                mix += yn
            y1[v], y2[v] = ny1, ny2
        mix_seq.append(mix)
        if body is not None:
            y, _, _ = body.process_sample(mix)
        else:
            y = mix
        out.append(sum_to_i16(y))
        for v in range(num_voices):
            if pos[v] < 7:
                pos[v] += 1
        samp = 0 if samp == note_gap - 1 else samp + 1
    if return_mix:
        return mix_seq, out
    return out
