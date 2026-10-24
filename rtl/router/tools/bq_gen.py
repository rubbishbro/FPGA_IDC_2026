#!/usr/bin/env python
"""bq_gen.py -- body_biquad (Q4.27, 5 sections) golden vectors + coefficient check.

Three jobs, all from one source of truth:

1. Re-quantise the guitar body cascade (``sythsound/sim_guitar.py`` ->
   ``BODY_BIQUADS``) to signed **Q4.27**, and verify the literals hard-coded in
   ``rtl/router/routers/body_router.sv`` (``INST_GUITAR``) are exactly those
   numbers.  A mismatch is a hard error: the RTL LUT and this model must never
   drift apart.

2. Build the stimulus and the expected RTL output using the independent integer
   model ``python/modal_sim/body_fixed_point.py`` (same format as the RTL:
   Q4.27 coefficients, ``(acc + 2**26) >> 27`` per section, per-section
   saturation to signed(64+G), final ``(y + 2**(G-1)) >> G`` fold).  The
   testbench ``rtl/router/tb_body_biquad.sv`` must match these vectors
   bit-for-bit.

3. Write the vectors the testbench $readmemh's, for three cases:

       passthru  5 passthrough sections      -> output must equal input exactly
       single    section 0 = guitar row 0, sections 1..4 passthrough
       five      all five guitar rows (what ``body_router`` emits, through the
                 real body_router + its embedded body_biquad)

   Files (in this directory):

       bq_stim.mem          512 samples     16 hex digits (signed 64)
       bq_coef_single.mem   25 coefficients  8 hex digits (signed Q4.27)
       bq_exp_<case>.mem    512 samples     16 hex digits (signed 64)

Usage::

    python rtl/router/tools/bq_gen.py            # write vectors, verify LUT
    python rtl/router/tools/bq_gen.py --check    # verify only, no writes
"""

from __future__ import annotations

import argparse
import ast
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

sys.path.insert(0, os.path.join(ROOT, "python", "modal_sim"))

from body_fixed_point import (  # noqa: E402
    COEFF_FRAC, TAPS, BodyFixedPoint, quant_coeff,
)

sythsound_guitar = os.path.join(ROOT, "sythsound", "sim_guitar.py")
body_router_sv = os.path.join(ROOT, "rtl", "router", "routers", "body_router.sv")
body_biquad_sv = os.path.join(ROOT, "rtl", "router", "parts", "body_biquad.sv")

MEM_DIR = HERE
STIM_MEM = "bq_stim.mem"
COEF_SINGLE_MEM = "bq_coef_single.mem"
CASES = (
    # (name, coefficient-set key, expected .mem)
    ("passthru", "pass", "bq_exp_passthru.mem"),
    ("single", "single", "bq_exp_single.mem"),
    ("five", "five", "bq_exp_five.mem"),
)

NSEC = 5
NTAP = len(TAPS)
NSAMP = 512
FS = 48_000
GUARD_BITS = 4
COEFF_BITS = 32
QSCALE = 1 << COEFF_FRAC
ONE = QSCALE                                   # 1.0 in Q4.27
QMIN, QMAX = -(1 << (COEFF_BITS - 1)), (1 << (COEFF_BITS - 1)) - 1


class BqGenError(Exception):
    pass


# ---------------------------------------------------------------------------
# 1. coefficients
# ---------------------------------------------------------------------------
def read_body_biquads(path: str = sythsound_guitar):
    """Parse ``BODY_BIQUADS`` out of sim_guitar.py without importing it."""
    with open(path, "r", encoding="utf-8") as fh:
        tree = ast.parse(fh.read(), filename=path)
    for node in tree.body:
        if isinstance(node, ast.Assign):
            for tgt in node.targets:
                if isinstance(tgt, ast.Name) and tgt.id == "BODY_BIQUADS":
                    rows = ast.literal_eval(node.value)
                    return [[float(v) for v in row] for row in rows]
    raise BqGenError(f"BODY_BIQUADS not found in {path}")


