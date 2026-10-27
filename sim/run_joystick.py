#!/usr/bin/env python3
"""Independent joystick adapter and raw ADC handoff regression."""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/joystick"


def executable(name: str) -> str:
    path = os.environ.get(name.upper()) or shutil.which(name)
    if path:
        return path
    local = Path.home() / "micromamba/envs/torch312/bin" / name
    if local.is_file():
        return str(local)
    raise RuntimeError(f"{name} not found; set {name.upper()} or add it to PATH")


def run_case(name: str, top: str, sources: list[str], parameters: dict[str, int]) -> None:
    image = OUT / f"{name}.vvp"
    command = [executable("iverilog"), "-g2012", "-Wall", "-s", top,
               *[f"-P{top}.{key}={value}" for key, value in parameters.items()],
               "-o", str(image), *[str(ROOT / source) for source in sources]]
    compile_result = subprocess.run(command, capture_output=True, text=True, timeout=60)
    (OUT / f"{name}.compile.log").write_text(compile_result.stdout + compile_result.stderr)
    if compile_result.returncode:
        raise RuntimeError(compile_result.stdout + compile_result.stderr)
    result = subprocess.run([executable("vvp"), str(image)], capture_output=True, text=True, timeout=30)
    output = result.stdout + result.stderr
    (OUT / f"{name}.log").write_text(output)
    print(output.strip())
    if result.returncode or "PASS " not in output:
        raise RuntimeError(f"{name} failed")


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    sources = ["rtl/drivers/pkg/joystick_pkg.sv", "rtl/drivers/joystick_adapter.sv",
               "sim/unit/control/tb_joystick_adapter.sv"]
    count = 0
    for cal in (0, 2, 4):
        for orientation in range(8):
            run_case(f"adapter_c{cal}_o{orientation}", "tb_joystick_adapter", sources,
                     {"CALIB_LOG2": cal, "SWAP_XY": orientation >> 2,
                      "INVERT_X": (orientation >> 1) & 1, "INVERT_Y": orientation & 1})
            count += 1
    for dummy in (0, 1):
        run_case(f"raw_dummy{dummy}", "tb_pad_joystick_raw",
                 ["rtl/drivers/pkg/clk_rst_pkg.sv", "rtl/drivers/pkg/pad_driver_pkg.sv",
                  "rtl/drivers/pkg/joystick_pkg.sv", "rtl/math/pkg/fxp_pkg.sv",
                  "rtl/math/math.sv", "rtl/drivers/pad_driver.sv",
                  "rtl/drivers/joystick_adapter.sv", "sim/unit/control/tb_pad_joystick_raw.sv"],
                 {"DUMMY_READ": dummy})
        count += 1
    print(f"PASS {count} joystick cases")


if __name__ == "__main__":
    main()
