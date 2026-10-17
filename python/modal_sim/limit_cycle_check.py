"""Limit-cycle / voice-reclaim check (the criterion bit-exactness cannot see).

The direct-form recursion has a non-zero fixed point at

    c_max = 2^23 / (1 + a1 + a2)          [state code units]

where it sticks forever when the per-sample decrease is < 0.5 LSB.  If c_max/2^FS is
ABOVE free_thr the voice never reclaims.  This script:

  1. scans every mode and asserts the worst trap is below free_thr, and
  2. drives the worst notes for real and asserts the voice actually reclaims.

Run:  python python/modal_sim/limit_cycle_check.py
"""

from __future__ import annotations

import argparse
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))

import params as P                       # noqa: E402
import gen_coeff_table as GEN            # noqa: E402
from fixed_point import Y_FRAC, C_FRAC, FixedModalSynth   # noqa: E402

FREE_THR = 2e-4


def analytic_scan(free_thr=FREE_THR):
    S2 = 1 << 24                         # coefficient scale
    worst = []
    for inst in ("guitar", "piano", "banjo", "mandolin"):
        tab = GEN.build(inst)
        for (midi, dyn), e in tab.entries.items():
            D = S2 + (e["a1"] << 4) + e["a2"]      # (1+a1+a2)*2^24
            assert (D > 0).all(), f"{inst} {midi} {dyn}: non-decaying mode"
            cmax = (1 << (C_FRAC - 1)) // D          # state code units at 2^FS
            lvl = cmax / float(1 << Y_FRAC)
            worst.append((float(lvl.max()), inst, midi, dyn))
    worst.sort(reverse=True)
    return worst


def behavioral(inst, midi, vel, max_s=60.0):
    tab = GEN.build(inst)
    fx = FixedModalSynth(tab, max_poly=1, max_modes=GEN.N_MODES)
    fx.note_on(midi, vel)
    limit = int(max_s * P.SR)
    for i in range(limit):
        fx.step()
        if not fx.active[0]:
            return i / P.SR
    return None


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--free-thr", type=float, default=FREE_THR)
    args = ap.parse_args(argv)

    print(f"FS={Y_FRAC} (state {Y_FRAC + 2}-bit), free_thr={args.free_thr:g}")
    worst = analytic_scan(args.free_thr)
    print(f"  worst trap levels (top 5)   [must be < free_thr]:")
    for lvl, inst, midi, dyn in worst[:5]:
        flag = "ok" if lvl < args.free_thr else "FAIL"
        print(f"    [{flag}] {lvl:.3e} ({20*np.log10(lvl):6.1f} dBFS)  "
              f"{inst} midi{midi} {dyn}")
    assert worst[0][0] < args.free_thr, "worst trap is above free_thr -> voice would stick"

    print("  behavioral reclaim on the worst notes:")
    ok = True
    for lvl, inst, midi, dyn in worst[:4]:
        vel = 1.0 if dyn == "forte" else 0.5
        t = behavioral(inst, midi, vel)
        good = t is not None
        ok &= good
        print(f"    [{'ok' if good else 'FAIL'}] {inst} midi{midi} {dyn}: "
              f"reclaimed at {t:.1f} s" if good else
              f"    [FAIL] {inst} midi{midi} {dyn}: NEVER reclaimed")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
