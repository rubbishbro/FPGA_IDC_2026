#!/usr/bin/env python3
"""Compare single-table router behavior to the immutable two-table RTL.

Uses the complete production router/consumers and real QSPI loader. Requires
Verilator (VERILATOR may select an isolated tool installation).
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BASELINE = "4bcee5f215f1180e09622e0d2f1fc1a48d2db490"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, default=ROOT / "build/single_play_table/tests")
    ap.add_argument("--baseline-ref", default=BASELINE)
    ap.add_argument("--modes", type=int, choices=[3, 4, 64], default=64)
    args = ap.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    result_file = out / "results.json"
    result_file.unlink(missing_ok=True)
    (out / "play_table.mem").write_text("00\n" * (12 * 4 * args.modes * 64 + 4096))
    original = subprocess.check_output(
        ["git", "show", f"{args.baseline_ref}:rtl/router/voice_router.sv"],
        cwd=ROOT, text=True)
    if "sustain_cfg_t pending_play" not in original:
        raise RuntimeError("baseline must contain the two-table implementation")
    reference = out / "voice_router_reference.sv"
    reference.write_text(re.sub(r"\bmodule voice_router\b",
                               "module voice_router_reference", original, count=1))
    sources = re.findall(r"'((?:rtl|tb)/[^']+\.sv)'",
                         (ROOT / "sim/router_sources.list").read_text())
    sources = [ROOT / s for s in sources if not s.startswith("rtl/tb/")]
    sources += [reference, ROOT / "sim/unit/midi/w25q64_read_model.sv",
                ROOT / "sim/unit/midi/tb_router_play_table.sv"]
    verilator = os.environ.get("VERILATOR") or shutil.which("verilator")
    if not verilator:
        raise RuntimeError("Verilator not found; set VERILATOR")
    obj = out / "obj"
    command = [verilator, "--binary", "--timing", "--assert", "-Wno-fatal",
               "--top-module", "tb_router_play_table", f"-GMODES={args.modes}",
               "-j", "4", "--Mdir", str(obj), "-MAKEFLAGS",
               "CFG_CXXFLAGS_PCH_I=-include", *map(str, sources)]
    with (out / "compile.log").open("w") as log:
        subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                       timeout=600, check=True)
    run = subprocess.run([str(obj / "Vtb_router_play_table")], cwd=out,
                         capture_output=True, text=True, timeout=180)
    output = run.stdout + run.stderr
    (out / "run.log").write_text(output)
    passed = (run.returncode == 0 and "PASS tb_router_play_table" in output
              and re.search(r"\b(?:FAIL|FATAL|Error)\b", output) is None)
    result_file.write_text(json.dumps(dict(
        passed=passed, modes=args.modes, baseline_ref=args.baseline_ref,
        baseline_sha256=hashlib.sha256(original.encode()).hexdigest(),
        current_sha256=hashlib.sha256((ROOT / "rtl/router/voice_router.sv").read_bytes()).hexdigest(),
        compile_command=command, output=output), indent=2) + "\n")
    print(output.strip())
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
