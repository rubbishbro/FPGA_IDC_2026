"""body_fixed_point.py -- independent integer model of the shared body filter.

This is the ``fixed_point.py`` analogue for the body module (verification chain
step 2 for the body filter): the RTL in ``rtl/router/parts/body_biquad.sv`` must
match this model bit-for-bit.  It is deliberately self-contained and does **not**
import ``gen_body_rom`` or the RTL; the coefficients are re-derived from a
float SOS with the same frozen rule.

Frozen local format (updated for the router's 5-section guitar body):

    coefficient   signed Q4.27, 32 bit   floor(c*2**27 + 0.5)
    external x/y  signed 64 bit          (input lattice of ``in_sum``)
    internal      signed (64+G) bit,     G = ``guard_bits``
    accumulator   >= 100 bit (exact integer sum; products are (64+G)+32 bit)
    Direct Form I, one order-2 section at a time:
        xin = input << G
        acc = b0*x + b1*x1 + b2*x2 - a1*y1 - a2*y2
        y   = clamp_s(64+G)( (acc + 2**26) >> 27 )        # Q(G)
    only the last section converts back:
        out = clamp_s64( (y + 2**(G-1)) >> G )

Why Q4.27 and not Q2.30: the guitar cascade needs five sections and its largest
magnitude coefficient is 6.94, i.e. 6.94*2**30 = 7.45e9, which does not fit the
signed 32-bit coefficient word.  Q4.27 tops out at 2**31/2**27 = 16.0 and the
largest quantised word here is 9.32e8, so every coefficient fits with 2.3x of
headroom.

The rounding is floor (arithmetic right shift), so Python's ``>>`` matches the
RTL ``>>>`` including for negative ``acc``.  Saturation is per section, to the
signed (64+G)-bit range, and the (possibly clamped) result feeds the next
section.  The final 64-bit saturation of the last section is folded into
``out_sat[last]`` together with that section's own (64+G)-bit saturation.
``guard_bits=0`` recovers the plain Q0/64-bit DFI used for the earlier numeric
pre-check.

The section count is taken from the coefficient set (guitar = 5, the older
4-section piano/banjo image = 4); instruments with fewer real sections pad
their tail with passthrough rows (b0 = 1, rest 0), which is what
``body_router`` emits.  ``load_coeffs_from_mem`` still describes the legacy
4-section Q2.30 ``rtl/rom/body_coeff.mem`` image written by
``gen_body_rom.py`` -- the router path no longer uses a ROM.
"""

from __future__ import annotations

import math

COEFF_FRAC = 27
COEFF_BITS = 32
STATE_FRAC = 27
STATE_BITS = 64
SECTIONS = 5                 # 路由器腔体滤波器段数（吉他 5 段，不足补直通）
TAPS = ("b0", "b1", "b2", "a1", "a2")

QSCALE = float(1 << COEFF_FRAC)
QMIN = -(1 << (COEFF_BITS - 1))
QMAX = (1 << (COEFF_BITS - 1)) - 1

LOW = -(1 << (STATE_BITS - 1))
HIGH = (1 << (STATE_BITS - 1)) - 1
ROUND = 1 << (COEFF_FRAC - 1)

# 老 ROM 镜像（rtl/rom/body_coeff.mem）仍然是 4 乐器 x 4 段 x 5 tap 的 Q2.30
ROM_INSTRUMENTS = 4
ROM_SECTIONS = 4
ROM_WORDS = len(TAPS) * ROM_SECTIONS * ROM_INSTRUMENTS          # 80
WORDS_PER_INSTRUMENT = len(TAPS) * ROM_SECTIONS                 # 20
INSTRUMENTS = ("guitar", "piano", "banjo", "mandolin")


class BodyFixedPointError(Exception):
    """Bad SOS or an out-of-range quantised coefficient."""


def quant_coeff(c: float) -> int:
    """Signed Q4.27, round half up; reject non-finite / out-of-range."""
    c = float(c)
    if not math.isfinite(c):
        raise BodyFixedPointError(f"non-finite coefficient {c!r}")
    q = math.floor(c * QSCALE + 0.5)
    if q < QMIN or q > QMAX:
        raise BodyFixedPointError(
            f"coefficient {c!r} -> {q} outside signed {COEFF_BITS}-bit Q4."
            f"{COEFF_FRAC}")
    return int(q)


def quantise_sos(sos, sections: int | None = None) -> list[list[int]]:
    """Normalise each section by a0 and return rows of ``[b0,b1,b2,a1,a2]``."""
    rows = []
    for row in sos:
        if len(row) != 6:
            raise BodyFixedPointError(f"SOS section must have 6 taps, got {len(row)}")
        b0, b1, b2, a0, a1, a2 = (float(v) for v in row)
        if a0 == 0.0:
            raise BodyFixedPointError(f"zero a0 in SOS section {row!r}")
        rows.append([quant_coeff(b0 / a0), quant_coeff(b1 / a0),
                     quant_coeff(b2 / a0), quant_coeff(a1 / a0),
                     quant_coeff(a2 / a0)])
    want = SECTIONS if sections is None else int(sections)
    if len(rows) != want:
        raise BodyFixedPointError(
            f"SOS has {len(rows)} sections, expected {want}")
    return rows


