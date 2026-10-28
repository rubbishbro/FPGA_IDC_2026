#!/usr/bin/env python3
"""MIDI performance-state and parser-to-consumer regression (no engine RTL)."""
from pathlib import Path
import argparse
import json
import re
import subprocess
from run_comm import ROOT, executable


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=ROOT / "build/midi")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    iv = executable("iverilog", "IVERILOG")
    vvp = executable("vvp", "VVP")
    results = []
    for name in ("tb_midi_note_state", "tb_midi_note_pipeline"):
        image = args.out / (name + ".vvp")
        compiled = subprocess.run([
            iv, "-g2012", "-Wall", "-s", name, "-o", str(image),
            str(ROOT / "rtl/midi/midi_note_state.sv"),
            str(ROOT / "rtl/drivers/analyzer/midi_analyzer.sv"),
            str(ROOT / "sim/unit/midi" / (name + ".sv")),
        ], capture_output=True, text=True, timeout=60, cwd=ROOT)
        (args.out / (name + ".compile.log")).write_text(compiled.stdout + compiled.stderr)
        output = compiled.stdout + compiled.stderr
        passed = False
        if compiled.returncode == 0:
            try:
                run = subprocess.run([vvp, str(image)], capture_output=True,
                                     text=True, timeout=60, cwd=ROOT)
                output = run.stdout + run.stderr
                passed = (run.returncode == 0 and "PASS" in output and
                          re.search(r"\b(?:FAIL|FATAL)\b", output) is None)
            except subprocess.TimeoutExpired:
                output = "FAIL simulation timeout\n"
        (args.out / (name + ".run.log")).write_text(output)
        print(f"{'PASS' if passed else 'FAIL'} {name}")
        if not passed:
            print(output[-6000:])
        results.append(dict(test=name, passed=passed))
    (args.out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    return 0 if all(r["passed"] for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
