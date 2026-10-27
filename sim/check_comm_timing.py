#!/usr/bin/env python3
"""Build the isolated communication probe and check real Gowin PnR reports."""
from __future__ import annotations
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/comm_timing"


def hashes() -> dict[str, str]:
    manifest = ROOT / "sim/comm_sources.f"
    files = sorted(ROOT / name for name in manifest.read_text().splitlines())
    files += [manifest]
    files += [ROOT / "sim/synth" / name for name in
              ("comm_probe.sv", "comm_probe.cst", "comm_probe.sdc", "comm_build.tcl")]
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    before = hashes()
    executable = os.environ.get("GOWIN_SH") or shutil.which("gw_sh")
    if not executable:
        raise RuntimeError("gw_sh not found; set GOWIN_SH")
    env = os.environ.copy()
    lib = Path(executable).resolve().parent.parent / "lib"
    env["LD_LIBRARY_PATH"] = str(lib) + (":" + env["LD_LIBRARY_PATH"] if env.get("LD_LIBRARY_PATH") else "")
    with (OUT / "gowin.log").open("w") as log:
        run = subprocess.run([executable, "sim/synth/comm_build.tcl"], cwd=ROOT,
                             env=env, stdout=log, stderr=subprocess.STDOUT)
    log = (OUT / "gowin.log").read_text(errors="replace")
    report = OUT / "comm_probe/impl/pnr/comm_probe.tr"
    resource_file = OUT / "comm_probe/impl/pnr/comm_probe.rpt.txt"
    result = {"time": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "scope": "isolated comm_probe, NOT audio/board signoff", "target_mhz": 100,
              "source_sha256": before, "source_unchanged": before == hashes(),
              "tool_exit": run.returncode, "log": str(OUT / "gowin.log")}
    if run.returncode != 0 or "COMM_PNR_DONE" not in log:
        result["passed"] = False
        (OUT / "results.json").write_text(json.dumps(result, indent=2) + "\n")
        print(log[-6000:])
        return 1
    text = report.read_text(errors="replace")
    result["setup_violations"] = int(re.search(r"<Numbers of Setup Violated Endpoints>:(\d+)", text)[1])
    result["hold_violations"] = int(re.search(r"<Numbers of Hold Violated Endpoints>:(\d+)", text)[1])
    fmax = re.search(r"\bclk\s+100\.000\(MHz\)\s+([\d.]+)\(MHz\)", text)
    result["fmax_mhz"] = float(fmax[1]) if fmax else None
    for key, heading in [("setup_slack_ns", "3.1.1 Setup Paths Table"),
                         ("hold_slack_ns", "3.1.2 Hold Paths Table")]:
        section = text.split(heading)[-1]
        match = re.search(r"^\s+1\s+(-?[\d.]+)\s+", section, re.M)
        result[key] = float(match[1]) if match else None
    resource = resource_file.read_text(errors="replace")
    for label, key in [("Logic", "logic"), ("Register", "registers"), ("BSRAM", "bsram")]:
        match = re.search(r"^\s+" + label + r"\s+\|\s+(\d+)/", resource, re.M)
        result[key] = int(match[1]) if match else None
    result["logic_loop_warning"] = "AG0100" in log or "AG0101" in log
    result["generic_clock_warning"] = "PR1014" in log
    result["passed"] = (result["source_unchanged"] and not result["logic_loop_warning"] and
                        not result["generic_clock_warning"] and result["setup_violations"] == 0 and
                        result["hold_violations"] == 0 and
                        result["fmax_mhz"] is not None and result["fmax_mhz"] >= 100)
    (OUT / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: v for k, v in result.items() if k != "source_sha256"}, indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
