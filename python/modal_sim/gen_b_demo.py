#!/usr/bin/env python3
"""生成一个真实 B timbre/note 的 demo core + θ 表（flute MIDI 69，48 modes）。

只用于验证 theta 生成链；真正的 B 表生成器应复用同样的 theta 规则。
输出：rtl/rom/demo/b_coeff_flute69.mem、b_theta_flute69.mem
"""

from __future__ import annotations

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sustain_engine import SR, SustainPatch  # noqa: E402
from gen_b_theta import theta_q_from_core  # noqa: E402

N_MODES = 48
MIDI = 69
INST = "flute"


def pack_core(g: int, a1: int, a2: int) -> int:
    return ((g & ((1 << 26) - 1)) << 46) | ((a2 & ((1 << 24) - 1)) << 22) | (a1 & ((1 << 22) - 1))


def main() -> int:
    p = SustainPatch(INST)
    kk, g, w, atk, rel, ndb, nwin = p.modes(MIDI)
    f0 = 440.0 * 2.0 ** ((MIDI - 69) / 12.0)
    period = max(2, int(round(SR / f0)))
    f = kk * (SR / period)
    theta = 2.0 * math.pi * f / SR

    coeff, thetas = [], []
    for k in range(N_MODES):
        if k < len(kk):
            rk = math.exp(-float(g[k]) / SR)
            a1k = -2.0 * rk * math.cos(float(theta[k]))
            gq = int(round(w[k] * (1 << 24)))
            a1q = int(round(a1k * (1 << 20)))
            a2q = int(round(rk * rk * (1 << 24)))
        else:
            gq = a1q = a2q = 0
        gq = max(-(1 << 25), min((1 << 25) - 1, gq))
        a1q = max(-(1 << 21), min((1 << 21) - 1, a1q))
        a2q = max(0, min((1 << 24) - 1, a2q))
        word = pack_core(gq, a1q, a2q)
        coeff.append(word)
        thetas.append(theta_q_from_core(word))

    out = os.path.join(os.path.dirname(__file__), "..", "..", "rtl", "rom", "demo")
    out = os.path.abspath(out)
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "b_coeff_flute69.mem"), "w") as fh:
        for wd in coeff:
            fh.write(f"{wd:018x}\n")
    with open(os.path.join(out, "b_theta_flute69.mem"), "w") as fh:
        for q in thetas:
            fh.write(f"{q:04x}\n")
    print(f"wrote {out}/b_coeff_flute69.mem ({len(coeff)} words)")
    print(f"wrote {out}/b_theta_flute69.mem ({len(thetas)} words)")
    print(f"modes={len(kk)} f0={f0:.2f}Hz period={period} theta[0..2]="
          f"{[round(thetas[i]/16384, 5) for i in range(3)]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
