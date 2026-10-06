"""Shared cocotb/Icarus runner helpers for the module 2B/2C test scripts.

Keeps the "build with -g2012/-Wall, always recompile, absolute paths, explicitly
parse the results XML and fail non-zero" contract in one place so every entry
point behaves the same.  Never writes ``sim/results.xml``.
"""

from __future__ import annotations

import os
import subprocess
import xml.etree.ElementTree as ET

_TOLERATED = "constant selects in always_"


def iverilog_wall_check(sources, top, parameters, build_dir):
    """Compile with explicit -g2012/-Wall and reject every diagnostic except the
    known iverilog always_comb constant-select sensitivity note."""
    out = os.path.join(build_dir, "wallcheck.vvp")
    cmd = ["iverilog", "-g2012", "-Wall", "-o", out, "-s", top]
    for k, v in parameters.items():
        cmd.append(f"-P{top}.{k}={v}")
    cmd += [str(s) for s in sources]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"iverilog -Wall build failed:\n{proc.stderr}{proc.stdout}")
    bad = []
    for line in (proc.stderr + "\n" + proc.stdout).splitlines():
        s = line.strip()
        if not s:
            continue
        low = s.lower()
        if "warning" not in low and "sorry" not in low and "error" not in low:
            continue
        if _TOLERATED in s:
            continue
        bad.append(s)
    if bad:
        raise RuntimeError("iverilog -Wall diagnostics not tolerated:\n"
                           + "\n".join(bad))


def parse_results(xml_path):
    if not os.path.exists(xml_path):
        return None
    try:
        root = ET.parse(xml_path).getroot()
    except ET.ParseError:
        return None
    suites = [root] if root.tag == "testsuite" else root.findall("testsuite")
    cases = []
    for s in suites:
        cases.extend(s.findall("testcase"))
    failures = [c.get("name", "?") for c in cases
                if c.find("failure") is not None or c.find("error") is not None]
    return {"n": len(cases), "failures": failures}


def build_and_run(sources, top, test_module, test_dir, build_dir, parameters,
                  env, testcase=None):
    """Build (always=True), run, then require a non-empty, failure-free XML."""
    from cocotb_tools.runner import get_runner

    build_dir = os.path.abspath(os.path.expanduser(build_dir))
    os.makedirs(build_dir, exist_ok=True)
    iverilog_wall_check(sources, top, parameters, build_dir)

    runner = get_runner("icarus")
    runner.build(sources=list(sources), hdl_toplevel=top, parameters=parameters,
                 build_dir=build_dir, waves=False, build_args=["-Wall"],
                 always=True, timescale=("1ns", "1ps"))
    results_xml = os.path.join(build_dir, "results.xml")
    if os.path.exists(results_xml):
        os.remove(results_xml)
    runner.test(test_module=test_module, hdl_toplevel=top, test_dir=test_dir,
                build_dir=build_dir, parameters=parameters, extra_env=env,
                testcase=testcase, results_xml=results_xml,
                timescale=("1ns", "1ps"))
    summary = parse_results(results_xml)
    if summary is None:
        raise RuntimeError(f"missing/unparseable results XML: {results_xml}")
    if summary["n"] == 0:
        raise RuntimeError(f"no tests ran (filter={testcase!r}); XML {results_xml}")
    if summary["failures"]:
        raise RuntimeError(
            f"cocotb tests failed: {summary['failures']} (XML {results_xml})")
    return summary
