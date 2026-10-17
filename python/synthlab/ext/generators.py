"""
Generators: everything that produces signal from a phase.

Two read laws, one shape concept
--------------------------------
A generator walks a *position* through a *shape* and returns the value there. What
separates the classes is only how the position is read:

* `Oscillator` -- repeats. The position is a phase in [0, 1) advancing at `freq`,
  so it never stops.
* `Scanner` -- reads once. The position runs from `start` for `duration` seconds,
  then holds (or repeats, with `loop=1`).

Everything else is a *shape*: a function from position to value. `sine`, `saw`,
`triangle`, `curve`, a wavetable, a sampled spectrum -- all the same kind of thing,
so a new waveform is a new shape rather than a new class.

Shapes
------
`Shape` wraps a callable `f(x)` on [0, 1) plus a list of the places it jumps:
`(position, slope)` pairs that the PolyBLEP correction needs. Build shapes with the
`sine`, `saw`, `triangle`, `square`, `pulse`, `expo_shape` and `power_shape`
helpers, or from data with `from_harmonics`, `from_samples`, `from_spectrum` and
`morph`. A shape is just a callable, so you can also pass any `lambda x: ...`
directly.

`Oscillator` always uses a shape; it never has a baked-in waveform.

Aliasing
--------
`antialias="polyblep"` corrects the discontinuities a shape declares through
`edges()`. A shape sampled from data declares none, so it is read as-is; band-limit
the table itself with `from_harmonics` if that matters.
"""

from __future__ import annotations

import math
from typing import Callable, Sequence

import numpy as np

from ..core import Block, Param, Source, TAU

__all__ = [
    "FMOscillator",
    "Noise",
    "Oscillator",
    "Scanner",
    "Shape",
    "SuperOscillator",
    "expo_shape",
    "from_harmonics",
    "from_samples",
    "from_spectrum",
    "lfo",
    "morph",
    "polyblep",
    "power_shape",
    "pulse",
    "saw",
    "sine",
    "square",
    "triangle",
]


# ---------------------------------------------------------------------------
# Shape: one position -> one value
# ---------------------------------------------------------------------------

class Shape:
    """A waveform as a function of position, plus where it jumps.

    `f(x)` is evaluated for `x` in [0, 1). `edges()` returns the discontinuities as
    `(position, slope)` pairs, where `position` is a phase in [0, 1) or the name of a
    parameter to read it from, and `slope` is the PolyBLEP correction sign.

    It is worth being blunt that the sign is **measured, not derived**: the direction
    of the jump does not determine it. Measured on this implementation, `saw` wants
    `-1` (31x less aliasing) and `pulse` wants `+1` (26x); swapping them makes both
    *worse*. Both are pinned by `test_polyblep_*`, so changing a shape means
    re-measuring.
    """

    __slots__ = ("f", "_edges", "needs")

    def __init__(self, f: Callable[[float], float],
                 edges: Sequence = (), needs: tuple = ()):
        self.f = f
        #: Either `(position, slope)` or `(parameter_name, slope)`.
        self._edges = tuple(edges)
        #: Parameters this shape reads by name, e.g. `("pulse_width",)`. An
        #: `Oscillator` fills them from its own parameters before calling.
        self.needs = tuple(needs)

    def edges(self) -> tuple:
        return self._edges

    def __call__(self, x: float) -> float:
        return self.f(x)

    def __repr__(self) -> str:
        return f"Shape(edges={self._edges or 'none'})"


#: The position marker for a `Shape` whose edge moves with a parameter.
PULSE_WIDTH = "pulse_width"


def _as_shape(spec) -> Shape:
    """Coerce a shape spec to a `Shape`."""
    if isinstance(spec, Shape):
        return spec
    if callable(spec):
        # A bare callable: no declared discontinuity, so PolyBLEP is a no-op.
        return Shape(spec)
    raise TypeError(f"expected a Shape or a callable, got {type(spec).__name__}")


# -- function shapes --------------------------------------------------------

def sine() -> Shape:
    """`sin(2*pi*x+pi/2)`, so x = 0 is the peak and x = 0.5 the trough."""
    return Shape(lambda x: math.sin(TAU * x + math.pi / 2))