def quantise_guitar():
    """Rows of 5 Q4.27 ints, plus the float rows they came from."""
    sos = read_body_biquads()
    if len(sos) != NSEC:
        raise BqGenError(f"guitar cascade has {len(sos)} sections, RTL has {NSEC}")
    rows = []
    for s, row in enumerate(sos):
        if len(row) != NTAP:
            raise BqGenError(f"section {s} has {len(row)} taps, expected {NTAP}")
        q = [quant_coeff(v) for v in row]
        for v, qv in zip(row, q):
            if not QMIN <= qv <= QMAX:
                raise BqGenError(f"section {s}: {v!r} -> {qv} outside int32")
        rows.append(q)
    return rows, sos


def read_body_router_literals(path: str = body_router_sv):
    """``{index: int}`` for every ``coef_q[N] = [- ]32'sd<k>;`` in the file."""
    pat = re.compile(r"coef_q\[\s*(\d+)\s*\]\s*=\s*(-?)\s*32'sd\s*(\d+)\s*;")
    out = {}
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            m = pat.search(line)
            if m:
                idx, sign, val = int(m.group(1)), m.group(2), int(m.group(3))
                if idx in out:
                    raise BqGenError(f"coef_q[{idx}] assigned twice in {path}")
                out[idx] = -val if sign == "-" else val
    return out


def check_rtl_literals(rows):
    """The RTL LUT must be exactly the Q4.27 quantisation of BODY_BIQUADS."""
    flat = [v for row in rows for v in row]
    lits = read_body_router_literals()
    if sorted(lits) != list(range(NSEC * NTAP)):
        missing = [i for i in range(NSEC * NTAP) if i not in lits]
        raise BqGenError(f"body_router INST_GUITAR: missing/extra coef_q "
                         f"indices (missing {missing})")
    bad = [(i, lits[i], flat[i]) for i in range(NSEC * NTAP) if lits[i] != flat[i]]
    if bad:
        detail = "\n".join(f"  coef_q[{i:2d}] = {got:12d}   expected {exp:12d}"
                           for i, got, exp in bad)
        raise BqGenError("body_router INST_GUITAR literals are stale:\n" + detail)
    return flat


def check_rtl_format():
    """COEFF_FRAC = 27 on both sides (the model constant is imported, not typed)."""
    if COEFF_FRAC != 27:
        raise BqGenError(f"model COEFF_FRAC = {COEFF_FRAC}, expected 27")
    for path in (body_router_sv, body_biquad_sv):
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
        m = re.search(r"parameter\s+int\s+COEFF_FRAC\s*=\s*(\d+)", text)
        if not m:
            raise BqGenError(f"{os.path.basename(path)}: no COEFF_FRAC default")
        if int(m.group(1)) != COEFF_FRAC:
            raise BqGenError(f"{os.path.basename(path)}: COEFF_FRAC = {m.group(1)}, "
                             f"model says {COEFF_FRAC}")
        for magic in ("2**29", "536870912", ">>> 30", "COEFF_FRAC-1 == 30"):
            if magic in text:
                raise BqGenError(f"{os.path.basename(path)}: leftover magic {magic!r}")


# ---------------------------------------------------------------------------
# 2. stimulus + integer model
# ---------------------------------------------------------------------------
def make_stimulus(n=NSAMP):
    """Impulse at n=0, then three tones + a little broadband noise (deterministic)."""
    import numpy as np

    rng = np.random.default_rng(20261023)      # fixed seed: reproducible vectors
    out = []
    for i in range(n):
        if i == 0:
            v = float(1 << 30)                 # impulse, pi rad/sample-ish broadband
        else:
            t = i / FS
            v = (0.50 * math.sin(2 * math.pi * 110.0 * t)
                 + 0.30 * math.sin(2 * math.pi * 700.0 * t)
                 + 0.15 * math.sin(2 * math.pi * 2900.0 * t)
                 + 0.01 * float(rng.standard_normal()))
            v *= float(1 << 29)
        q = int(math.floor(v + 0.5))
        if not -(1 << 63) <= q < (1 << 63):
            raise BqGenError(f"stimulus sample {i} does not fit signed 64")
        out.append(q)
    return out


