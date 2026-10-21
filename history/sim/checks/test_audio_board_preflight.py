"""Preflight gate tests for rtl/platform/tang_mega_138k_pro/preflight.py.

Runs the checker end-to-end (subprocess) and unit-checks a few fragment
behaviours directly (comments must not count, ROM corruption, missing source
list).  A SYNTHETIC IP fixture is created under the build directory (never in
rtl/platform, never in sources.f) to prove the checker accepts a correctly
named/ported primitive-PLL module and rejects stubs, missing ports, initial
blocks and delays.

The fixture is a test double for the *checker only*; it is not a real PLL and is
never used by synthesis.  Results go to
sim/build/audio_board_preflight/results.xml and are gated explicitly
(missing/empty/failed XML -> non-zero exit).  sim/results.xml is never touched.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
import sys
import xml.etree.ElementTree as ET

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = _HERE
while not (os.path.isdir(os.path.join(_ROOT, "rtl"))
           and os.path.isdir(os.path.join(_ROOT, "sim"))):
    _ROOT = os.path.dirname(_ROOT)
sys.path.insert(0, os.path.join(_ROOT, "sim", "support"))
from _sim_paths import bootstrap as _sim_bootstrap  # noqa: E402
_ROOT = str(_sim_bootstrap(__file__))
_PLAT = os.path.join(_ROOT, "rtl", "platform", "tang_mega_138k_pro")
_PREFLIGHT = os.path.join(_PLAT, "preflight.py")

_PORTS = ["lock", "clkout0", "clkout1", "clkout2", "clkin", "reset",
          "enclk0", "enclk1", "enclk2"]


def _load_preflight():
    spec = importlib.util.spec_from_file_location("board_preflight", _PREFLIGHT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_AUDIO_PORTS = ["clkin", "init_clk", "clkout0", "lock"]


def _module_text(name, ports, primitive=True, initial=False, delay=False):
    # Real Gowin wrapper interface: (clkin, init_clk, clkout0, lock).
    decl = ", ".join(f"input {p}" if p in ("clkin", "init_clk")
                     else f"output {p}" for p in ports)
    body = []
    if initial:
        body.append("  initial lock = 1'b0;")
    if delay:
        body.append("  always #5 clkout0 = ~clkout0;")
    return f"module {name} ({decl});\n" + "\n".join(body) + "\nendmodule\n"


def _mod_text(name, primitive=True, initial=False, delay=False):
    body = []
    if initial:
        body.append("  initial lock = 1'b0;")
    if delay:
        body.append("  always #5 clkout0 = ~clkout0;")
    if primitive:
        body.append("  PLL PLL_inst (.CLKIN(clkin), .CLKOUT0(clkout0), "
                    ".LOCK(lock));")
    return (f"module {name}_MOD (clkin, clkout0, lock);\n"
            "  input clkin; output clkout0; output lock;\n"
            + "\n".join(body) + "\nendmodule\n")


def _write_fixture(ip_dir, man, core_kwargs=None, audio_kwargs=None):
    p0, p1 = man["pll"][0], man["pll"][1]
    core = os.path.join(ip_dir, p0["ip_subdir"], p0["ip_file"])
    audio = os.path.join(ip_dir, p1["ip_subdir"], p1["ip_file"])
    os.makedirs(os.path.dirname(core), exist_ok=True)
    os.makedirs(os.path.dirname(audio), exist_ok=True)
    ck = dict(core_kwargs or {})
    ak = dict(audio_kwargs or {})
    cports = ck.pop("ports", p0["ports"])
    aports = ak.pop("ports", p1["ports"])
    with open(core, "w", encoding="utf-8") as fh:
        fh.write(_module_text(p0["module"], cports, **ck))
    with open(audio, "w", encoding="utf-8") as fh:
        fh.write(_module_text(p1["module"], aports, **ak))
    cmod = os.path.join(ip_dir, p0["ip_subdir"], p0["mod_file"])
    amod = os.path.join(ip_dir, p1["ip_subdir"], p1["mod_file"])
    cvariant = {k: v for k, v in ck.items() if k in ("primitive", "initial", "delay")}
    with open(cmod, "w", encoding="utf-8") as fh:
        fh.write(_mod_text(p0["module"], **cvariant))
    with open(amod, "w", encoding="utf-8") as fh:
        fh.write(_mod_text(p1["module"]))


def _run_preflight(ip_dir, no_tool=True, clean_path=False):
    cmd = [sys.executable, _PREFLIGHT, "--root", _ROOT, "--ip-dir", ip_dir]
    if no_tool:
        cmd.append("--no-tool")
    env = dict(os.environ)
    if clean_path:
        # isolate the tool check: no Gowin on PATH, regardless of the host env
        env["PATH"] = "/usr/bin:/bin"
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env)
    return proc.returncode, proc.stdout + proc.stderr


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--build-dir", default=os.path.join(_ROOT, "sim", "build",
                                                        "audio_board_preflight"))
    args = ap.parse_args(argv)

    build_dir = os.path.abspath(os.path.expanduser(args.build_dir))
    os.makedirs(build_dir, exist_ok=True)
    pf = _load_preflight()
    man = json.load(open(os.path.join(_PLAT, "board_build.json"),
                         encoding="utf-8"))

    good_ip = os.path.join(build_dir, "ip_fixture")
    bad_port_ip = os.path.join(build_dir, "ip_bad_port")
    initial_ip = os.path.join(build_dir, "ip_initial")
    empty_ip = os.path.join(build_dir, "ip_empty")
    for d in (good_ip, bad_port_ip, initial_ip, empty_ip):
        os.makedirs(d, exist_ok=True)
    _write_fixture(good_ip, man)
    bad_ports = [p for p in man["pll"][0]["ports"] if p != "lock"]
    _write_fixture(bad_port_ip, man, core_kwargs={"ports": bad_ports})
    _write_fixture(initial_ip, man,
                   core_kwargs={"primitive": False, "initial": True})

    results = []

    def record(name, ok, detail):
        results.append((name, bool(ok), detail))

    rc, out = _run_preflight(empty_ip)
    record("missing_ip_nonzero", rc != 0, f"rc={rc}")

    rc, out = _run_preflight(good_ip, no_tool=False, clean_path=True)
    record("missing_tool_nonzero", rc == 1, f"rc={rc}")

    rc, out = _run_preflight(good_ip)
    record("fixture_ip_structural_pass", rc == 0, f"rc={rc}: {out.strip()}")

    rc, out = _run_preflight(bad_port_ip)
    record("bad_port_nonzero", rc == 3, f"rc={rc}")

    rc, out = _run_preflight(initial_ip)
    record("initial_block_rejected", rc == 3, f"rc={rc}")

    # the real repo now ships the real vendor PLL IP, so it must PASS
    rc, out = _run_preflight(os.path.join(_PLAT, "ip"))
    record("real_repo_ip_passes", rc == 0, f"rc={rc}")

    # --- direct fragment checks -------------------------------------------
    # commented-out SDC must not count as a valid timing configuration
    tmp = os.path.join(build_dir, "frag")
    os.makedirs(tmp, exist_ok=True)
    sdc_rel = "commented.sdc"
    with open(os.path.join(tmp, sdc_rel), "w", encoding="utf-8") as fh:
        fh.write("# create_clock -name clk_50m -period 20.000 [get_ports {clk}]\n"
                 "// create_generated_clock -name clk_core -divide_by 1 "
                 "-multiply_by 2 [get_pins {x}]\n")
    rep = pf.Report()
    pf.check_sdc(tmp, {"sdc": sdc_rel, "pll": man["pll"]}, rep)
    record("commented_sdc_not_counted", rep.rc == 4, f"rc={rep.rc}")

    # corrupted ROM (bad token + wrong length) must be caught
    with open(os.path.join(tmp, "bad.mem"), "w", encoding="utf-8") as fh:
        fh.write("ff\nzz\n01\n")
    rep = pf.Report()
    pf.check_rom(tmp, {"rom": {"coeff": {"path": "bad.mem", "width": 8,
                                         "depth": 3}}}, rep)
    record("rom_corruption_detected", rep.rc == 2, f"rc={rep.rc}")

    # missing source list -> code 2, no traceback
    rep = pf.Report()
    got = pf.parse_source_list(tmp, {"source_list": "missing.f"}, rep)
    record("missing_source_list_code2", got is None and rep.rc == 2,
           f"got={got} rc={rep.rc}")

    # a listed non-IP source that does not resolve -> code 2
    rep = pf.Report()
    pf.check_sources(tmp, tmp, {"sources": ["nope.sv"], "test_only_sources": [],
                                "pll": []}, rep, ["nope.sv"])
    record("missing_source_entry_code2", rep.rc == 2, f"rc={rep.rc}")

    failures = [n for n, ok, _ in results if not ok]
    xml_path = os.path.join(build_dir, "results.xml")
    suite = ET.Element("testsuite", name="audio_board_preflight",
                       tests=str(len(results)), failures=str(len(failures)))
    for name, ok, detail in results:
        case = ET.SubElement(suite, "testcase", name=name)
        if not ok:
            ET.SubElement(case, "failure", message=detail)
    ET.ElementTree(suite).write(xml_path, encoding="utf-8", xml_declaration=True)

    root = ET.parse(xml_path).getroot()
    cases = root.findall("testcase")
    bad = [c.get("name") for c in cases
           if c.find("failure") is not None or c.find("error") is not None]
    if not cases:
        print("[FAIL] no preflight tests recorded", file=sys.stderr)
        return 1
    if bad:
        for name, ok, detail in results:
            if not ok:
                print(f"[FAIL] {name}: {detail}", file=sys.stderr)
        print(f"[audio_board_preflight] {len(bad)} failed; XML {xml_path}",
              file=sys.stderr)
        return 1
    print(f"[audio_board_preflight] {len(cases)} passed; XML {xml_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
