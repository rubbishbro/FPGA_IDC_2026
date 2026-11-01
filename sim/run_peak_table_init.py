#!/usr/bin/env python3
"""Verify sequential peak initialization and post-init equivalence to old RTL."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import subprocess
from run_source_fixes import executable

ROOT = Path(__file__).resolve().parents[1]
BASELINE = "2a366f0400d595935c2ba13106299959e38c18d7"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, default=ROOT / "build/peak_init_savings/tests")
    args = ap.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    source = ROOT / "FFT_spectrumshow/src/display/lcd_fft.v"
    baseline = subprocess.check_output(["git", "show", f"{BASELINE}:{source.relative_to(ROOT)}"], cwd=ROOT, text=True)
    reference = out / "lcd_fft_reset_reference.v"
    reference.write_text(re.sub(r"\blcd_fft\b", "lcd_fft_reset_reference", baseline))
    results = []
    for name, fixture in [
        ("tb_peak_table_init", "sim/unit/board/tb_peak_table_init.sv"),
        ("lcd_fft_tb", "FFT_spectrumshow/sim/lcd_fft_tb.sv"),
        ("lcd_fft_align_tb", "FFT_spectrumshow/sim/lcd_fft_align_tb.sv"),
    ]:
        image = out / f"{name}.vvp"
        compile_run = subprocess.run([executable("iverilog"), "-g2012", "-s", name, "-o", str(image),
            str(source), str(reference), str(ROOT / fixture)], capture_output=True, text=True, timeout=60)
        (out / f"{name}.compile.log").write_text(compile_run.stdout + compile_run.stderr)
        if compile_run.returncode:
            raise RuntimeError(compile_run.stdout + compile_run.stderr)
        run = subprocess.run([executable("vvp"), str(image)], capture_output=True, text=True, timeout=90)
        output = run.stdout + run.stderr
        (out / f"{name}.run.log").write_text(output)
        passed = run.returncode == 0 and ("PASS" in output or "TEST PASSED" in output) and not re.search(r"\b(?:FAIL|FATAL|ERROR)\b", output)
        results.append(dict(test=name, passed=bool(passed)))
        print(output.strip())
    (out / "results.json").write_text(json.dumps(dict(baseline_ref=BASELINE,
        current_sha256=hashlib.sha256(source.read_bytes()).hexdigest(), tests=results), indent=2) + "\n")
    return 0 if all(r["passed"] for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