def run_model(rows, stim):
    """Bit-exact integer reference (same rules as rtl/router/parts/body_biquad.sv)."""
    model = BodyFixedPoint(coeffs=rows, guard_bits=GUARD_BITS)
    ys, masks = model.process(stim)
    return ys, masks, model


def float_cascade(rows_float, xs):
    """Float64 DFI cascade -- the 'ideal' the fixed-point is compared against."""
    x = [float(v) for v in xs]
    for b0, b1, b2, a1, a2 in rows_float:
        x1 = x2 = y1 = y2 = 0.0
        out = []
        for xin in x:
            y = b0 * xin + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2, x1 = x1, xin
            y2, y1 = y1, y
            out.append(y)
        x = out
    return x


def coeff_sets(guitar_rows):
    passthru = [[ONE, 0, 0, 0, 0] for _ in range(NSEC)]
    single = [list(guitar_rows[0])] + [[ONE, 0, 0, 0, 0] for _ in range(NSEC - 1)]
    five = [list(row) for row in guitar_rows]
    return {"pass": passthru, "single": single, "five": five}


# ---------------------------------------------------------------------------
# 频响 / 内部电平体检（Q4.27 量化到底伤了多少）
# ---------------------------------------------------------------------------
REPORT_FREQS = (50, 100, 200, 400, 700, 1000, 1500, 2500, 4000, 8000, 12000, 16000)


def h_at(rows_float, f, fs=FS):
    """H(e^jw) of a cascade of DFI sections, coefficients already scaled."""
    w = -2.0 * math.pi * f / fs
    z = complex(math.cos(w), math.sin(w))          # z^-1
    h = 1.0 + 0.0j
    for b0, b1, b2, a1, a2 in rows_float:
        h *= (b0 + b1 * z + b2 * z * z) / (1.0 + a1 * z + a2 * z * z)
    return h


def pole_report(rows):
    """Quantised pole radius/frequency per section (stability + tuning)."""
    out = []
    for b0, b1, b2, a1, a2 in rows:
        a1f, a2f = a1 / QSCALE, a2 / QSCALE
        disc = a1f * a1f - 4.0 * a2f
        if disc < 0.0:
            r = math.sqrt(a2f)
            th = math.acos(max(-1.0, min(1.0, -a1f / (2.0 * r))))
            f = th * FS / (2.0 * math.pi)
        else:
            r1, r2 = (-a1f + math.sqrt(disc)) / 2.0, (-a1f - math.sqrt(disc)) / 2.0
            r, f = max(abs(r1), abs(r2)), 0.0
        out.append((r, f))
    return out


def peak_state(rows, xs):
    """Largest internal |state| (Q(G) lattice) the cascade ever reaches."""
    model = BodyFixedPoint(coeffs=rows, guard_bits=GUARD_BITS)
    peak = 0
    for v in xs:
        model.process_sample(v)
        for st in model.state:
            for q in st:
                peak = max(peak, abs(q))
    return peak


def print_response(guitar_rows, guitar_float):
    fixed_float = [[v / QSCALE for v in row] for row in guitar_rows]
    print("[bq_gen] 5 段腔体频响：float 设计 vs Q4.27 定点系数")
    print("[bq_gen]   freq[Hz]   float[dB]   Q4.27[dB]      diff[dB]")
    worst = 0.0
    for f in REPORT_FREQS:
        hf = abs(h_at(guitar_float, f))
        hq = abs(h_at(fixed_float, f))
        df = 20.0 * math.log10(max(hq, 1e-30) / max(hf, 1e-30))
        worst = max(worst, abs(df))
        print(f"[bq_gen]   {f:8d}   {20*math.log10(max(hf,1e-30)):9.3f}   "
              f"{20*math.log10(max(hq,1e-30)):9.3f}   {df:+9.4f}")
    print(f"[bq_gen]   最大偏差 {worst:.4f} dB")
    print("[bq_gen] 量化后的极点（半径 / 频率）：")
    for s, (r, f) in enumerate(pole_report(guitar_rows)):
        print(f"[bq_gen]   sec{s}: r = {r:.6f}   f = {f:8.1f} Hz"
              + ("   <-- 不稳定!" if r >= 1.0 else ""))


