"""
Filters, with the coefficient maths exposed.

The point of this module is that you can see and replace the algebra, not just
turn a cutoff knob.

Design and filtering are separate. The `design_*` functions turn a description of a
response (a corner frequency, a resonance) into the five biquad coefficients;
`Biquad` applies coefficients and nothing else, so it never has to know what
response they came from. Every filter also exposes:

  * the coefficients themselves as parameters (`b0, b1, b2, a1, a2`);
  * the per-sample state (`x1, x2, y1, y2`, or `ic1, ic2` for the SVF);
  * `magnitude_at(freq)` -- the analytic transfer function, so you can plot or
    assert the response instead of guessing.

Cutoff values are clamped just below Nyquist; a filter asked for 30 kHz at
48 kHz is silently moved rather than producing NaNs.
"""

from __future__ import annotations

import math

import numpy as np

from ..core import Block, Param, TAU


__all__ = [
    "Biquad",
    "DESIGNS",
    "LowpassGate",
    "MoogLadder",
    "OnePole",
    "OnePoleHighpass",
    "StateVariableFilter",
    "biquad",
    "clamp_cutoff",
    "design_bandpass",
    "design_highpass",
    "design_highshelf",
    "design_lowpass",
    "design_lowshelf",
    "design_notch",
    "design_peak",
    "one_pole_alpha",
]


def one_pole_alpha(cutoff: float, sr: float) -> float:
    """Smoothing coefficient for `y += a * (x - y)`.

    `a = 1 - exp(-2*pi*fc/sr)`, which is the exact discretisation of a first-order
    lowpass (better than the common 2*pi*fc/sr approximation, which drifts at high
    cutoffs).
    """
    return float(1.0 - math.exp(-TAU * cutoff / sr))


# ---------------------------------------------------------------------------
# Biquad coefficient design (RBJ Audio EQ Cookbook)
# ---------------------------------------------------------------------------
#
# These are plain functions, not a block: they turn a description of a response
# into the five coefficients, and `Biquad` applies whatever coefficients it is
# given. Keeping them apart means you can design a filter, inspect or edit the
# numbers, save them, or run a filter whose coefficients came from somewhere else
# entirely.

def _alpha(cutoff: float, q: float, sr: float):
    """`(w0, cos w0, sin w0, alpha)` for a corner at `cutoff` with resonance `q`."""
    w0 = TAU * clamp_cutoff(cutoff, sr) / sr
    cw = math.cos(w0)
    sw = math.sin(w0)
    return w0, cw, sw, sw / (2.0 * max(q, 1e-6))


def _normalise(b0, b1, b2, a0, a1, a2):
    return (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)


def design_lowpass(cutoff: float, q: float = 0.707, sr: float = 48_000.0):
    """RBJ lowpass. `q = 0.707` is maximally flat; higher peaks at the corner."""
    _, cw, _, alpha = _alpha(cutoff, q, sr)
    b0 = (1.0 - cw) / 2.0
    return _normalise(b0, 1.0 - cw, b0, 1.0 + alpha, -2.0 * cw, 1.0 - alpha)


def design_highpass(cutoff: float, q: float = 0.707, sr: float = 48_000.0):
    """RBJ highpass."""
    _, cw, _, alpha = _alpha(cutoff, q, sr)
    b0 = (1.0 + cw) / 2.0
    return _normalise(b0, -(1.0 + cw), b0, 1.0 + alpha, -2.0 * cw, 1.0 - alpha)


def design_bandpass(cutoff: float, q: float = 0.707, sr: float = 48_000.0):
    """RBJ bandpass with constant 0 dB peak gain (so it is 1.0 at the centre)."""
    _, cw, _, alpha = _alpha(cutoff, q, sr)
    return _normalise(alpha, 0.0, -alpha, 1.0 + alpha, -2.0 * cw, 1.0 - alpha)


def design_notch(cutoff: float, q: float = 0.707, sr: float = 48_000.0):
    """RBJ notch."""
    _, cw, _, alpha = _alpha(cutoff, q, sr)
    return _normalise(1.0, -2.0 * cw, 1.0, 1.0 + alpha, -2.0 * cw, 1.0 - alpha)


def design_peak(cutoff: float, q: float = 0.707, gain_db: float = 6.0,
                sr: float = 48_000.0):
    """RBJ peaking EQ: `gain_db` at the centre, unity far away."""
    _, cw, _, alpha = _alpha(cutoff, q, sr)
    A = 10.0 ** (gain_db / 40.0)
    return _normalise(1.0 + alpha * A, -2.0 * cw, 1.0 - alpha * A,
                      1.0 + alpha / A, -2.0 * cw, 1.0 - alpha / A)


