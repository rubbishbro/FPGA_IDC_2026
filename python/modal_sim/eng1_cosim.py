#!/usr/bin/env python3
"""Generate eng1 co-simulation vectors and run the RTL testbench.

The model and ``rtl/router/engines/eng1.sv`` must produce the same 64-bit
``y_data`` for the same job.  The current RTL still has F05 (the multiplier uses
the previous mode's captured state, and the captured state leaks between jobs),
so this co-simulation runs the model's ``rtl_compat=True`` mode.  That validates
the arithmetic skeleton -- product widths, rounding, saturation, the mode loop,
``nmod_lat`` -- independently of the intended-behaviour fix.

Once F05 is fixed in the RTL, regenerate with ``--mode intended``; the default
model then should match the RTL bit for bit.

    python python/modal_sim/eng1_cosim.py
    python python/modal_sim/eng1_cosim.py --mode intended   # after the F05 fix

Outputs ``build/eng1_cosim/cases.txt`` and ``build/eng1_cosim/tb_eng1_cosim``.
"""

from __future__ import annotations

import argparse
import os
import random
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / "python"))

import router_eng1 as R  # noqa: E402

N = 8
OUT = ROOT / "build" / "eng1_cosim"
CASES = OUT / "cases.txt"


def _golden_cases():
    """The TB golden plus the documented F05 sequence."""
    return [
        # n, zero, x, G, a1, a2, y1, y2
        (3, 1, -(1 << 28), 1 << 24, 0, 0, [0] * N, [0] * N),
        (3, 0, 0, 0, 1 << 24, 0, [10, 20, 30] + [0] * (N - 3), [0] * N),
    ]


def build_cases(n_cases: int, seed: int):
    rng = random.Random(seed)
    core = R.Eng1Core(slots=1, n_modes=N, rtl_compat=True)
    cases = []
    expected = []

    for n, zero, x, g, a1, a2, y1, y2 in _golden_cases():
        core.G[0] = 0
        core.a1[0] = 0
        core.a2[0] = 0
        core.nm[0] = n
        core.y1[0] = np.asarray(y1, dtype=np.int64)
        core.y2[0] = np.asarray(y2, dtype=np.int64)
        core.G[0] = g
        core.a1[0] = a1
        core.a2[0] = a2
        y, _ = core.step([x], [zero])
        cases.append((n, int(zero), int(x), int(g), int(a1), int(a2), list(y1), list(y2)))
        expected.append(int(y[0]))

    for _ in range(n_cases):
        n = rng.randrange(0, N + 1)
        zero = int(rng.random() < 0.3)
        x = rng.randrange(-(1 << 31), 1 << 31)
        g = rng.randrange(-(1 << 25), 1 << 25)
        a1 = rng.randrange(-(1 << 25), 1 << 25)
        a2 = rng.randrange(0, 1 << 24)
        y1 = [rng.randrange(-(1 << 31), 1 << 31) for _ in range(N)]
        y2 = [rng.randrange(-(1 << 31), 1 << 31) for _ in range(N)]

        core.G[0] = 0
        core.a1[0] = 0
        core.a2[0] = 0
        core.nm[0] = n
        core.y1[0] = np.asarray(y1, dtype=np.int64)
        core.y2[0] = np.asarray(y2, dtype=np.int64)
        core.G[0] = g
        core.a1[0] = a1
        core.a2[0] = a2
        y, _ = core.step([x], [zero])
        cases.append((n, zero, x, g, a1, a2, y1, y2))
        expected.append(int(y[0]))
    return cases, expected


def write_cases(cases, expected):
    if not cases or len(cases) != len(expected):
        raise ValueError(
            f"refusing to write {len(cases)} cases with {len(expected)} expected values")
    OUT.mkdir(parents=True, exist_ok=True)
    with open(CASES, "w", encoding="utf-8") as fh:
        for (n, zero, x, g, a1, a2, y1, y2), exp in zip(cases, expected):
            fields = [n, zero, x, g, a1, a2]
            fields += [int(v) for v in y1]
            fields += [int(v) for v in y2]
            fields += [int(exp)]
            fh.write(" ".join(str(v) for v in fields) + "\n")


def run_tb(mode: str = "rtl"):
    iverilog = os.environ.get("IVERILOG") or shutil.which("iverilog")
    vvp = os.environ.get("VVP") or shutil.which("vvp")
    if not iverilog or not vvp:
        print("SKIP: iverilog/vvp not found (set IVERILOG/VVP or add them to PATH)")
        return 2
    exe = OUT / "tb_eng1_cosim"
    srcs = [
        ROOT / "rtl/math/pkg/fxp_pkg.sv",
        ROOT / "rtl/router/pkg/modal_step_pkg.sv",
        ROOT / "rtl/router/engines/eng1.sv",
        ROOT / "rtl/router/tb_eng1_cosim.sv",
    ]
    cmd = [iverilog, "-g2012", "-s", "tb_eng1_cosim", "-o", str(exe)] + [str(p) for p in srcs]
    proc = subprocess.run(cmd, cwd=ROOT, text=True, capture_output=True)
    if proc.returncode != 0:
        print(proc.stdout)
        print(proc.stderr)
        print("FAIL: iverilog")
        return 1
    proc = subprocess.run([vvp, str(exe)], cwd=ROOT, text=True, capture_output=True)
    tail = "\n".join(proc.stdout.splitlines()[-12:])
    print(tail)
    if "RESULT: PASS" not in proc.stdout:
        print("FAIL: co-simulation mismatched")
        return 1
    print(f"PASS: {CASES.relative_to(ROOT)} matches eng1 ({mode} mode)")
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--cases", type=int, default=64,
                    help="random cases after the two golden ones (default 64)")
    ap.add_argument("--seed", type=int, default=20261025)
    ap.add_argument("--mode", choices=("rtl", "intended"), default="rtl",
                    help="rtl = reproduce the current F05 pipeline; "
                         "intended = the fixed model (only after the RTL is fixed)")
    ap.add_argument("--write-only", action="store_true")
    args = ap.parse_args(argv)

    if args.mode == "intended":
        print("NOTE: --mode intended expects the RTL to be F05-free; "
              "this will fail on the current eng1.sv.")

    cases, expected = build_cases(args.cases, args.seed)
    if args.mode == "intended":
        # Regenerate with the intended model.  The sequence of jobs is the same;
        # only the F05 pipeline changes.
        core = R.Eng1Core(slots=1, n_modes=N, rtl_compat=False)
        old_expected = expected
        expected = []
        for (n, zero, x, g, a1, a2, y1, y2), _old in zip(cases, old_expected):
            core.G[0] = 0
            core.a1[0] = 0
            core.a2[0] = 0
            core.nm[0] = n
            core.y1[0] = np.asarray(y1, dtype=np.int64)
            core.y2[0] = np.asarray(y2, dtype=np.int64)
            if n:
                core.G[0, :n] = g
                core.a1[0, :n] = a1
                core.a2[0, :n] = a2
            y, _ = core.step([x], [zero])
            expected.append(int(y[0]))

    write_cases(cases, expected)
    print(f"wrote {CASES.relative_to(ROOT)} ({len(cases)} cases)")
    if args.write_only:
        return 0
    return run_tb(args.mode)


if __name__ == "__main__":
    raise SystemExit(main())
