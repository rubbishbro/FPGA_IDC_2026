"""Single source of truth for where analysis and simulation write their files.

Layout under ``FFT_results/``::

    README.md, report.md          overview + extraction summary
    params/                       extracted tables the engine loads
        <inst>_partials.npz, <inst>_body.npz, <inst>_manifest.json,
        <inst>_summary.json, drums.npz
    figures/<inst>/               extraction diagnostics per instrument
    sim/                          synthesis deliverables -- one folder per topic,
                                  each holding its own audio + figures + data
        README.md, report.json
        pitched/                  <inst>_{melody,stress}.wav + stress/synth_vs_table
        sustained/                sustained_trio.wav + per-instrument verify figures
        drums/                    kit demos, cymbal_compare, kit_eval
        song/                     a real song excerpt
        roll_compare/             roll-vs-repeated-hit experiment
        crosscheck/               cross-instrument checks (timbre, filter chain)
"""

from __future__ import annotations

import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))

MUSIC = os.path.join(ROOT, "music_resources")
FFT = os.path.join(ROOT, "FFT_results")

PARAMS = os.path.join(FFT, "params")
FIG_EXTRACT = os.path.join(FFT, "figures")

SIM = os.path.join(FFT, "sim")
SIM_PITCHED = os.path.join(SIM, "pitched")
SIM_SONG = os.path.join(SIM, "song")
SIM_DRUMS = os.path.join(SIM, "drums")
SIM_ROLL = os.path.join(SIM, "roll_compare")
SIM_SUSTAIN = os.path.join(SIM, "sustained")
SIM_CROSSCHECK = os.path.join(SIM, "crosscheck")

ALL_DIRS = [PARAMS, FIG_EXTRACT, SIM, SIM_PITCHED, SIM_SONG,
            SIM_DRUMS, SIM_ROLL, SIM_SUSTAIN, SIM_CROSSCHECK]


def param(inst: str, kind: str, ext: str = "npz") -> str:
    """``params/guitar_partials.npz``"""
    return os.path.join(PARAMS, f"{inst}_{kind}.{ext}")


def extract_fig_dir(inst: str) -> str:
    return os.path.join(FIG_EXTRACT, inst)


def makedirs() -> None:
    for d in ALL_DIRS:
        os.makedirs(d, exist_ok=True)
