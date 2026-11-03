#!/usr/bin/env python3
"""Focused held-pad keymap regression (Verilator, board top).

Only boot + one 0x20 keymap request per scenario. It first asserts that the
request is admitted, then checks 04-without-table-change for a held pad and
00-with-commit for release-before-deadline.
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUT = ROOT / "build/keymap_held_only"
TB = ROOT / "sim/unit/comm/tb_keymap_held_only.sv"
MODELS = ROOT / "sim/unit/comm/tb_keymap_held_models.sv"


def sources() -> list[str]:
    out = []
    for line in (ROOT / "rtl/platform/tang_mega_138k_pro/sources.f").read_text().splitlines():
        s = line.strip()
        if not s or s.startswith("//") or "/ip/" in s or s == "rtl/drivers/gowin_adc/gowin_adc.v":
            continue
        out.append(str(ROOT / s))
    out += [str(ROOT / "sim/unit/midi/w25q64_read_model.sv"), str(MODELS), str(TB)]
    return out


def prepare_memories(run: Path) -> None:
    for mem in (ROOT / "rtl_FFT/board").glob("*.mem"):
        shutil.copyfile(mem, run / mem.name)
    tables = run / "rtl/drivers/pad_led_tables"
    tables.mkdir(parents=True, exist_ok=True)
    for mem in (ROOT / "rtl/drivers/pad_led_tables").glob("*.mem"):
        shutil.copyfile(mem, tables / mem.name)
    shutil.copyfile(ROOT / "rtl/router/tools/performance/resources.mem",
                    run / "performance_resources.mem")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--reuse", action="store_true")
    ap.add_argument("--timeout", type=int, default=600)
    args = ap.parse_args()
    out = args.out.resolve()
    run = out / "run"
    image = out / "tb_keymap_held_only"
    out.mkdir(parents=True, exist_ok=True)
    run.mkdir(parents=True, exist_ok=True)
    prepare_memories(run)
    verilator = ROOT / "build/verilator_env/bin/verilator"
    if not verilator.is_file():
        verilator = Path(shutil.which("verilator") or "verilator")
    if not args.reuse:
        command = [str(verilator), "--binary", "--timing", "-Wno-fatal", "-j", "4",
                   "--top-module", "tb_keymap_held_only",
                   "--Mdir", str(out / "obj"), "-o", str(image),
                   "-MAKEFLAGS", "CXX=g++ LINK=g++ AR=ar CFG_CXXFLAGS_PCH_I=-include",
                   *sources()]
        with (out / "compile.log").open("w") as log:
            build = subprocess.run(command, cwd=ROOT, stdout=log,
                                   stderr=subprocess.STDOUT, timeout=600)
        if build.returncode:
            print((out / "compile.log").read_text()[-5000:])
            return 1
    started = time.perf_counter()
    proc = subprocess.run([str(image)], cwd=run, capture_output=True,
                          text=True, timeout=args.timeout)
    elapsed = time.perf_counter() - started
    log = out / "run.log"
    log.write_text(proc.stdout + proc.stderr)
    text = log.read_text(errors="replace")
    fails = [ln for ln in text.splitlines() if ln.startswith("CHECK FAIL") or ln.startswith("FAIL ")]
    passed = "PASS tb_keymap_held_only" in text and proc.returncode == 0 and not fails
    result = {"passed": passed, "runtime_s": round(elapsed, 2),
              "returncode": proc.returncode, "failures": fails,
              "log": str(log)}
    (out / "results.json").write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(result, indent=2, ensure_ascii=False))
    if not passed:
        print(text[-5000:])
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
