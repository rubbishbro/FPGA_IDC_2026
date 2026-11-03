#!/usr/bin/env python3
"""Board-level integration regression: keymap 0x20 <-> config 0x02.

Builds and runs sim/unit/comm/tb_integration_keymap_config.sv with Verilator.
Only the PLL/ADC/Flash use test models; comm_top, the board bridge, router,
keymap owner and UARTs are production RTL.

Usage:
    python3 sim/run_integration_keymap_config.py
    python3 sim/run_integration_keymap_config.py --reuse
    python3 sim/run_integration_keymap_config.py --analyze build/.../run.log
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUT = ROOT / "build/integration_keymap_config"
TB = ROOT / "sim/unit/comm/tb_integration_keymap_config.sv"
MODELS = ROOT / "sim/unit/comm/tb_integration_keymap_models.sv"


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


def analyze(log: Path) -> dict:
    text = log.read_text(errors="replace")
    checks = [ln for ln in text.splitlines() if ln.startswith("CHECK ")]
    fails = [ln for ln in checks if ln.startswith("CHECK FAIL")]
    passed = "PASS tb_integration_keymap_config" in text and not fails
    return {"log": str(log), "passed": passed, "checks": len(checks),
            "failures": len(fails), "failure_lines": fails}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--analyze", type=Path, help="parse an existing run log")
    ap.add_argument("--reuse", action="store_true", help="skip Verilator build")
    ap.add_argument("--jobs", type=int, default=2, help="Verilator build jobs")
    ap.add_argument("--timeout", type=int, default=900)
    args = ap.parse_args()
    out = args.out.resolve()
    run = out / "run"
    image = out / "tb_integration_keymap_config"
    if args.analyze:
        result = analyze(args.analyze)
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return 0 if result["passed"] else 1
    out.mkdir(parents=True, exist_ok=True)
    run.mkdir(parents=True, exist_ok=True)
    prepare_memories(run)
    verilator = ROOT / "build/verilator_env/bin/verilator"
    if not verilator.is_file():
        verilator = Path(shutil.which("verilator") or "verilator")
    if not args.reuse:
        command = [str(verilator), "--binary", "--timing", "-Wno-fatal",
                   "-j", str(args.jobs), "--top-module", "tb_integration_keymap_config",
                   "--Mdir", str(out / "obj"), "-o", str(image),
                   "-MAKEFLAGS", "CXX=g++ LINK=g++ AR=ar CFG_CXXFLAGS_PCH_I=-include",
                   *sources()]
        with (out / "compile.log").open("w") as log:
            build = subprocess.run(command, cwd=ROOT, stdout=log,
                                   stderr=subprocess.STDOUT, timeout=1200)
        if build.returncode:
            print((out / "compile.log").read_text()[-5000:])
            return 1
    started = time.perf_counter()
    proc = subprocess.run([str(image)], cwd=run, capture_output=True,
                          text=True, timeout=args.timeout)
    elapsed = time.perf_counter() - started
    log = out / "run.log"
    log.write_text(proc.stdout + proc.stderr)
    result = analyze(log)
    result["runtime_s"] = round(elapsed, 2)
    result["returncode"] = proc.returncode
    (out / "results.json").write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({k: result[k] for k in
                      ("passed", "checks", "failures", "runtime_s", "returncode", "log")},
                     indent=2))
    for line in result["failure_lines"]:
        print(line)
    if not result["passed"]:
        print(log.read_text(errors="replace")[-5000:])
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
