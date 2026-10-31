#!/usr/bin/env python3
"""Focused self-checking regression for comm_v2_codec.

This runner deliberately compiles only the codec contract and its independent
unit test, so it does not depend on the rest of the communication tree.  It
searches IVERILOG/VVP overrides, PATH, the local /tmp tool bundle used during
development, and the usual micromamba environment.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    ROOT / "rtl/comm/comm_pkg.sv",
    ROOT / "rtl/comm/comm_v2_codec.sv",
    ROOT / "sim/unit/comm/tb_comm_v2_codec.sv",
]
TEST = "tb_comm_v2_codec"
LOCAL_TOOLS = Path("/tmp/bt-v2-tools")


def executable(name: str, env: str) -> str:
    if env in os.environ and os.environ[env]:
        candidate = Path(os.environ[env]).expanduser()
        if candidate.is_file():
            return str(candidate)
        raise RuntimeError(f"{env}={candidate} is not a file")
    candidates = [shutil.which(name), str(LOCAL_TOOLS / name)]
    candidates.append(str(Path.home() / "micromamba/envs/torch312/bin" / name))
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return candidate
    raise RuntimeError(
        f"{name} not found; set {env}, add it to PATH, or unpack Icarus under "
        f"{LOCAL_TOOLS}"
    )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, default=ROOT / "build/comm-v2-codec")
    ap.add_argument("--keep", action="store_true", help="keep the compiled .vvp image")
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    try:
        iverilog = executable("iverilog", "IVERILOG")
        vvp = executable("vvp", "VVP")
    except RuntimeError as exc:
        print(f"FAIL: {exc}")
        return 2

    image = args.out / f"{TEST}.vvp"
    command = [
        iverilog, "-g2012", "-Wall", "-s", TEST, "-o", str(image),
        *(str(source) for source in SOURCES),
    ]
    compiled = subprocess.run(
        command, cwd=ROOT, capture_output=True, text=True, timeout=120
    )
    compile_log = compiled.stdout + compiled.stderr
    (args.out / f"{TEST}.compile.log").write_text(compile_log)
    print(f"iverilog: {iverilog}")
    print(f"vvp:      {vvp}")

    passed = False
    if compiled.returncode != 0:
        output = compile_log
        print(f"FAIL {TEST}: compile error")
    else:
        try:
            run = subprocess.run(
                [vvp, str(image)], cwd=ROOT, capture_output=True,
                text=True, timeout=180,
            )
            output = run.stdout + run.stderr
            passed = (
                run.returncode == 0
                and "PASS" in output
                and re.search(r"\b(?:FAIL|FATAL)\b", output) is None
            )
            print(f"{'PASS' if passed else 'FAIL'} {TEST}")
        except subprocess.TimeoutExpired as exc:
            output = f"TIMEOUT: {exc}"
            print(f"FAIL {TEST}: timeout")

    (args.out / f"{TEST}.run.log").write_text(output)
    if not passed:
        print(output[-8000:])
    (args.out / "results.json").write_text(
        json.dumps(
            {
                "test": TEST,
                "passed": passed,
                "iverilog": iverilog,
                "vvp": vvp,
                "compile_log": str(args.out / f"{TEST}.compile.log"),
                "run_log": str(args.out / f"{TEST}.run.log"),
            },
            indent=2,
        )
        + "\n"
    )
    if not args.keep and image.exists():
        image.unlink()
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