def design_lowshelf(cutoff: float, q: float = 0.707, gain_db: float = 6.0,
                    sr: float = 48_000.0):
    """RBJ low shelf: `gain_db` below `cutoff`."""
    A = 10.0 ** (gain_db / 40.0)
    w0 = TAU * clamp_cutoff(cutoff, sr) / sr
    cw = math.cos(w0)
    sw = math.sin(w0)
    alpha = sw / (2.0 * max(q, 1e-6))
    sq = 2.0 * math.sqrt(A) * alpha
    return _normalise(
        A * ((A + 1.0) - (A - 1.0) * cw + sq),
        2.0 * A * ((A - 1.0) - (A + 1.0) * cw),
        A * ((A + 1.0) - (A - 1.0) * cw - sq),
        (A + 1.0) + (A - 1.0) * cw + sq,
        -2.0 * ((A - 1.0) + (A + 1.0) * cw),
        (A + 1.0) + (A - 1.0) * cw - sq)


def design_highshelf(cutoff: float, q: float = 0.707, gain_db: float = 6.0,
                     sr: float = 48_000.0):
    """RBJ high shelf: `gain_db` above `cutoff`."""
    A = 10.0 ** (gain_db / 40.0)
    w0 = TAU * clamp_cutoff(cutoff, sr) / sr
    cw = math.cos(w0)
    sw = math.sin(w0)
    alpha = sw / (2.0 * max(q, 1e-6))
    sq = 2.0 * math.sqrt(A) * alpha
    return _normalise(
        A * ((A + 1.0) + (A - 1.0) * cw + sq),
        -2.0 * A * ((A - 1.0) + (A + 1.0) * cw),
        A * ((A + 1.0) + (A - 1.0) * cw - sq),
        (A + 1.0) - (A - 1.0) * cw + sq,
        2.0 * ((A - 1.0) - (A + 1.0) * cw),
        (A + 1.0) - (A - 1.0) * cw - sq)


#: The RBJ designs by name, for the convenience constructors below.
DESIGNS = {
    "lowpass": design_lowpass,
    "highpass": design_highpass,
    "bandpass": design_bandpass,
    "notch": design_notch,
    "peak": design_peak,
    "lowshelf": design_lowshelf,
    "highshelf": design_highshelf,
}


def clamp_cutoff(freq: float, sr: float, headroom: float = 0.45) -> float:
    """Keep a cutoff inside a stable range. RBJ biquads go unstable at Nyquist."""
    return float(min(max(freq, 1.0), sr * headroom))


def biquad(mode: str, cutoff: float, q: float = 0.707, gain_db: float = 0.0,
           sr: float = 48_000.0, **params) -> "Biquad":
    """A `Biquad` configured for one of the named RBJ responses.

    Thin convenience over `DESIGNS[mode]` + `Biquad`: the coefficients are worked
    out once, here, rather than by the filter. Use the functions directly if you
    want the numbers instead of the block.
    """
    try:
        design = DESIGNS[mode]
    except KeyError:
        raise ValueError(
            f"unknown mode {mode!r}; known: {sorted(DESIGNS)}"
        ) from None
    if mode in ("peak", "lowshelf", "highshelf"):
        coeffs = design(cutoff, q, gain_db, sr)
    else:
        coeffs = design(cutoff, q, sr)
    return Biquad(*coeffs, **params)


# ---------------------------------------------------------------------------
# Biquad: the filter itself, coefficients only
# ---------------------------------------------------------------------------