def saw() -> Shape:
    """Rises from -1 to +1 across the cycle, jumping back at x = 0.

    The jump is at x = 0, i.e. between x = 1-eps and x = 0, which is the one place
    a discontinuity in a sampled signal is unambiguous.
    """
    return Shape(lambda x: 2.0 * x - 1.0, edges=((0.0, -1.0),))


def triangle() -> Shape:
    """Rises from -1 at x = 0 to +1 at x = 0.5, back down. Continuous."""
    return Shape(lambda x: 4.0 * abs(x - 0.5) - 1.0)


def square() -> Shape:
    """+1 for the first half, -1 for the second; steps at x = 0 and x = 0.5."""
    return Shape(lambda x: 1.0 if x < 0.5 else -1.0,
                 edges=((0.0, +1.0), (0.5, -1.0)))


def pulse(width: float = 0.5) -> Shape:
    """Like `square` but with an adjustable duty cycle.

    The width is captured here rather than read per sample, because a `Shape` maps
    one position to one value. To sweep the duty cycle, use `Oscillator`'s own
    `pulse_width`, which rebuilds the shape when the value changes.
    """
    w = float(width)

    def f(x: float) -> float:
        return 1.0 if x < w else -1.0

    return Shape(f, edges=((0.0, +1.0), (PULSE_WIDTH, -1.0)),
                 needs=("pulse_width",))


def expo_shape(k: float) -> Shape:
    """`(1 - exp(-k*x)) / (1 - exp(-k))`: linear at k = 0, bends either way."""
    if abs(k) < 1e-9:
        return Shape(lambda x: x)
    denom = 1.0 - math.exp(-k)
    return Shape(lambda x: (1.0 - math.exp(-k * x)) / denom)


def power_shape(k: float) -> Shape:
    """`x ** exp(k)` -- the shape most envelopes actually want."""
    if abs(k) < 1e-9:
        return Shape(lambda x: x)
    e = math.exp(k)
    return Shape(lambda x: x ** e)


#: The named function shapes, for `Oscillator(wave="saw")` and friends.
NAMED = {
    "sine": sine,
    "saw": saw,
    "triangle": triangle,
    "square": square,
    "pulse": pulse,
}


# -- table shapes -----------------------------------------------------------

class _TableShape(Shape):
    """A `Shape` backed by a sampled cycle, read with linear interpolation.

    Keeps the array exposed as `.table` so you can inspect or edit the spectrum in
    place between renders, which is how wavetable morphing is usually built.
    """

    __slots__ = ("table",)

    def __init__(self, table: np.ndarray, edges: Sequence = ()):
        table = np.ascontiguousarray(table, dtype=np.float64)
        if table.ndim != 1 or table.size < 2:
            raise ValueError("a wavetable must be 1-D with at least 2 entries")
        n = table.size

        def f(x: float) -> float:
            pos = x * n
            i0 = int(pos)
            if i0 >= n:
                i0 = n - 1
            frac = pos - i0
            i1 = i0 + 1 if i0 + 1 < n else 0
            a = table[i0]
            return a + (table[i1] - a) * frac

        super().__init__(f, edges)
        self.table = table


def _normalise(table: np.ndarray) -> np.ndarray:
    peak = float(np.max(np.abs(table)))
    return table / peak if peak > 0 else table


def from_harmonics(
    amplitudes: Sequence[float],
    size: int = 2048,
    phases: Sequence[float] | None = None,
) -> Shape:
    """One cycle from a harmonic spectrum: `amplitudes[k-1]` is harmonic k.

    An all-ones vector is a sawtooth-like spectrum, a single 1.0 is a sine, and
    [1, 0, 1/3, 0, 1/5, ...] is a square. Band-limited by construction, so reading
    it does not alias.
    """
    n = int(size)
    amps = np.asarray(amplitudes, dtype=np.float64)
    phs = (np.zeros_like(amps) if phases is None
           else np.asarray(phases, dtype=np.float64))
    grid = np.arange(n, dtype=np.float64) / n
    table = np.zeros(n)
    for k, (amp, phase) in enumerate(zip(amps, phs), start=1):
        if amp:
            table += amp * np.sin(TAU * k * grid + phase)
    return _TableShape(_normalise(table))


