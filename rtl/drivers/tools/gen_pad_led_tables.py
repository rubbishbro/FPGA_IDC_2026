#!/usr/bin/env python3
"""Generate the fixed-point, multiplier-free 8x8 pad LED ROMs."""
from __future__ import annotations

import argparse
import colorsys
import hashlib
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DEST = ROOT / "rtl/drivers/pad_led_tables"
FAMILIES = [(-7, 7), (22, 36), (48, 60), (106, 134),
            (172, 190), (218, 242), (266, 290)]


def quant(value: float, maximum: int) -> int:
    return max(0, min(maximum, int(value * maximum + 0.5)))


def phase_offset(x: int, y: int) -> int:
    return round(-math.hypot(x, y) / 4.2 * 65536) & 0xFFFF


def tables() -> dict[str, tuple[int, list[int]]]:
    phase = [phase_offset(x, y) for y in range(8) for x in range(8)]
    breath = [1 + quant((0.5 + 0.5 * math.cos(2 * math.pi * p / 256)) ** 1.8, 79)
              for p in range(256)]
    palette = [min(55, p * 56 // 256) for p in range(256)]
    distance = [round(math.hypot(dx + 0.5, dy + 0.5) * 256)
                for dy in range(8) for dx in range(8)]
    shape = []
    for address in range(512):
        u = (address / 64) / 0.65
        sinc = 1 if u == 0 else math.sin(math.pi * u) / (math.pi * u)
        t = max(0.0, min(1.0, (u - 6.6) / (9 - 6.6)))
        shape.append(quant(abs(sinc) * (1 - t * t * (3 - 2 * t)), 63))
    age = [quant(math.exp(-(i * 0.05) / 2.9), 63) for i in range(64)]
    radial = [quant(1 / (1 + 0.055 * i / 4), 63) for i in range(64)]
    combine = [round(a * b / 63) for a in range(64) for b in range(64)]
    colour = []
    for low, high in FAMILIES:
        for shade in range(8):
            t = shade / 7
            t = t * t * (3 - 2 * t)
            rgb = colorsys.hsv_to_rgb(((low + (high - low) * t) % 360) / 360, 0.96, 1)
            for level in range(64):
                r, g, b = [quant(channel * level / 63, 160) for channel in rgb]
                colour.append((g << 16) | (r << 8) | b)  # pixel_t is GRB
    return {
        "phase": (16, phase), "breath": (8, breath), "palette": (6, palette),
        "distance": (12, distance), "shape": (6, shape), "age": (6, age),
        "radial": (6, radial), "combine": (6, combine), "colour": (24, colour),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="check generated files without writing")
    args = parser.parse_args()
    output: dict[str, str] = {}
    summary = {}
    for name, (width, values) in tables().items():
        assert all(0 <= value < (1 << width) for value in values)
        content = "".join(f"{value:0{(width + 3) // 4}x}\n" for value in values)
        output[name + ".mem"] = content
        summary[name] = dict(entries=len(values), width=width, bits=len(values) * width,
                             sha256=hashlib.sha256(content.encode()).hexdigest())
    summary["total_bits"] = sum(item["bits"] for item in summary.values())
    summary["parameters"] = dict(frame_hz=200, speed_cells_s=6, width_cells=0.65,
                                  background_period_s=5.2, background_wavelength_cells=4.2,
                                  background_peak=80, wave_peak=160, age_bin_ms=50,
                                  radius_step_q16=round(6 / 200 * 65536),
                                  phase_step_q32=round(2**32 / (5.2 * 200)))
    output["manifest.json"] = json.dumps(summary, indent=2) + "\n"
    if args.check:
        for name, content in output.items():
            if not (DEST / name).is_file() or (DEST / name).read_text() != content:
                raise SystemExit(f"stale LED table: {DEST / name}")
        print(f"PASS LED ROMs: {summary['total_bits']} bits, reproducible")
    else:
        DEST.mkdir(parents=True, exist_ok=True)
        for name, content in output.items():
            (DEST / name).write_text(content)
        print(f"Generated LED ROMs: {summary['total_bits']} bits")


if __name__ == "__main__":
    main()
