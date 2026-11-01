#!/usr/bin/env python3
"""Questa: real MIDI state -> router mux -> excitation/envelope -> unmodified engines.

Uses a private library/ini. No declaration-only RTL copies or warning suppression.
Requires a configured full Questa modelsim.ini (QSIM_INI or --ini).
"""
from pathlib import Path
import argparse
import json
import os
import re
import shutil
import subprocess
from run_comm import ROOT


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, default=ROOT / "build/router_midi")
    ap.add_argument("--ini", type=Path)
    ap.add_argument("--test", action="append", help="run only the named test(s)")
    args = ap.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    for name in ["sidebar_font.mem","sidebar_labels.mem"]:
        shutil.copyfile(ROOT / "FFT_spectrumshow/board" / name, out / name)
    for memory in (ROOT / "FFT_spectrumshow/board").glob("*.mem"):
        shutil.copyfile(memory, out / memory.name)
    (out / "results.json").unlink(missing_ok=True)
    ini = args.ini or Path(os.environ.get("QSIM_INI") or os.environ.get("MODELSIM") or
                           str(Path.home() / "gowin/simlib_questa/modelsim.ini"))
    text = ini.read_text()
    work = str(out / "work")
    if re.search(r"^work\s*=", text, re.M):
        text = re.sub(r"^work\s*=.*$", "work = " + work, text, flags=re.M)
    else:
        text = text.replace("[Library]", "[Library]\nwork = " + work, 1)
    local_ini = out / "modelsim.ini"
    local_ini.write_text(text)
    env = os.environ.copy()
    env["QSIM_INI"] = str(local_ini)
    env["MODELSIM"] = str(local_ini)

    def run(name, tool, options):
        exe = shutil.which(tool) or str(Path.home() / ".local/bin" / tool)
        command = [exe, *options]
        try:
            proc = subprocess.run(command, cwd=out, env=env, capture_output=True,
                                  text=True, timeout=600)
            output = proc.stdout + proc.stderr
            passed = (proc.returncode == 0 and
                      re.search(r"\*\* (?:Error|Fatal)|\b(?:FAIL|FATAL)\b", output) is None)
        except subprocess.TimeoutExpired:
            output, passed = "FAIL timeout\n", False
        (out / (name + ".log")).write_text(output)
        if not passed:
            print(output[-6000:])
            raise RuntimeError(name + " failed")
        return output, command

    run("vlib", "vlib", [work])
    # Same production DSP files/order as the existing music build.
    sources = re.findall(r"'((?:rtl|tb)/[^']+\.sv)'", (ROOT / "sim/router_sources.list").read_text())
    sources = [s for s in sources if s != "rtl/tb/router/tb_music.sv"]
    sources += ["rtl/midi/midi_note_state.sv", "rtl/midi/midi_guide_state.sv", "rtl/midi/midi_instrument_map.sv",
                "rtl/router/midi_voice_top.sv", "rtl/router/pad_voice_top.sv"]
    sources += [s for s in (ROOT / "sim/ui_sources.f").read_text().splitlines() if s not in sources]
    tests = ["tb_midi_guide_state", "tb_midi_guide", "tb_midi_instrument_map", "tb_performance_input_mux", "tb_router_midi",
             "tb_router_midi_eng1", "tb_router_pending_config", "tb_loader_offsets", "tb_loader_timeout", "tb_loader_relocated", "tb_loader_flash_bounds", "tb_midi_safety", "tb_joint_config", "tb_config_joint_result", "tb_pad_load_failure", "tb_pad_load_relocated"]
    sources += ["sim/unit/midi/w25q64_read_model.sv"]
    sources += ["sim/unit/midi/" + t + ".sv" for t in tests if t not in ("tb_loader_timeout", "tb_pad_load_failure")]
    _, compile_command = run("compile", "vlog", ["-sv", "-work", work, *(str(ROOT / s) for s in sources)])
    results = []
    if args.test:
        if any(t not in tests for t in args.test):
            ap.error("unknown test")
        tests = args.test
    for test in tests:
        output, command = run(test, "vsim", ["-c", "-lib", work, test,
                              "-wlf", str(out / (test + ".wlf")),
                              "-do", "run -all; quit -f"])
        passed = "PASS " + test in output
        print(("PASS " if passed else "FAIL ") + test)
        results.append(dict(test=test, passed=passed, command=command))
    (out / "results.json").write_text(json.dumps(dict(compile_command=compile_command, tests=results), indent=2) + "\n")
    return 0 if all(r["passed"] for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
