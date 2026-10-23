#!/usr/bin/env python3
"""从 B 的 72-bit core 表生成 b_theta.mem（θ = acos(-a1/(2r))，UQ2.14）。

用法：
    python python/modal_sim/gen_b_theta.py \
        --coeff rtl/rom/b_coeff.mem --out rtl/rom/b_theta.mem

core 字布局（class_format_pkg.core_t）：
    [71:46] G  Q2.24, [45:22] a2 UQ0.24, [21:0] a1 Q2.20
θ 的范围 [0, π]，16-bit UQ2.14 足够（π*2^14 = 51472）。
"""

from __future__ import annotations

import argparse
import json
import math
import os


def unpack_core(word: int) -> tuple[int, int, int]:
    g = (word >> 46) & ((1 << 26) - 1)
    if g & (1 << 25):
        g -= 1 << 26
    a2 = (word >> 22) & ((1 << 24) - 1)
    a1 = word & ((1 << 22) - 1)
    if a1 & (1 << 21):
        a1 -= 1 << 22
    return g, a1, a2


def theta_from_a1a2(a1: int, a2: int) -> float:
    """a1 Q2.20、a2 UQ0.24 -> θ (rad)。r=0 / 越界时钳位。"""
    r = math.sqrt(max(a2, 0) / float(1 << 24))
    if r <= 1e-12:
        return 0.0
    c = -(a1 / float(1 << 20)) / (2.0 * r)
    c = max(-1.0, min(1.0, c))
    return math.acos(c)


def theta_q_from_core(word: int, bits: int = 14) -> int:
    _, a1, a2 = unpack_core(word)
    th = theta_from_a1a2(a1, a2)
    q = int(round(th * (1 << bits)))
    return max(0, min((1 << 16) - 1, q))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--coeff", default="rtl/rom/b_coeff.mem")
    ap.add_argument("--out", default="rtl/rom/b_theta.mem")
    ap.add_argument("--bits", type=int, default=14)
    ap.add_argument("--manifest", default="")
    args = ap.parse_args()

    if not os.path.exists(args.coeff):
        raise SystemExit(f"missing coeff file: {args.coeff}")

    words = []
    with open(args.coeff) as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("//"):
                words.append(int(line, 16))

    out, errs = [], []
    for w in words:
        _, a1, a2 = unpack_core(w)
        th = theta_from_a1a2(a1, a2)
        q = theta_q_from_core(w, args.bits)
        out.append(q)
        errs.append(abs(q / float(1 << args.bits) - th))

    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
    with open(args.out, "w") as fh:
        for q in out:
            fh.write(f"{q:04x}\n")

    summary = {
        "coeff": args.coeff,
        "out": args.out,
        "n": len(out),
        "theta_bits": args.bits,
        "max_err_lsb": max(errs) * (1 << args.bits) if errs else 0.0,
        "max_err_rad": max(errs) if errs else 0.0,
    }
    print(json.dumps(summary, indent=2))
    if args.manifest:
        with open(args.manifest, "w") as fh:
            json.dump(summary, fh, indent=2)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
