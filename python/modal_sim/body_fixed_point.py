"""body_fixed_point.py -- independent integer model of the shared body filter.

This is the ``fixed_point.py`` analogue for the body module (verification chain
step 2 for the body filter): the RTL in ``rtl/core/body_filter.sv`` must match
this model bit-for-bit.  It is deliberately self-contained and does **not**
import ``gen_body_rom`` or the RTL; the coefficients are re-derived from a
float SOS with the same frozen rule.

Frozen local format (``rtl/body_design.md`` section 2, updated by the parent
for the guard-bit variant):

    coefficient   signed Q2.30, 32 bit   floor(c*2**30 + 0.5)
    external x/y  signed 64 bit, Q30
    internal      signed (64+G) bit, Q(30+G), G = ``guard_bits``
    accumulator   >= 100 bit (exact integer sum; products are (64+G)+32 bit)
    Direct Form I, one order-2 section at a time:
        xin = input << G
        acc = b0*x + b1*x1 + b2*x2 - a1*y1 - a2*y2
        y   = clamp_s(64+G)( (acc + 2**29) >> 30 )        # Q(30+G)
    only the last section converts back:
        out = clamp_s64( (y + 2**(G-1)) >> G )

The rounding is floor (arithmetic right shift), so Python's ``>>`` matches the
RTL ``>>>`` including for negative ``acc``.  Saturation is per section, to the
signed (64+G)-bit range, and the (possibly clamped) result feeds the next
section.  The final 64-bit saturation of section 3 is folded into ``out_sat[3]``
together with section 3's own (64+G)-bit saturation.  ``guard_bits=0`` recovers
the plain Q30/64-bit DFI used for the earlier numeric pre-check.
"""

from __future__ import annotations

import math

COEFF_FRAC = 30
COEFF_BITS = 32
STATE_FRAC = 30
STATE_BITS = 64
SECTIONS = 4
TAPS = ("b0", "b1", "b2", "a1", "a2")

QSCALE = float(1 << COEFF_FRAC)
QMIN = -(1 << (COEFF_BITS - 1))
QMAX = (1 << (COEFF_BITS - 1)) - 1

LOW = -(1 << (STATE_BITS - 1))
HIGH = (1 << (STATE_BITS - 1)) - 1
ROUND = 1 << (COEFF_FRAC - 1)

ROM_WORDS = len(TAPS) * SECTIONS * 4          # 80
WORDS_PER_INSTRUMENT = len(TAPS) * SECTIONS   # 20
INSTRUMENTS = ("guitar", "piano", "banjo", "mandolin")


class BodyFixedPointError(Exception):
    """Bad SOS or an out-of-range quantised coefficient."""


def quant_coeff(c: float) -> int:
    """Signed Q2.30, round half up; reject non-finite / out-of-range."""
    c = float(c)
    if not math.isfinite(c):
        raise BodyFixedPointError(f"non-finite coefficient {c!r}")
    q = math.floor(c * QSCALE + 0.5)
    if q < QMIN or q > QMAX:
        raise BodyFixedPointError(
            f"coefficient {c!r} -> {q} outside signed {COEFF_BITS}-bit Q2."
            f"{COEFF_FRAC}")
    return int(q)


def quantise_sos(sos) -> list[list[int]]:
    """Normalise each section by a0 and return 4 rows of ``[b0,b1,b2,a1,a2]``."""
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
    if len(rows) != SECTIONS:
        raise BodyFixedPointError(
            f"SOS has {len(rows)} sections, expected {SECTIONS}")
    return rows


def load_coeffs_from_mem(path: str, instrument: int) -> list[list[int]]:
    """Read the merged 80-word body ROM and return one instrument's 4 sections.

    Layout: ``line = instrument*20 + section*5 + tap``; words are signed Q2.30
    hex.  Used to cross-check that the RTL/generator agree on the image.
    """
    if not 0 <= instrument < 4:
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
    for s in range(SECTIONS):
        off = base + s * len(TAPS)
        row = [words[off + k] for k in range(len(TAPS))]
        for k, v in enumerate(row):
            if v >= (1 << (COEFF_BITS - 1)):
                row[k] = v - (1 << COEFF_BITS)
        out.append(row)
    return out


class BodyFixedPoint:
    """Bit-exact DFI integer model of one shared 4-section body filter.

    ``guard_bits`` (default 4) are extra internal fractional bits: the external
    input/output stay signed64/Q30 while the four sections recurse on
    signed(64+G)/Q(30+G) state.  ``guard_bits=0`` is the plain Q30 model.
    """

    def __init__(self, sos=None, coeffs=None, validate: bool = True,
                 guard_bits: int = 4):
        if coeffs is not None:
            self.c = [list(int(v) for v in row) for row in coeffs]
            if len(self.c) != SECTIONS or any(len(r) != len(TAPS) for r in self.c):
                raise BodyFixedPointError("coeffs must be 4 rows of 5 ints")
        elif sos is not None:
            self.c = quantise_sos(sos)
        else:
            raise BodyFixedPointError("pass sos= or coeffs=")
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
        self.state = [[0, 0, 0, 0] for _ in range(SECTIONS)]
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
        # only the last section folds the internal Q(30+G) result back to Q30
        rawf = (x + self.final_round) >> G if G else x
        yf = rawf
        if yf > HIGH:
            yf = HIGH
        elif yf < LOW:
            yf = LOW
        if yf != rawf:
            mask |= 1 << 3
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
