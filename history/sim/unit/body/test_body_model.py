"""Pure-Python body tests: ROM generator, integer model, float comparison.

No cocotb / no RTL here; this is the numeric gate between the original float
``Patch.sos`` reference and the new integer model (verification chain step 2 for
the body filter).  Run directly::

    python sim/unit/body/test_body_model.py [--rom-dir rtl/rom]

Covers rtl/body_design.md test items 1, 4 and 5:

  * generator quantises every coefficient of the four original ``Patch.sos``
    exactly, 80-word layout, signed Q2.30, reproducibility/hash, stability and
    strict rejection of bad sources without touching existing output;
  * integer DFI-Q34 model vs ``scipy.signal.sosfilt`` on impulse, random and a
    real guitar modal song (peak/RMS + 20 Hz..20 kHz frequency response);
  * >= 65536-sample limit-cycle residual after silence, and the Q30 vs Q34
    guard-bit comparison that motivated the guard bits.

Exit code is non-zero if any check fails.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import sys

import numpy as np
from scipy.signal import sosfilt, sosfreqz

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = _HERE
while not (os.path.isdir(os.path.join(_ROOT, "rtl"))
           and os.path.isdir(os.path.join(_ROOT, "sim"))):
    _ROOT = os.path.dirname(_ROOT)
sys.path.insert(0, os.path.join(_ROOT, "sim", "support"))
from _sim_paths import bootstrap as _sim_bootstrap  # noqa: E402
_ROOT = str(_sim_bootstrap(__file__))
sys.path.insert(0, _HERE)
sys.path.insert(0, os.path.join(_ROOT, "python", "modal_sim"))

import gen_body_rom as GEN                      # noqa: E402
import body_fixed_point as BFP                  # noqa: E402
from params import Patch                        # noqa: E402
from body_helpers import song_coeffs, song_chain  # noqa: E402

NAMES = ("guitar", "piano", "banjo", "mandolin")
SR = 48000
PEAK_TOL = 1e-5
FRF_TOL_DB = 0.01
TAIL_TOL = 2e-7

_failures = []


def check(cond, msg):
    if cond:
        print(f"  [ok]   {msg}")
    else:
        print(f"  [FAIL] {msg}")
        _failures.append(msg)


def _sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        h.update(fh.read())
    return h.hexdigest()


def _sos_map():
    return {name: np.asarray(Patch(name).sos) for name in NAMES}


# ---------------------------------------------------------------------------
def test_rom_layout(rom_dir):
    print("[1] generator / ROM layout / quantisation")
    words = [int(l, 16) for l in open(os.path.join(rom_dir, "body_coeff.mem"),
                                      encoding="utf-8") if l.strip()]
    raw = open(os.path.join(rom_dir, "body_coeff.mem"), encoding="utf-8").read().split()
    check(len(words) == 80, f"80 words ({len(words)})")
    check(all(len(l) == 8 for l in raw), "every word is 8 hex digits")

    sos = _sos_map()
    for inst_idx, name in enumerate(NAMES):
        for s in range(4):
            row = sos[name][s]
            a0 = row[3]
            want = [GEN.quantize_coeff(row[k] / a0) for k in (0, 1, 2, 4, 5)]
            base = inst_idx * 20 + s * 5
            got = [BFP.quant_coeff(v) for v in
                   (row[0] / a0, row[1] / a0, row[2] / a0, row[4] / a0, row[5] / a0)]
            check(got == want, f"{name} sec{s}: quantiser agreement")
            # stored words are two's-complement signed Q2.30
            got_signed = [w - (1 << 32) if w >= (1 << 31) else w for w in words[base:base + 5]]
            check(got_signed == want, f"{name} sec{s}: ROM layout line {base}")
    # load_coeffs_from_mem must reconstruct the same sections
    for inst_idx, name in enumerate(NAMES):
        coeffs = BFP.load_coeffs_from_mem(os.path.join(rom_dir, "body_coeff.mem"),
                                          inst_idx)
        q = BFP.quantise_sos(sos[name])
        check(coeffs == q, f"{name}: load_coeffs_from_mem == quantise_sos")

    manifest = json.load(open(os.path.join(rom_dir, "body_manifest.json"),
                              encoding="utf-8"))
    check(manifest["total_words"] == 80, "manifest total_words == 80")
    check(manifest["coeff_bits"] == 32 and manifest["coeff_frac"] == 30,
          "manifest Q2.30 / 32-bit")
    check(manifest.get("external_bits") == 64
          and manifest.get("external_frac") == 30, "manifest external signed64/Q30")
    check(manifest.get("internal_bits") == 68
          and manifest.get("internal_frac") == 34
          and manifest.get("guard_bits") == 4,
          "manifest internal signed68/Q34 guard=4")
    check(manifest.get("product_bits") == 100 and manifest.get("acc_bits") == 104,
          "manifest product 100 / acc 104")
    check(manifest.get("fs") == 48000, "manifest fs == 48000")
    check(manifest.get("sos_fit", {}).get("order") == 8, "manifest SOS fit order 8")
    for name in NAMES:
        sf = manifest["per_instrument"][name].get("sos_float")
        check(sf is not None and len(sf) == 4 and all(len(r) == 6 for r in sf),
              f"{name}: manifest float SOS is 4x6")
        src = manifest.get("source_files", {}).get(name, {})
        check(bool(src.get("sha256")), f"{name}: manifest source body hash")
    check(manifest["instrument_order"] == list(NAMES), "manifest instrument order")
    check(manifest["coeff_sha256"] == _sha(os.path.join(rom_dir, "body_coeff.mem")),
          "manifest coeff_sha256 matches file")
    for name in NAMES:
        radii = [sec["pole_radius"] for sec in manifest["per_instrument"][name]["sections"]]
        check(all(r < 1.0 for r in radii),
              f"{name}: manifest pole radii < 1 ({['%.6f' % r for r in radii]})")
    return manifest


def test_reproducible_and_reject(rom_dir):
    print("[2] reproducibility + strict rejection (no partial write)")
    a_words, a_man = GEN.build_products()
    b_words, b_man = GEN.build_products()
    check(a_words == b_words and a_man == b_man, "two builds are identical")

    mem = os.path.join(rom_dir, "body_coeff.mem")
    man = os.path.join(rom_dir, "body_manifest.json")
    h0 = (_sha(mem), _sha(man))

    good = {n: np.asarray(Patch(n).sos) for n in NAMES}
    # out-of-range coefficient
    bad = {k: v.copy() for k, v in good.items()}
    bad["guitar"][0, 0] = 3.0
    try:
        GEN.build_from_sos(bad)
        check(False, "out-of-range coefficient rejected")
    except GEN.BodyRomError:
        check(True, "out-of-range coefficient rejected")
    # non-finite
    bad = {k: v.copy() for k, v in good.items()}
    bad["piano"][1, 5] = math.nan
    try:
        GEN.build_from_sos(bad)
        check(False, "non-finite coefficient rejected")
    except GEN.BodyRomError:
        check(True, "non-finite coefficient rejected")
    # exactly +2.0 cannot be represented in signed Q2.30
    bad = {k: v.copy() for k, v in good.items()}
    bad["mandolin"][0, 0] = 2.0
    try:
        GEN.build_from_sos(bad)
        check(False, "coefficient +2.0 rejected")
    except GEN.BodyRomError:
        check(True, "coefficient +2.0 rejected")
    # unstable quantised poles (a2 = 1 -> radius 1)
    bad = {k: v.copy() for k, v in good.items()}
    bad["banjo"][2, 5] = 1.0
    try:
        GEN.build_from_sos(bad)
        check(False, "unstable section rejected")
    except GEN.BodyRomError:
        check(True, "unstable section rejected")
    # write_products refuses a wrong-length image before opening any file
    try:
        GEN.write_products(a_words[:-1], a_man, rom_dir)
        check(False, "short image refused before write")
    except GEN.BodyRomError:
        check(True, "short image refused before write")
    check((_sha(mem), _sha(man)) == h0, "existing ROM/manifest untouched")
    return a_words, a_man


def test_int_vs_float():
    print("[3] integer DFI-Q34 vs scipy sosfilt (peak/RMS/FRF)")
    rng = np.random.default_rng(7)
    for name in NAMES:
        sos = np.asarray(Patch(name).sos)
        # frequency response of the quantised coefficients
        q = BFP.quantise_sos(sos)
        sosq = np.array([[c[0] / (1 << 30), c[1] / (1 << 30), c[2] / (1 << 30),
                          1.0, c[3] / (1 << 30), c[4] / (1 << 30)] for c in q])
        f = np.linspace(20.0, 20000.0, 8192)
        _, h0 = sosfreqz(sos, worN=f, fs=SR)
        _, h1 = sosfreqz(sosq, worN=f, fs=SR)
        frf = np.max(np.abs(20 * np.log10(np.abs(h1) + 1e-300)
                            - 20 * np.log10(np.abs(h0) + 1e-300)))
        check(frf <= FRF_TOL_DB, f"{name}: FRF error {frf:.3e} dB <= {FRF_TOL_DB}")

        # quantised pole stability
        worst_r = 0.0
        for row in q:
            a1 = row[3] / (1 << 30)
            a2 = row[4] / (1 << 30)
            roots = np.roots([1.0, a1, a2])
            worst_r = max(worst_r, float(np.max(np.abs(roots))))
        check(worst_r < 1.0, f"{name}: quantised pole radius {worst_r:.6f} < 1")

        for tag, xs in (("impulse", np.concatenate([[1.0], np.zeros(4095)])),
                        ("random", rng.uniform(-0.5, 0.5, 4096))):
            xq = [int(round(v * (1 << 30))) for v in xs]
            xf = np.array([v / float(1 << 30) for v in xq])
            yf = sosfilt(sos, xf)
            m = BFP.BodyFixedPoint(sos=sos, guard_bits=4)
            yi, _ = m.process(xq)
            yi = np.array([v / float(1 << 30) for v in yi])
            peak = float(np.max(np.abs(yi - yf)))
            rms = float(np.sqrt(np.mean((yi - yf) ** 2)))
            check(peak <= PEAK_TOL,
                  f"{name} {tag}: peak err {peak:.3e} <= {PEAK_TOL} (rms {rms:.3e})")


def test_guitar_song():
    print("[4] integer body vs float scipy on a real guitar modal song")
    sos = np.asarray(Patch("guitar").sos)
    coeffs = song_coeffs()
    nsamp = 4096
    mix, _ = song_chain(nsamp, coeffs, note_gap=512, return_mix=True)
    xf = np.array([v / float(1 << 30) for v in mix])
    yf = sosfilt(sos, xf)
    m = BFP.BodyFixedPoint(sos=sos, guard_bits=4)
    yi, _ = m.process(mix)
    yi = np.array([v / float(1 << 30) for v in yi])
    peak = float(np.max(np.abs(yi - yf)))
    rms = float(np.sqrt(np.mean((yi - yf) ** 2)))
    check(peak <= PEAK_TOL, f"guitar song: peak err {peak:.3e} <= {PEAK_TOL}")
    check(m.sat_count == 0, f"guitar song: no saturation (got {m.sat_count})")
    print(f"         guitar song {nsamp} samples, peak err {peak:.3e}, rms {rms:.3e}, "
          f"input peak {np.max(np.abs(xf)):.4f}")


def test_limit_cycle():
    print("[5] long-silence limit cycle (1 impulse + 4096 rand + 65536 zeros)")
    rng = np.random.default_rng(20261004)
    nr, nz = 4096, 65536
    report = {}
    for name in NAMES:
        sos = np.asarray(Patch(name).sos)
        xs = np.concatenate([[1.0], rng.uniform(-0.5, 0.5, nr), np.zeros(nz)])
        xq = [int(round(v * (1 << 30))) for v in xs]
        xf = np.array([v / float(1 << 30) for v in xq])
        yf = sosfilt(sos, xf)
        tails = {}
        for g in (0, 4):
            m = BFP.BodyFixedPoint(sos=sos, guard_bits=g)
            yi, _ = m.process(xq)
            yi = np.array([v / float(1 << 30) for v in yi])
            # quantization residual floor over the last 4096 silent samples
            tails[g] = float(np.max(np.abs(yi[1 + nr:][-4096:] - yf[1 + nr:][-4096:])))
        report[name] = tails
        check(tails[4] <= TAIL_TOL,
              f"{name}: Q34 tail residual {tails[4]:.3e} <= {TAIL_TOL}")
        print(f"         {name:9s} Q30 tail {tails[0]:.3e}  ->  Q34 tail {tails[4]:.3e}")
    check(report["piano"][0] > TAIL_TOL,
          f"Q30 piano tail {report['piano'][0]:.3e} > {TAIL_TOL} (guard bits needed)")
    return report


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--rom-dir", default=os.path.join(_ROOT, "rtl", "rom"))
    args = ap.parse_args(argv)
    rom_dir = os.path.abspath(os.path.expanduser(args.rom_dir))

    test_rom_layout(rom_dir)
    test_reproducible_and_reject(rom_dir)
    test_int_vs_float()
    test_guitar_song()
    test_limit_cycle()

    if _failures:
        print(f"\n[body_model] FAIL: {len(_failures)} check(s) failed")
        return 1
    print("\n[body_model] all checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
