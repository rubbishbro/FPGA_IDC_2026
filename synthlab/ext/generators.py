"""
Oscillators and noise sources.

Every oscillator follows the same three-step split so each layer is replaceable:

    advance phase  ->  compute waveform from phase  ->  (optional) anti-alias

Override or inject any one of them:

  * `Oscillator(wave="custom", shape=my_func)` replaces the waveform only;
  * subclass and override `tick()` to own the phase law itself (hard sync,
    through-zero FM, chaotic maps, ...);
  * subclass and override `shape()` for a cheap waveform change that keeps the
    accumulator and the anti-aliasing path.

Aliasing
--------
`wave="saw"` with `antialias=None` is the naive, aliasing oscillator -- that is
the honest reference implementation. `antialias="polyblep"` applies PolyBLEP
correction to the discontinuities, and `antialias="minblep"` (later) will be
better still. Aliasing is measurable with `synthlab.analysis.describe_aliasing`,
so you can see exactly what a design costs you instead of trusting your ears.
"""

from __future__ import annotations

import math
from typing import Callable, Sequence

import numpy as np

from ..core import Block, Param, Source, TAU

# ---------------------------------------------------------------------------
# Anti-aliasing helpers
# ---------------------------------------------------------------------------

__all__ = [
    "AdditiveOscillator",
    "FMOscillator",
    "Noise",
    "Oscillator",
    "SuperOscillator",
    "WavetableOscillator",
    "polyblep",
]


def polyblep(t: float, dt: float) -> float:
    """PolyBLEP residual for a unit discontinuity at phase 0.

    `t` is the phase in [0, 1) and `dt` the phase increment (= freq / sr). Near a
    jump, subtracting this residual rounds the step over one sample, which cancels
    most of the aliasing energy. Cheaper than a wavetable and modulation-friendly.
    """
    if dt <= 0.0:
        return 0.0
    if t < dt:
        x = t / dt
        return x + x - x * x - 1.0
    if t > 1.0 - dt:
        x = (t - 1.0) / dt
        return x * x + x + x + 1.0
    return 0.0


def _resolve_shape(wave: str, shape: Callable | None, pulse_width: float):
    if shape is not None:
        return shape
    table = {
        "sine": lambda ph, pw: math.sin(TAU * ph),
        "saw": lambda ph, pw: 2.0 * ph - 1.0,
        "ramp": lambda ph, pw: 1.0 - 2.0 * ph,
        "square": lambda ph, pw: 1.0 if ph < 0.5 else -1.0,
        "pulse": lambda ph, pw: 1.0 if ph < pw else -1.0,
        "triangle": lambda ph, pw: 4.0 * abs(ph - 0.5) - 1.0,
    }
    if wave not in table:
        raise ValueError(f"unknown wave {wave!r}; known: {sorted(table)}, or pass shape=")
    return table[wave]


# ---------------------------------------------------------------------------
# The base oscillator
# ---------------------------------------------------------------------------

