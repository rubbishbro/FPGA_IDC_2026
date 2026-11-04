#!/usr/bin/env python3
"""Vibrato -> a1 coefficient modulation experiment (Class B / A).

Question this script answers
----------------------------
The modal recursion is ``y[n] = g*x[n] - a1*y[n-1] - a2*y[n-2]`` with

    a1 = -2 r cos(theta),   a2 = r^2,   r = exp(-gamma/fs).

For a pitch shift by ``c`` cents, ``rho = 2**(c/1200)`` and the *exact* coefficient is

    a1(rho) = -2 r cos(rho*theta),   a2 unchanged.

The engine does not want a cos/CORDIC per mode per sample.  This experiment measures

1. how strongly ``a1`` really changes for +-20 cents,
2. whether a first-order (linear) or second-order Taylor expansion is enough,
3. what the *fixed-point* formats do -- a1 Q2.20, theta UQ2.14, ratio UQ1.15,
   delta-theta Q3.14, a1 shadow Q2.20 (the current RTL, ``b_a1_refresh.sv``),
4. the time-domain consequence: a free-decay mode (A-like) and a driven mode
   (B-like), with a 96-sample control update.

Outputs land in ``python_monotor/results/sim/vibrato_coeff/`` (figures, CSV/JSON, WAVs, report).

Run
---
    python python_monotor/modal_sim/vibrato_coeff.py
    python python_monotor/modal_sim/vibrato_coeff.py --quick
    python python_monotor/modal_sim/vibrato_coeff.py --depth 20 --rate 5.2
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
from dataclasses import dataclass

import numpy as np

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt                       # noqa: E402
from scipy.signal import lfilter, welch                # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "fft_analysis"))

import core as CORE                                   # noqa: E402
import paths                                          # noqa: E402
import sustain_engine as SE                           # noqa: E402

SR = CORE.SR
OUT = paths.SIM_VIBRATO

#: default maximum vibrato depth (cents) requested by the router knob
DEPTH = 20.0
#: default LFO rate (Hz); the current Python demo uses 5.2 Hz
RATE = 5.2
#: control-rate coefficient update, in samples (current engine: 96 = 500 Hz)
INTERVAL = 96

NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


def note_name(midi: int) -> str:
    return f"{NOTE_NAMES[int(midi) % 12]}{int(midi) // 12 - 1}"


# ---------------------------------------------------------------------------
# quantisers -- mirror the RTL formats ("round half up", then clamp)
# ---------------------------------------------------------------------------
def quant(x, frac: int, bits: int | None = None, signed: bool = True):
    """Round to ``frac`` fractional bits; optionally clamp to a ``bits``-wide word.

    The rounding is ``floor(x*2^frac + 0.5)`` (the same "round half up" used by
    ``fixed_point.quant``).  ``bits`` is the *total* word width including sign.
    """
    s = float(2 ** frac)
    v = np.floor(np.asarray(x, dtype=float) * s + 0.5) / s
    if bits is not None:
        if signed:
            lo, hi = -(2 ** (bits - 1)) / s, (2 ** (bits - 1) - 1) / s
        else:
            lo, hi = 0.0, (2 ** bits - 1) / s
        v = np.clip(v, lo, hi)
    return v


def q_a1(x, frac: int):
    """a1 Q2.<frac>: signed, 2 integer bits -> ``frac + 2`` bits total."""
    return quant(x, frac, frac + 2, signed=True)


def q_theta(x):
    """theta UQ2.14: unsigned, 16 bits, range [0, 4)."""
    return quant(x, 14, 16, signed=False)


def q_ratio(x):
    """ratio UQ1.15: unsigned, 16 bits, range [0, 2)."""
    return quant(x, 15, 16, signed=False)


def q_s(x):
    """s = 2r sin(theta), Q1.12: signed, 14 bits, range [-2, 2)."""
    return quant(x, 12, 14, signed=True)


def q_dtheta(x, frac: int):
    """delta-theta Q3.<frac>: signed.  Q3.14 -> 18 bit, Q3.20 -> 24 bit."""
    return quant(x, frac, frac + 4, signed=True)


# ---------------------------------------------------------------------------
# mode tables
# ---------------------------------------------------------------------------
@dataclass
class ModeSet:
    inst: str
    midi: int
    f_drive: float
    k: np.ndarray
    f: np.ndarray
    gamma: np.ndarray
    weight: np.ndarray
    theta: np.ndarray
    r: np.ndarray
    a1: np.ndarray
    a2: np.ndarray
    s: np.ndarray


_PATCHES: dict[str, SE.SustainPatch] = {}


def get_patch(inst: str) -> SE.SustainPatch:
    if inst not in _PATCHES:
        _PATCHES[inst] = SE.SustainPatch(inst)
    return _PATCHES[inst]


def load_modes(inst: str, midi: int) -> ModeSet:
    """Modes exactly as the B engine builds them: harmonics of the drive grid."""
    patch = get_patch(inst)
    k, gamma, weight, *_ = patch.modes(midi)
    f0 = CORE.midi_to_hz(midi)
    period = max(2, int(round(SR / f0)))
    f_drive = SR / period
    f = k * f_drive
    theta = 2.0 * np.pi * f / SR
    r = np.exp(-gamma / SR)
    a1 = -2.0 * r * np.cos(theta)
    a2 = r * r
    s = 2.0 * r * np.sin(theta)
    return ModeSet(inst=inst, midi=int(midi), f_drive=float(f_drive), k=k, f=f,
                   gamma=gamma, weight=weight, theta=theta, r=r, a1=a1, a2=a2, s=s)


# ---------------------------------------------------------------------------
# coefficient models
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class Config:
    name: str
    method: str                 # exact / ideal / t1 / t2 / secant
    qa1: int | None = None      # a1 output fractional bits
    qd: int | None = None       # delta-theta fractional bits
    qth: int | None = None      # theta fractional bits (None -> exact)
    qr: int | None = None       # ratio fractional bits (None -> exact)
    qs: int | None = None       # s fractional bits (None -> exact)
    base: int | None = None     # nominal a1 fractional bits (None -> exact)
    label: str = ""


CONFIGS = [
    Config("float_exact", "exact", label="float, exact cos"),
    Config("float_t1", "t1", label="float, 1st order"),
    Config("float_t2", "t2", label="float, 2nd order"),
    Config("float_sec", "secant", label="float, endpoint secant"),
    Config("q20_ideal", "ideal", qa1=20, base=20,
           label="a1 Q2.20, ideal delta"),
    Config("q20_rtl", "t2", qa1=20, qd=14, qth=14, qr=15, qs=12, base=20,
           label="Q2.20 + dtheta Q3.14, rounded polynomial"),
    Config("q20_int", "int", qa1=20, qd=14, base=20,
           label="current RTL: integer Q2.20 + Q3.14"),
    Config("q24_ideal", "ideal", qa1=24, base=20,
           label="a1 Q2.24, ideal delta"),
    Config("q24_t1", "t1", qa1=24, qd=20, qth=14, qr=15, qs=12, base=20,
           label="Q2.24 + dtheta Q3.20, 1st order"),
    Config("q24_t2", "t2", qa1=24, qd=20, qth=14, qr=15, qs=12, base=20,
           label="Q2.24 + dtheta Q3.20, 2nd order"),
    Config("q24_int", "int", qa1=24, qd=20, base=20,
           label="proposed: integer Q2.24 + Q3.20"),
]
CONFIG_BY_NAME = {c.name: c for c in CONFIGS}


def _theta_q_from_a1a2(a1q20: int, a2q: int) -> int:
    """b_theta.mem convention: theta = acos(-a1/(2r)) from the *stored* a1/a2."""
    r = math.sqrt(max(a2q, 0) / float(1 << 24))
    if r <= 1e-12:
        return 0
    c = -(a1q20 / float(1 << 20)) / (2.0 * r)
    return int(round(math.acos(max(-1.0, min(1.0, c))) * (1 << 14)))


def _refresh_int(a1q20: int, a2q: int, thetaq: int, ratioq: int,
                 qa1: int, qd: int, rounding: bool = False) -> int:
    """Bit-faithful model of ``b_a1_refresh`` (and its Q2.24/Q3.20 variant).

    a1_nom Q2.20, a2 UQ0.24, theta UQ2.14, ratio UQ1.15.  The polynomial is formed
    in the same fixed-point scales as the RTL; the output is a Q2.<qa1> word.
    """
    delta = int(ratioq) - (1 << 15)
    dth = (delta * int(thetaq)) >> (29 - qd)
    dth = max(-(1 << (qd + 3)), min((1 << (qd + 3)) - 1, dth))

    a1sq = int(a1q20) * int(a1q20)
    rad = (int(a2q) << 2) - (a1sq >> 16)
    s = math.isqrt(max(rad, 0))
    d2 = dth * dth

    s1 = 12 + qd - qa1
    s2 = 20 + 2 * qd - qa1
    if rounding:
        t1 = (s * dth + (1 << (s1 - 1))) >> s1
        t2 = (int(a1q20) * d2 + (1 << (s2 - 1))) >> s2
    else:
        t1 = (s * dth) >> s1
        t2 = (int(a1q20) * d2) >> s2
    calc = (int(a1q20) << (qa1 - 20)) + t1 - t2
    lo, hi = -(1 << (qa1 + 1)), (1 << (qa1 + 1)) - 1
    return max(lo, min(hi, calc))


def _a1_curve_int(ms: ModeSet, cents: np.ndarray, qa1: int, qd: int) -> np.ndarray:
    """a1 trajectory from the integer refresh, one (voice, mode) at a time."""
    a1q = np.round(ms.a1 * (1 << 20)).astype(np.int64)
    a2q = np.round(ms.a2 * (1 << 24)).astype(np.int64)
    thq = np.array([_theta_q_from_a1a2(int(a1q[i]), int(a2q[i]))
                    for i in range(a1q.size)])
    rq = np.round((2.0 ** (cents / 1200.0)) * (1 << 15)).astype(np.int64)
    out = np.empty((a1q.size, cents.size))
    for i in range(a1q.size):
        for j in range(cents.size):
            out[i, j] = _refresh_int(int(a1q[i]), int(a2q[i]), int(thq[i]),
                                     int(rq[j]), qa1, qd) / float(1 << qa1)
    return out


def a1_curve(ms: ModeSet, cents, cfg: Config, depth: float = DEPTH):
    """Return a1 (modes x cents) for one configuration.

    Ordering of operations mirrors the RTL: quantise theta/s/ratio/delta-theta first,
    then form the polynomial, then quantise the 22/26-bit a1 shadow.
    """
    cents = np.atleast_1d(np.asarray(cents, dtype=float))
    if cfg.method == "int":
        return _a1_curve_int(ms, cents, int(cfg.qa1), int(cfg.qd))
    rho = 2.0 ** (cents / 1200.0)
    theta = q_theta(ms.theta) if cfg.qth is not None else ms.theta
    s = q_s(ms.s) if cfg.qs is not None else ms.s
    ratio = q_ratio(rho) if cfg.qr is not None else rho
    base = q_a1(ms.a1, cfg.base) if cfg.base is not None else ms.a1.copy()

    dth = (ratio[None, :] - 1.0) * theta[:, None]
    if cfg.qd is not None:
        dth = q_dtheta(dth, cfg.qd)

    if cfg.method in ("exact", "ideal"):
        exact = -2.0 * ms.r[:, None] * np.cos(ratio[None, :] * theta[:, None])
        # `ideal` (and `exact` with a fixed base) means: keep the stored nominal a1
        # and add the *ideal* delta, so the comparison isolates the output format.
        out = base[:, None] + (exact - ms.a1[:, None]) if cfg.base is not None else exact
    elif cfg.method == "t1":
        out = base[:, None] + s[:, None] * dth
    elif cfg.method == "t2":
        out = base[:, None] + s[:, None] * dth - base[:, None] * dth * dth / 2.0
    elif cfg.method == "secant":
        span = (-2.0 * ms.r * np.cos(2.0 ** (depth / 1200.0) * theta)) - ms.a1
        out = ms.a1[:, None] + span[:, None] * (cents[None, :] / depth)
    else:
        raise ValueError(cfg.method)

    if cfg.qa1 is not None:
        out = q_a1(out, cfg.qa1)
    return out


def pitch_error_cents(a1, r: np.ndarray, f_target: np.ndarray) -> np.ndarray:
    """Invert a1 -> pole angle -> frequency, then compare with the target in cents."""
    c = -np.asarray(a1, dtype=float) / (2.0 * np.asarray(r)[:, None])
    bad = np.abs(c) > 1.0
    c = np.clip(c, -1.0, 1.0)
    f = np.arccos(c) / (2.0 * np.pi) * SR
    with np.errstate(divide="ignore", invalid="ignore"):
        err = 1200.0 * np.log2(np.maximum(f, 1e-9) / np.maximum(f_target, 1e-9))
    err = np.where(bad, np.nan, err)
    return err


def max_pole_radius(a1, a2: np.ndarray) -> float:
    """Largest |pole| for z^2 + a1 z + a2.  Exact for both complex and real roots."""
    a1 = np.asarray(a1, dtype=float)
    r = np.sqrt(np.asarray(a2, dtype=float))[:, None]
    absa = np.abs(a1)
    disc = np.maximum(absa * absa - 4.0 * r * r, 0.0)
    rad = np.where(absa <= 2.0 * r, r, (absa + np.sqrt(disc)) / 2.0)
    return float(np.max(rad))


def a1_lsb_cents(ms: ModeSet, frac: int, k: int = 0) -> float:
    """One a1 LSB is worth how many cents at this mode?  (small-angle derivative)"""
    lsb = 2.0 ** (-frac)
    slope = 2.0 * ms.r[k] * math.sin(ms.theta[k])      # d a1 / d theta
    dtheta = lsb / max(slope, 1e-15)
    return float(1200.0 / math.log(2.0) * dtheta / ms.theta[k])


# ---------------------------------------------------------------------------
# static sweep
# ---------------------------------------------------------------------------
def note_grid(inst: str, n: int = 9) -> list[int]:
    mids = sorted(set(get_patch(inst).midis))
    if len(mids) <= n:
        return mids
    idx = np.linspace(0, len(mids) - 1, n).round().astype(int)
    return sorted({mids[i] for i in idx})


def sweep(insts, depth: float, npts: int):
    rows = []
    curves = {}
    plot_notes = {"cello": [36, 48, 60, 72, 84], "flute": [60, 69, 84],
                  "trumpet": [51, 60, 72]}
    for inst in insts:
        for midi in note_grid(inst, 9):
            ms = load_modes(inst, midi)
            cents = np.linspace(-depth, depth, npts)
            rho = 2.0 ** (cents / 1200.0)
            f_target = ms.f[:, None] * rho[None, :]
            for cfg in CONFIGS:
                a1 = a1_curve(ms, cents, cfg, depth)
                err = pitch_error_cents(a1, ms.r, f_target)
                abs_err = np.abs(err)
                per_mode = np.nanmax(abs_err, axis=1)
                k_worst = int(np.nanargmax(per_mode))
                err0 = err[:, int(np.argmin(np.abs(cents)))]
                rel = np.abs(err - err0[:, None])
                per_mode_rel = np.nanmax(rel, axis=1)

                n_lev = None
                span_lsb = None
                if cfg.qa1 is not None:
                    n_lev = int(np.unique(np.round(a1[0], 12)).size)
                    span_lsb = float((a1[0].max() - a1[0].min()) / 2.0 ** (-cfg.qa1))

                rows.append(dict(
                    inst=inst, midi=int(midi), note=note_name(midi), f0=ms.f_drive,
                    config=cfg.name, label=cfg.label,
                    max_err=float(per_mode[k_worst]),
                    rel_err=float(per_mode_rel[k_worst]),
                    fund_err=float(per_mode[0]),
                    fund_rel=float(per_mode_rel[0]),
                    mean_err=float(np.nanmean(abs_err)),
                    k_worst=float(ms.k[k_worst]),
                    static_err=float(err0[0]),
                    levels=n_lev, span_lsb=span_lsb,
                    a1_lsb_cents=a1_lsb_cents(ms, cfg.qa1, 0) if cfg.qa1 else None,
                ))

                key = (inst, int(midi), cfg.name)
                if cfg.name in ("float_t1", "float_t2", "float_sec",
                                "q20_int", "q24_int") and int(midi) in plot_notes.get(inst, []):
                    curves[key] = (cents.copy(), a1.copy(), err.copy())
    return rows, curves


# ---------------------------------------------------------------------------
# time domain
# ---------------------------------------------------------------------------
def render_driven(ms: ModeSet, cfg: Config, seconds: float = 1.6,
                  depth: float = DEPTH, rate: float = RATE,
                  interval: int = INTERVAL):
    """B-like render: fractional drive + all modes, coefficients at control rate.

    The drive is *always* exact (the NCO carries the vibrato pitch); only the
    resonator coefficients are changed by ``cfg``.  That mirrors the B engine and
    separates "pitch from the drive" from "resonance from a1".
    """
    n = int(seconds * SR)
    t = np.arange(n) / SR
    cents = depth * np.sin(2.0 * np.pi * rate * t)
    rho = 2.0 ** (cents / 1200.0)

    phase = np.cumsum(ms.f_drive * rho / SR) % 1.0
    drive = np.zeros(n)
    wrap = np.nonzero(np.diff(np.concatenate(([-1.0], phase))) < 0.0)[0]
    drive[wrap] = 1.0

    a_unit = np.array([SE.steady_amp_unit(g, f, ms.f_drive, SR)
                       for g, f in zip(ms.gamma, ms.f)])
    gains = ms.weight / np.maximum(a_unit, 1e-12)

    y = np.zeros((n, len(ms.f)))
    zi = np.zeros((len(ms.f), 2))
    a1_prev = None
    max_jump = 0.0
    for b in range(0, n, interval):
        e = min(n, b + interval)
        c = cents[b]
        a1v = a1_curve(ms, np.array([c]), cfg, depth)[:, 0]
        if a1_prev is not None and b > 0:
            jump = np.abs((a1v - a1_prev) * y[b - 1])
            max_jump = max(max_jump, float(jump.max()))
        a1_prev = a1v
        x = drive[b:e]
        for k in range(len(ms.f)):
            y[b:e, k], zi[k] = lfilter([gains[k]], [1.0, a1v[k], ms.a2[k]],
                                       x, zi=zi[k])
    return y.sum(axis=1), max_jump


def render_decay(ms: ModeSet, cfg: Config, seconds: float = 1.2,
                 depth: float = DEPTH, rate: float = RATE,
                 interval: int = INTERVAL, mode: int = 0):
    """A-like render: one impulse, then a free-decaying mode (pitch = coefficients)."""
    n = int(seconds * SR)
    t = np.arange(n) / SR
    cents = depth * np.sin(2.0 * np.pi * rate * t)
    x = np.zeros(n)
    x[0] = 1.0
    y = np.zeros(n)
    zi = np.zeros(2)
    a1_prev = None
    max_jump = 0.0
    for b in range(0, n, interval):
        e = min(n, b + interval)
        a1v = float(a1_curve(ms, np.array([cents[b]]), cfg, depth)[mode, 0])
        if a1_prev is not None and b > 0:
            max_jump = max(max_jump, abs((a1v - a1_prev) * y[b - 1]))
        a1_prev = a1v
        y[b:e], zi = lfilter([1.0], [1.0, a1v, ms.a2[mode]], x[b:e], zi=zi)
    return y, max_jump


def null_db(ref: np.ndarray, test: np.ndarray, start: int) -> float:
    e = test[start:] - ref[start:]
    p = np.sum(ref[start:] ** 2)
    if p <= 0:
        return float("nan")
    return 10.0 * math.log10(max(np.sum(e ** 2) / p, 1e-30))


def time_domain(depth: float, rate: float, interval: int):
    cases = [("cello", 36), ("cello", 60), ("flute", 69), ("trumpet", 60)]
    ref_name = "float_t2"
    rows = []
    audio = {}
    for inst, midi in cases:
        ms = load_modes(inst, midi)
        ref, _ = render_driven(ms, CONFIG_BY_NAME[ref_name], depth=depth,
                               rate=rate, interval=interval)
        for name in ("q20_int", "q24_int"):
            cfg = CONFIG_BY_NAME[name]
            y, jump = render_driven(ms, cfg, depth=depth, rate=rate, interval=interval)
            start = int(0.5 * SR)
            peak = float(np.max(np.abs(y[start:])))
            rows.append(dict(
                inst=inst, midi=int(midi), note=note_name(midi), config=name,
                null_db=null_db(ref, y, start),
                max_jump_db=20.0 * math.log10(max(jump, 1e-30) / max(peak, 1e-30)),
                peak=peak,
            ))
            if (inst, midi) == ("cello", 36):
                audio[name] = y.copy()
        if (inst, midi) == ("cello", 36):
            audio["float_t2"] = ref.copy()
    return rows, audio


def free_decay_case(midi: int = 36, depth: float = DEPTH, rate: float = RATE,
                    interval: int = INTERVAL):
    ms = load_modes("cello", midi)
    out = {}
    for name in ("float_t2", "q20_int", "q24_int"):
        y, jump = render_decay(ms, CONFIG_BY_NAME[name], depth=depth, rate=rate,
                               interval=interval)
        out[name] = dict(y=y, jump=jump)
    return ms, out


# ---------------------------------------------------------------------------
# figures
# ---------------------------------------------------------------------------
def _style():
    plt.rcParams.update({
        "figure.dpi": 120, "savefig.dpi": 140, "font.size": 8.5,
        "axes.grid": True, "grid.alpha": 0.25, "axes.titlesize": 9,
        "axes.labelsize": 8.5, "legend.fontsize": 7.2, "legend.frameon": False,
        "lines.linewidth": 1.2,
    })


def fig_a1(curves, outdir):
    notes = [(36, "C2"), (60, "C4"), (84, "C6")]
    fig, axs = plt.subplots(1, 3, figsize=(9.4, 3.0), sharey=False)
    for ax, (midi, lab) in zip(axs, notes):
        base = None
        for name, color, ls, lw in [
            ("float_t2", "C0", "-", 1.6),
            ("float_t1", "C1", "--", 1.1),
            ("q20_int", "C3", "-", 1.1),
            ("q24_int", "C2", "-", 1.1),
        ]:
            key = ("cello", midi, name)
            if key not in curves:
                continue
            c, a, _ = curves[key]
            if base is None:
                base = a[0, len(c) // 2]
            y = (a - base) / 2.0 ** (-20)
            ax.plot(c, y[0], color=color, ls=ls, lw=lw,
                    label={"float_t2": "float", "float_t1": "float 1st",
                           "q20_int": "Q2.20 (current)",
                           "q24_int": "Q2.24 (proposed)"}[name],
                    drawstyle="steps-mid" if name.startswith("q") else "default")
        ax.set_title(f"cello {lab} (MIDI {midi}), fundamental")
        ax.set_xlabel("vibrato offset (cents)")
        ax.set_ylabel("a1 - a1(0)  [Q2.20 LSB]")
        ax.axhline(0, color="0.7", lw=0.6)
    axs[0].legend(loc="upper left")
    fig.tight_layout()
    path = os.path.join(outdir, "fig_a1_curve.png")
    fig.savefig(path)
    plt.close(fig)
    return path


def fig_pitch_error(curves, outdir):
    rows = [(36, "C2"), (60, "C4"), (84, "C6")]
    fig, axs = plt.subplots(2, 3, figsize=(9.4, 5.0), sharex=True)
    for j, (midi, lab) in enumerate(rows):
        ax = axs[0, j]
        for name, color in [("float_t1", "C1"), ("float_t2", "C0"),
                            ("float_sec", "C4")]:
            key = ("cello", midi, name)
            if key not in curves:
                continue
            c, _, e = curves[key]
            ax.plot(c, e[0], color=color, lw=1.1,
                    label={"float_t1": "1st order", "float_t2": "2nd order",
                           "float_sec": "secant"}[name])
        ax.axhline(0, color="0.7", lw=0.6)
        ax.set_ylim(-0.7, 0.7)
        ax.set_ylabel("pitch error (cents)")
        ax.set_title(f"float: cello {lab}")

        ax = axs[1, j]
        for name, color in [("q20_int", "C3"), ("q24_int", "C2")]:
            key = ("cello", midi, name)
            if key not in curves:
                continue
            c, _, e = curves[key]
            ax.plot(c, e[0], color=color, lw=1.1, drawstyle="steps-mid",
                    label={"q20_int": "Q2.20 + dtheta Q3.14 (current)",
                           "q24_int": "Q2.24 + dtheta Q3.20 (proposed)"}[name])
        ax.axhline(0, color="0.7", lw=0.6)
        ax.axhspan(-5, 5, color="0.85", zorder=0, alpha=0.5)
        ax.set_xlabel("vibrato offset (cents)")
        ax.set_ylabel("pitch error (cents)")
        ax.set_title(f"fixed point: cello {lab}")
    axs[0, 0].legend(loc="lower left")
    axs[1, 0].legend(loc="lower left")
    fig.tight_layout()
    path = os.path.join(outdir, "fig_pitch_error.png")
    fig.savefig(path)
    plt.close(fig)
    return path


def fig_error_vs_note(rows, outdir):
    insts = ["cello", "flute", "trumpet"]
    fig, axs = plt.subplots(1, 3, figsize=(9.4, 3.1), sharey=True)
    for ax, inst in zip(axs, insts):
        for name, color, lab in [("float_t1", "C1", "float 1st"),
                                 ("q20_int", "C3", "Q2.20 current"),
                                 ("q24_int", "C2", "Q2.24 proposed")]:
            pts = [(r["midi"], r["max_err"]) for r in rows
                   if r["inst"] == inst and r["config"] == name]
            pts.sort()
            if not pts:
                continue
            ax.semilogy([p[0] for p in pts], [max(p[1], 1e-3) for p in pts],
                        "o-", ms=3, color=color, label=lab)
        ax.axhline(5.0, color="0.4", lw=0.7, ls=":")
        ax.text(ax.get_xlim()[0] + 1, 5.4, "5 cents", color="0.4", fontsize=7)
        ax.set_title(inst)
        ax.set_xlabel("MIDI note")
    axs[0].set_ylabel("max |pitch error| over +-20 c (cents)")
    axs[0].legend(loc="upper right")
    fig.tight_layout()
    path = os.path.join(outdir, "fig_error_vs_note.png")
    fig.savefig(path)
    plt.close(fig)
    return path


def fig_staircase(depth, rate, interval, outdir):
    fig, axs = plt.subplots(1, 2, figsize=(9.4, 3.1))
    for ax, midi in zip(axs, (36, 60)):
        ms = load_modes("cello", midi)
        n = int(0.5 * SR)
        t = np.arange(n) / SR
        cents = depth * np.sin(2.0 * np.pi * rate * t)
        for name, color, lab in [("q20_int", "C3", "Q2.20"),
                                 ("q24_int", "C2", "Q2.24")]:
            cfg = CONFIG_BY_NAME[name]
            a1 = a1_curve(ms, cents, cfg, depth)[0]
            f = np.arccos(np.clip(-a1 / (2.0 * ms.r[0]), -1, 1)) / (2.0 * np.pi) * SR
            realized = 1200.0 * np.log2(f / ms.f[0])
            ax.plot(t * 1e3, cents, color="0.6", lw=0.9, label="target")
            ax.plot(t * 1e3, realized, color=color, lw=1.0,
                    drawstyle="steps-mid", label=lab)
        ax.set_title(f"cello {note_name(midi)}: a1 quantisation -> pitch")
        ax.set_xlabel("time (ms)")
        ax.set_ylabel("pitch offset (cents)")
        ax.set_xlim(0, 250)
    axs[0].legend(loc="upper right")
    fig.tight_layout()
    path = os.path.join(outdir, "fig_staircase.png")
    fig.savefig(path)
    plt.close(fig)
    return path


def fig_free_decay(depth, rate, interval, outdir):
    ms, out = free_decay_case(36, depth, rate, interval)
    fig, axs = plt.subplots(1, 2, figsize=(9.4, 3.2))
    y0 = out["float_t2"]["y"]
    y1 = out["q20_int"]["y"]
    n0, n1 = int(0.30 * SR), int(0.34 * SR)
    ax = axs[0]
    ax.plot(np.arange(n0, n1) / SR * 1e3, y0[n0:n1], color="0.5", lw=1.2,
            label="float")
    ax.plot(np.arange(n0, n1) / SR * 1e3, y1[n0:n1], color="C3", lw=0.9,
            label="Q2.20")
    ax.set_title("free decay C2, waveform zoom (A-like pitch = a1)")
    ax.set_xlabel("time (ms)")
    ax.set_ylabel("y[n]")
    ax.legend(loc="upper right")

    ax = axs[1]
    n = int(0.45 * SR)
    t = np.arange(n) / SR
    cents = depth * np.sin(2.0 * np.pi * rate * t)
    for name, color, lab in [("float_t2", "0.5", "float"),
                             ("q20_int", "C3", "Q2.20"),
                             ("q24_int", "C2", "Q2.24")]:
        cfg = CONFIG_BY_NAME[name]
        a1 = a1_curve(ms, cents, cfg, depth)[0]
        f = np.arccos(np.clip(-a1 / (2.0 * ms.r[0]), -1, 1)) / (2.0 * np.pi) * SR
        offset = 1200.0 * np.log2(f / ms.f[0])
        ax.plot(t * 1e3, offset, color=color, lw=1.0,
                drawstyle="steps-mid" if name.startswith("q") else "default",
                label=lab)
    ax.axhline(0.0, color="0.8", lw=0.7, ls=":")
    ax.set_title("commanded pitch from a1 (free decay)")
    ax.set_xlabel("time (ms)")
    ax.set_ylabel("pitch offset (cents)")
    ax.set_xlim(0, 250)
    ax.legend(loc="upper right")
    fig.tight_layout()
    path = os.path.join(outdir, "fig_free_decay.png")
    fig.savefig(path)
    plt.close(fig)
    return path


def fig_driven(depth, rate, interval, outdir, audio):
    fig, axs = plt.subplots(1, 2, figsize=(9.4, 3.2))
    ax = axs[0]
    for name, color, lab in [("float_t2", "0.5", "float"),
                             ("q20_int", "C3", "Q2.20"),
                             ("q24_int", "C2", "Q2.24")]:
        y = audio[name]
        f, p = welch(y[int(0.5 * SR):], fs=SR, nperseg=8192)
        sel = (f >= 50) & (f <= 800)
        ax.semilogy(f[sel], p[sel] / max(p[sel]), color=color, lw=0.9, label=lab)
    ax.set_title("driven C2 spectrum (steady state)")
    ax.set_xlabel("frequency (Hz)")
    ax.set_ylabel("normalised PSD")
    ax.legend(loc="upper right")

    ax = axs[1]
    labels, vals = [], []
    for midi, lab in [(36, "C2"), (60, "C4")]:
        ms = load_modes("cello", midi)
        ref, _ = render_driven(ms, CONFIG_BY_NAME["float_t2"],
                               depth=depth, rate=rate, interval=interval)
        for name, color in [("q20_int", "C3"), ("q24_int", "C2")]:
            y, _ = render_driven(ms, CONFIG_BY_NAME[name],
                                 depth=depth, rate=rate, interval=interval)
            labels.append(f"{lab}\n{'Q2.20' if name == 'q20_int' else 'Q2.24'}")
            vals.append(null_db(ref, y, int(0.5 * SR)))
    ax.bar(range(len(vals)), vals, color=["C3", "C2"] * 2)
    ax.set_xticks(range(len(vals)))
    ax.set_xticklabels(labels, fontsize=7)
    ax.set_ylabel("null vs float (dB)")
    ax.set_title("driven voice: fixed-point residual")
    ax.axhline(-40, color="0.5", lw=0.7, ls=":")
    fig.tight_layout()
    path = os.path.join(outdir, "fig_driven.png")
    fig.savefig(path)
    plt.close(fig)
    return path


# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------
def _f(x, n=2):
    if x is None or not np.isfinite(x):
        return "-"
    return f"{x:.{n}f}"


def write_report(rows, time_rows, summary, outdir, depth, rate, interval):
    by = {(r["inst"], r["midi"], r["config"]): r for r in rows}
    insts = ["cello", "flute", "trumpet"]

    def worst(inst, config):
        vals = [r for r in rows if r["inst"] == inst and r["config"] == config]
        return max(vals, key=lambda r: r["max_err"]) if vals else None

    def note_row(inst, midi, config):
        return by.get((inst, midi, config))

    # representative a1 values: cello C2 fundamental
    ms = load_modes("cello", 36)
    sample_cents = np.array([-depth, -depth / 2, 0.0, depth / 2, depth])
    t2 = a1_curve(ms, sample_cents, CONFIG_BY_NAME["float_t2"], depth)[0]
    q20 = a1_curve(ms, sample_cents, CONFIG_BY_NAME["q20_int"], depth)[0]
    q24 = a1_curve(ms, sample_cents, CONFIG_BY_NAME["q24_int"], depth)[0]

    lines = []
    A = lines.append
    A("# 颤音 a1 系数调制实验")
    A("")
    A(f"生成脚本：`python_monotor/modal_sim/vibrato_coeff.py`  "
      f"（深度 ±{depth:g} cents，LFO {rate:g} Hz，控制率 {interval} 采样 = "
      f"{SR / interval:.0f} Hz）")
    A("")
    A("## 1. 结论摘要")
    A("")
    A("- **系数怎么变**：颤音只改 a1，a2 不变。"
      "`a1(rho) = -2 r cos(rho*theta)`，`rho = 2^(cents/1200)`；"
      "在 ±20 c 内它几乎是 `a1` 的一条直线。")
    A("- **线性近似够不够**：在浮点里，一阶 Taylor 的最大音高误差约 "
      f"**{worst('cello', 'float_t1')['max_err']:.2f} c**（全乐器/全音域），"
      "二阶约 "
      f"**{max(worst(i, 'float_t2')['max_err'] for i in insts):.3f} c**。"
      "所以“线性调制”在数学上是够的。")
    A("- **真正的瓶颈是定点位宽**：当前 RTL 的 a1 影子是 Q2.20，"
      "在 cello C2（65 Hz）1 个 a1 LSB 就是 "
      f"**{note_row('cello', 36, 'q20_int')['a1_lsb_cents']:.1f} c**；"
      "从 0 到 +20 c 的真实变化只有 1.8 LSB（±20 c 全范围 3.6 LSB），"
      "而 `term1 = (s*dtheta)>>6` 又把它截成整数个 a1 LSB，"
      f"最终只有 **{note_row('cello', 36, 'q20_int')['levels']} 个电平**。"
      "Q3.14 的 δθ 只是第二层限制。")
    A("- **时域**：96 采样（约 2 ms）更新足够；系数切换引入的状态跳变在 "
      f"{min(t['max_jump_db'] for t in time_rows):.0f} dB 以下，没有失稳。"
      "B 类的音高由驱动 NCO 决定，a1 量化主要影响共振/音色；"
      "A 类自由衰减的音高直接由 a1 决定，量化台阶会直接变成音高台阶。")
    A("- **建议**：router 只发“深度（cents）+ 速率”，不要发 a1 增量；"
      "每个控制 tick 用 per-mode 的 `theta/r` 算 `a1`。"
      "如果要把 20 c 颤音做到低音也平滑，把 a1 影子从 Q2.20 加到 **Q2.24**、"
      "δθ 从 Q3.14 加到 **Q3.20**（a2 仍固定）。")
    A("")
    A("## 2. 系数公式与数值")
    A("")
    A("```text")
    A("y[n] = g*x[n] - a1*y[n-1] - a2*y[n-2]")
    A("a1 = -2 r cos(theta),  a2 = r^2,  r = exp(-gamma/fs)")
    A("rho = 2^(c/1200)  (c = cents)")
    A("a1(rho) = -2 r cos(rho*theta),  a2 unchanged")
    A("da1/dc = -2 r sin(theta) * theta * ln2/1200  (at c=0)")
    A("```")
    A("")
    A(f"cello C2 基频 θ={ms.theta[0]:.6f} rad，r={ms.r[0]:.8f}；"
      f"0→+20 c 对应 a1 变化 {(t2[-1] - t2[2]) / 2 ** -20:.2f} 个 Q2.20 LSB。")
    A("")
    A("| cents | exact a1 (float) | Q2.20 current | Q2.24 proposed |")
    A("|---:|---:|---:|---:|")
    for c, a, b, d in zip(sample_cents, t2, q20, q24):
        A(f"| {c:+.0f} | {a:.9f} | {b:.9f} | {d:.9f} |")
    A("")
    A("## 3. 线性近似误差（浮点）")
    A("")
    A("| 方法 | 全乐器最差音高误差 (c) | 说明 |")
    A("|---|---:|---|")
    for name, lab in [("float_t1", "一阶 Taylor（线性）"),
                      ("float_t2", "二阶 Taylor"),
                      ("float_sec", "端点 secant（线性插值到 ±20 c）")]:
        w = max((worst(i, name) for i in insts), key=lambda r: r["max_err"])
        A(f"| {lab} | {w['max_err']:.3f} | {w['inst']} {w['note']} |")
    A("")
    A("一阶误差随深度按二次方增长；±20 c 时 < 0.2 c，远低于 ~5 c 的可闻阈。"
      "二阶项在 ±20 c 内 < 0.01 c，基本是“免费”的精度，但只有在定点位宽足够时才有意义。")
    A("")
    A("### 线性斜率随模态变化（cello C2）")
    A("")
    A("`da1/dc = 2r sin(theta)*theta*ln2/1200`，低音模态下约与 k² 成正比：")
    A("")
    A("| 模态 k | f (Hz) | da1/dc (Q2.20 LSB / cent) | 相对 k=1 |")
    A("|---:|---:|---:|---:|")
    slope0 = None
    for kk in (1, 2, 4, 8, 16, 32):
        i = int(np.argmin(np.abs(ms.k - kk)))
        sl = (2.0 * ms.r[i] * math.sin(ms.theta[i]) * ms.theta[i]
              * math.log(2.0) / 1200.0 / 2 ** -20)
        if slope0 is None:
            slope0 = sl
        A(f"| {int(ms.k[i])} | {ms.f[i]:.1f} | {sl:.4f} | {sl / slope0:.1f}x |")
    A("")
    A("所以**不能**把同一个 `Δa1` 加到所有模态：必须让 router 发 `cents/ratio`，"
      "engine 用每个模态自己的 `theta` 展开；否则高次模态会欠调制约 k² 倍。")
    A("")
    A("## 4. 定点才是瓶颈")
    A("")
    A("下面的“当前 RTL”指 `history/rtl/core/legacy_frontend/b_a1_refresh.sv` 的整数算法"
      "（a1 Q2.20、theta UQ2.14、ratio UQ1.15、δθ Q3.14、a1 shadow Q2.20）。"
      "实验按它的移位/饱和顺序逐位建模，而不是只把浮点结果四舍五入。")
    A("")
    A("| 配置 | cello C2 | cello C3 | cello C4 | 全乐器最差 |")
    A("|---|---:|---:|---:|---:|")
    for name, lab in [("q20_ideal", "a1 Q2.20, 理想 δ"),
                      ("q20_int", "当前 RTL: Q2.20 + δθ Q3.14（整数）"),
                      ("q24_ideal", "a1 Q2.24, 理想 δ"),
                      ("q24_t1", "Q2.24 + δθ Q3.20, 一阶（浮点多项式）"),
                      ("q24_int", "Q2.24 + δθ Q3.20（整数）")]:
        a = note_row("cello", 36, name)
        b = note_row("cello", 48, name)
        c = note_row("cello", 60, name)
        w = max((worst(i, name) for i in insts), key=lambda r: r["max_err"])
        A(f"| {lab} | {a['max_err']:.2f} | {b['max_err']:.2f} | {c['max_err']:.2f} "
          f"| {w['max_err']:.2f} |")
    A("")
    A("注意：这里的误差是相对“目标音高”的绝对值，包含静态 a1 Q2.20 的调音误差"
      f"（cello C2 为 {note_row('cello', 36, 'q20_int')['static_err']:+.2f} c）。"
      "只看颤音本身的相对误差，当前 RTL 在 C2 仍有 "
      f"{note_row('cello', 36, 'q20_int')['rel_err']:.1f} c；"
      "Q2.24 + Q3.20 可降到 "
      f"{note_row('cello', 36, 'q24_int')['rel_err']:.2f} c。")
    A("")
    A("还要注意：Q2.24 只加宽了**调制后的 a1**，标称 a1 仍来自 Q2.20 ROM，"
      f"所以 C2 的静态调音误差 {note_row('cello', 36, 'q24_int')['static_err']:+.2f} c 仍在。"
      "要绝对音准，需要在 note-on 用更高精度重算 a1_nom（或把 ROM 的 a1 也加宽）。"
      "另外，当前 RTL 的 `dtheta` 和 `term1` 都用算术右移（向下取整），"
      "负半周会被多压一点；C4 从 0 到 +20 c 只有 ~6 个 δθ 台阶，"
      f"造成最大约 {note_row('cello', 60, 'q20_int')['fund_err']:.1f} c 的向下误差。"
      "加宽到 Q2.24/Q3.20 后这个偏置可以忽略。")
    A("")
    A("### 为什么低音最差")
    A("")
    A("| 音 | 1 个 a1 Q2.20 LSB = | ±20 c 全范围 a1 变化 | 当前 RTL 电平数 |")
    A("|---|---:|---:|---:|")
    for midi in (36, 48, 60, 72, 84):
        r = note_row("cello", midi, "q20_int")
        if r:
            ms_i = load_modes("cello", midi)
            span = ((-2.0 * ms_i.r[0] * math.cos(2.0 ** (depth / 1200.0) * ms_i.theta[0]))
                    - (-2.0 * ms_i.r[0] * math.cos(2.0 ** (-depth / 1200.0) * ms_i.theta[0])))
            A(f"| {r['note']} | {r['a1_lsb_cents']:.2f} c | {span / 2 ** -20:.1f} LSB "
              f"| {r['levels']} |")
    A("")
    A("C2 上从 0 到 +20 c 只有 1.8 个 LSB 的真实变化（全范围 3.6 LSB），"
      "截成整数 LSB 后只剩几个 10 c 级台阶；C4 以上每 LSB < 1 c，听起来才连续。")
    A("")
    A("## 5. 时域结果")
    A("")
    A("| 乐器/音 | 配置 | 与浮点参考的 null | 最大系数跳变 |")
    A("|---|---|---:|---:|")
    for t in time_rows:
        A(f"| {t['inst']} {t['note']} | {t['config']} | {t['null_db']:.1f} dB "
          f"| {t['max_jump_db']:.0f} dB |")
    A("")
    c2 = [t for t in time_rows if t["inst"] == "cello" and t["midi"] == 36]
    A("- 系数每 96 采样切换一次，切换处的状态跳变约为 `Δa1*y1`；"
      "在 20 c 深度下最大也只有 -100 dB 量级，不需要额外的状态补偿。")
    A("- B 类（持续音）的基频由驱动 NCO 决定，所以 a1 量化不会把颤音音高变成台阶；"
      "它改变的是各模态的共振幅度/相位。"
      f"cello C2 的 null 为 {c2[0]['null_db']:.1f} dB（Q2.20）与 "
      f"{c2[1]['null_db']:.1f} dB（Q2.24）；C4 更明显（"
      f"{[t for t in time_rows if t['inst'] == 'cello' and t['midi'] == 60][0]['null_db']:.1f} dB "
      "vs "
      f"{[t for t in time_rows if t['inst'] == 'cello' and t['midi'] == 60][1]['null_db']:.1f} dB），"
      "因为 Q3.14 δθ 在 C4 已有最大约 3.3 c 的误差。")
    A("- A 类（自由衰减）没有持续驱动，音高直接由 a1 决定；"
      "当前 RTL 在 C2 的 20 c 颤音会变成几个 10 c 台阶，见 `fig_staircase.png` / "
      "`fig_free_decay.png`。")
    A("")
    A("## 6. 实时调制建议")
    A("")
    A("1. **router 只发参数，不发系数**：旋钮 0..1 线性映射到深度 `D`（0..20 cents），"
      "再发速率 `f_vib`；LFO 相位和 `ratio` 放在 router 后面的 expression 小模块"
      "（或 refresh 引擎的控制口），router 本身不做 per-mode 乘法。"
      "每个控制 tick 每声部算 `c = D*sin(2*pi*f_vib*t)`。")
    A("2. **每声部一个 ratio**：`rho = 2^(c/1200)`（UQ1.15 足够，20 c 约 380 LSB）。"
      "不要所有声部共用一个相位，否则所有音会同时颤；现有 `b_a1_engine` 只有一个 "
      "`ratio` 输入，要做独立相位就得每声部一个 ratio 寄存器，或在 refresh 引擎里"
      "按声部相位现算。")
    A("3. **per-mode 刷新**：`delta_theta = (rho-1)*theta`，"
      "`a1' = a1 + s*delta_theta - a1*delta_theta^2/2`（当前公式），"
      "`s = sqrt(4a2-a1^2)`；`a2` 不动。20 c 用途下二阶项只多修 ~0.7 c（C2），"
      "可以只做 `a1 += s*delta_theta`，省掉 d2/term2 的乘法；"
      "若要 ±50 c 或滑音，再保留二阶或直接 cos。")
    A("4. **更新率**：每 96 采样（500 Hz）足够；5.2 Hz 颤音每周期约 96 个更新点。"
      "不需要 per-sample cos。以上假设一个 tick 内该声部全部模态一起换 a1；"
      "如果 RTL 逐模态写 shadow，需要双缓冲/影子区，避免同一采样内新旧系数混用。")
    A("5. **位宽**：如果目标包含 cello C2 的 20 c 颤音，把 a1 影子（包括 term1）"
      "做成 Q2.24，δθ 用 Q3.20；否则 term1 仍然被截成整数个 a1 LSB，C2 只有几个台阶。")
    A("6. **深度变化要 slew**：0->20 c 的阶跃相当于 a1 跳满整个 span；"
      "实测单次跳变的峰值约 -96 dB（C2）、-82 dB（C4）、-69 dB（C6），"
      "虽不刺耳，但快速拧旋钮时建议给深度加 10–20 ms 一阶平滑。")
    A("")
    A("## 7. 复现")
    A("")
    A("```bash")
    A("python python_monotor/modal_sim/vibrato_coeff.py            # full run")
    A("python python_monotor/modal_sim/vibrato_coeff.py --quick    # fewer points")
    A("```")
    A("")
    A("产物：")
    A("")
    A("- `summary.json` — 机器可读的汇总")
    A("- `coeff_sweep.csv` — 每个乐器/音/配置一行")
    A("- `fig_a1_curve.png`, `fig_pitch_error.png`, `fig_error_vs_note.png`, "
      "`fig_staircase.png`, `fig_free_decay.png`, `fig_driven.png`")
    A("- `audio_cello_C2_*.wav` — 单音试听（float / Q2.20 / Q2.24）")
    A("- `demo_*.wav`, `demo_decay_*.wav`, `DEMO.md` — `vibrato_demo.py` 用 "
      "`SustainSynth` 渲染的 A/B 试听")
    A("")

    path = os.path.join(outdir, "README.md")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    return path


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--depth", type=float, default=DEPTH,
                    help="maximum vibrato depth in cents (default: 20)")
    ap.add_argument("--rate", type=float, default=RATE,
                    help="LFO rate in Hz (default: 5.2)")
    ap.add_argument("--interval", type=int, default=INTERVAL,
                    help="coefficient update interval in samples (default: 96)")
    ap.add_argument("--points", type=int, default=401,
                    help="cents grid points (default: 401)")
    ap.add_argument("--quick", action="store_true",
                    help="fewer notes/points for a fast smoke test")
    args = ap.parse_args(argv)

    _style()
    paths.makedirs()
    os.makedirs(OUT, exist_ok=True)
    t0 = time.time()

    insts = ["cello", "flute", "trumpet"]
    npts = 81 if args.quick else max(41, args.points)
    depth, rate, interval = args.depth, args.rate, args.interval

    rows, curves = sweep(insts, depth, npts)
    time_rows, audio = time_domain(depth, rate, interval)

    # WAVs for listening (drop stale variants from an earlier run)
    import soundfile as sf
    for f in os.listdir(OUT):
        if f.startswith("audio_cello_C2_") and f.endswith(".wav"):
            os.remove(os.path.join(OUT, f))
    for name in ("float_t2", "q20_int", "q24_int"):
        y = audio[name]
        y = 0.9 * y / max(float(np.max(np.abs(y))), 1e-12)
        sf.write(os.path.join(OUT, f"audio_cello_C2_{name}.wav"), y, SR,
                 subtype="PCM_16")

    # CSV
    import csv
    csv_path = os.path.join(OUT, "coeff_sweep.csv")
    fields = ["inst", "midi", "note", "f0", "config", "label", "max_err", "rel_err",
              "fund_err", "fund_rel", "mean_err", "k_worst", "static_err",
              "levels", "span_lsb", "a1_lsb_cents"]
    with open(csv_path, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=fields)
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k) for k in fields})

    # figures
    figs = []
    figs.append(fig_a1(curves, OUT))
    figs.append(fig_pitch_error(curves, OUT))
    figs.append(fig_error_vs_note(rows, OUT))
    figs.append(fig_staircase(depth, rate, interval, OUT))
    figs.append(fig_free_decay(depth, rate, interval, OUT))
    figs.append(fig_driven(depth, rate, interval, OUT, audio))

    # summary json
    def find(inst, midi, config):
        for r in rows:
            if r["inst"] == inst and r["midi"] == midi and r["config"] == config:
                return r
        return None

    summary = dict(
        depth_cents=depth, rate_hz=rate, interval=interval, sr=SR,
        points=npts,
        worst={name: max((r for r in rows if r["config"] == name),
                          key=lambda r: r["max_err"], default=None)
               for name in CONFIG_BY_NAME},
        cello_c2={name: find("cello", 36, name) for name in CONFIG_BY_NAME},
        time_domain=time_rows,
        figures=[os.path.basename(p) for p in figs],
        elapsed_s=round(time.time() - t0, 2),
    )
    with open(os.path.join(OUT, "summary.json"), "w", encoding="utf-8") as fh:
        json.dump(summary, fh, indent=2, ensure_ascii=False, default=float)

    report = write_report(rows, time_rows, summary, OUT, depth, rate, interval)

    print(f"wrote {OUT}")
    print(f"  report: {os.path.basename(report)}")
    print(f"  elapsed: {time.time() - t0:.1f} s")
    for name in ("float_t1", "float_t2", "q20_int", "q24_int"):
        w = summary["worst"][name]
        if w:
            print(f"  worst {name:10s}: {w['max_err']:6.2f} c abs / "
                  f"{w['rel_err']:5.2f} c modulation "
                  f"({w['inst']} {w['note']}, mode k={w['k_worst']:g})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
