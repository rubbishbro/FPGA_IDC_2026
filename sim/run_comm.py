#!/usr/bin/env python3
"""Self-checking communication regression; does not use audio/router RTL."""
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
SOURCES = (ROOT / "sim/comm_sources.f").read_text().splitlines()
TESTS = ["tb_comm_fifo", "tb_comm_uart", "tb_comm_uart_rates", "tb_comm_hc05_status", "tb_slip_frame_rx",
         "tb_slip_frame_tx", "tb_frame_arbiter", "tb_midi_analyzer",
         "tb_config_analyzer", "tb_comm_top", "tb_comm_faults",
         "tb_comm_drivers", "tb_session_ctrl", "tb_comm_v2_codec",
         "tb_transport_v2_link", "tb_comm_v2_top"]


def executable(name: str, env: str) -> str:
    if env in os.environ:
        return os.environ[env]
    found = shutil.which(name)
    if found:
        return found
    local = Path.home() / "micromamba/envs/torch312/bin" / name
    if local.is_file():
        return str(local)
    raise RuntimeError(f"{name} not found; set {env} or add it to PATH")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--test", action="append", choices=TESTS)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--seed", type=int, help="optional SV +seed value for randomized fixtures")
    ap.add_argument("--out", type=Path, default=ROOT / "build/comm")
    args = ap.parse_args()
    if args.list:
        print("\n".join(TESTS))
        return 0
    args.out.mkdir(parents=True, exist_ok=True)
    iv, vvp = executable("iverilog", "IVERILOG"), executable("vvp", "VVP")
    results = []
    for test in args.test or TESTS:
        image = args.out / f"{test}.vvp"
        command = [iv, "-g2012", "-Wall", "-s", test, "-o", str(image),
                   *(str(ROOT / x) for x in SOURCES),
                   str(ROOT / "sim/unit/comm" / f"{test}.sv")]
        compiled = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=60)
        compile_log = compiled.stdout + compiled.stderr
        (args.out / f"{test}.compile.log").write_text(compile_log)
        output = ""
        passed = False
        if compiled.returncode == 0:
            try:
                run_command = [vvp, str(image)]
                if args.seed is not None:
                    run_command.append(f"+seed={args.seed}")
                run = subprocess.run(run_command, cwd=ROOT, capture_output=True,
                                     text=True, timeout=120)
                output = run.stdout + run.stderr
                passed = (run.returncode == 0 and "PASS" in output and
                          re.search(r"\b(?:FAIL|FATAL)\b", output) is None)
            except subprocess.TimeoutExpired as exc:
                output = f"TIMEOUT: {exc}"
        else:
            output = compile_log
        (args.out / f"{test}.run.log").write_text(output)
        print(f"{'PASS' if passed else 'FAIL'} {test}")
        if not passed:
            print(output[-6000:])
        results.append({"test": test, "passed": passed,
                        "seed": args.seed,
                        "compile_log": str(args.out / f"{test}.compile.log"),
                        "run_log": str(args.out / f"{test}.run.log")})
    (args.out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    return 0 if all(x["passed"] for x in results) else 1


if __name__ == "__main__":
    sys.exit(main())
