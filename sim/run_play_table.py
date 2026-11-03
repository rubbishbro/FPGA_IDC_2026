#!/usr/bin/env python3
"""Compare single-table storage to the historical two-table publication block.

Both sides use the current router interface/controller and real QSPI consumers.
Only the reference's storage declaration/publication block comes from BASELINE;
this isolates the table optimization from unrelated modulation/reset revisions.
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


def reference_source(current, historical):
    """Keep the historical table algorithm exact, with current surrounding RTL."""
    declaration = "sustain_cfg_t active_play[0:SLOTS-1];"
    legacy_declaration = "sustain_cfg_t pending_play[0:SLOTS-1],active_play[0:SLOTS-1];"
    if current.count(declaration) != 1 or historical.count(legacy_declaration) != 1:
        raise RuntimeError("parameter-table declaration changed; review the reference adapter")
    def block(source, key):
        location = source.index(key)
        start = source.rfind("    always_ff @(posedge clk) begin", 0, location)
        end = source.index("\n    end", location) + len("\n    end")
        if start < 0:
            raise RuntimeError("parameter-table block not found")
        return source[start:end]
    old_block = block(historical, "pending_play[p] <= '0;")
    new_block = block(current, "active_play[p] <= '0;")
    if historical.count(old_block) != 1 or current.count(new_block) != 1:
        raise RuntimeError("ambiguous parameter-table block")
    reference = current.replace(declaration, legacy_declaration, 1).replace(new_block, old_block, 1)
    # Assert the adapter did not alter the controller, interfaces or consumers.
    restored = reference.replace(legacy_declaration, declaration, 1).replace(old_block, new_block, 1)
    if restored != current:
        raise RuntimeError("reference adapter changed unrelated logic")
    reference = re.sub(r"\bmodule voice_router\b", "module voice_router_reference", reference, count=1)
    return reference, hashlib.sha256((legacy_declaration + "\n" + old_block).encode()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, default=ROOT / "build/single_play_table/tests")
    ap.add_argument("--baseline-ref", default=BASELINE)
    ap.add_argument("--modes", type=int, choices=[3, 4, 64], default=64)
    ap.add_argument("--simulator", choices=["auto", "questa", "verilator"], default="auto")
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
    current = (ROOT / "rtl/router/voice_router.sv").read_text()
    reference = out / "voice_router_reference.sv"
    adapted, storage_hash = reference_source(current, original)
    reference.write_text(adapted)
    sources = re.findall(r"'((?:rtl|tb)/[^']+\.sv)'",
                         (ROOT / "sim/router_sources.list").read_text())
    sources = [ROOT / s for s in sources if not s.startswith("rtl/tb/")]
    sources += [reference, ROOT / "sim/unit/midi/w25q64_read_model.sv",
                ROOT / "sim/unit/midi/tb_router_play_table.sv"]
    def executable(name):
        return shutil.which(name) or (str(Path.home()/".local/bin"/name)
                                       if (Path.home()/".local/bin"/name).is_file() else None)
    questa = {name: executable(name) for name in ("vlib", "vlog", "vsim")}
    simulator = args.simulator
    if simulator == "auto":
        simulator = "verilator" if os.environ.get("VERILATOR") else ("questa" if all(questa.values()) else "verilator")
    if simulator == "questa":
        if not all(questa.values()):
            raise RuntimeError("Questa vlib/vlog/vsim not found")
        ini = Path(os.environ.get("QSIM_INI", str(Path.home()/"gowin/simlib_questa/modelsim.ini")))
        work = out / "work"
        (out/"modelsim.ini").write_text(re.sub(r"^work\s*=.*$", "work = "+str(work), ini.read_text(), flags=re.M))
        env = dict(os.environ, QSIM_INI=str(out/"modelsim.ini"), MODELSIM=str(out/"modelsim.ini"))
        commands = [[questa["vlib"], str(work)],
                    [questa["vlog"], "-sv", "-work", str(work), *map(str,sources)],
                    [questa["vsim"], "-c", "-lib", str(work), "tb_router_play_table",
                     f"-gMODES={args.modes}", "-do", "run -all; quit -f"]]
    else:
        verilator = os.environ.get("VERILATOR") or shutil.which("verilator")
        if not verilator:
            raise RuntimeError("Verilator not found; use --simulator questa or set VERILATOR")
        obj = out / "obj"
        commands = [[verilator, "--binary", "--timing", "--assert", "-Wno-fatal",
                     "--top-module", "tb_router_play_table", f"-GMODES={args.modes}",
                     "-j", "4", "--Mdir", str(obj), "-MAKEFLAGS",
                     "CFG_CXXFLAGS_PCH_I=-include", *map(str,sources)],
                    [str(obj/"Vtb_router_play_table")]]
        env = os.environ.copy()
    (out/"commands.json").write_text(json.dumps(commands,indent=2)+"\n")
    for index, command in enumerate(commands):
        run = subprocess.run(command, cwd=out, env=env, capture_output=True, text=True, timeout=600)
        output = run.stdout + run.stderr
        name = "run" if index==len(commands)-1 else f"compile_{index}"
        (out/(name+".log")).write_text(output)
        if run.returncode or re.search(r"\*\* (?:Error|Fatal)|Trouble making server|%Error", output):
            print(output[-6000:])
            return 1
    passed = (run.returncode == 0 and "PASS tb_router_play_table" in output
              and re.search(r"\b(?:FAIL|FATAL)\b", output) is None)
    result_file.write_text(json.dumps(dict(
        passed=passed, modes=args.modes, simulator=simulator, baseline_ref=args.baseline_ref,
        reference_scope="current router shell + exact historical two-table declaration/publication block",
        historical_storage_sha256=storage_hash,
        adapted_reference_sha256=hashlib.sha256(adapted.encode()).hexdigest(),
        baseline_sha256=hashlib.sha256(original.encode()).hexdigest(),
        current_sha256=hashlib.sha256((ROOT / "rtl/router/voice_router.sv").read_bytes()).hexdigest(),
        commands=commands, output=output), indent=2) + "\n")
    print("\n".join(line.lstrip("# ") for line in output.splitlines() if "PASS tb_router_play_table" in line))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
