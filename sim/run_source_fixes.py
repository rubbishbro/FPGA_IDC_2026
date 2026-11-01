#!/usr/bin/env python3
"""Exercise the production recording bridge and both router tick branches.

The generated wrappers select unchanged blocks from the board/router sources,
so Icarus can test them without the unrelated vendor IP and DSP hierarchy.
No controller or tick implementation is duplicated in the fixtures.
"""
from pathlib import Path
import argparse
import json
import os
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def executable(name):
    found = os.environ.get(name.upper()) or shutil.which(name)
    if found:
        return found
    for directory in [Path.home() / "micromamba/envs/torch312/bin",
                      *sorted((Path.home() / "miniforge3/pkgs").glob("iverilog-*/bin"))]:
        if (directory / name).is_file():
            return str(directory / name)
    raise RuntimeError(f"{name} not found; set {name.upper()}")


def between(source, start, end):
    return source[source.index(start):source.index(end, source.index(start))]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, default=ROOT / "build/source_fixes")
    out = ap.parse_args().out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    board = (ROOT / "rtl/platform/tang_mega_138k_pro/instrument_system.sv").read_text()
    capture = between(board, "    logic record_snapshot_valid", "    logic event_valid")
    declarations = between(board, "    typedef enum logic [2:0] {B_IDLE", "    localparam logic [111:0] COMM_NOTE_MAP")
    bridge = between(board, "    assign cfg_ready=", "    wire [9:0] pix_x,pix_y;")
    wrapper = """`timescale 1ns/1ps
module record_bridge_probe;
    import config_pkg::*;
    parameter int CLK_HZ=1000;
    logic clk_core=0; always #5 clk_core=~clk_core;
    logic core_n=0,spatial_frame_tick=0;
    logic [1:0] quarantine=0,remote_permission=3;
    logic audio_valid=1,audio_fault=0;
    audio_config_t audio_state;
    logic cfg_valid,cfg_ready,cfg_source,cfg_done,cfg_done_ready;
    logic [15:0] cfg_seq;
    logic [7:0] cfg_cmd,cfg_result;
    logic [6:0] cfg_len;
    logic [511:0] cfg_shadow;
    logic ext_valid,ext_ready=0,ext_rsp_valid=0;
    cfg_request_t ext_request;
    cfg_response_t ext_response;
""" + capture + declarations + "\n" + bridge + "\nendmodule\n"
    (out / "record_bridge_probe.sv").write_text(wrapper)
    router = (ROOT / "rtl/router/voice_router.sv").read_text()
    ticks = between(router, "    wire smp_tick;", "    sustain_cfg_t active_play")
    (out / "sample_tick_probe.sv").write_text("""`timescale 1ns/1ps
module sample_tick_probe #(parameter bit EXTERNAL_SAMPLE_TICK=0,
    parameter int CLK_HZ=100,SR_HZ=10)(input logic clk,rst_n,sample_tick);
""" + ticks + "\nendmodule\n")
    tests = {
        "tb_record_control": ["rtl/config_pkg.sv", "rtl/drivers/common/comm_fifo.sv",
            "rtl/comm/performance_capture.sv", "rtl/drivers/analyzer/config_analyzer.sv",
            out / "record_bridge_probe.sv", "sim/unit/comm/tb_record_control.sv"],
        "tb_sample_tick_modes": [out / "sample_tick_probe.sv", "sim/unit/board/tb_sample_tick_modes.sv"],
        "tb_performance_limits": ["rtl/drivers/common/comm_fifo.sv", "rtl/comm/performance_capture.sv",
            "sim/unit/comm/tb_performance_limits.sv"],
    }
    results = []
    for name, sources in tests.items():
        image = out / f"{name}.vvp"
        compiled = subprocess.run([executable("iverilog"), "-g2012", "-Wall", "-s", name,
            "-o", str(image), *(str(ROOT / source) for source in sources)],
            capture_output=True, text=True, timeout=60)
        (out / f"{name}.compile.log").write_text(compiled.stdout + compiled.stderr)
        if compiled.returncode:
            raise RuntimeError(compiled.stdout + compiled.stderr)
        run = subprocess.run([executable("vvp"), str(image)], capture_output=True, text=True, timeout=60)
        output = run.stdout + run.stderr
        (out / f"{name}.run.log").write_text(output)
        passed = run.returncode == 0 and "PASS" in output and "FAIL" not in output
        results.append(dict(test=name, passed=passed))
        print(output.strip())
    (out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    return 0 if all(result["passed"] for result in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
