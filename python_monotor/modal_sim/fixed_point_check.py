"""Check the fixed-point model (chain step 2) against the float engine (step 1).

Per note:

1. **Coefficient precision** -- solve the pole equation ``z^2 + a1 z + a2 = 0`` exactly
   (no conjugate assumption, no clip), report frequency / decay error AND stability.
   The criterion is DECISIONS section H: the slowest / lowest poles matter.

2. **Waveform** -- run both engines sample by sample (noise off) and report error / SNR.

This script is a **gate**: it returns non-zero when a threshold is exceeded.
"""

from __future__ import annotations

import argparse
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))

import params as P                                    # noqa: E402
from engine import ModalSynth                         # noqa: E402
import gen_coeff_table as GEN                         # noqa: E402
from fixed_point import FixedModalSynth, A1_FRAC, A2_FRAC   # noqa: E402

# ---- acceptance thresholds (fail -> non-zero exit) -------------------------
GAMMA_TOL = 1e-2          # |dgamma|/gamma < 1%
CENTS_TOL = 30.0          # |df| in cents < 30 (worst mode is ~21.6)
SNR2K_MIN = 30.0          # short-window SNR (dB) lower bound
REAL_ROOT_MAX = 0         # quantisation must not turn the conjugate pair real


def exact_roots(a1, a2):
    """Roots of z^2 + a1 z + a2 = 0 as complex numbers (no conjugate assumption)."""
    a1 = np.asarray(a1, dtype=float)
    a2 = np.asarray(a2, dtype=float)
    disc = (a1 * a1 - 4.0 * a2).astype(complex)
    sq = np.sqrt(disc)
    return (-a1 + sq) / 2.0, (-a1 - sq) / 2.0


def pole_report(a1, a2, sr=P.SR):
    """(f Hz, gamma 1/s, max|pole|, is_real) for each mode."""
    r1, r2 = exact_roots(a1, a2)
    R = np.maximum(np.abs(r1), np.abs(r2))
    is_real = np.abs(r1.imag) < 1e-12
    # dominant (larger modulus) root's angle/decay
    dom = np.where(np.abs(r1) >= np.abs(r2), r1, r2)
    f = np.angle(dom) / (2.0 * np.pi) * sr
    gamma = -sr * np.log(np.maximum(R, 1e-12))
    return f, gamma, R, is_real


def coef_errors(a1f, a2f, a1q, a2q, sr=P.SR):
    f0, g0, R0, _ = pole_report(a1f, a2f, sr)
    f1, g1, R1, real1 = pole_report(a1q / float(1 << A1_FRAC),
                                    a2q / float(1 << A2_FRAC), sr)
    # frequency error in cents (only meaningful for complex pairs)
    cents = np.abs(1200.0 * np.log2(np.maximum(f1, 1e-9) / np.maximum(f0, 1e-9)))
    g_err = np.abs(g1 - g0) / np.maximum(g0, 1e-12)
    return cents, g_err, R1, real1


def run_pair(inst, midi, vel, seconds, max_poly=1):
    cfg = __import__("instruments").get(inst)
    patch = P.Patch(inst, band_hz=cfg["band_hz"], max_modes=GEN.N_MODES)
    table = GEN.build(inst)

    fe = ModalSynth(patch, max_poly=max_poly, noise_amp=0.0)
    fx = FixedModalSynth(table, max_poly=max_poly, max_modes=GEN.N_MODES)
    fe.note_on(midi, vel)
    fx.note_on(midi, vel)

    n = int(seconds * P.SR)
    a = np.empty(n)
    b = np.empty(n)
    for i in range(n):
        a[i] = fe.step()
        b[i] = fx.step()
    return a, b