# ---------------------------------------------------------------------------
# 3. output
# ---------------------------------------------------------------------------
def write_mem(path, values):
    """64-bit signed samples, 16 hex digits (stimulus / expected output)."""
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        for v in values:
            fh.write(f"{v & 0xFFFFFFFFFFFFFFFF:016X}\n")


def write_mem32(path, values):
    """32-bit signed coefficients, 8 hex digits (Q4.27 table for the tb)."""
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        for v in values:
            fh.write(f"{v & 0xFFFFFFFF:08X}\n")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true",
                    help="verify the RTL literals/format only, write nothing")
    args = ap.parse_args(argv)

    try:
        guitar_rows, guitar_float = quantise_guitar()
        flat = check_rtl_literals(guitar_rows)
        check_rtl_format()
    except Exception as exc:                          # noqa: BLE001 - report all
        print(f"[bq_gen] FAIL: {exc}", file=sys.stderr)
        return 1

    print(f"[bq_gen] format Q4.{COEFF_FRAC} (1.0 = {ONE}), {NSEC} sections x {NTAP} taps")
    print(f"[bq_gen] body_router INST_GUITAR == Q4.{COEFF_FRAC} of BODY_BIQUADS "
          f"({len(flat)} literals OK)")
    head = max(abs(v) for v in flat)
    print(f"[bq_gen] max |coef_q| = {head} ({head / ONE:.4f}), int32 headroom "
          f"{QMAX / head:.2f}x")
    for s, row in enumerate(guitar_rows):
        print(f"[bq_gen]   sec{s}: " + ", ".join(f"{v:12d}" for v in row))

    print_response(guitar_rows, guitar_float)

    stim = make_stimulus()
    sets = coeff_sets(guitar_rows)
    peak_in = max(abs(v) for v in stim)
    print(f"[bq_gen] stimulus: {NSAMP} samples, fs={FS}, peak |x| = {peak_in} "
          f"({peak_in / ONE:.3f} x 2**27)")

    results = {}
    for name, key, mem in CASES:
        rows = sets[key]
        ys, masks, _model = run_model(rows, stim)
        ideal = float_cascade([[v / QSCALE for v in r] for r in rows], stim)
        err = [abs(a - b) for a, b in zip(ys, ideal)]
        peak_out = max(abs(v) for v in ys)
        n_sat = sum(1 for m in masks if m)
        pk_st = peak_state(rows, stim)
        results[name] = (rows, ys, masks)
        print(f"[bq_gen] case '{name}': peak |y| = {peak_out} "
              f"({peak_out / peak_in:8.3f}x in), sat_samples = {n_sat}, "
              f"max |y - float| = {max(err):.1f} LSB "
              f"({max(err) / max(peak_out, 1):.2e} rel)")
        print(f"[bq_gen]    peak |state| = {pk_st} "
              f"({math.log2((1 << 67) / pk_st):.1f} bits below the 68-bit clamp, "
              f"= {pk_st / (1 << GUARD_BITS):.3e} input LSB)")
        if not args.check:
            write_mem(os.path.join(MEM_DIR, mem), ys)

    # passthru 是硬约束：模型输出必须和输入逐位相同（RTL 也据此检查）
    ys_pass = results["passthru"][1]
    if list(ys_pass) != list(stim):
        bad = next(i for i, (a, b) in enumerate(zip(ys_pass, stim)) if a != b)
        raise SystemExit(f"[bq_gen] FAIL: passthru model != input at n={bad}")

    if not args.check:
        write_mem(os.path.join(MEM_DIR, STIM_MEM), stim)
        # 单段用例的系数表（吉他第 0 段 + 4 行直通）：tb 直接 $readmemh 进 coef_q，
        # 这样"单段"用的就是真系数，又不用在 tb 里再抄一遍字面量
        write_mem32(os.path.join(MEM_DIR, COEF_SINGLE_MEM),
                    [v for row in sets["single"] for v in row])
        print(f"[bq_gen] wrote {STIM_MEM}, {COEF_SINGLE_MEM}, "
              + ", ".join(c[2] for c in CASES) + f" into {MEM_DIR}")
    else:
        print("[bq_gen] --check: nothing written")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