def load_coeffs_from_mem(path: str, instrument: int) -> list[list[int]]:
    """Read the legacy 80-word Q2.30 body ROM and return one instrument's rows.

    Layout: ``line = instrument*20 + section*5 + tap``; words are signed Q2.30
    hex.  Kept for the old ``rtl/rom/body_coeff.mem`` image only -- the router
    takes its coefficients from ``body_router``'s constant LUT, not from a ROM.
    """
    if not 0 <= instrument < ROM_INSTRUMENTS:
        raise BodyFixedPointError(f"instrument {instrument} outside 0..3")
    words = []
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            words.append(int(line, 16))
    if len(words) != ROM_WORDS:
        raise BodyFixedPointError(
            f"{path}: {len(words)} words, expected {ROM_WORDS}")
    base = instrument * WORDS_PER_INSTRUMENT
    out = []
    for s in range(ROM_SECTIONS):
        off = base + s * len(TAPS)
        row = [words[off + k] for k in range(len(TAPS))]
        for k, v in enumerate(row):
            if v >= (1 << (COEFF_BITS - 1)):
                row[k] = v - (1 << COEFF_BITS)
        out.append(row)
    return out


class BodyFixedPoint:
    """Bit-exact DFI integer model of one body filter cascade.

    ``sections`` comes from the coefficient set: ``guard_bits`` (default 4) are
    extra internal fractional bits, so the four/five sections recurse on
    signed(64+G) state while the external input/output stay signed 64.
    ``guard_bits=0`` is the plain Q0/64-bit model.
    """

    def __init__(self, sos=None, coeffs=None, validate: bool = True,
                 guard_bits: int = 4):
        if coeffs is not None:
            self.c = [list(int(v) for v in row) for row in coeffs]
            if not self.c or any(len(r) != len(TAPS) for r in self.c):
                raise BodyFixedPointError("coeffs must be N rows of 5 ints")
        elif sos is not None:
            self.c = quantise_sos(sos, sections=len(sos))
        else:
            raise BodyFixedPointError("pass sos= or coeffs=")
        self.sections = len(self.c)
        if guard_bits < 0:
            raise BodyFixedPointError("guard_bits must be >= 0")
        self.guard_bits = int(guard_bits)
        self.state_bits = 64 + self.guard_bits
        self.s_low = -(1 << (self.state_bits - 1))
        self.s_high = (1 << (self.state_bits - 1)) - 1
        self.final_round = (1 << (self.guard_bits - 1)) if self.guard_bits else 0
        if validate:
            self._check_stable()
        self.reset()

    # ------------------------------------------------------------------
    def _check_stable(self):
        S = 1 << COEFF_FRAC
        for s, (b0, b1, b2, a1, a2) in enumerate(self.c):
            ok = (S + a1 + a2 > 0) and (S - a1 + a2 > 0) and (S - a2 > 0)
            if not ok:
                raise BodyFixedPointError(
                    f"section {s} unstable: a=({a1},{a2})")

    def reset(self):
        self.state = [[0, 0, 0, 0] for _ in range(self.sections)]
        self.sat_count = 0

    # "clear history, keep coefficients" -- the same operation here, named to
    # mirror the RTL's clear_valid contract.
    def clear(self):
        self.reset()

    # ------------------------------------------------------------------
    def process_sample(self, x: int):
        """One input sample -> ``(y, sat_mask, sat_count_of_frame)``."""
        G = self.guard_bits
        x = int(x) << G
        mask = 0
        for s, (b0, b1, b2, a1, a2) in enumerate(self.c):
            x1, x2, y1, y2 = self.state[s]
            acc = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            raw = (acc + ROUND) >> COEFF_FRAC
            y = raw
            if y > self.s_high:
                y = self.s_high
            elif y < self.s_low:
                y = self.s_low
            if y != raw:
                mask |= 1 << s
            self.state[s] = [x, x1, y, y1]
            x = y
        # only the last section folds the internal Q(G) result back
        rawf = (x + self.final_round) >> G if G else x
        yf = rawf
        if yf > HIGH:
            yf = HIGH
        elif yf < LOW:
            yf = LOW
        if yf != rawf:
            mask |= 1 << (self.sections - 1)
        n = bin(mask).count("1")
        self.sat_count += n
        return yf, mask, n

    # ------------------------------------------------------------------
    def process(self, seq):
        """Return ``(ys, masks)`` for a whole input sequence."""
        ys, masks = [], []
        for v in seq:
            y, mask, _ = self.process_sample(v)
            ys.append(y)
            masks.append(mask)
        return ys, masks
