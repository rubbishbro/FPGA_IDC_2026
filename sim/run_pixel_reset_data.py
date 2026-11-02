#!/usr/bin/env python3
"""Compare observable behavior to the pre-optimization RTL across warm resets.

Reference modules come from an immutable Git revision, not a second handwritten
implementation. RGB wrappers select the actual production pipeline blocks.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import subprocess
from run_source_fixes import executable

ROOT = Path(__file__).resolve().parents[1]
BASELINE = "2a366f0400d595935c2ba13106299959e38c18d7"


def rgb_wrapper(source, name):
    start = source.index(".visible_width(sidebar_width));")
    body = source[source.index("\n", start):source.rindex("endmodule")]
    return """`timescale 1ns/1ps
module NAME(input logic pix_clk,pix_n,lcd_valid,
    input logic [5:0] base_r,base_g,base_b,overlay_r,overlay_g,overlay_b,guide_r,guide_g,guide_b,
    input logic overlay_hit,guide_hit,output logic lcd_valid_out,
    output logic [5:0] lcd_r,lcd_g,lcd_b);
    logic [2:0][5:0] base_r_q,base_g_q,base_b_q;
    logic [2:0] de_q;
""".replace("NAME", name) + body + "\nendmodule\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, default=ROOT / "build/pixel_reset_savings/tests")
    ap.add_argument("--baseline-ref", default=BASELINE)
    args = ap.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    paths = {
        "cordic_polar": "rtl_FFT/src/display/cordic_polar.sv",
        "lcd_polar_curve": "rtl_FFT/src/display/lcd_polar_curve.sv",
        "sidebar_mailbox": "rtl_FFT/src/ui/sidebar_mailbox.sv",
        "sidebar_system": "rtl_FFT/src/ui/sidebar_system.sv",
    }
    sources = []
    hashes = {}
    for name, path in paths.items():
        current = (ROOT / path).read_text()
        baseline = subprocess.check_output(["git", "show", f"{args.baseline_ref}:{path}"], cwd=ROOT, text=True)
        hashes[path] = dict(current=hashlib.sha256(current.encode()).hexdigest(),
                            baseline=hashlib.sha256(baseline.encode()).hexdigest())
        if name == "sidebar_system":
            for text, module in [(current, "rgb_pipeline_probe"), (baseline, "rgb_pipeline_reference")]:
                target = out / f"{module}.sv"
                target.write_text(rgb_wrapper(text, module))
                sources.append(target)
        else:
            sources.append(ROOT / path)
            # Also rename the reference polar page's CORDIC instance type.
            for original in ["cordic_polar", "lcd_polar_curve", "sidebar_mailbox"]:
                baseline = re.sub(r"\b" + original + r"\b", original + "_reset_reference", baseline)
            target = out / f"{name}_reset_reference.sv"
            target.write_text(baseline)
            sources.append(target)
    sources.append(ROOT / "sim/unit/board/tb_pixel_reset_data.sv")
    sources.append(ROOT / "sim/unit/board/tb_polar_reverse_scan.sv")
    results = []
    for name in ["tb_cordic_data_reset", "tb_polar_data_reset", "tb_rgb_data_reset",
                 "tb_mailbox_data_reset", "tb_polar_reverse_scan"]:
        image = out / f"{name}.vvp"
        proc = subprocess.run([executable("iverilog"), "-g2012", "-s", name, "-o", str(image),
                               *map(str, sources)], capture_output=True, text=True, timeout=60)
        (out / f"{name}.compile.log").write_text(proc.stdout + proc.stderr)
        if proc.returncode:
            raise RuntimeError(proc.stdout + proc.stderr)
        run = subprocess.run([executable("vvp"), str(image)], capture_output=True, text=True, timeout=60)
        output = run.stdout + run.stderr
        (out / f"{name}.run.log").write_text(output)
        passed = run.returncode == 0 and "PASS" in output and "FAIL" not in output
        results.append(dict(test=name, passed=passed))
        print(output.strip())
    (out / "results.json").write_text(json.dumps(dict(baseline_ref=args.baseline_ref,
        inputs=hashes, tests=results), indent=2) + "\n")
    return 0 if all(r["passed"] for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
