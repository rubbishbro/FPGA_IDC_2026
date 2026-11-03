#!/usr/bin/env python3
"""Analyze raw Q24 instrument renders and derive RMS-based per-instrument trims.

Inputs are the production raw arrays under
build/performance_gain_calibration/*_raw_q24.npy: (samples, notes), Q24.
The script reports peak, overall RMS, max 20 ms RMS, and a Q4.12 gain that
maps the selected RMS metric to a common target. It also reports the maximum
target RMS that keeps the measured peak inside the chosen full-scale limit.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
Q24 = 1 << 24
INSTRUMENTS = {
    "piano": 0,
    "guitar": 1,
    "trumpet": 3,
    "violin": 5,
    "piano_abc": 10,
    "guitar_abc": 11,
}


def dbfs(value: float, ref: float = Q24) -> float:
    return 20.0 * math.log10(max(abs(value), 1e-30) / ref)


def db_ratio(value: float) -> float:
    return 20.0 * math.log10(max(value, 1e-30))


def analyze_array(a: np.ndarray, fs: int, window_ms: float) -> dict:
    a = np.asarray(a, dtype=np.float64)
    if a.ndim == 1:
        a = a[:, None]
    peak = float(np.max(np.abs(a)))
    rms = float(np.sqrt(np.mean(a * a)))
    win = max(1, int(round(fs * window_ms / 1000.0)))
    max_win = 0.0
    per_note = []
    for col in range(a.shape[1]):
        x = a[:, col]
        n = (len(x) // win) * win
        if n:
            blocks = x[:n].reshape(-1, win)
            note_max = float(np.sqrt(np.mean(blocks * blocks, axis=1)).max())
        else:
            note_max = float(np.sqrt(np.mean(x * x)))
        per_note.append(note_max)
        max_win = max(max_win, note_max)
    return dict(
        samples=int(a.shape[0]),
        notes=int(a.shape[1]),
        peak_q24=peak,
        rms_q24=rms,
        max20ms_rms_q24=max_win,
        peak_dbfs=dbfs(peak),
        rms_dbfs=dbfs(rms),
        max20ms_rms_dbfs=dbfs(max_win),
        note_max20ms_dbfs=[dbfs(v) for v in per_note],
    )


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--dir", type=Path,
                   default=ROOT / "build/performance_gain_calibration")
    p.add_argument("--out", type=Path,
                   default=ROOT / "build/instrument_loudness_analysis.json")
    p.add_argument("--fs", type=int, default=48000)
    p.add_argument("--window-ms", type=float, default=20.0)
    p.add_argument("--target-dbfs", type=float, default=-14.0,
                   help="target max-20ms RMS in dBFS (Q24 reference)")
    p.add_argument("--fs-q24", type=float, default=1.0,
                   help="full-scale Q24 per channel (h=0 -> 1.0; h=3 -> 8.0)")
    args = p.parse_args()

    rows = {}
    for name in INSTRUMENTS:
        path = args.dir / f"{name}_raw_q24.npy"
        if not path.is_file():
            raise SystemExit(f"missing {path}")
        rows[name] = analyze_array(np.load(path), args.fs, args.window_ms)

    target_q24 = Q24 * 10.0 ** (args.target_dbfs / 20.0)
    full_q24 = Q24 * args.fs_q24

    print(f"target max20ms RMS = {args.target_dbfs:+.2f} dBFS "
          f"({target_q24:.0f} Q24); full scale = {args.fs_q24:.3f} Q24")
    print(f"{'instrument':12s} {'peak':>8s} {'rms':>8s} {'max20ms':>8s} "
          f"{'gain_q12':>8s} {'gain_dB':>8s} {'pred_peak':>10s} {'margin':>8s}")
    for name, r in rows.items():
        gain = target_q24 / r["max20ms_rms_q24"]
        q12 = int(round(4096.0 * gain))
        pred_peak = r["peak_q24"] * gain
        margin_db = db_ratio(full_q24 / max(pred_peak, 1e-30))
        r.update(
            target_dbfs=args.target_dbfs,
            gain_linear=gain,
            gain_q12=q12,
            gain_db=db_ratio(gain),
            predicted_peak_q24=pred_peak,
            predicted_peak_dbfs=dbfs(pred_peak),
            peak_margin_db=margin_db,
            clipped=pred_peak > full_q24,
            max_safe_target_dbfs=dbfs(
                r["max20ms_rms_q24"] * full_q24 / max(r["peak_q24"], 1e-30)),
        )
        print(f"{name:12s} {r['peak_dbfs']:+8.2f} {r['rms_dbfs']:+8.2f} "
              f"{r['max20ms_rms_dbfs']:+8.2f} {q12:8d} {r['gain_db']:+8.2f} "
              f"{r['predicted_peak_dbfs']:+10.2f} {margin_db:+8.2f}"
              + (" CLIP" if r["clipped"] else ""))

    worst = min(rows.values(), key=lambda r: r["max_safe_target_dbfs"])
    print("\nmaximum target that keeps every measured peak inside full scale: "
          f"{worst['max_safe_target_dbfs']:+.2f} dBFS "
          f"({worst['max20ms_rms_dbfs']:+.2f} dBFS raw)")
    print("note: this is a peak-safe target; RMS loudness may prefer a "
          "different point, but positive gains then clip.")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(dict(
        source_dir=str(args.dir.relative_to(ROOT)),
        fs=args.fs, window_ms=args.window_ms,
        target_dbfs=args.target_dbfs, full_scale_q24=args.fs_q24,
        instruments=rows,
    ), indent=2) + "\n")
    print("wrote", args.out)


if __name__ == "__main__":
    main()
