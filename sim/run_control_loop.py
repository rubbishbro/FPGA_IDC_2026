#!/usr/bin/env python3
"""Standalone control_loop regression; no UI, communication or router RTL needed."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
CASES = ((1, 1), (1, 32), (2, 8), (3, 17), (5, 128))


def executable(name: str, variable: str) -> str:
    override = os.environ.get(variable)
    if override:
        return override
    found = shutil.which(name)
    if found:
        return found
    local = Path.home() / "micromamba/envs/torch312/bin" / name
    if local.is_file():
        return str(local)
    raise RuntimeError(f"{name} not found; set {variable} or add it to PATH")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, action="append", help="repeat for multiple seeds")
    parser.add_argument("--out", type=Path, default=ROOT / "build/control_loop")
    args = parser.parse_args()
    seeds = args.seed if args.seed is not None else [1, 42, 20261027]
    args.out.mkdir(parents=True, exist_ok=True)
    iv = executable("iverilog", "IVERILOG")
    vvp = executable("vvp", "VVP")
    for sources, width in CASES:
        name = f"control_loop_s{sources}_w{width}"
        image = args.out / f"{name}.vvp"
        command = [iv, "-g2012", "-Wall", "-s", "tb_control_loop",
                   f"-Ptb_control_loop.SOURCES={sources}",
                   f"-Ptb_control_loop.REQUEST_W={width}", "-o", str(image),
                   str(ROOT / "rtl/control_loop.sv"),
                   str(ROOT / "sim/unit/control/tb_control_loop.sv")]
        compiled = subprocess.run(command, capture_output=True, text=True, timeout=60)
        (args.out / f"{name}.compile.log").write_text(compiled.stdout + compiled.stderr)
        if compiled.returncode:
            print(compiled.stdout + compiled.stderr)
            return 1
        for seed in seeds:
            run = subprocess.run([vvp, str(image), f"+seed={seed}"],
                                 capture_output=True, text=True, timeout=30)
            output = run.stdout + run.stderr
            (args.out / f"{name}.seed{seed}.log").write_text(output)
            print(output.strip())
            if run.returncode or "PASS tb_control_loop" not in output:
                return 1
    print(f"PASS {len(CASES)*len(seeds)} control_loop cases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
