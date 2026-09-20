"""
Filters, with the coefficient maths exposed.

The point of this module is that you can see and replace the algebra, not just
turn a cutoff knob. Every filter therefore exposes:

  * `design(...)` -- the coefficient calculation, as a separate callable;
  * the coefficients themselves as instance attributes (`b0, b1, b2, a1, a2`);
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
    "LowpassGate",
    "MoogLadder",
    "OnePole",
    "OnePoleHighpass",
    "StateVariableFilter",
    "clamp_cutoff",
    "one_pole_alpha",
]


def clamp_cutoff(freq: float, sr: float, headroom: float = 0.45) -> float:
    """Keep a cutoff inside a stable range. RBJ biquads go unstable at Nyquist."""
    return float(min(max(freq, 1.0), sr * headroom))


def one_pole_alpha(cutoff: float, sr: float) -> float:
    """Smoothing coefficient for `y += a * (x - y)`.

    `a = 1 - exp(-2*pi*fc/sr)`, which is the exact discretisation of a first-order
    lowpass (better than the common 2*pi*fc/sr approximation, which drifts at high
    cutoffs).
    """
    return float(1.0 - math.exp(-TAU * cutoff / sr))


# ---------------------------------------------------------------------------
# Biquad: the reference RBJ design, fully open
# ---------------------------------------------------------------------------

class Biquad(Block):
    """Direct-form-I biquad using the Audio EQ Cookbook (RBJ) coefficients.

        y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] - a1*y[n-1] - a2*y[n-2]

    Form I is used rather than the more common transposed form II because you can
    read `x1, x2, y1, y2` directly and see the history terms the equation names.

    `mode` selects the response; `q` is the resonance (0.707 = Butterworth, no
    peak). The coefficients are recomputed every sample from the live `cutoff` and
    `q` parameters, so audio-rate modulation of the cutoff works -- that is the
    whole point of a per-sample filter. Override `design()` to use your own
    topology (ladder, SVF, state-variable moog, ...) while keeping the same API.
    """

    cutoff = Param(1000.0, "Hz", doc="corner/centre frequency")
    q = Param(0.707, doc="resonance; 0.707 = maximally flat, higher = peak")
    gain_db = Param(0.0, "dB", doc="peak gain, used by peaking/shelf modes only")
    mode = Param(0.0, doc="see MODES; a float so it can be scheduled")
    mix = Param(1.0, "", 0.0, 1.0, doc="0 = dry, 1 = fully filtered")

    MODES = ("lowpass", "highpass", "bandpass", "notch", "peak", "lowshelf", "highshelf")

    def __init__(
        self,
        cutoff: float = 1000.0,
        q: float = 0.707,
        mode: str = "lowpass",
        name: str | None = None,
        **params,
    ):
        if mode not in self.MODES:
            raise ValueError(f"unknown mode {mode!r}; known: {self.MODES}")
        self.mode_name = mode
        super().__init__(name=name, cutoff=cutoff, q=q,
                         mode=float(self.MODES.index(mode)), **params)
        self.b0 = self.b1 = self.b2 = 1.0
        self.a1 = self.a2 = 0.0

    def reset(self) -> None:
        super().reset()
        self.x1 = self.x2 = self.y1 = self.y2 = 0.0

    # -- the maths you may want to replace ---------------------------------
    def design(self, cutoff: float, q: float, mode: str, gain_db: float, sr: float):
        """Return `(b0, b1, b2, a1, a2)` normalised so a0 = 1.

        This is the RBJ cookbook, written out rather than imported so you can edit
        it. `w0` is the digital corner frequency, `alpha` sets the bandwidth.
        """
        w0 = TAU * clamp_cutoff(cutoff, sr) / sr
        cw = math.cos(w0)
        sw = math.sin(w0)
        alpha = sw / (2.0 * max(q, 1e-6))
        A = 10.0 ** (gain_db / 40.0)

        if mode == "lowpass":
            b0 = (1.0 - cw) / 2.0
            b1 = 1.0 - cw
            b2 = b0
            a0 = 1.0 + alpha
            a1 = -2.0 * cw
            a2 = 1.0 - alpha
        elif mode == "highpass":
            b0 = (1.0 + cw) / 2.0
            b1 = -(1.0 + cw)
            b2 = b0
            a0 = 1.0 + alpha
            a1 = -2.0 * cw
            a2 = 1.0 - alpha
        elif mode == "bandpass":  # constant 0 dB peak gain
            b0 = alpha
            b1 = 0.0
            b2 = -alpha
            a0 = 1.0 + alpha
            a1 = -2.0 * cw
            a2 = 1.0 - alpha
        elif mode == "notch":
            b0 = 1.0
            b1 = -2.0 * cw
            b2 = 1.0
            a0 = 1.0 + alpha
            a1 = -2.0 * cw
            a2 = 1.0 - alpha
        elif mode == "peak":
            b0 = 1.0 + alpha * A
            b1 = -2.0 * cw
            b2 = 1.0 - alpha * A
            a0 = 1.0 + alpha / A
            a1 = -2.0 * cw
            a2 = 1.0 - alpha / A
        elif mode == "lowshelf":
            sq = 2.0 * math.sqrt(A) * alpha
            b0 = A * ((A + 1.0) - (A - 1.0) * cw + sq)
            b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cw)
            b2 = A * ((A + 1.0) - (A - 1.0) * cw - sq)
            a0 = (A + 1.0) + (A - 1.0) * cw + sq
            a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cw)
            a2 = (A + 1.0) + (A - 1.0) * cw - sq
        else:  # highshelf
            sq = 2.0 * math.sqrt(A) * alpha
            b0 = A * ((A + 1.0) + (A - 1.0) * cw + sq)
            b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cw)
            b2 = A * ((A + 1.0) + (A - 1.0) * cw - sq)
            a0 = (A + 1.0) - (A - 1.0) * cw + sq
            a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cw)
            a2 = (A + 1.0) - (A - 1.0) * cw - sq

        return b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0

    def magnitude_at(self, freq: float, sr: float = 48000.0) -> float:
        """Analytic |H(e^jw)| at `freq`, using the current coefficients.

        Evaluate this to plot or assert the response. It reads `self.b0..a2`, so to
        test a design without running audio, set the coefficients with `update()`
        and call this directly.
        """
        w = TAU * freq / sr
        z1 = complex(math.cos(-w), math.sin(-w))
        z2 = z1 * z1
        num = self.b0 + self.b1 * z1 + self.b2 * z2
        den = 1.0 + self.a1 * z1 + self.a2 * z2
        return float(abs(num / den)) if den != 0 else float("inf")

    def update(self, sr: float) -> None:
        """Recompute the coefficients from the live parameters."""
        mode = self.MODES[int(self.mode) % len(self.MODES)]
        self.b0, self.b1, self.b2, self.a1, self.a2 = self.design(
            self.cutoff, self.q, mode, self.gain_db, sr
        )

    # -- Block -------------------------------------------------------------
    def prepare(self, ctx) -> None:
        super().prepare(ctx)
        self.update(ctx.sr)

    def process(self, x: float, ctx=None) -> float:
        self.update(ctx.sr)
        y = (
            self.b0 * x
            + self.b1 * self.x1
            + self.b2 * self.x2
            - self.a1 * self.y1
            - self.a2 * self.y2
        )
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

    def reset(self) -> None:
        super().reset()
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

    def reset(self) -> None:
        super().reset()
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

    def reset(self) -> None:
        super().reset()
        self.z = 0.0

    def process(self, x: float, ctx=None) -> float:
        a = one_pole_alpha(clamp_cutoff(self.cutoff, ctx.sr), ctx.sr)
        self.z += a * (x - self.z)
        return x + (self.z - x) * self.mix


class OnePoleHighpass(Block):
    """Complement of `OnePole`: `y = x - lowpass(x)`. Good for stripping DC."""

    cutoff = Param(20.0, "Hz")
    mix = Param(1.0, "", 0.0, 1.0)

    def reset(self) -> None:
        super().reset()
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

    def reset(self) -> None:
        super().reset()
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
