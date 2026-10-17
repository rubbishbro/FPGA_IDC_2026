"""Generate the frozen 72-bit coefficient table from the extracted parameters.

Produces, per A-class instrument, under ``FFT_results/params/``:

* ``<inst>_coeftable.npz``  -- quantised arrays + packed 72-bit words + index
* ``<inst>_coeff.mem``      -- one 18-hex-digit line per mode, for RTL ``$readmemh``
* ``<inst>_coeffindex.json``-- {midi, dynamic} -> {offset, n_modes}

The words are laid out exactly as ``fixed_point.pack_word``:

    [71:46] G (Q2.24, 26 bit, signed)
    [45:22] a2 (UQ0.24, 24 bit, unsigned)
    [21:0]  a1 (Q2.20, 22 bit, signed)

Coefficients are taken from the float engine itself, so this table reproduces the exact
float coefficients before quantisation.  ``-d/--instrument`` selects one instrument.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)                              # engine / params / fixed_point
sys.path.insert(0, os.path.dirname(HERE))             # instruments.py
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))  # paths.py

import paths                                          # noqa: E402
import instruments                                    # noqa: E402
import params as P                                    # noqa: E402
from engine import ModalSynth                         # noqa: E402
from fixed_point import (CoeffTable, q_a1, q_a2, q_G,  # noqa: E402
                         word_hex)

# A-class notes are keyed by (midi, dynamic) with two dynamics; velocity only picks the
# table row (tau_forte / tau_piano) and scales the excitation amplitude at runtime.
DYN_VEL = {"forte": 1.0, "piano": 0.5}
N_MODES = 48                                          # DECISIONS B4


def build(instrument: str) -> CoeffTable:
    cfg = instruments.get(instrument)
    patch = P.Patch(instrument, band_hz=cfg["band_hz"], max_modes=N_MODES)
    synth = ModalSynth(patch, max_poly=1)

    table = CoeffTable()
    for midi in patch.midis:
        for dyn, vel in DYN_VEL.items():
            if (midi, dyn) not in patch.by_key:
                continue
            n = patch.modes(midi, dyn)[0].size
            synth.note_on(midi, vel)                  # fills f / base_gamma / gain
            f = synth.f[0, :n]
            gam = synth.base_gamma[0, :n]
            G = synth.gain[0, :n]

            a1 = -2.0 * np.exp(-gam / P.SR) * np.cos(2.0 * np.pi * f / P.SR)
            a2 = np.exp(-2.0 * gam / P.SR)
            table.add(midi, dyn, q_a1(a1), q_a2(a2), q_G(G))
    return table


def save(table: CoeffTable, instrument: str):
    words, index = table.flattened()
    arr = np.array(words, dtype=object)

    lo = np.array([int(w) & ((1 << 36) - 1) for w in words], dtype=np.uint64)
    hi = np.array([int(w) >> 36 for w in words], dtype=np.uint64)

    midis, dyns, offs, ns = [], [], [], []
    for (midi, dyn), meta in sorted(index.items()):
        midis.append(midi); dyns.append(dyn)
        offs.append(meta["offset"]); ns.append(meta["n_modes"])

    npz_path = paths.param(instrument, "coeftable", "npz")
    np.savez(npz_path,
             word_lo=lo, word_hi=hi,
             midi=np.array(midis, dtype=np.int64),
             dynamic=np.array(dyns),
             offset=np.array(offs, dtype=np.int64),
             n_modes=np.array(ns, dtype=np.int64),
             word_bits=np.array(72),
             n_modes_max=np.array(N_MODES))

    mem_path = os.path.join(paths.PARAMS, f"{instrument}_coeff.mem")
    with open(mem_path, "w", encoding="utf-8") as fh:
        for w in words:
            fh.write(word_hex(w) + "\n")

    idx_path = os.path.join(paths.PARAMS, f"{instrument}_coeffindex.json")
    with open(idx_path, "w", encoding="utf-8") as fh:
        json.dump({f"{m}|{d}": index[(m, d)] for (m, d) in sorted(index)},
                  fh, indent=2)

    return npz_path, mem_path, idx_path, len(words)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-d", "--instrument", default=None,
                    help="one instrument (default: every A-class instrument)")
    args = ap.parse_args(argv)

    paths.makedirs()
    names = [args.instrument] if args.instrument else list(instruments.REGISTRY)
    for inst in names:
        table = build(inst)
        npz_path, mem_path, idx_path, n = save(table, inst)
        print(f"[{inst}] {n} modes -> {os.path.basename(npz_path)}, "
              f"{os.path.basename(mem_path)}, {os.path.basename(idx_path)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