class Biquad(Block):
    """Direct-form-I biquad, driven purely by its coefficients.

        y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] - a1*y[n-1] - a2*y[n-2]

    Form I is used rather than the more common transposed form II because you can
    read `x1, x2, y1, y2` directly and see the history terms the equation names.

    The five coefficients are the parameters; `a0` is assumed to be 1 (normalise
    your design). Set them directly for a fixed filter::

        Biquad(0.2929, 0.5858, 0.2929, -0.1716, 0.0)      # 1 kHz lowpass

    or get them from a design:

        from synthlab.ext.processors import design_lowpass, Biquad
        Biquad(*design_lowpass(1000.0, 0.707, 48000.0))

    `biquad("lowpass", 1000.0)` does both in one call.

    Nothing is recomputed per sample, so these are constant coefficients unless you
    write them. To sweep a filter, modulate a parameter of a design function's
    output -- or write the coefficients from a `Modulated` -- rather than expecting
    the block to redraw itself from a cutoff.
    """

    b0 = Param(1.0, doc="feedforward coefficient of x[n]")
    b1 = Param(0.0, doc="feedforward coefficient of x[n-1]")
    b2 = Param(0.0, doc="feedforward coefficient of x[n-2]")
    a1 = Param(0.0, doc="feedback coefficient of y[n-1] (a0 is taken as 1)")
    a2 = Param(0.0, doc="feedback coefficient of y[n-2]")
    mix = Param(1.0, "", 0.0, 1.0, doc="0 = dry, 1 = fully filtered")

    def __init__(self, b0: float = 1.0, b1: float = 0.0, b2: float = 0.0,
                 a1: float = 0.0, a2: float = 0.0,
                 name: str | None = None, **params):
        super().__init__(name=name, b0=b0, b1=b1, b2=b2, a1=a1, a2=a2, **params)

    def reset(self, ctx) -> None:
        super().reset(ctx)
        self.x1 = self.x2 = self.y1 = self.y2 = 0.0

    def coefficients(self) -> tuple:
        """The five live coefficients as a tuple."""
        return (self.b0, self.b1, self.b2, self.a1, self.a2)

    def magnitude_at(self, freq: float, sr: float = 48_000.0) -> float:
        """Analytic |H(e^jw)| at `freq`, from the live coefficients."""
        w = TAU * freq / sr
        z1 = complex(math.cos(-w), math.sin(-w))
        z2 = z1 * z1
        num = self.b0 + self.b1 * z1 + self.b2 * z2
        den = 1.0 + self.a1 * z1 + self.a2 * z2
        return float(abs(num / den)) if den != 0 else float("inf")

    def process(self, x: float, ctx=None) -> float:
        y = (self.b0 * x
             + self.b1 * self.x1
             + self.b2 * self.x2
             - self.a1 * self.y1
             - self.a2 * self.y2)
        self.x2, self.x1 = self.x1, x
        self.y2, self.y1 = self.y1, y
        return x + (y - x) * self.mix


# ---------------------------------------------------------------------------
# State-variable filter: all responses at once
# ---------------------------------------------------------------------------

class StateVariableFilter(Block):
    """Chamberlin state-variable filter -- lowpass, bandpass, highpass and notch
    available simultaneously from the same two integrators.

        lp += f * bp
        hp  = x - lp - q * bp
        bp += f * hp

    `f = 2*sin(pi*fc/sr)` is the standard Chamberlin tuning. The tuning is only
    accurate while `f` stays small (roughly fc < sr/6); beyond that the resonant
    frequency warps upward and the filter eventually blows up, which is why
    `stable` clamps it. Use `Biquad` when you need accurate tuning at high
    cutoffs, and this when you want several responses for free or a filter whose
    instability you can hear.

    Outputs are exposed as attributes after each sample: `.lp`, `.bp`, `.hp`,
    `.notch`. `output` selects which one `process` returns.
    """

    cutoff = Param(1000.0, "Hz")
    q = Param(1.0, doc="damping; larger = less resonant")
    drive = Param(1.0, doc="input gain before the filter, for saturation")
    output = Param(0.0, doc="0=lp, 1=bp, 2=hp, 3=notch")
    stable = Param(1.0, doc="1.0 clamps f to keep the integrators from diverging")

    def reset(self, ctx) -> None:
        super().reset(ctx)
        self.lp = self.bp = 0.0
        self.hp = self.notch = 0.0

    def coefficients(self, cutoff: float, sr: float) -> float:
        """`f = 2*sin(pi*fc/sr)`, clamped so the loop stays stable."""
        fc = clamp_cutoff(cutoff, sr, headroom=0.25)
        f = 2.0 * math.sin(math.pi * fc / sr)
        if self.stable >= 0.5:
            f = min(f, 1.0)
        return float(f)

    def process(self, x: float, ctx=None) -> float:
        f = self.coefficients(self.cutoff, ctx.sr)
        q = max(self.q, 1e-4)
        x = x * self.drive

        self.lp += f * self.bp
        self.hp = x - self.lp - q * self.bp
        self.bp += f * self.hp
        self.notch = self.lp + self.hp

        which = int(self.output) % 4
        if which == 0:
            return self.lp
        if which == 1:
            return self.bp
        if which == 2:
            return self.hp
        return self.notch


# ---------------------------------------------------------------------------
# Moog ladder: the classic 4-pole, non-linear
# ---------------------------------------------------------------------------