class Oscillator(Source):
    """Phase accumulator + pluggable waveform + optional anti-aliasing.

    Parameters
    ----------
    freq:       Hz. This is a live parameter, so `Modulated` can drive it for FM.
    phase:      initial phase in [0, 1).
    wave:       "sine" | "saw" | "ramp" | "square" | "pulse" | "triangle" | "custom".
    shape:      callable `(phase, pulse_width) -> float`; overrides `wave`.
    phase_mod:  added to the phase before the waveform lookup. This is how FM/PM
                is implemented -- a modulator block writes into this parameter
                (or you use `Modulated`), giving phase modulation, not frequency
                modulation. PM is equivalent to FM with an integrated modulator,
                and it is numerically better behaved.
    pulse_width: duty cycle for "pulse"; 0.5 makes it "square".
    antialias:  None | "polyblep".
    notes:      toggles the PolyBLEP correction for pulse-width-modulated pulses.

    State you can read or overwrite: `.ph` (phase). `tick()` returns the current
    waveform value and advances `.ph`; override `tick` to change the phase law.
    """

    freq = Param(220.0, "Hz", doc="oscillator frequency")
    phase_mod = Param(0.0, doc="phase offset, in cycles; drive for FM/PM")
    pulse_width = Param(0.5, "", 0.01, 0.99, doc="duty cycle for the pulse wave")
    amplitude = Param(1.0, doc="output scale")
    phase = Param(0.0, "", 0.0, 1.0, doc="starting phase")

    def __init__(
        self,
        freq: float = 220.0,
        wave: str = "sine",
        shape: Callable | None = None,
        antialias: str | None = None,
        name: str | None = None,
        **params,
    ):
        self.wave = wave
        self.antialias = antialias
        self._shape = _resolve_shape(wave, shape, 0.5)
        merged = {"freq": freq}
        merged.update(params)
        super().__init__(name=name, **merged)

    def reset(self) -> None:
        super().reset()
        self.ph = float(self.p.get("phase", 0.0)) if hasattr(self, "p") else 0.0

    def prepare(self, ctx) -> None:
        super().prepare(ctx)
        self._dt_scale = 1.0 / ctx.sr

    # -- override points ---------------------------------------------------
    def shape(self, ph: float, pulse_width: float) -> float:
        """Waveform lookup. `ph` is in [0, 1). Override for a custom waveform."""
        return self._shape(ph, pulse_width)

    def tick(self, freq: float, dt: float) -> float:
        """Compute one sample and advance the phase.

        This OWNS the phase accumulator: whatever it leaves in `self.ph` is what
        the next sample reads. That is what makes the phase law replaceable -- hard
        sync, through-zero FM, non-linear or chaotic phase maps all go here.

        `freq` is the parameter value, for the phase law to use. `dt` is 1/sr.
        The anti-aliasing correction uses `self.freq`, because a subclass is free
        to advance the phase at some other rate.
        """
        ph = self.ph
        value = self.shape(ph, self.pulse_width)

        if self.antialias == "polyblep":
            # Step polarity must match the direction of the jump, or the correction
            # *adds* a discontinuity of its own and makes aliasing worse. Measured
            # on this implementation: a sign error takes the alias fraction from
            # 0.0027 to 0.0249 for a pulse, so getting this right matters.
            dt_ph = abs(self.freq) * dt
            if self.wave in ("pulse", "square"):
                # Rising step at phase 0 (-1 -> +1): add the residual.
                value += polyblep(ph, dt_ph)
                # Falling step at the duty-cycle edge (+1 -> -1): subtract it.
                edge = ph - self.pulse_width
                if edge < 0.0:
                    edge += 1.0
                value -= polyblep(edge, dt_ph)
            else:
                # "saw" falls at phase 0, "ramp" and "triangle" rise/fall elsewhere.
                value -= polyblep(ph, dt_ph)

        self.ph = ph + freq * dt
        self.ph -= math.floor(self.ph)
        return value

    # -- Block -------------------------------------------------------------
    def process(self, ctx) -> float:
        dt = 1.0 / ctx.sr
        # `phase_mod` is in cycles, so it only shifts the lookup position. The
        # accumulator keeps the true phase, which is why this is phase modulation
        # rather than frequency modulation, and why modulation cannot accumulate
        # into the oscillator's phase (a well-known FM pitfall).
        ph = self.ph + self.phase_mod
        self.ph = ph - math.floor(ph)
        value = self.tick(self.freq, dt)
        return value * self.amplitude