def snr_db(ref, test):
    e = ref - test
    p_sig = float(np.sum(ref ** 2))
    p_err = float(np.sum(e ** 2))
    if p_err <= 0:
        return float("inf"), 0.0
    return 10.0 * np.log10(p_sig / p_err), float(np.max(np.abs(e)))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-i", "--instrument", default="guitar")
    ap.add_argument("--seconds", type=float, default=1.0)
    args = ap.parse_args(argv)

    inst = args.instrument
    cfg = __import__("instruments").get(inst)
    patch = P.Patch(inst, band_hz=cfg["band_hz"], max_modes=GEN.N_MODES)
    table = GEN.build(inst)
    midis = patch.midis
    probes = [midis[0], midis[len(midis) // 4], midis[len(midis) // 2],
              midis[3 * len(midis) // 4], midis[-1]]

    print(f"[{inst}] fixed-point vs float  ({GEN.N_MODES} modes, "
          f"{args.seconds:g} s, noise off)")
    print(f"{'midi':>4} {'dyn':>6} {'n':>3} {'cents':>8} {'|dg|/g':>10} "
          f"{'SNR2k':>8} {'max err':>9}")

    worst_cents = worst_g = real_total = 0
    snr_ok = True
    for midi in probes:
        for dyn, vel in (("forte", 1.0), ("piano", 0.5)):
            if (midi, dyn) not in patch.by_key:
                continue
            a, b = run_pair(inst, midi, vel, args.seconds)
            snr, err = snr_db(a, b)
            snr2k, _ = snr_db(a[:2048], b[:2048])
            snr_ok &= snr2k >= SNR2K_MIN
            # coefficient error for the played row
            synth = ModalSynth(patch, max_poly=1, noise_amp=0.0)
            synth.note_on(midi, vel)
            n = table.get(midi, dyn)["a1"].size
            f = synth.f[0, :n]; gam = synth.base_gamma[0, :n]
            a1f = -2.0 * np.exp(-gam / P.SR) * np.cos(2.0 * np.pi * f / P.SR)
            a2f = np.exp(-2.0 * gam / P.SR)
            e = table.get(midi, dyn)
            cents, ge, _, real1 = coef_errors(a1f, a2f, e["a1"], e["a2"])
            worst_cents = max(worst_cents, float(np.max(cents)))
            worst_g = max(worst_g, float(np.max(ge)))
            real_total += int(real1.sum())
            print(f"{midi:>4} {dyn:>6} {n:>3} {np.max(cents):>8.2f} {np.max(ge):>10.2e} "
                  f"{snr2k:>8.1f} {err:>9.2e}")

    # whole-table coefficient scan
    synth = ModalSynth(patch, max_poly=1, noise_amp=0.0)
    all_c, all_g, all_R, all_real = [], [], [], []
    for (midi, dyn), ent in table.entries.items():
        n = ent["a1"].size
        synth.note_on(midi, 1.0 if dyn == "forte" else 0.5)
        f = synth.f[0, :n]; gam = synth.base_gamma[0, :n]
        a1f = -2.0 * np.exp(-gam / P.SR) * np.cos(2.0 * np.pi * f / P.SR)
        a2f = np.exp(-2.0 * gam / P.SR)
        c, g, R, real1 = coef_errors(a1f, a2f, ent["a1"], ent["a2"])
        all_c.append(c); all_g.append(g); all_R.append(R); all_real.append(real1)
    all_c = np.concatenate(all_c); all_g = np.concatenate(all_g)
    all_R = np.concatenate(all_R); all_real = np.concatenate(all_real)

    print(f"\nwhole table, {all_c.size} modes:")
    print(f"  freq  : median {np.median(all_c):.3f}  p99 {np.percentile(all_c,99):.2f}  "
          f"max {all_c.max():.2f} cents")
    print(f"  gamma : median {np.median(all_g):.2e}  p99 {np.percentile(all_g,99):.2e}  "
          f"max {all_g.max():.2e}")
    print(f"  poles : max |z| = {all_R.max():.9f}  (stable < 1);  "
          f"real roots after quant = {int(all_real.sum())}")

    # ---- gates ----
    fails = []
    if all_R.max() >= 1.0:
        fails.append(f"unstable pole |z|={all_R.max():.9f} >= 1")
    if int(all_real.sum()) > REAL_ROOT_MAX:
        fails.append(f"{int(all_real.sum())} modes have real roots after quant "
                     f"(limit {REAL_ROOT_MAX}); the conjugate premise breaks")
    if all_g.max() >= GAMMA_TOL:
        fails.append(f"gamma err {all_g.max():.3e} >= {GAMMA_TOL:g}")
    if all_c.max() >= CENTS_TOL:
        fails.append(f"freq err {all_c.max():.2f} cents >= {CENTS_TOL:g}")
    if not snr_ok:
        fails.append(f"short-window SNR < {SNR2K_MIN:g} dB on some probe")

    if fails:
        print("\nGATE FAILED:")
        for m in fails:
            print("  -", m)
        return 1
    print("\nGATE PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