class MoogLadder(Block):
    """Stroud/Stilson-style digital model of the Moog ladder.

    Four one-pole lowpasses in series inside a feedback loop, with a non-linearity
    in the loop that is what gives the Moog its character: as the input gets
    louder the resonance compresses instead of ringing forever.

        x  = x - 4 * fb * (s4 - 0.5 * x)        # feedback, partially compensated
        s1 += f * (x  - s1)
        s2 += f * (s1 - s2)
        s3 += f * (s2 - s3)
        s4 += f * (s3 - s4)

    `f = 2*sin(pi*fc/sr)` detunes at high cutoffs (same caveat as the SVF), and
    `drive` pushes the tanh saturation harder. Stage state is exposed as
    `s1..s4` so you can inspect or seed the resonator.
    """

    cutoff = Param(1000.0, "Hz")
    resonance = Param(0.0, "", 0.0, 1.0, doc="0 = no resonance, 1 = self-oscillating")
    drive = Param(1.0, doc="input gain into the ladder non-linearity")
    mix = Param(1.0, "", 0.0, 1.0)

    def reset(self, ctx) -> None:
        super().reset(ctx)
        self.s1 = self.s2 = self.s3 = self.s4 = 0.0

    def coefficients(self, cutoff: float, sr: float):
        """Return `(f, fb)`: the integrator gain and the feedback amount.

        `fb = res * (1 - 0.15*f^2)` is the common compensation for the way `f`
        interacts with the feedback path at high cutoffs.

        `resonance` is clamped to its documented 0..1. Beyond 1 the loop gain at the
        resonant frequency exceeds unity and the filter diverges to NaN within a
        second -- `Block.__init__` warns about the out-of-range value, and clamping
        here keeps the output finite instead of poisoning the whole render.
        """
        fc = clamp_cutoff(cutoff, sr, headroom=0.45)
        f = 2.0 * math.sin(math.pi * fc / sr)
        resonance = min(max(float(self.resonance), 0.0), 1.0)
        fb = resonance * (1.0 - 0.15 * f * f)
        return float(f), float(fb)

    def process(self, x: float, ctx=None) -> float:
        f, fb = self.coefficients(self.cutoff, ctx.sr)
        x = math.tanh(x * self.drive)

        x = x - 4.0 * fb * (self.s4 - 0.5 * x)
        self.s1 += f * (x - self.s1)
        self.s2 += f * (self.s1 - self.s2)
        self.s3 += f * (self.s2 - self.s3)
        self.s4 += f * (self.s3 - self.s4)
        return x * (1.0 - self.mix) + self.s4 * self.mix


# ---------------------------------------------------------------------------
# One-pole building blocks
# ---------------------------------------------------------------------------

class OnePole(Block):
    """Single-pole lowpass: `y += a*(x - y)`, `a = 1 - exp(-2*pi*fc/sr)`.

    The cheapest useful filter, and the right tool for smoothing a parameter
    (see `synthlab.modulation.Smoothed`). Exposes `.z` (the integrator state).
    """

    cutoff = Param(1000.0, "Hz")
    mix = Param(1.0, "", 0.0, 1.0)

    def reset(self, ctx) -> None:
        super().reset(ctx)
        self.z = 0.0

    def process(self, x: float, ctx=None) -> float:
        a = one_pole_alpha(clamp_cutoff(self.cutoff, ctx.sr), ctx.sr)
        self.z += a * (x - self.z)
        return x + (self.z - x) * self.mix


class OnePoleHighpass(Block):
    """Complement of `OnePole`: `y = x - lowpass(x)`. Good for stripping DC."""

    cutoff = Param(20.0, "Hz")
    mix = Param(1.0, "", 0.0, 1.0)

    def reset(self, ctx) -> None:
        super().reset(ctx)
        self.z = 0.0

    def process(self, x: float, ctx=None) -> float:
        a = one_pole_alpha(clamp_cutoff(self.cutoff, ctx.sr), ctx.sr)
        self.z += a * (x - self.z)
        y = x - self.z
        return x + (y - x) * self.mix


class LowpassGate(Block):
    """Vactrol-style lowpass gate: a filter whose cutoff tracks the input level.

    This is the West-Coast "tone follows loudness" behaviour, and it is the reason
    a LPG sounds percussive without an explicit envelope. `response` sets how fast
    the internal envelope follows, `depth` how far the cutoff drops when quiet.
    """

    cutoff = Param(2000.0, "Hz", doc="cutoff when fully open")
    response = Param(0.001, "s", doc="attack time of the level follower")
    depth = Param(0.9, "", 0.0, 1.0, doc="how much the cutoff closes at low level")

    def reset(self, ctx) -> None:
        super().reset(ctx)
        self.env = 0.0
        self.z = 0.0

    def process(self, x: float, ctx=None) -> float:
        a = one_pole_alpha(1.0 / max(self.response, 1e-6), ctx.sr)
        level = abs(x)
        self.env += a * (level - self.env)
        # Cutoff scales from a low floor up to the full cutoff with level.
        fc = self.cutoff * (1.0 - self.depth) + self.cutoff * self.depth * self.env
        fc = float(np.clip(fc, 20.0, ctx.sr * 0.45))
        k = one_pole_alpha(fc, ctx.sr)
        self.z += k * (x - self.z)
        return self.z