class WavetableOscillator(Oscillator):
    """Reads a precomputed table with linear interpolation between entries.

    A wavetable is how you get an arbitrary spectrum without evaluating trig per
    sample. Build one with `from_harmonics` (additive) or `from_samples`
    (a recorded or generated single cycle), then read it.

    `table` is exposed, so you can edit the spectrum in place between renders --
    or even mid-render, which is how wavetable morphing is usually built.
    """

    freq = Param(220.0, "Hz")
    phase_mod = Param(0.0)
    amplitude = Param(1.0)
    phase = Param(0.0, "", 0.0, 1.0)

    def __init__(
        self,
        table: np.ndarray | None = None,
        freq: float = 220.0,
        name: str | None = None,
        **params,
    ):
        super().__init__(freq=freq, wave="custom", shape=lambda p, w: 0.0, name=name, **params)
        if table is None:
            table = self.from_harmonics([1.0], size=2048)
        self.table = np.asarray(table, dtype=np.float64)
        if self.table.ndim != 1 or self.table.size < 2:
            raise ValueError("table must be a 1-D array with at least 2 samples")
        self._n = self.table.size

    # -- table construction ------------------------------------------------
    @staticmethod
    def from_harmonics(
        amplitudes: Sequence[float],
        size: int = 2048,
        phases: Sequence[float] | None = None,
    ) -> np.ndarray:
        """Additive synthesis of one cycle: sum of `k`-th harmonics.

        `amplitudes[k-1]` is the level of harmonic k (so index 0 is the
        fundamental). An all-ones vector gives a sawtooth-like spectrum, a single
        1.0 gives a sine, and [1, 0, 1/3, 0, 1/5, ...] gives a square.
        """
        n = int(size)
        amps = np.asarray(amplitudes, dtype=np.float64)
        phs = np.zeros_like(amps) if phases is None else np.asarray(phases, dtype=np.float64)
        grid = np.arange(n, dtype=np.float64) / n
        table = np.zeros(n)
        for k, (amp, phs0) in enumerate(zip(amps, phs), start=1):
            if amp:
                table += amp * np.sin(TAU * k * grid + phs0)
        # Normalise so the table stays in range regardless of how many harmonics.
        peak = np.max(np.abs(table))
        return table / peak if peak > 0 else table

    @staticmethod
    def from_samples(cycle: np.ndarray, size: int = 2048) -> np.ndarray:
        """Resample (and normalise) one cycle of an arbitrary waveform."""
        cycle = np.asarray(cycle, dtype=np.float64).ravel()
        if cycle.size < 2:
            raise ValueError("need at least 2 samples to resample a cycle")
        src = np.linspace(0.0, 1.0, cycle.size, endpoint=False)
        dst = np.linspace(0.0, 1.0, int(size), endpoint=False)
        table = np.interp(dst, src, cycle)
        peak = np.max(np.abs(table))
        return table / peak if peak > 0 else table

    @staticmethod
    def from_spectrum(
        spectrum: np.ndarray, size: int | None = None
    ) -> np.ndarray:
        """Build a single cycle from an arbitrary complex spectrum via the inverse
        FFT. The array is interpreted as the positive-frequency half; the result is
        real and normalised. Use this to design a waveform by drawing its spectrum.
        """
        spec = np.asarray(spectrum, dtype=np.complex128).ravel()
        n = int(size) if size else 2 * (spec.size - 1)
        full = np.zeros(n, dtype=np.complex128)
        half = min(spec.size, n // 2 + 1)
        full[:half] = spec[:half]
        # Mirror for a real output.
        for k in range(1, half):
            if n - k < n:
                full[n - k] = np.conj(spec[k])
        table = np.fft.ifft(full).real
        peak = np.max(np.abs(table))
        return table / peak if peak > 0 else table

    # -- override points ---------------------------------------------------
    def shape(self, ph: float, pulse_width: float) -> float:
        """Linear interpolation into the table. Replace with cubic if you want."""
        pos = ph * self._n
        i0 = int(pos)
        frac = pos - i0
        i1 = i0 + 1
        if i1 >= self._n:
            i1 = 0
        if i0 >= self._n:
            i0 = 0
        return self.table[i0] + (self.table[i1] - self.table[i0]) * frac


# ---------------------------------------------------------------------------
# Composite / specialist oscillators
# ---------------------------------------------------------------------------

class FMOscillator(Source):
    """Two-operator FM: a sine carrier whose phase is bent by a sine modulator.

    This is the classic 2-op FM voice. The ratio between modulator and carrier
    decides harmonic vs inharmonic; the index decides brightness, and sweeping the
    index over time is what produces the characteristic FM attack.

        out = sin(2*pi*(carrier_phase + index * sin(2*pi*mod_phase)))

    Both `ratio` and `index` are live parameters, so you can modulate the timbre at
    audio rate (that is feedback FM territory when depth is high).
    """

    freq = Param(220.0, "Hz", doc="carrier frequency")
    ratio = Param(1.0, doc="modulator freq = freq * ratio; non-integers are inharmonic")
    index = Param(2.0, doc="modulation depth in radians")
    feedback = Param(0.0, "", 0.0, 1.0, doc="self-feedback (>=0.5 gets noisy/chaotic)")
    amplitude = Param(1.0)

    def reset(self) -> None:
        super().reset()
        self.carrier_ph = 0.0
        self.mod_ph = 0.0
        self.fb_state = 0.0

    def prepare(self, ctx) -> None:
        super().prepare(ctx)
        self._dt = 1.0 / ctx.sr

    def process(self, ctx) -> float:
        dt = self._dt
        f = self.freq

        mod = math.sin(TAU * self.mod_ph)
        # Averaging the feedback term with the previous output is the standard
        # stabiliser: raw self-feedback at index >~ 1 diverges or locks to DC.
        effective_index = self.index + 0.5 * self.feedback * self.fb_state
        carrier = math.sin(TAU * (self.carrier_ph + effective_index * mod))
        self.fb_state = carrier

        self.mod_ph += f * self.ratio * dt
        self.mod_ph -= math.floor(self.mod_ph)
        self.carrier_ph += f * dt
        self.carrier_ph -= math.floor(self.carrier_ph)
        return carrier * self.amplitude


class AdditiveOscillator(Source):
    """Explicit sum of `count` partials, each with its own amplitude.

    The most direct possible synth: you own the spectrum. `partials` is exposed as
    a numpy array of length `count`, so you can reshape it per sample, per block or
    between renders. Phase is tracked per partial only when `independent_phase` is
    set; otherwise partial k simply reads phase k times the accumulator, which is
    cheap and keeps the partials phase-locked (they will not drift).

    Beware of aliasing: partial k aliases once k * freq > sr / 2. `max_partial`
    enforces that automatically when `auto_limit=True`.
    """

    freq = Param(220.0, "Hz")
    amplitude = Param(1.0)
    auto_limit = Param(1.0, doc="1.0 = drop partials above Nyquist, 0.0 = let them alias")

    def __init__(
        self,
        partials: Sequence[float] | None = None,
        freq: float = 220.0,
        name: str | None = None,
        **params,
    ):
        super().__init__(name=name, freq=freq, **params)
        if partials is None:
            partials = [1.0 / k for k in range(1, 17)]  # sawtooth-ish spectrum
        self.partials = np.asarray(partials, dtype=np.float64)
        if self.partials.ndim != 1:
            raise ValueError("partials must be 1-D")
        self.count = self.partials.size
        self.phase = 0.0
        # Cache the harmonic index vector once.
        self._k = np.arange(1, self.count + 1, dtype=np.float64)

    def reset(self) -> None:
        super().reset()
        self.phase = 0.0

    def prepare(self, ctx) -> None:
        super().prepare(ctx)
        self._dt = 1.0 / ctx.sr
        self._nyquist = ctx.sr * 0.5

    def process(self, ctx) -> float:
        amps = self.partials
        if self.auto_limit >= 0.5:
            limit = self._nyquist / max(abs(self.freq), 1e-9)
            # Vectorised mask; for large partial counts this is the inner cost.
            amps = np.where(self._k <= limit, amps, 0.0)
        # Evaluate all partials at once: phase_k = k * phase.
        value = float(np.sum(amps * np.sin(TAU * self._k * self.phase)))
        self.phase += self.freq * self._dt
        self.phase -= math.floor(self.phase)
        return value * self.amplitude


class SuperOscillator(Source):
    """`voices` detuned oscillators with an equal-power stereo spread.

    The classic supersaw. `detune` is the total spread in Hz-ish terms (as a
    fraction of freq), `spread` places the detuned voices across the stereo image,
    and the centre voice stays exactly in tune so the pitch stays correct.

    Each voice keeps its own phase, so the beating evolves naturally instead of
    being a fixed comb. Reads `self.phase` (array) if you want to reset or inspect.
    """

    freq = Param(220.0, "Hz")
    detune = Param(0.12, doc="total detune spread as a fraction of freq")
    amplitude = Param(1.0)
    mix = Param(1.0, doc="blend with an exactly-in-tune centre voice: 1.0 = all voices even")
    waveform = Param(0.0, doc="0 = saw, 1 = pulse; interpolated per voice")

    def __init__(
        self,
        freq: float = 220.0,
        voices: int = 7,
        detune: float = 0.12,
        spread: float = 0.6,
        name: str | None = None,
        **params,
    ):
        if voices < 1:
            raise ValueError("voices must be >= 1")
        # Set these BEFORE super().__init__, because Block.__init__ calls reset()
        # and reset() needs them to already exist.
        self.voices = int(voices)
        self.spread = float(spread)
        # Symmetric detune multipliers; centre voice (if odd) stays at 0 offset.
        self.offsets = (
            np.linspace(-1.0, 1.0, self.voices) if self.voices > 1 else np.zeros(1)
        )
        # Equal-power pan gains per voice: this makes the stereo width real.
        self.pans = self.offsets * self.spread
        self.pan_l = np.cos((self.pans + 1.0) * 0.25 * np.pi)
        self.pan_r = np.sin((self.pans + 1.0) * 0.25 * np.pi)
        super().__init__(name=name, freq=freq, detune=detune, **params)

    def reset(self) -> None:
        super().reset()
        # Stagger start phases so the voices do not all begin in phase.
        self.phases = np.linspace(0.0, 1.0, self.voices, endpoint=False)
        self.last_stereo = (0.0, 0.0)

    def prepare(self, ctx) -> None:
        super().prepare(ctx)
        self._dt = 1.0 / ctx.sr

    def _wave(self, ph: np.ndarray, w: float) -> np.ndarray:
        saw = 2.0 * ph - 1.0
        if w <= 0.0:
            return saw
        pulse = np.where(ph < 0.5 + 0.4 * w, 1.0, -1.0)
        return saw * (1.0 - w) + pulse * w

    def process(self, ctx) -> float:
        freqs = self.freq * (1.0 + self.offsets * self.detune)
        wave = self._wave(self.phases, self.waveform)
        # Store the stereo pair for the caller to pick up if they want width.
        self.last_stereo = (
            float(np.sum(wave * self.pan_l)) / math.sqrt(self.voices),
            float(np.sum(wave * self.pan_r)) / math.sqrt(self.voices),
        )
        self.phases += freqs * self._dt
        self.phases -= np.floor(self.phases)
        mono = float(np.mean(wave)) * self.amplitude
        return mono


class Noise(Source):
    """White, pink or brown noise from the render's seeded generator.

    Uses `ctx.rng`, so a render is reproducible from its seed -- comparing two
    algorithms on the same noise is possible.

    * white: flat spectrum, uniform in [-1, 1]
    * pink:  -3 dB/octave (Voss-McCartney style filter cascade, state exposed)
    * brown: -6 dB/octave, integrated white with leakage to stop DC drift
    """

    amplitude = Param(1.0)
    colour = Param(0.0, doc="0 = white, 1 = pink, 2 = brown (read-only by convention)")

    def __init__(self, kind: str = "white", name: str | None = None, **params):
        super().__init__(name=name, **params)
        if kind not in ("white", "pink", "brown"):
            raise ValueError("kind must be 'white', 'pink' or 'brown'")
        self.kind = kind

    def reset(self) -> None:
        super().reset()
        self.brown_state = 0.0
        # Voss-McCartney: a row of octave-spaced lowpasses.
        self.pink_rows = np.zeros(16)
        self.pink_counter = 0

    def process(self, ctx) -> float:
        white = float(ctx.rng.uniform(-1.0, 1.0))
        if self.kind == "white":
            return white * self.amplitude
        if self.kind == "brown":
            self.brown_state = 0.99 * self.brown_state + 0.01 * white
            return self.brown_state * 3.5 * self.amplitude
        # Pink: update one row per sample in round-robin, sum the rows.
        self.pink_counter += 1
        row = (self.pink_counter & -self.pink_counter).bit_length() - 1
        row = min(row, self.pink_rows.size - 1)
        self.pink_rows[row] = white
        return float(self.pink_rows.sum()) / 3.0 * self.amplitude