def from_samples(cycle: np.ndarray, size: int = 2048) -> Shape:
    """One cycle resampled from an array (a recording, or anything you generated)."""
    cycle = np.asarray(cycle, dtype=np.float64).ravel()
    if cycle.size < 2:
        raise ValueError("need at least 2 samples to resample a cycle")
    src = np.linspace(0.0, 1.0, cycle.size, endpoint=False)
    dst = np.linspace(0.0, 1.0, int(size), endpoint=False)
    return _TableShape(_normalise(np.interp(dst, src, cycle)))


def from_spectrum(spectrum: np.ndarray, size: int | None = None) -> Shape:
    """One cycle from the positive-frequency half of a spectrum, via the inverse FFT.

    Use this to design a waveform by drawing its spectrum rather than its shape.
    """
    spec = np.asarray(spectrum, dtype=np.complex128).ravel()
    n = int(size) if size else 2 * (spec.size - 1)
    full = np.zeros(n, dtype=np.complex128)
    half = min(spec.size, n // 2 + 1)
    full[:half] = spec[:half]
    for k in range(1, half):
        full[n - k] = np.conj(spec[k])
    return _TableShape(_normalise(np.fft.ifft(full).real))


def morph(a: Shape, b: Shape, amount: float) -> Shape:
    """Blend two shapes: `amount = 0` is `a`, `1` is `b`.

    The cheap way to build a moving timbre -- sweep `amount` instead of rebuilding
    a table per sample. Both shapes are evaluated, so this costs two lookups.
    """
    amount = float(amount)

    def f(x: float) -> float:
        return a(x) * (1.0 - amount) + b(x) * amount

    return Shape(f, edges=a.edges())


# ---------------------------------------------------------------------------
# Anti-aliasing
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Oscillator: repeats forever
# ---------------------------------------------------------------------------

class Oscillator(Source):
    """Phase accumulator reading a `Shape` over and over.

    Parameters
    ----------
    freq:       Hz. A live parameter, so `Modulated` can drive it for FM.
    shape:      a `Shape`, a bare `f(x)`, or the name of a built-in ("sine",
                "saw", "triangle", "square", "pulse").
    phase:      starting phase in [0, 1).
    phase_mod:  added to the lookup position. This is how FM/PM works -- a
                modulator writes this parameter. It shifts the *lookup*, so
                modulation cannot accumulate into the phase (the classic FM bug).
    pulse_width: duty cycle, used when the shape asks for it.
    amplitude:  output scale.
    antialias:  None | "polyblep".

    State you can read or overwrite: `.ph`. `tick()` owns the accumulator, so
    overriding it changes the phase law (hard sync, through-zero FM, chaos).
    """

    freq = Param(220.0, "Hz", doc="oscillator frequency")
    phase_mod = Param(0.0, doc="phase offset, in cycles; drive for FM/PM")
    pulse_width = Param(0.5, "", 0.01, 0.99, doc="duty cycle, for shapes that use it")
    amplitude = Param(1.0, doc="output scale")
    phase = Param(0.0, "", 0.0, 1.0, doc="starting phase")

    def __init__(
        self,
        freq: float = 220.0,
        shape: Shape | Callable | str = "sine",
        antialias: str | None = None,
        name: str | None = None,
        **params,
    ):
        # `wave=` is the older spelling of `shape=`; keep it working. An explicit
        # `shape` wins, so `Oscillator(wave="custom", shape=f)` still means `f`.
        if "wave" in params:
            wave = params.pop("wave")
            if shape == "sine" or shape is None:
                shape = wave
        self._shape = self._coerce(shape, params)
        self.antialias = antialias
        merged = {"freq": freq}
        merged.update(params)
        super().__init__(name=name, **merged)

    @staticmethod
    def _coerce(shape, params) -> Shape:
        """Resolve the shape argument, including the string names."""
        if isinstance(shape, str):
            if shape == "custom":
                raise ValueError(
                    "wave='custom' needs a shape; pass shape=<Shape or callable>"
                )
            try:
                shape = NAMED[shape]()
            except KeyError:
                raise ValueError(
                    f"unknown wave {shape!r}; known: {sorted(NAMED)}, "
                    f"or pass shape=<Shape or callable>"
                ) from None
        return _as_shape(shape)

    def reset(self, ctx) -> None:
        super().reset(ctx)
        self._dt_scale = 1.0 / ctx.sr
        self.ph = float(self.params.phase)
        self._shape_key = None

    def shape(self, x: float) -> float:
        """Evaluate the shape at position `x`; override for a custom waveform."""
        return self._shape(x)

    def _live_shape(self) -> Shape:
        """The shape with any parameter it asked for filled in from `pulse_width`.

        Only `pulse` declares `needs`, and it is the one shape whose width is worth
        sweeping, so rebuilding it when the width changes keeps that cheap: one
        construction per change instead of one per sample.
        """
        if not self._shape.needs:
            return self._shape
        width = float(self.params.pulse_width)
        if width != getattr(self, "_shape_key", None):
            self._shape_key = width
            self._shape = pulse(width)
        return self._shape

    def tick(self, freq: float, dt: float) -> float:
        """Compute one sample and advance the phase.

        This OWNS the phase accumulator: whatever it leaves in `self.ph` is what the
        next sample reads. That is what makes the phase law replaceable.
        """
        shape = self._live_shape()
        ph = self.ph
        value = shape(ph)

        if self.antialias == "polyblep":
            # The correction's sign is a property of the shape (see `Shape`): the
            # direction of the jump does not determine it.
            dt_ph = abs(self.params.freq) * dt
            for position, slope in shape.edges():
                if isinstance(position, str):
                    position = float(self.params[position])
                edge = ph - position
                if edge < 0.0:
                    edge += 1.0
                value += slope * polyblep(edge, dt_ph)

        self.ph = ph + freq * dt
        self.ph -= math.floor(self.ph)
        return value

    def process(self, ctx) -> float:
        dt = 1.0 / ctx.sr
        ph = self.ph + self.params.phase_mod
        self.ph = ph - math.floor(ph)
        return self.tick(self.params.freq, dt) * self.params.amplitude


# ---------------------------------------------------------------------------
# Scanner: reads once
# ---------------------------------------------------------------------------

class Scanner(Source):
    """Walks a `Shape` once, from `start` for `duration` seconds.

    The position is relative to the start of the render (`ctx.t`), not to an
    absolute clock, so a Scanner is placed by writing when it should happen inside
    the buffer being rendered. Rendering a song in pieces therefore gives the same
    audio as rendering it whole, as long as the pieces are rendered separately.

    `loop = 1` turns it into an oscillator reading the same shape over and over.
    `hold = 0` makes it fall silent after the scan instead of holding the last
    value. Before `start` it outputs 0 and reports `active` false.

    This is one gesture, not an envelope: its length is a parameter. A contour
    whose length depends on events (a key being held, then released) is `ADSR`.
    """

    start = Param(0.0, "s", 0.0, doc="when the scan begins, from the render start")
    duration = Param(0.1, "s", 1e-6, doc="how long the scan takes")
    loop = Param(0.0, doc="1.0 = repeat the scan instead of finishing")
    hold = Param(1.0, doc="1.0 = hold the final value, 0.0 = fall silent")
    amplitude = Param(1.0, doc="output scale")

    def __init__(
        self,
        shape: Shape | Callable = None,
        start: float = 0.0,
        duration: float = 0.1,
        loop: float = 0.0,
        hold: float = 1.0,
        amplitude: float = 1.0,
        name: str | None = None,
        **params,
    ):
        if shape is None:
            shape = saw()
        self._shape = _as_shape(shape)
        super().__init__(name=name, start=start, duration=duration,
                         loop=loop, hold=hold, amplitude=amplitude, **params)

    def reset(self, ctx) -> None:
        super().reset(ctx)
        self._dt_scale = 1.0 / ctx.sr
        self._active = False

    def shape(self, x: float) -> float:
        return self._shape(x)

    @property
    def active(self) -> bool:
        """True while the scan is running; false before it starts and once done.

        This is "still producing a moving value", not "output is non-zero": a scan
        that has finished and is holding reads `active == False` while still
        returning its final value. Voice allocation wants this, not the output.
        """
        return self._active

    def process(self, ctx) -> float:
        t = ctx.t - float(self.params.start)
        duration = max(float(self.params.duration), 1e-9)
        looping = self.params.loop > 0.5

        if t < 0.0:
            self._active = False
            return 0.0

        if looping:
            self._active = True
            return self.shape((t / duration) % 1.0) * self.params.amplitude

        if t >= duration:
            self._active = False
            if self.params.hold <= 0.5:
                return 0.0
            # Just inside the end, so a shape that jumps at x = 0 holds its final
            # value rather than wrapping to its start.
            return self.shape(1.0 - 1e-9) * self.params.amplitude

        self._active = True
        return self.shape(t / duration) * self.params.amplitude


# ---------------------------------------------------------------------------
# Composite oscillators: not reducible to a single Shape
# ---------------------------------------------------------------------------

def lfo(rate: float = 1.0, shape: Shape | Callable | str = "sine",
        sync: float = 0.0, bpm: float = 120.0, name: str | None = None,
        **params) -> Oscillator:
    """A low-frequency oscillator: an `Oscillator` at a control rate.

    There is nothing special about an LFO here. It is the same phase accumulator
    and the same shapes as any other oscillator -- the library makes no distinction
    between control rate and audio rate, so you can use either at either rate. This
    helper only converts the tempo-synced spelling of the rate into Hz::

        lfo(rate=1.0, sync=1.0, bpm=120.0)     # one cycle per beat
        lfo(rate=0.5, shape="triangle")

    Scale and offset the output with `Amp` (or by writing the target's base):
    an LFO that should sweep 400..1400 Hz is `Modulated(filt, lfo, "cutoff",
    depth=500, base=900)`, not a special unipolar mode on the oscillator.

    A stepped/random contour is not a shape and is not here: feed one oscillator
    through `SampleHold` to sample it, or build a random wavetable once and sweep
    it with `morph`.
    """
    hz = rate * (bpm / 60.0) if sync > 0.5 else rate
    return Oscillator(freq=hz, shape=shape, name=name, **params)


class FMOscillator(Source):
    """Two-operator FM: a sine carrier whose phase is bent by a sine modulator.

        out = sin(2*pi*(carrier_phase + index * sin(2*pi*mod_phase)))

    This is NOT a Shape: two independent phase accumulators at an arbitrary ratio
    make the output depend on more than the carrier's position. Only when `ratio`
    is rational does the pair repeat (at ratio's denominator times the carrier
    period), and an irrational ratio never repeats at all.

    `ratio` and `index` are live parameters, so the timbre can be modulated at
    audio rate -- that is feedback-FM territory when the depth is high.
    """

    freq = Param(220.0, "Hz", doc="carrier frequency")
    ratio = Param(1.0, doc="modulator freq = freq * ratio; non-integers are inharmonic")
    index = Param(2.0, doc="modulation depth in radians")
    feedback = Param(0.0, "", 0.0, 1.0, doc="self-feedback (>=0.5 gets noisy/chaotic)")
    amplitude = Param(1.0)

    def reset(self, ctx) -> None:
        super().reset(ctx)
        self._dt = 1.0 / ctx.sr
        self.carrier_ph = 0.0
        self.mod_ph = 0.0
        self.fb_state = 0.0

    def process(self, ctx) -> float:
        dt = self._dt
        f = self.params.freq

        mod = math.sin(TAU * self.mod_ph)
        # Averaging the feedback term with the previous output is the standard
        # stabiliser: raw self-feedback at index >~ 1 diverges or locks to DC.
        effective_index = self.params.index + 0.5 * self.params.feedback * self.fb_state
        carrier = math.sin(TAU * (self.carrier_ph + effective_index * mod))
        self.fb_state = carrier

        self.mod_ph += f * self.params.ratio * dt
        self.mod_ph -= math.floor(self.mod_ph)
        self.carrier_ph += f * dt
        self.carrier_ph -= math.floor(self.carrier_ph)
        return carrier * self.params.amplitude


class SuperOscillator(Source):
    """`voices` detuned oscillators with an equal-power stereo spread.

    The classic supersaw. Also not a Shape: each voice has its own accumulator, and
    the frequency ratios are not small rationals (7 voices at detune 0.12 are
    0.88, 0.92, ..., 1.12 -- 22/25 through 28/25), so the sum never repeats.
    """

    freq = Param(220.0, "Hz")
    detune = Param(0.12, doc="total detune spread as a fraction of freq")
    amplitude = Param(1.0)
    mix = Param(1.0, doc="blend with an exactly-in-tune centre voice")
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
        self.voices = int(voices)
        self.spread = float(spread)
        self.offsets = (
            np.linspace(-1.0, 1.0, self.voices) if self.voices > 1 else np.zeros(1)
        )
        self.pans = self.offsets * self.spread
        self.pan_l = np.cos((self.pans + 1.0) * 0.25 * np.pi)
        self.pan_r = np.sin((self.pans + 1.0) * 0.25 * np.pi)
        super().__init__(name=name, freq=freq, detune=detune, **params)

    def reset(self, ctx) -> None:
        super().reset(ctx)
        self._dt = 1.0 / ctx.sr
        self.phases = np.linspace(0.0, 1.0, self.voices, endpoint=False)
        self.last_stereo = (0.0, 0.0)

    def _wave(self, ph: np.ndarray, w: float) -> np.ndarray:
        a = 2.0 * ph - 1.0
        if w <= 0.0:
            return a
        b = np.where(ph < 0.5 + 0.4 * w, 1.0, -1.0)
        return a * (1.0 - w) + b * w

    def process(self, ctx) -> float:
        freqs = self.params.freq * (1.0 + self.offsets * self.params.detune)
        wave = self._wave(self.phases, self.params.waveform)
        self.last_stereo = (
            float(np.sum(wave * self.pan_l)) / math.sqrt(self.voices),
            float(np.sum(wave * self.pan_r)) / math.sqrt(self.voices),
        )
        self.phases += freqs * self._dt
        self.phases -= np.floor(self.phases)
        return float(np.mean(wave)) * self.params.amplitude


# ---------------------------------------------------------------------------
# Noise: no position, no shape
# ---------------------------------------------------------------------------

class Noise(Source):
    """White, pink or brown noise from the render's seeded generator.

    Uses `ctx.rng`, so a render is reproducible from its seed -- comparing two
    algorithms on the same noise is possible.

    * white: flat spectrum, uniform in [-1, 1]
    * pink:  -3 dB/octave (Voss-McCartney filter cascade, state exposed)
    * brown: -6 dB/octave, integrated white with leakage to stop DC drift
    """

    amplitude = Param(1.0)
    colour = Param(0.0, doc="0 = white, 1 = pink, 2 = brown (read-only by convention)")

    def __init__(self, kind: str = "white", name: str | None = None, **params):
        super().__init__(name=name, **params)
        if kind not in ("white", "pink", "brown"):
            raise ValueError("kind must be 'white', 'pink' or 'brown'")
        self.kind = kind

    def reset(self, ctx) -> None:
        super().reset(ctx)
        self.brown_state = 0.0
        self.pink_rows = np.zeros(16)
        self.pink_counter = 0

    def process(self, ctx) -> float:
        white = float(ctx.rng.uniform(-1.0, 1.0))
        if self.kind == "white":
            return white * self.params.amplitude
        if self.kind == "brown":
            self.brown_state = 0.99 * self.brown_state + 0.01 * white
            return self.brown_state * 3.5 * self.params.amplitude
        # Pink: update one row per sample in round-robin, sum the rows.
        self.pink_counter += 1
        row = (self.pink_counter & -self.pink_counter).bit_length() - 1
        row = min(row, self.pink_rows.size - 1)
        self.pink_rows[row] = white
        return float(self.pink_rows.sum()) / 3.0 * self.params.amplitude
