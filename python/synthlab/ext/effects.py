"""
Time-domain effects: delay, comb/allpass filters, reverb, modulated delays,
waveshaping, quantisation and DC removal.

Everything here is a plain `synthlab.core.Block` following the library's one
rule: **process is called once per sample, and the state is public**.  There is no
hidden buffer, no locked-in "sound" and no opaque library call.  If you want a
different interpolation kernel, a different allpass topology or a different
waveshaping curve, you read the difference equation in the docstring, look at the
attribute that holds the state, and change it.

Reading guide
-------------
Each class docstring states the *algorithm*, the *difference equation* it
implements, and the *coefficient maths*, then names the attributes it exposes.
Anything named `self.buffer`, `self.write_index`, `self.x1`, `self.y1`,
`self.damping_state`, `self.ap_state`, `self.hold`, ... is live state you can
read or write between samples.

Sample rate
-----------
`Context` carries the sample rate and it is only known at `prepare()` time, so
every block resolves the rate in `prepare()` and stores it in `self._sr`.  Blocks
also accept an `sr=` constructor fallback and default to 48000.0 for direct,
offline use where `prepare` was never called (and therefore *any* delay length is
allowed -- see `read`).

Notation
--------
* `x[n]`  input sample, `y[n]` output sample
* `N`     delay length in **samples** (fractional delays are interpolated)
* `fs`    sample rate in Hz, `T = 1 / fs`

Deliberate omissions
--------------------
`synthlab.osc` is *not* imported (the oscillators would be the natural place to
get an LFO).  Each modulated effect runs its own phase accumulator instead, which
also keeps it honest: you can see exactly what drives the delay time.
"""

from __future__ import annotations

import math
from typing import Any, Callable, Mapping

import numpy as np

from ..core import Block, Param, Source

__all__ = [
    "DelayLine",
    "Allpass",
    "Comb",
    "Reverb",
    "Chorus",
    "Flanger",
    "Phaser",
    "Waveshaper",
    "Bitcrush",
    "DcBlocker",
    "Gain",
    "freeverb_tunings",
    "default_shapers",
    "to_polynomial",
]

# Freeverb (Jezar at Dreampoint, 2000) tuning, in samples **at 44.1 kHz**.
# `Reverb` scales these by sr / 44100 so the acoustics are rate independent.
FREEVERB_COMB_TUNING: tuple[int, int, int, int, int, int, int, int] = (
    1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617,
)
FREEVERB_ALLPASS_TUNING: tuple[int, int, int, int] = (556, 441, 341, 225)
FREEVERB_STEREO_SPREAD: int = 23


def freeverb_tunings(sr: float = 48_000.0) -> dict[str, list[int]]:
    """The Freeverb delay lengths in samples, scaled from 44.1 kHz to `sr`.

    Also used internally by `Reverb`.  Printing this is the fastest way to see
    what the reverb is actually doing to the signal:

        >>> freeverb_tunings(48000)["comb"][0]
        1215
    """
    scale = float(sr) / 44_100.0
    return {
        "comb": [max(1, int(round(v * scale))) for v in FREEVERB_COMB_TUNING],
        "allpass": [max(1, int(round(v * scale))) for v in FREEVERB_ALLPASS_TUNING],
        "stereo_spread": max(0, int(round(FREEVERB_STEREO_SPREAD * scale))),
    }


# ---------------------------------------------------------------------------
# Delay line: the workhorse every other delay effect is built from
# ---------------------------------------------------------------------------

class DelayLine(Block):
    """A circular (ring) delay buffer with fractional-delay reads.

    Algorithm
    ---------
    A `max_seconds * fs` long float64 ring buffer, plus a write cursor.
    Processing one sample performs:

        y[n] = read(N)
        buf[write_index] = x[n] + y[n] * feedback
        write_index = (write_index + 1) % len(buf)

    Because the cursor advances *after* the store, immediately before the write at
    step `n` the cell `buf[write_index]` holds `x[n - L]` (the oldest sample) and
    the freshly written neighbour `buf[write_index - 1]` holds `x[n - 1]`.  Shifting
    the read window by that one sample is exactly what makes `N = 1` return the
    previous input sample with no off-by-one.

    Fractional delays
    -----------------
    `read` uses **linear interpolation** between the two samples that straddle the
    requested position:

        N  = delay in samples
        d  = int(floor(N));  f = N - d
        i1 = (write_index - d) % L           # newer neighbour, read at N = d
        i0 = (i1 + 1) % L                    # older neighbour, read at N = d + 1
        y  = buf[i1] * (1 - f) + buf[i0] * f

    Linear interpolation is a one-zero lowpass whose gain falls to -inf at
    Nyquist, so fast modulated delays dull the tail slightly -- that is the
    familiar character of a modulated delay, and swapping in a cubic/allpass
    interpolator is a one-method change.

    Reachable delays are `[1, L]` samples.  `N < 1` is clamped to 1 (a delay of
    zero samples is physically meaningless inside a ring buffer; use the dry path
    for that), and `N > L` is clamped to L.  Until the cursor has come round
    once, the samples it has not written yet are zero, so a delay longer than the
    elapsed render time simply reads silence rather than garbage.

    Parameters
    ----------
    max_seconds : float   buffer length in seconds (default 1.0). Quantised to
                          `int(round(max_seconds * sr))` samples, minimum 2.
    delay       : float   read offset in seconds (default 0.25).
    feedback    : float   gain applied to the delayed tail (default 0.0); clamped
                          to +/-0.9999 so it can never blow up.
    mix         : float   0.0 = dry only, 1.0 = delayed only (default 0.5).
    sr          : float   fallback sample rate when the block is used without
                          `core.render` (default 48000.0).

    Exposed state
    -------------
    buffer      : np.ndarray  the ring buffer itself
    write_index : int         current write cursor
    delay_samples : int       resolved delay length
    max_delay_samples : int   buffer length in samples
    _sr         : float       resolved sample rate
    """

    max_seconds = Param(1.0, unit="s", minimum=0.0, maximum=60.0,
                        doc="delay buffer length in seconds")
    delay = Param(0.25, unit="s", minimum=0.0, maximum=60.0,
                  doc="read offset in seconds")
    feedback = Param(0.0, unit="-", minimum=-1.0, maximum=1.0,
                     doc="gain of the recirculated tail (clamped to +/-0.9999)")
    mix = Param(0.5, unit="-", minimum=0.0, maximum=1.0,
                doc="0 = dry, 1 = delayed")

    #: Largest feedback this block will ever apply.  Feedback poles live on the
    #: unit circle at exactly 1.0, so anything >= 1.0 is a growing (unstable)
    #: system; 0.9999 is an infinite-decay rather than an exploding one.
    MAX_FEEDBACK: float = 0.9999

    def __init__(self, name: str | None = None, sr: float = 48_000.0, **params):
        self._sr: float = float(sr)
        self._alloc_sr: float | None = None
        self._alloc_max: float | None = None
        self.buffer: np.ndarray | None = None
        self.write_index: int = 0
        # `max_seconds` is a Param descriptor, and the per-instance parameter cell
        # `self.p` does not exist until `Block.__init__` runs, so seed the shadow
        # attribute directly and let the descriptor take over afterwards.
        self.__dict__["max_seconds"] = float(self._param_defaults["max_seconds"][0])
        self.delay_samples: int = 0
        self.max_delay_samples: int = 0
        super().__init__(name=name, **params)

    # -- lifecycle ---------------------------------------------------------
    def prepare(self, ctx) -> None:
        """Resolve the sample rate from `ctx`, allocate the buffer if needed."""
        super().prepare(ctx)
        self._sr = float(getattr(ctx, "sr", self._sr) or self._sr)
        if self.buffer is None or self._alloc_sr != self._sr:
            self.max_seconds = float(self.p["max_seconds"])
            self._alloc_sr = self._sr
        self._ensure_buffer()

    def reset(self) -> None:
        """Zero the ring buffer and park the write cursor at 0."""
        super().reset()
        self.max_seconds = float(self.p["max_seconds"])
        self._ensure_buffer()
        self.buffer[:] = 0.0
        self.write_index = 0

    def _ensure_buffer(self) -> None:
        """(Re)allocate the ring buffer so it holds at least `max_seconds`.

        Growing the buffer preserves the already-written history; a *new* buffer
        is zeroed.  At least 2 samples are allocated so that interpolation always
        has a neighbour to look at, even for `max_seconds == 0`.
        """
        sr = float(getattr(self, "_sr", 48_000.0) or 48_000.0)
        max_seconds = float(getattr(self, "max_seconds", 1.0))
        length = max(2, int(round(max_seconds * sr)))
        current = self.buffer
        if current is None or current.size < length:
            fresh = np.zeros(length, dtype=np.float64)
            if current is not None and current.size:
                fresh[: current.size] = current
            self.buffer = fresh
        self.max_delay_samples = int(self.buffer.size)
        self.delay_samples = int(round(float(self.p["delay"]) * sr))
        self._alloc_max = max_seconds

    # -- low level buffer access: the whole point of this class ------------
    def read(self, delay_samples: float) -> float:
        """Read the buffer at a (possibly fractional) delay, no state change.

        Linear interpolation, see the class docstring.  Safe for any finite
        `delay_samples` and safe when no render has happened yet (returns 0.0).
        """
        buf = self.buffer
        if buf is None or buf.size < 2:
            return 0.0
        L = buf.size
        try:
            n = float(delay_samples)
        except (TypeError, ValueError):
            return 0.0
        if not math.isfinite(n):
            return 0.0
        d = int(n)
        if d >= L:
            # Requested delay is longer than the whole buffer: history is gone.
            return 0.0
        n = min(max(n, 1.0), float(L - 1))
        d = int(n)
        frac = n - d
        i1 = (self.write_index - d) % L
        i0 = (i1 + 1) % L
        if frac == 0.0:
            return float(buf[i1])
        return float(buf[i1] * (1.0 - frac) + buf[i0] * frac)

    def tap(self, delay_samples: float) -> float:
        """Stateless multi-tap read -- same as `read`, no feedback involved.

        Use it to pull several echoes out of one line (delays are in samples):

            line.tap(0.125 * line._sr)      # 125 ms tap
            line.tap(0.250 * line._sr)      # 250 ms tap
        """
        return self.read(delay_samples)

    def taps(self, delays_in_samples) -> list[float]:
        """`tap` for a whole list of delays (one write, many reads)."""
        return [self.read(d) for d in delays_in_samples]

    def peek(self, offset: int = 0) -> float:
        """Read a raw integer offset (0 = most recently written sample)."""
        buf = self.buffer
        if buf is None or buf.size == 0:
            return 0.0
        return float(buf[(self.write_index - 1 - int(offset)) % buf.size])

    def _clamped_feedback(self) -> float:
        return float(np.clip(self.p["feedback"], -self.MAX_FEEDBACK, self.MAX_FEEDBACK))

    # -- per-sample --------------------------------------------------------
    def process(self, x: float, ctx) -> float:
        """Write the input, read the delayed tail, mix dry/wet."""
        if self.buffer is None or self._alloc_sr != float(getattr(ctx, "sr", self._sr)):
            # `prepare` was skipped (or the rate changed): stay usable.
            self._sr = float(getattr(ctx, "sr", self._sr) or self._sr)
            self._alloc_sr = self._sr
            self._ensure_buffer()

        buf = self.buffer
        L = buf.size
        sr = self._sr
        delay_samples = float(self.p["delay"]) * sr
        self.delay_samples = int(round(delay_samples))

        tail = self.read(delay_samples)
        buf[self.write_index] = float(x) + tail * self._clamped_feedback()
        self.write_index = (self.write_index + 1) % L

        mix = float(np.clip(self.p["mix"], 0.0, 1.0))
        return float(x) * (1.0 - mix) + tail * mix


# ---------------------------------------------------------------------------
# Schroeder building blocks
# ---------------------------------------------------------------------------

class Allpass(Block):
    """Schroeder allpass section: flat magnitude, frequency-dependent phase.

    Maths
    -----
    The transfer function is

        H(z) = (-g + z^-N) / (1 - g * z^-N)

    which has |H(e^jw)| = 1 for every w: the section *colours phase only*, it
    never changes the magnitude spectrum.  In the time domain (Gerzon's form):

        v[n] = x[n] + g * v[n - N]        # `self.delay_line` holds v[]
        y[n] = -g * v[n] + v[n - N]

    The inner delay line stores `v`, writes `v[n]`, and its own feedback is 0.
    `self.last_delayed` exposes `v[n - N]` from the last sample so you can verify
    the identity `y[n] + g * x[n] == (1 - g^2) * v[n - N]` (energy preservation).

    `delay` is snapped to whole samples for the canonical Schroeder tuning
    (`round(delay * sr)`, minimum 1).  A fractional length is just a different
    filter -- set `self.delay_line.delay` directly if you want to explore it.

    Parameters
    ----------
    delay       : float  delay length in seconds (default 0.005).
    gain        : float  coefficient g, |g| < 1 (default 0.5).
    max_seconds : float  size of the internal ring buffer; must exceed `delay`
                         (default 0.05).  `Reverb` resizes it for its tunings.
    sr          : float  fallback sample rate (default 48000.0).

    Exposed state
    -------------
    delay_line   : DelayLine  the internal N-sample delay (holds v[])
    last_delayed : float      v[n - N]
    """

    delay = Param(0.005, unit="s", minimum=0.0, maximum=10.0,
                  doc="allpass delay length in seconds")
    gain = Param(0.5, unit="-", minimum=-0.9999, maximum=0.9999,
                 doc="allpass coefficient g")
    max_seconds = Param(0.05, unit="s", minimum=0.001, maximum=10.0,
                        doc="internal ring buffer length in seconds")

    def __init__(self, name: str | None = None, sr: float = 48_000.0, **params):
        self._sr: float = float(sr)
        self.__dict__["max_seconds"] = float(self._param_defaults["max_seconds"][0])
        self.delay_line = DelayLine(max_seconds=0.05, sr=self._sr)
        self.last_delayed: float = 0.0
        super().__init__(name=name, **params)

    def prepare(self, ctx) -> None:
        super().prepare(ctx)
        self._sr = float(getattr(ctx, "sr", self._sr) or self._sr)
        self._ensure_buffer()
        self.delay_line.delay = 0.0
        self.delay_line.feedback = 0.0
        self.delay_line.prepare(ctx)

    def _ensure_buffer(self) -> None:
        """Size the inner line for the current `delay` and `max_seconds`."""
        need = (max(1, int(round(float(self.p["delay"]) * self._sr))) + 2) / self._sr
        # Never shrink a buffer the user asked to be larger: `Reverb` sizes its
        # allpasses so the tuning is never clipped.
        self.p["max_seconds"] = max(need, float(self.p["max_seconds"]))
        self.__dict__["max_seconds"] = self.p["max_seconds"]
        self.delay_line.max_seconds = self.p["max_seconds"]
        self.delay_line._ensure_buffer()

    def reset(self) -> None:
        super().reset()
        if hasattr(self, "delay_line"):
            self.delay_line.reset()
        self.last_delayed = 0.0

    def process(self, x: float, ctx) -> float:
        """One allpass sample; see the class docstring for the equation."""
        n = max(1.0, round(float(self.p["delay"]) * self._sr))
        g = float(np.clip(self.p["gain"], -0.9999, 0.9999))
        vn = float(x) + g * self.delay_line.read(n)
        delayed = self.delay_line.read(n)
        self.delay_line.buffer[self.delay_line.write_index] = vn
        L = self.delay_line.buffer.size
        self.delay_line.write_index = (self.delay_line.write_index + 1) % L
        self.last_delayed = delayed
        return -g * vn + delayed


class Comb(Block):
    """Feedforward + feedback comb filter -- one tuned resonance.

    Maths
    -----
        y[n] = b0 * x[n] + bN * x[n - N] + aN * y[n - N]

    which factorises into a feedforward section `b0 + bN * z^-N` and a feedback
    section `1 / (1 - aN * z^-N)`.  The magnitude response is a comb:

        |H| = |b0 + bN * e^-jwN| / |1 - aN * e^-jwN|

    with peaks every `fs / N` Hz (the feedback poles) and nulls every `fs / N` Hz
    offset by half a period (the feedforward zeros).  Feedback gain `aN` sets how
    sharp/long the resonances are; |=1| is the stability boundary, so it is
    clamped to +/-0.9999.  Feedforward is what Freeverb uses for its "lowpass
    comb" variant.

    Parameters
    ----------
    delay       : float  N in seconds (default 0.025).
    feedback    : float  aN, feedback coefficient (default 0.5).
    feedforward : float  bN, feedforward coefficient (default 0.0). b0 is 1.0.
    max_seconds : float  size of the internal ring buffer; must exceed `delay`
                         (default 0.05).  `Reverb` resizes it for its tunings.
    sr          : float  fallback sample rate (default 48000.0).

    Exposed state
    -------------
    delay_line  : DelayLine  the N-sample delay holding x[n-N] and y[n-N]
    last_delay  : float      x[n - N]
    last_out    : float      y[n - N]
    """

    delay = Param(0.025, unit="s", minimum=0.0, maximum=10.0,
                  doc="comb delay length in seconds")
    feedback = Param(0.5, unit="-", minimum=-0.9999, maximum=0.9999,
                     doc="feedback coefficient aN")
    feedforward = Param(0.0, unit="-", minimum=-4.0, maximum=4.0,
                        doc="feedforward coefficient bN")
    max_seconds = Param(0.05, unit="s", minimum=0.001, maximum=10.0,
                        doc="internal ring buffer length in seconds")

    def __init__(self, name: str | None = None, sr: float = 48_000.0, **params):
        self._sr: float = float(sr)
        self.__dict__["max_seconds"] = float(self._param_defaults["max_seconds"][0])
        self.delay_line = DelayLine(max_seconds=0.05, sr=self._sr)
        self.last_delay: float = 0.0
        self.last_out: float = 0.0
        super().__init__(name=name, **params)

    def prepare(self, ctx) -> None:
        super().prepare(ctx)
        self._sr = float(getattr(ctx, "sr", self._sr) or self._sr)
        self._ensure_buffer()
        self.delay_line.feedback = 0.0
        self.delay_line.prepare(ctx)

    def _ensure_buffer(self) -> None:
        """Size the inner line for the current `delay` and `max_seconds`."""
        need = (max(1, int(round(float(self.p["delay"]) * self._sr))) + 2) / self._sr
        # Never shrink a buffer the user asked to be larger: `Reverb` sizes its
        # combs so a `room_size` change never clips the Freeverb tuning.
        self.p["max_seconds"] = max(need, float(self.p["max_seconds"]))
        self.__dict__["max_seconds"] = self.p["max_seconds"]
        self.delay_line.max_seconds = self.p["max_seconds"]
        self.delay_line._ensure_buffer()

    def reset(self) -> None:
        super().reset()
        if hasattr(self, "delay_line"):
            self.delay_line.reset()
        self.last_delay = 0.0
        self.last_out = 0.0

    def _stabilize(self) -> None:
        """Pull `delay` down if an unstable setup would oscillate.

        A feedback comb is unstable for |aN| >= 1 and also *marginally* stable at
        some integer delays even below that (e.g. a 2-sample delay with
        feedback 0.95 is fine, but a 1-sample delay with 0.999 rings for a very
        long time).  This helper nudges `delay` fractionally longer, which pushes
        the pole slightly off the resonance, restoring decay.  Call it from
        `prepare` after changing `feedback`/`delay` yourself.
        """
        n = float(self.p["delay"]) * self._sr
        if abs(float(self.p["feedback"])) >= 0.9999 and n > 2.0:
            self.p["delay"] = (n - 0.5 * n) / self._sr

    def process(self, x: float, ctx) -> float:
        """One comb sample; see the class docstring for the equation."""
        n = max(1.0, round(float(self.p["delay"]) * self._sr))
        a = float(np.clip(self.p["feedback"], -0.9999, 0.9999))
        b = float(self.p["feedforward"])

        delayed = self.delay_line.read(n)
        self.last_delay = delayed
        out = float(x) + b * delayed + a * self.last_out
        self.delay_line.buffer[self.delay_line.write_index] = out
        L = self.delay_line.buffer.size
        self.delay_line.write_index = (self.delay_line.write_index + 1) % L
        self.last_out = self.delay_line.read(n)
        return out


# ---------------------------------------------------------------------------
# Reverb
# ---------------------------------------------------------------------------

class Reverb(Block):
    """Schroeder / Freeverb reverb: 4 parallel damping combs into 4 allpasses.

    Monte-Carlo history: Manfred Schroeder (1962) proposed parallel feedback
    combs to build echo density and series allpasses to smear the result without
    changing the magnitude response.  Jezar's **Freeverb** (2000) is the widely
    copied voicing of that idea; the delay lengths below are its constants:

        comb     (samples @ 44.1 kHz) : 1116, 1188, 1277, 1356,
                                        1422, 1491, 1557, 1617
        allpass  (samples @ 44.1 kHz) : 556, 441, 341, 225
        stereo spread                 : 23 samples on the right channel

    This block uses the **first four** of each (the prompt's 4-comb voicing) and
    scales every length by `sr / 44100`, so the room is the same size at any rate.
    `freeverb_tunings(sr)` returns the scaled numbers if you want to retune.

    Structure, per channel
    ----------------------
        wet[n] = allpass4(allpass3(allpass2(allpass1(sum_i comb_i(x[n])))))

    Comb i is a lowpass-feedback comb (Freeverb's `comb`):

        y_i[n] = buf_i[write]                          # read N_i samples back
        lp     = y_i[n] * (1 - d) + lp_i * d           # one-pole lowpass in loop
        lp_i   = lp
        buf_i[write] = x[n] + lp * feedback_i
        feedback_i = room_size * 0.28 + 0.7            # 0.70 .. 0.98

    The lowpass in the feedback path makes high frequencies decay faster than low
    ones, which is what air absorption does -- that is `damping`:

        d = damping * 0.4                              # 0.0 .. 0.4

    `Reverb` uses `synthlab.effects.DelayLine` instances rather than a bespoke
    buffer, so `self.combs[i].delay_line.buffer` and `self.damping_state[i]` are
    both directly inspectable/mutable.

    Stereo
    ------
    The block stores a **stereo** pair of comb/allpass banks internally: the right
    bank's comb lengths are offset by the Freeverb stereo spread (23 samples), so
    the two channels decorrelate.  With `width == 0.0` (default) the mono sum is
    returned, exactly matching the requested mono behaviour; `width > 0` returns

        W = 0.5 * width * (1 + cos(pi * t))      t = (L + R) / 2
        out = W * L + (1 - W) * R

    which is the classic width crossfade (0 -> mono, 1 -> fully separated stereo;
    negative width swaps the channels).  Left and right combs always run, so the
    state is warm whichever width you choose.

    Parameters
    ----------
    room_size : float  0..1, scales comb feedback 0.70..0.98 (default 0.5).
    damping   : float  0..1, one-pole lowpass in the comb feedback loop
                       (default 0.5 = coefficient 0.2).
    mix       : float  0 = dry, 1 = wet only (default 0.3).
    width     : float  0 = mono sum, 1 = fully separated stereo (default 0.0).
    sr        : float  fallback sample rate (default 48000.0).

    Exposed state
    -------------
    combs / combs_r               : list[Comb]        4 parallel combs per channel
    damping_state / damping_state_r : list[float]     one-pole lowpass memory
    allpasses / allpasses_r       : list[Allpass]     4 series sections per channel
    last_wet / last_wet_r         : float             wet sample per channel
    buffered_input                : float             input fed to the comb bank
    """

    room_size = Param(0.5, unit="-", minimum=0.0, maximum=1.0,
                      doc="0 = small/damped room, 1 = long tail (feedback 0.70..0.98)")
    damping = Param(0.5, unit="-", minimum=0.0, maximum=1.0,
                    doc="0 = bright tail, 1 = heavily lowpassed tail (coeff 0..0.4)")
    mix = Param(0.3, unit="-", minimum=0.0, maximum=1.0,
                doc="0 = dry, 1 = wet")
    width = Param(0.0, unit="-", minimum=-1.0, maximum=2.0,
                  doc="0 = mono sum, 1 = fully separated stereo")

    #: Freeverb's output gain.  The fixed-point original uses 0.015 because the
    #: eight combs sum to roughly +/-8 before the allpasses.  Change it if you
    #: change the comb count.
    WET_GAIN: float = 0.015

    def __init__(self, name: str | None = None, sr: float = 48_000.0, **params):
        self._sr: float = float(sr)
        self.combs: list[Comb] = []
        self.combs_r: list[Comb] = []
        self.allpasses: list[Allpass] = []
        self.allpasses_r: list[Allpass] = []
        #: The Freeverb tunings in seconds after `sr / 44100` scaling -- inspect or
        #: overwrite these (then call `rebuild()`) to retune the room.
        self.delay_seconds: list[float] = []
        self.delay_seconds_r: list[float] = []
        self.allpass_seconds: list[float] = []
        self.damping_state: list[float] = []
        self.damping_state_r: list[float] = []
        self.last_wet: float = 0.0
        self.last_wet_r: float = 0.0
        self.buffered_input: float = 0.0
        self._alloc_sr: float | None = None
        self._alloc_max_seconds: float | None = None
        super().__init__(name=name, **params)

    # -- lifecycle ---------------------------------------------------------
    def prepare(self, ctx) -> None:
        """(Re)tune the comb and allpass banks for `ctx.sr`, keeping state.

        The banks are only rebuilt when the sample rate changes or the required
        buffer grows; on an ordinary re-prepare the existing delay lines are kept
        and merely re-tuned, so a reverb tail survives `reset()`-less replay and
        no buffer is ever silently swapped out from under the state.
        """
        super().prepare(ctx)
        sr = float(getattr(ctx, "sr", self._sr) or self._sr)
        self._sr = sr
        scale = sr / 44_100.0
        comb = [max(1, int(round(v * scale))) for v in FREEVERB_COMB_TUNING[:4]]
        ap = [max(1, int(round(v * scale))) for v in FREEVERB_ALLPASS_TUNING]
        spread = max(0, int(round(FREEVERB_STEREO_SPREAD * scale)))
        max_seconds = min(60.0, max(comb[-1] + spread, ap[0]) * 2.5 / sr)

        rebuild = (
            not self.combs
            or self._alloc_sr != sr
            or self._alloc_max_seconds is None
            or self._alloc_max_seconds < max_seconds
        )
        if rebuild:
            self.delay_seconds = [c / sr for c in comb]
            self.delay_seconds_r = [(c + spread) / sr for c in comb]
            self.allpass_seconds = [a / sr for a in ap]
            self.combs = [
                Comb(name=f"comb{i}", max_seconds=max_seconds, sr=sr) for i in range(4)
            ]
            self.combs_r = [
                Comb(name=f"comb_r{i}", max_seconds=max_seconds, sr=sr) for i in range(4)
            ]
            self.allpasses = [
                Allpass(name=f"allpass{i}", delay=self.allpass_seconds[i], gain=0.5, sr=sr)
                for i in range(4)
            ]
            self.allpasses_r = [
                Allpass(name=f"allpass_r{i}", delay=self.allpass_seconds[i], gain=0.5, sr=sr)
                for i in range(4)
            ]
            self._alloc_max_seconds = max_seconds
            self._alloc_sr = sr
            self.reset()

        for i, c in enumerate(self.combs):
            c.delay = self.delay_seconds[i]
            c.feedback = 0.5
            c.feedforward = 0.0
            c.delay_line.feedback = 0.0
            c.delay_line.delay = self.delay_seconds[i]
        for i, c in enumerate(self.combs_r):
            c.delay = self.delay_seconds_r[i]
            c.feedback = 0.5
            c.feedforward = 0.0
            c.delay_line.feedback = 0.0
            c.delay_line.delay = self.delay_seconds_r[i]
        for i, a in enumerate(self.allpasses):
            a.delay = self.allpass_seconds[i]
            a.gain = 0.5
            a.delay_line.delay = 0.0
            a.delay_line.feedback = 0.0
        for i, a in enumerate(self.allpasses_r):
            a.delay = self.allpass_seconds[i]
            a.gain = 0.5
            a.delay_line.delay = 0.0
            a.delay_line.feedback = 0.0
        self.damping_state = [0.0] * len(self.combs)
        self.damping_state_r = [0.0] * len(self.combs_r)

    def rebuild(self) -> None:
        """Force a fresh allocation of the comb/allpass banks on the next prepare.

        Use it after changing `FREEVERB_COMB_TUNING` (or the module constants) so
        the new lengths take effect instead of the cached ones.
        """
        self.combs = []
        self.combs_r = []
        self.allpasses = []
        self.allpasses_r = []
        self._alloc_sr = None
        self._alloc_max_seconds = None

    def reset(self) -> None:
        """Clear comb buffers, allpass buffers and the damping one-pole memory."""
        super().reset()
        for c in list(getattr(self, "combs", [])) + list(getattr(self, "combs_r", [])):
            c.reset()
        for a in list(getattr(self, "allpasses", [])) + list(
            getattr(self, "allpasses_r", [])
        ):
            a.reset()
        self.damping_state = [0.0] * len(getattr(self, "combs", []))
        self.damping_state_r = [0.0] * len(getattr(self, "combs_r", []))
        self.last_wet = 0.0
        self.last_wet_r = 0.0
        self.buffered_input = 0.0

    # -- coefficients ------------------------------------------------------
    def _feedback(self) -> float:
        """Freeverb's room size -> comb feedback mapping: 0.70 + 0.28 * room."""
        return 0.70 + 0.28 * float(np.clip(self.p["room_size"], 0.0, 1.0))

    def _damping_coeff(self) -> float:
        """Freeverb's damping -> one-pole coefficient mapping: 0.4 * damping."""
        return 0.4 * float(np.clip(self.p["damping"], 0.0, 1.0))

    # -- per-sample --------------------------------------------------------
    def _comb_bank(self, combs, damping_state, x: float, fb: float, damp: float,
                   ctx) -> float:
        """Sum one channel's 4 lowpass-feedback combs, updating their states."""
        total = 0.0
        for i, comb in enumerate(combs):
            n = max(1.0, round(comb.delay * self._sr))
            d = comb.delay_line
            delayed = d.read(n)
            lp = delayed * (1.0 - damp) + damping_state[i] * damp
            damping_state[i] = lp
            d.buffer[d.write_index] = x + lp * fb
            d.write_index = (d.write_index + 1) % d.buffer.size
            total += delayed
        return total

    def process(self, x: float, ctx) -> float:
        """One reverb sample: 4 combs per channel into 4 series allpasses."""
        fb = self._feedback()
        damp = self._damping_coeff()

        dry = float(x)
        self.buffered_input = dry
        left = self._comb_bank(self.combs, self.damping_state, dry, fb, damp, ctx) \
            * self.WET_GAIN
        right = self._comb_bank(self.combs_r, self.damping_state_r, dry, fb, damp, ctx) \
            * self.WET_GAIN
        for a in self.allpasses:
            left = a.run(left, ctx)
        for a in self.allpasses_r:
            right = a.run(right, ctx)
        if not math.isfinite(left):
            left = 0.0
        if not math.isfinite(right):
            right = 0.0
        self.last_wet = left
        self.last_wet_r = right

        width = float(np.clip(self.p["width"], -1.0, 2.0))
        if width == 0.0:
            wet = 0.5 * (left + right)            # mono sum
        else:
            t = 0.5 * (left + right)
            w = 0.5 * width * (1.0 + math.cos(math.pi * t))
            wet = w * left + (1.0 - w) * right

        mix = float(np.clip(self.p["mix"], 0.0, 1.0))
        return dry * (1.0 - mix) + wet * mix


# ---------------------------------------------------------------------------
# Modulated delays
# ---------------------------------------------------------------------------

class Chorus(Block):
    """Multi-voice modulated delay -- thickens a source with detuned copies.

    Algorithm
    ---------
    Each voice has its own phase accumulator over the shared delay line:

        phi_i[n] = frac(phi_i[n-1] + rate / fs)        # 0..1, `self.phase[i]`
        d_i[n]   = center + depth * fs * sin(TAU * phi_i[n] + offset_i)

    `center` sits exactly half way between the shortest and longest delay the
    modulation needs, so no voice ever asks for a negative delay:

        center = max(0.001 s, depth) * fs

    The dry input is stored once into the ring buffer together with the feedback
    term (a *global* feedback is used, not per-voice, so the loop stays stable):

        buf[write] = x[n] + feedback * sum_i (read_i)
        y[n]       = sum_i (read_i) / voices
        out[n]     = (1 - mix) * x[n] + mix * y[n]

    Delay-time modulation by a sine is *not* just a pitch shift: the read pointer
    velocity adds a Doppler detune of roughly `-depth * fs * TAU * rate *
    cos(...)` samples per sample, and linear interpolation lowpasses the copies
    (see `DelayLine`).  Both effects are the sound of a chorus.

    Voice phases start at `2*pi*i/voices` (a `self.voice_offsets` list you can
    overwrite) so the voices start spread out instead of stacked.

    Parameters
    ----------
    rate     : float  LFO rate in Hz (default 0.6).
    depth    : float  peak delay excursion in **seconds** (default 0.003).
    mix      : float  0 = dry, 1 = wet only (default 0.5).
    feedback : float  wet signal re-injected, |fb| < 0.95 usable (default 0.0).
    voices   : int    how many modulated taps are summed (default 2, >= 1).
    max_seconds : float  ring buffer length; must exceed the longest delay
                      (default 0.2).
    sr       : float  fallback sample rate (default 48000.0).

    Exposed state
    -------------
    delay_line    : DelayLine       the shared ring buffer
    phase         : list[float]     one fractional LFO phase per voice
    voice_offsets : list[float]     per-voice LFO offset in radians
    voice_delays  : list[float]     last delay in samples asked of each voice
    lfo           : float           the first voice's raw sine value
    last_wet      : float           last wet (summed, normalised) sample
    """

    rate = Param(0.6, unit="Hz", minimum=0.0, maximum=20.0,
                 doc="LFO rate in Hz")
    depth = Param(0.003, unit="s", minimum=0.0, maximum=0.1,
                  doc="peak delay excursion in seconds (converted to samples)")
    mix = Param(0.5, unit="-", minimum=0.0, maximum=1.0,
                doc="0 = dry, 1 = wet")
    feedback = Param(0.0, unit="-", minimum=-0.99, maximum=0.99,
                     doc="global feedback of the summed voices")
    voices = Param(2, unit="count", minimum=1, maximum=16,
                   doc="number of modulated taps")
    max_seconds = Param(0.2, unit="s", minimum=0.001, maximum=10.0,
                        doc="ring buffer length in seconds")

    def __init__(self, name: str | None = None, sr: float = 48_000.0, **params):
        self._sr: float = float(sr)
        self.delay_line = DelayLine(max_seconds=0.2, sr=self._sr)
        self.phase: list[float] = []
        self.voice_offsets: list[float] = []
        self.voice_delays: list[float] = []
        self.lfo: float = 0.0
        self.last_wet: float = 0.0
        super().__init__(name=name, **params)

    def prepare(self, ctx) -> None:
        super().prepare(ctx)
        sr = float(getattr(ctx, "sr", self._sr) or self._sr)
        self._sr = sr
        self.delay_line.max_seconds = float(self.p["max_seconds"])
        self.delay_line.delay = min(
            float(self.p["max_seconds"]), max(0.002, float(self.p["depth"])) * 2.0
        )
        self.delay_line.feedback = 0.0
        self.delay_line.prepare(ctx)
        self.reset()

    def reset(self) -> None:
        super().reset()
        if hasattr(self, "delay_line"):
            self.delay_line.reset()
        voices = self._voice_count()
        self.phase = [i / voices for i in range(voices)]
        self.voice_offsets = [2.0 * math.pi * i / voices for i in range(voices)]
        self.voice_delays = [0.0] * voices
        self.lfo = 0.0
        self.last_wet = 0.0

    def _voice_count(self) -> int:
        return max(1, int(self.p["voices"]))

    def _center_samples(self) -> float:
        """Delay length half way between the shortest and longest excursion."""
        return max(0.001, float(self.p["depth"])) * self._sr

    def process(self, x: float, ctx) -> float:
        """One sample: advance every LFO, sum the taps, write once."""
        voices = self._voice_count()
        if len(self.phase) != voices or self.delay_line.buffer is None:
            self.reset()
        sr = self._sr
        inc = float(self.p["rate"]) / sr
        center = self._center_samples()
        span = float(self.p["depth"]) * sr
        x = float(x)

        total = 0.0
        for i in range(voices):
            phi = self.phase[i] + inc
            phi -= math.floor(phi)
            self.phase[i] = phi
            sine = math.sin(2.0 * math.pi * phi + self.voice_offsets[i])
            if i == 0:
                self.lfo = sine
            d = center + span * sine
            self.voice_delays[i] = d
            total += self.delay_line.read(d)
        wet = total / voices

        fb = float(np.clip(self.p["feedback"], -0.99, 0.99))
        d = self.delay_line
        d.buffer[d.write_index] = x + wet * fb
        d.write_index = (d.write_index + 1) % d.buffer.size

        self.last_wet = wet
        mix = float(np.clip(self.p["mix"], 0.0, 1.0))
        return x * (1.0 - mix) + wet * mix


class Flanger(Block):
    """Short modulated delay with feedback -- the classic swept comb.

    Maths
    -----
    Same ring buffer as `Chorus`, but the delay stays in the 0.5-10 ms range:

        d[n] = center + depth * fs * sin(TAU * phi[n])
             = max(0.001, depth) * fs * (1 + sin(...))

        center = max(0.001, depth) * fs          # so d >= 1 sample, always
        buf[write] = x[n] + feedback * y[n]
        y[n]       = read_linear(d[n])
        out[n]     = (1 - mix) * x[n] + mix * y[n]

    Because d is only a handful of samples, the comb's first notch sits in the
    low kilohertz and sweeps as the LFO moves the delay: |H(f)| has maxima at
    `f = k * fs / d`.  The feedback turns those maxima into a resonant "jet"
    whistle.  A flanger and a chorus are the *same* algorithm at different delay
    scales -- chorus delays are ~20x longer, which decorrelates the copies
    instead of comb-filtering them.

    Parameters
    ----------
    rate     : float  LFO rate in Hz (default 0.25).
    depth    : float  peak delay in seconds, 0.0005..0.01 (default 0.002).
    feedback : float  comb feedback, |fb| < 0.99 (default 0.5).
    mix      : float  0 = dry, 1 = wet (default 0.5).
    sr       : float  fallback sample rate (default 48000.0).

    Exposed state
    -------------
    delay_line : DelayLine    ring buffer, holds the feedback loop
    phase      : float        fractional LFO phase
    lfo        : float        last raw sine value
    delay_samples : float     last delay asked of the buffer
    last_wet   : float        last wet sample
    """

    rate = Param(0.25, unit="Hz", minimum=0.0, maximum=20.0,
                 doc="LFO rate in Hz")
    depth = Param(0.002, unit="s", minimum=0.0, maximum=0.05,
                  doc="peak delay in seconds (converted to samples)")
    feedback = Param(0.5, unit="-", minimum=-0.99, maximum=0.99,
                     doc="comb feedback; the resonance/whistle amount")
    mix = Param(0.5, unit="-", minimum=0.0, maximum=1.0,
                doc="0 = dry, 1 = wet")

    def __init__(self, name: str | None = None, sr: float = 48_000.0, **params):
        self._sr: float = float(sr)
        self.delay_line = DelayLine(max_seconds=0.05, sr=self._sr)
        self.phase: float = 0.0
        self.lfo: float = 0.0
        self.delay_samples: float = 0.0
        self.last_wet: float = 0.0
        super().__init__(name=name, **params)

    def prepare(self, ctx) -> None:
        super().prepare(ctx)
        sr = float(getattr(ctx, "sr", self._sr) or self._sr)
        self._sr = sr
        self.delay_line.max_seconds = 0.05
        self.delay_line.delay = max(0.001, float(self.p["depth"])) * 2.0
        self.delay_line.feedback = 0.0
        self.delay_line.prepare(ctx)

    def reset(self) -> None:
        super().reset()
        if hasattr(self, "delay_line"):
            self.delay_line.reset()
        self.phase = 0.0
        self.lfo = 0.0
        self.delay_samples = 0.0
        self.last_wet = 0.0

    def process(self, x: float, ctx) -> float:
        """One sample: advance the LFO, read the comb, write with feedback."""
        sr = self._sr
        phi = self.phase + float(self.p["rate"]) / sr
        phi -= math.floor(phi)
        self.phase = phi
        sine = math.sin(2.0 * math.pi * phi)
        self.lfo = sine

        span = max(0.001, float(self.p["depth"])) * sr
        d = span * (1.0 + sine)
        self.delay_samples = d
        x = float(x)
        wet = self.delay_line.read(d)

        fb = float(np.clip(self.p["feedback"], -0.99, 0.99))
        dl = self.delay_line
        dl.buffer[dl.write_index] = x + wet * fb
        dl.write_index = (dl.write_index + 1) % dl.buffer.size

        self.last_wet = wet
        mix = float(np.clip(self.p["mix"], 0.0, 1.0))
        return x * (1.0 - mix) + wet * mix


# ---------------------------------------------------------------------------
# Phaser
# ---------------------------------------------------------------------------

class Phaser(Block):
    """N cascaded first-order allpass sections with feedback -- swept notches.

    Maths
    -----
    One first-order allpass has the transfer function

        H(z) = (a + z^-1) / (1 + a * z^-1)

    and a phase response that sweeps 0 -> -180 degrees as the frequency rises
    through the break frequency.  Cascading N of them multiplies the phase by N,
    and summing that with the dry path gives `N/2` notches wherever the total
    phase shift is 180 degrees out of phase with the dry signal:

        y[n] = x[n] + g * out[n]        # feedback, |g| < 0.99
        out[n] = A^N(y[n])              # N sections in series
        result = (1 - mix) * x[n] + mix * out[n]

    The coefficient formula used here is the standard *frequency-warped* form

        a = (1 - tan(pi * f / fs)) / (1 + tan(pi * f / fs))

    where `f` is the sweep centre.  `f = 0` gives a = +1 (no phase shift) and
    `f -> fs/2` gives a -> 0 (a pure one-sample delay); the LFO sweeps `f` over
    `self.fmin .. self.fmax`, computed each sample from

        rate, depth, stages, and `self.stages_coeff` (the a values in use).

    `feedback` is taken from the cascade output, which sharpens the notches into
    resonant peaks; without feedback a phaser is just a gentle comb-free sweep.
    Because each section is only `y = -a * x + x1 + a * y1`, the state is two
    floats per stage -- all of them exposed.

    Parameters
    ----------
    rate    : float  LFO rate in Hz (default 0.4).
    depth   : float  0..1, how far the sweep travels between fmin/fmax
                     (default 1.0 = the full 100 Hz .. 8000 Hz range).
    feedback: float  cascade output fed back into the input, |g| < 0.99
                     (default 0.3).
    mix     : float  0 = dry, 1 = wet (default 0.5).
    stages  : int    number of first-order sections (default 4; 4 -> 2 notches).
    fmin    : float  sweep lower bound in Hz (default 100.0).
    fmax    : float  sweep upper bound in Hz (default 8000.0).
    sr      : float  fallback sample rate (default 48000.0).

    Exposed state
    -------------
    ap_x1, ap_y1   : np.ndarray  per-stage input/output history (size `stages`)
    stages_coeff   : np.ndarray  the a coefficient currently in each stage
    delay_line     : DelayLine   a one-sample memory, for parity with siblings
    phase          : float       fractional LFO phase
    lfo            : float       last raw LFO value, -1..1
    cutoff_hz      : float       the frequency the coefficient was computed for
    last_wet       : float       cascade output before dry mix
    """

    rate = Param(0.4, unit="Hz", minimum=0.0, maximum=20.0,
                 doc="LFO rate in Hz")
    depth = Param(1.0, unit="-", minimum=0.0, maximum=1.0,
                  doc="sweep depth, 0..1 of the fmin..fmax range")
    feedback = Param(0.3, unit="-", minimum=-0.99, maximum=0.99,
                     doc="cascade output fed back into the input")
    mix = Param(0.5, unit="-", minimum=0.0, maximum=1.0,
                doc="0 = dry, 1 = wet")
    stages = Param(4, unit="count", minimum=1, maximum=16,
                   doc="number of first-order allpass sections (2 notches at 4)")
    fmin = Param(100.0, unit="Hz", minimum=1.0, maximum=20_000.0,
                 doc="lower end of the sweep")
    fmax = Param(8000.0, unit="Hz", minimum=2.0, maximum=24_000.0,
                 doc="upper end of the sweep")

    def __init__(self, name: str | None = None, sr: float = 48_000.0, **params):
        self._sr: float = float(sr)
        self.ap_x1 = np.zeros(1, dtype=np.float64)
        self.ap_y1 = np.zeros(1, dtype=np.float64)
        self.stages_coeff = np.zeros(1, dtype=np.float64)
        self.delay_line = DelayLine(max_seconds=0.01, sr=self._sr)
        self.phase: float = 0.0
        self.lfo: float = 0.0
        self.cutoff_hz: float = 0.0
        self.last_wet: float = 0.0
        super().__init__(name=name, **params)

    def prepare(self, ctx) -> None:
        super().prepare(ctx)
        sr = float(getattr(ctx, "sr", self._sr) or self._sr)
        self._sr = sr
        self.delay_line.max_seconds = 0.01
        self.delay_line.delay = 1.0 / sr
        self.delay_line.feedback = 0.0
        self.delay_line.prepare(ctx)
        self._ensure_stages()

    def reset(self) -> None:
        super().reset()
        if hasattr(self, "delay_line"):
            self.delay_line.reset()
        self._ensure_stages()
        self.ap_x1[:] = 0.0
        self.ap_y1[:] = 0.0
        self.stages_coeff[:] = 0.0
        self.phase = 0.0
        self.lfo = 0.0
        self.cutoff_hz = 0.0
        self.last_wet = 0.0

    def _ensure_stages(self) -> None:
        n = max(1, int(self.p["stages"]))
        if self.ap_x1.size != n:
            self.ap_x1 = np.zeros(n, dtype=np.float64)
            self.ap_y1 = np.zeros(n, dtype=np.float64)
            self.stages_coeff = np.zeros(n, dtype=np.float64)

    def allpass_coeff(self, freq_hz: float) -> float:
        """The first-order allpass coefficient for a break frequency.

            a = (1 - tan(pi * f / fs)) / (1 + tan(pi * f / fs))

        `f <= 0` -> a = +1.0 (transparent), `f >= fs/2` -> a = 0.0 (one-sample
        delay).  Call this yourself to modulate the sweep from an external source
        instead of the built-in LFO, then write `self.stages_coeff[:] = a`.
        """
        sr = self._sr
        nyq = 0.5 * sr
        f = min(max(float(freq_hz), 0.0), nyq * 0.999)
        t = math.tan(math.pi * f / sr)
        return (1.0 - t) / (1.0 + t)

    def sweep_frequency(self) -> float:
        """Current sweep frequency in Hz, exponentially between fmin and fmax.

        The exponential (log-frequency) map is what keeps the sweep sounding
        even: the ear hears octaves, not hertz.
        """
        fmin = max(1.0, float(self.p["fmin"]))
        fmax = min(max(float(self.p["fmax"]), fmin + 1e-6), 0.49 * self._sr)
        lfo = 0.5 * (1.0 + self.lfo)                     # 0..1
        lfo = 1.0 - float(np.clip(self.p["depth"], 0.0, 1.0)) * (1.0 - lfo)
        return fmin * (fmax / fmin) ** lfo

    def process(self, x: float, ctx) -> float:
        """One sample: advance the LFO, cascade N allpasses, mix with the dry."""
        self._ensure_stages()
        sr = self._sr
        phi = self.phase + float(self.p["rate"]) / sr
        phi -= math.floor(phi)
        self.phase = phi
        self.lfo = math.sin(2.0 * math.pi * phi)

        freq = self.sweep_frequency()
        self.cutoff_hz = freq
        a = self.allpass_coeff(freq)
        self.stages_coeff[:] = a

        x = float(x)
        g = float(np.clip(self.p["feedback"], -0.99, 0.99))
        v = x + g * self.last_wet
        for i in range(self.ap_x1.size):
            x1 = self.ap_x1[i]
            y1 = self.ap_y1[i]
            y = -a * v + x1 + a * y1
            self.ap_x1[i] = v
            self.ap_y1[i] = y
            self.delay_line.buffer[0] = x1         # 1-sample memory, for parity
            self.delay_line.write_index = 0
            v = y
        self.last_wet = v

        mix = float(np.clip(self.p["mix"], 0.0, 1.0))
        return x * (1.0 - mix) + v * mix


# ---------------------------------------------------------------------------
# Waveshaping / quantisation
# ---------------------------------------------------------------------------

def _shape_tanh(x: float, k: float) -> float:
    """y = tanh(k * x).  Odd, soft, monotonic saturation."""
    return math.tanh(k * x)


def _shape_atan(x: float, k: float) -> float:
    """y = atan(k * x) / atan(k).  Odd, softer than tanh, gentler knee."""
    return math.atan(k * x) / math.atan(k)


def _shape_soft(x: float, k: float) -> float:
    """Cubic soft clip on |x| <= 1 (odd and *polynomial*):

        y = 1.5 * u - 0.5 * u^3,  u = clip(k * x, -1, 1)

    Its Taylor series terminates after the cubic term, so for small drive the
    limiter is genuinely third-order: the dominant new partial is 3*f0, with 5*f0
    and up appearing only once the input exceeds the clip point.  The waveform is
    continuous with a discontinuous derivative at the knee -> faster rolloff than
    tanh, so less buzzy at high drive.
    """
    u = k * x
    if u > 1.0:
        u = 1.0
    elif u < -1.0:
        u = -1.0
    return 1.5 * u - 0.5 * u * u * u


def _shape_hard(x: float, k: float) -> float:
    """y = clip(k * x, -1, 1).  Infinite-gain limiter: the harshest curve.

    Output touches +/-1 with a corner discontinuity.  The output spectrum of a
    clipped sine is the Fourier series of a trapezoid/square-ish wave, so it
    fills every odd harmonic with a slow (roughly 1/n) rolloff: the square-wave
    buzz that can alias badly at high drive.
    """
    u = k * x
    if u > 1.0:
        return 1.0
    if u < -1.0:
        return -1.0
    return u


def _shape_fold(x: float, k: float) -> float:
    """Wavefolding -- y = fold(k * x) by reflecting at +/-1.

    Implemented with the triangular wave identity

        y = 4 * |0.5 * ((u + 1) / 4 - floor((u + 1) / 4 + 0.5))| - 1

    which is the odd, periodic triangle of period 4 in u: it mirrors instead of
    clipping.  Folding is *not* a saturator: increasing drive adds new partials
    without limit and the harmonic content alternates rather than asymptoting,
    which is why it is used for metallic/bell timbres.
    """
    u = k * x
    q = (u + 1.0) * 0.25
    q -= math.floor(q + 0.5)
    return 4.0 * abs(q) - 1.0


def _shape_cheby(x: float, k: float, harmonic: int = 2) -> float:
    """Chebyshev waveshaping: y = T_n(clamp(k*x, -1, 1)).

    The Chebyshev polynomials satisfy `T_n(cos(theta)) = cos(n * theta)`.  A
    full-scale sine `x = cos(theta)` therefore maps to a pure `n`-th harmonic with
    **no other partials at all** -- exact harmonic generation rather than the
    broadband spray of tanh/hard clipping.  The mapping is only exact for a
    unit-amplitude input, so `k` must bring the signal to full scale first.

    Stability: `T_n` grows like `|u|**n` outside [-1, 1] but stays bounded by 1
    inside, so evaluating it on an out-of-range argument amplifies rounding noise
    astronomically (a 1-ULP overshoot of the clamp showed up as a spurious partial
    1e5 times the fundamental).  The argument is therefore clamped to the unit
    interval, and when the clamp bites the value is taken straight from the
    defining identity rather than from the recurrence:

        T_n(1)  = cos(n * arccos(1))  = cos(0)   = +1        for every n
        T_n(-1) = cos(n * pi)                     = (-1)**n

    (Getting these the wrong way round makes the curve discontinuous at the peaks,
    which sprays a comb of spurious partials across the spectrum.)  For
    `|u| < 1`, `T_n` is evaluated by `T_{n+1} = 2 u T_n - T_{n-1}`, which is
    numerically well behaved inside the ring.  See `to_polynomial` for the
    coefficients.
    """
    n = max(0, int(harmonic))
    u = k * x
    if u >= 1.0:
        return 1.0
    if u <= -1.0:
        return -1.0 if n % 2 else 1.0
    if n == 0:
        return 1.0
    if n == 1:
        return u
    tm1 = 1.0
    t = u
    for _ in range(2, n + 1):
        tm1, t = t, 2.0 * u * t - tm1
    return t


def _shape_hard_knee(x: float, k: float) -> float:
    """Alias of `_shape_hard` kept for symmetry with the other names."""
    return _shape_hard(x, k)


class Waveshaper(Block):
    """Memoryless non-linearity -- static distortion that adds harmonics.

    Maths
    -----
    A memoryless function `y = f(k * x + bias)` cannot create new frequencies by
    itself: it *rearranges* the spectrum of whatever you feed it.  For a sine
    input `x = A cos(w t)`, moose rule says the harmonics produced, and their
    amplitudes, are the Fourier coefficients of `f`.  The practical consequences
    of each `shape`:

    =========  ====================  ===========================================
    shape      curve                 harmonic series of a sine input
    =========  ====================  ===========================================
    ``tanh``   tanh(k*x)             every *odd* harmonic; amplitudes fall off
                                     exponentially fast -> warm, gentle, no
                                     aliasing-friendly high end
    ``atan``   atan(k*x)/atan(k)     odd harmonics, even softer knee than tanh,
                                     slightly more low-order content
    ``soft``   1.5u - 0.5u^3         odd harmonics; polynomial cubic, so the
               (u=clip(k*x,-1,1))    series terminates early and 3*f0 dominates
    ``hard``   clip(k*x,-1,1)        odd harmonics with a ~1/n rolloff: a
                                     square-ish buzz that *will* alias when
                                     k*f0 approaches Nyquist
    ``fold``   reflect at +/-1       odd harmonics, endlessly rich as k rises;
                                     metallic, great for bell timbres
    ``cheby``  T_harmonic(k*x)       exactly *one* harmonic (the `harmonic`-th)
                                     for a unit-amplitude sine
    =========  ====================  ===========================================

    `bias` adds DC before the curve.  A symmetric curve (all of the above are
    odd) then produces no even harmonics; a non-zero bias breaks the symmetry and
    brings in 2*f0, 4*f0, ... .  That is the standard way to get even harmonics
    from an odd shaper, so it is exposed as a parameter rather than hidden.

    Parameters
    ----------
    drive   : float  pre-gain k applied before the curve (default 1.0). Scaling
                     the input scales the harmonic content, and for Chebyshev it
                     must reach 1.0 to be exact.
    bias    : float  DC offset added before the curve (default 0.0).
    mix     : float  0 = dry, 1 = fully shaped (default 1.0).
    shape   : str    one of the six curve names above (default "tanh").
    harmonic: int    Chebyshev order n, ignored by the other shapes (default 2).
    sr      : float  fallback sample rate (default 48000.0, unused here).

    Exposed state
    -------------
    shaper     : callable  the resolved curve `f(u, k)` -- swapped in `prepare`,
                           never looked up per sample
    last_wet   : float     last shaped (pre-mix) sample
    last_drive : float     the effective drive used last sample
    """

    drive = Param(1.0, unit="-", minimum=0.0, maximum=1000.0,
                  doc="pre-gain k into the curve")
    bias = Param(0.0, unit="-", minimum=-1.0, maximum=1.0,
                 doc="DC offset before the curve; breaks odd symmetry -> even harmonics")
    mix = Param(1.0, unit="-", minimum=0.0, maximum=1.0,
                doc="0 = dry, 1 = fully shaped")
    shape = Param("tanh", unit="", minimum=None, maximum=None,
                  doc="tanh | atan | soft | hard | fold | cheby")
    harmonic = Param(2, unit="count", minimum=0, maximum=64,
                     doc="Chebyshev order for shape='cheby'")

    DEFAULT_SHAPERS: Mapping[str, Callable[..., float]] = {
        "tanh": _shape_tanh,
        "atan": _shape_atan,
        "soft": _shape_soft,
        "hard": _shape_hard,
        "fold": _shape_fold,
        "cheby": _shape_cheby,
    }

    def __init__(self, name: str | None = None, sr: float = 48_000.0, **params):
        self._sr: float = float(sr)
        self.shaper: Callable[..., float] = _shape_tanh
        self.last_wet: float = 0.0
        self.last_drive: float = 0.0
        self._shaper_key = None
        super().__init__(name=name, **params)
        # Validate immediately so a typo fails loudly at construction time.
        self.shaper = self.resolve_shaper(self.p["shape"])
        self._shaper_key = self.shaper_key()

    def prepare(self, ctx) -> None:
        super().prepare(ctx)
        self._sr = float(getattr(ctx, "sr", self._sr) or self._sr)
        self.shaper = self.resolve_shaper(self.p["shape"])
        self._shaper_key = self.shaper_key()

    def reset(self) -> None:
        """Memoryless: nothing to clear, but the hook stays for combinators."""
        super().reset()
        self.last_wet = 0.0
        self.last_drive = 0.0

    def shaper_key(self):
        """Identity of the resolved curve. Used to detect when it must be rebuilt.

        Includes `harmonic` because the Chebyshev curve is parameterised by it --
        leaving it out is why `shape="cheby", harmonic=5` used to silently produce
        the 2nd harmonic.
        """
        return (self.p["shape"], self.p["harmonic"])

    def resolve_shaper(self, shape) -> Callable[..., float]:
        """Return the callable for a `shape` name (or a callable, passed through).

        Called once in `prepare`; the resolved callable is cached on `self.shaper`
        so the per-sample path never touches a dict or an `if` chain.  Assign
        `self.shaper = your_own_function` to experiment without subclassing:

            shaper.shaper = lambda u, k: math.sin(k * u)   # your own curve

        The returned callable always has the 2-argument `(u, k)` signature, so a
        curve that needs more configuration closes over it instead.
        """
        if callable(shape):
            return shape
        key = str(shape)
        try:
            curve = self.DEFAULT_SHAPERS[key]
        except KeyError:
            raise ValueError(
                f"unknown shape {shape!r}; known: {sorted(self.DEFAULT_SHAPERS)}"
            ) from None
        if key == "cheby":
            # Bind the harmonic order now, so the per-sample call stays 2-arg.
            harmonic = max(0, int(self.p["harmonic"]))
            return lambda u, k, n=harmonic: curve(u, k, n)
        return curve

    def process(self, x: float, ctx) -> float:
        """One shaped sample; resolves nothing per sample but the curve itself."""
        # Re-resolve only when `shape`/`harmonic` changed: a per-sample dict lookup
        # or `if` chain is exactly the overhead this caching exists to avoid.
        if self.shaper_key() != self._shaper_key:
            self.shaper = self.resolve_shaper(self.p["shape"])
            self._shaper_key = self.shaper_key()

        k = max(0.0, float(self.p["drive"]))
        if not math.isfinite(k):
            k = 0.0
        self.last_drive = k
        u = float(x) + float(self.p["bias"])
        if not math.isfinite(u):
            u = 0.0
        wet = float(self.shaper(u, k))
        self.last_wet = wet
        mix = float(np.clip(self.p["mix"], 0.0, 1.0))
        return u * (1.0 - mix) + wet * mix


def default_shapers() -> dict[str, Callable[..., float]]:
    """A copy of the built-in curve table (name -> `f(u, k)`)."""
    return dict(Waveshaper.DEFAULT_SHAPERS)


def to_polynomial(harmonic: int) -> list[float]:
    """Coefficients of the Chebyshev polynomial T_n as a plain Python list.

    Uses the recurrence `T_0 = 1`, `T_1 = x`, `T_{n+1} = 2 x T_n - T_{n-1}`, which
    makes explicit what `_shape_cheby` evaluates.  Index `i` of the returned list
    is the coefficient of `x**i`:

        >>> to_polynomial(2)
        [-1.0, 0.0, 2.0]
        >>> to_polynomial(3)
        [-3.0, 0.0, 4.0]
        >>> to_polynomial(4)
        [1.0, 0.0, -8.0, 0.0, 8.0]

    Note the `2x` terms: a naive polynomial waveshaper (`a*x^3 + b*x`) can only
    make odd harmonics in a fixed ratio, because it is a *sum* of Chebyshev
    polynomials; generating a single clean harmonic requires isolating one T_n,
    which is what `shape="cheby"` does.
    """
    n = max(0, int(harmonic))
    if n == 0:
        return [1.0]
    tm1 = [1.0]                    # T_0
    t = [0.0, 1.0]                 # T_1 = x   (index i holds the x**i coefficient)
    for _ in range(2, n + 1):
        # 2 * x * T_{n-1}: multiply every coefficient by 2 and shift up one degree.
        shifted = [0.0] + [2.0 * c for c in t]
        if len(tm1) < len(shifted):
            tm1 = tm1 + [0.0] * (len(shifted) - len(tm1))
        new = [a - b for a, b in zip(shifted, tm1)]
        tm1, t = t, new
    return t


class Bitcrush(Block):
    """Bit-depth reduction and sample-rate reduction (decimation).

    Maths
    -----
    Two independent quantisations along the two axes of a signal:

    * **amplitude**: truncation to `bits` levels.  With

          levels = 2**(bits - 1)                    # 8 levels at 4 bits
          y = trunc(x * levels) / levels

      the step size is `1 / levels` and the error is a deterministic sawtooth in
      `[-1/levels, 0]`.  `trunc` (toward zero) is used deliberately rather than
      `round`: it is the *asymmetric, DC-shifting* quantiser of classic 1980s
      hardware, and the raw (unbiased) choice.  Swapping to unbiased rounding is
      a one-line change -- replace `math.trunc` with `math.floor(m + 0.5)`; the
      measurable difference is that a low-level signal then keeps its noise floor
      centred instead of acquiring a DC offset.

    * **time**: sample-and-hold.  `downsample = M` means a new input sample is
      latched every M samples:

          if n % M == 0:  hold = x[n]
          y[n] = hold

      Holding is a zero-order hold: it repeats the spectrum at multiples of
      `fs / M`, so anything above `fs / (2M)` folds back down.  That is the
      "grainy" part of the sound.  M is rounded to an integer >= 1.

    Parameters
    ----------
    bits       : int    output bit depth, >= 1 (default 8 -> 128 levels).
    downsample : float  hold length in samples, rounded to an int (default 1).
    mix        : float  0 = dry, 1 = crushed (default 1.0).
    sr         : float  fallback sample rate (default 48000.0).

    Exposed state
    -------------
    hold      : float  the currently latched amplitude
    counter   : int    samples until the next latch (M-1 .. 0)
    step      : float  the quantisation step 1/levels in use
    last_wet  : float  last quantised sample
    """

    bits = Param(8, unit="bits", minimum=1, maximum=32,
                 doc="bit depth; levels = 2**(bits-1)")
    downsample = Param(1.0, unit="samples", minimum=1.0, maximum=4096.0,
                       doc="sample-rate reduction factor M (hold length)")
    mix = Param(1.0, unit="-", minimum=0.0, maximum=1.0,
                doc="0 = dry, 1 = crushed")

    def __init__(self, name: str | None = None, sr: float = 48_000.0, **params):
        self._sr: float = float(sr)
        self.hold: float = 0.0
        self.counter: int = 0
        self.step: float = 0.0
        self.last_wet: float = 0.0
        super().__init__(name=name, **params)

    def prepare(self, ctx) -> None:
        super().prepare(ctx)
        self._sr = float(getattr(ctx, "sr", self._sr) or self._sr)

    def reset(self) -> None:
        super().reset()
        self.hold = 0.0
        self.counter = 0
        self.step = 0.0
        self.last_wet = 0.0

    def levels(self) -> int:
        """Number of quantisation levels per polarity: `2**(bits - 1)`."""
        bits = int(np.clip(self.p["bits"], 1, 32))
        return 1 << (bits - 1)

    def hold_samples(self) -> int:
        """`downsample` rounded to an integer number of samples, minimum 1."""
        try:
            m = int(round(float(self.p["downsample"])))
        except (TypeError, ValueError):
            m = 1
        return max(1, m)

    def process(self, x: float, ctx) -> float:
        """One sample: sample-and-hold, then truncate to `bits` levels."""
        levels = self.levels()
        step = 1.0 / levels
        self.step = step
        m = self.hold_samples()

        x = float(x)
        if self.counter <= 0:
            self.counter = m - 1
            if levels <= 1:
                # 1 bit is a pure sign quantiser: +/-1 only.
                self.hold = 1.0 if x >= 0.0 else -1.0
            else:
                # Truncation toward zero (see the class docstring).
                self.hold = float(math.trunc(x * levels)) * step
        else:
            self.counter -= 1
        wet = self.hold
        self.last_wet = wet

        mix = float(np.clip(self.p["mix"], 0.0, 1.0))
        return x * (1.0 - mix) + wet * mix


# ---------------------------------------------------------------------------
# Utility blocks
# ---------------------------------------------------------------------------

class DcBlocker(Block):
    """One-pole DC blocker (a leaky differentiator around a pole at DC).

    Maths
    -----
    The transfer function is

        H(z) = (1 - z^-1) / (1 - a * z^-1),   y[n] = x[n] - x[n-1] + a * y[n-1]

    with the pole `a` placed just inside the unit circle.  The zero at z = 1
    removes DC exactly; the pole at z = a keeps the response flat above the
    cutoff instead of differentiating the whole spectrum.  A first-order highpass
    with cutoff `fc` has

        a = exp(-2 * pi * fc / fs)   (equivalently 1 - 2*pi*fc/fs for fc << fs)

    which puts the -3 dB point at approximately `fc`.  At fc = 20 Hz and
    48 kHz, a = 0.99740, so the tail of a decaying signal is still removed but
    everything above ~20 Hz passes within 0.001 dB.

    State is the classic pair `x1`, `y1`; both are exposed so you can seed them
    (e.g. to run the filter backwards) or watch the DC term converge.

    Parameters
    ----------
    cutoff : float  -3 dB corner in Hz (default 20.0). 0 disables the pole
                    (a = 1.0, a pure differentiator, which *does* remove DC but
                    colours the low end badly).
    sr     : float  fallback sample rate (default 48000.0).

    Exposed state
    -------------
    x1 : float  previous input sample
    y1 : float  previous output sample
    a  : float  the pole coefficient currently in use
    """

    cutoff = Param(20.0, unit="Hz", minimum=0.0, maximum=1000.0,
                   doc="-3 dB corner frequency in Hz")

    def __init__(self, name: str | None = None, sr: float = 48_000.0, **params):
        self._sr: float = float(sr)
        self.x1: float = 0.0
        self.y1: float = 0.0
        self.a: float = 0.0
        super().__init__(name=name, **params)

    def prepare(self, ctx) -> None:
        super().prepare(ctx)
        self._sr = float(getattr(ctx, "sr", self._sr) or self._sr)

    def reset(self) -> None:
        super().reset()
        self.x1 = 0.0
        self.y1 = 0.0
        self.a = 0.0

    def coeff(self, cutoff_hz: float | None = None) -> float:
        """The pole coefficient `a = exp(-2*pi*fc/fs)` for a cutoff (Hz)."""
        fc = float(self.p["cutoff"]) if cutoff_hz is None else float(cutoff_hz)
        if fc <= 0.0:
            return 1.0
        return math.exp(-2.0 * math.pi * fc / self._sr)

    def process(self, x: float, ctx) -> float:
        """One sample of y[n] = x[n] - x[n-1] + a*y[n-1]."""
        a = self.coeff()
        self.a = a
        x = float(x)
        y = x - self.x1 + a * self.y1
        if not math.isfinite(y):
            y, a = 0.0, 0.0
            self.a = 0.0
        self.x1 = x
        self.y1 = y
        return y


class Gain(Block):
    """Linear and decibel gain in one block.

    Maths
    -----
        db    = 20 * log10(gain)          gain = 10 ** (db / 20)
        y[n]  = gain * x[n]               (+ `offset` when `dc` is set)

    Both parameters are live; `db` is the "musical" one and is read first, so
    writing `g.db = -6.0` at any time (including from a `Modulated` block) is the
    intended way to automate a level.  Setting `gain` directly *also* works and
    overwrites the equivalent dB value -- the two are kept in sync by
    `_sync_from_gain` / `_sync_from_db`, and `self.gain`/`self.db` are the live
    values in use.

    `db = -inf` (a gain of exactly zero) is representable: db -> -400 is clamped
    to digital silence.  NaNs are floored to 0.0 rather than propagated.

    Parameters
    ----------
    gain   : float  linear multiplier (default 1.0).
    db     : float  level in decibels (default 0.0); takes precedence over `gain`
                    for the "source of truth" display.
    dc     : float  constant offset added after gain (default 0.0), useful for
                    deliberately breaking a shaper's odd symmetry.
    sr     : float  fallback sample rate (default 48000.0, unused).

    Exposed state
    -------------
    gain : float  the linear value actually applied
    db   : float  its decibel equivalent
    """

    gain = Param(1.0, unit="-", minimum=0.0, maximum=1000.0,
                 doc="linear multiplier")
    db = Param(0.0, unit="dB", minimum=-400.0, maximum=120.0,
               doc="level in decibels (overrides `gain` when set)")
    dc = Param(0.0, unit="-", minimum=-10.0, maximum=10.0,
               doc="constant offset added after the gain")

    def __init__(self, name: str | None = None, sr: float = 48_000.0, **params):
        self._sr: float = float(sr)
        super().__init__(name=name, **params)
        self.sync(which="db")

    def prepare(self, ctx) -> None:
        super().prepare(ctx)
        self._sr = float(getattr(ctx, "sr", self._sr) or self._sr)
        self.sync(which="db")

    def reset(self) -> None:
        """Stateless: only re-asserts the gain/db consistency."""
        super().reset()
        if hasattr(self, "p"):
            self.sync(which="db")

    @staticmethod
    def db_to_gain(db: float) -> float:
        """`10 ** (db / 20)`; -inf is clamped to a true zero."""
        db = float(db)
        if db <= -400.0 or not math.isfinite(db):
            return 0.0
        return 10.0 ** (db / 20.0)

    @staticmethod
    def gain_to_db(gain: float) -> float:
        """`20 * log10(gain)`; a zero or negative gain maps to -400 dB."""
        gain = float(gain)
        if gain <= 0.0 or not math.isfinite(gain):
            return -400.0
        return 20.0 * math.log10(gain)

    def sync(self, which: str = "db") -> float:
        """Copy `db -> gain` (or `gain -> db`) and return the linear value.

        `which="db"` treats the dB parameter as the source of truth (the default,
        so `Gain(db=-6)` does what you expect); `which="gain"` goes the other way.
        """
        if which == "db":
            g = self.db_to_gain(float(self.p["db"]))
            self.p["db"] = self.gain_to_db(g)
            self.p["gain"] = g
            return g
        g = max(0.0, float(self.p["gain"]))
        self.p["gain"] = g
        self.p["db"] = self.gain_to_db(g)
        return g

    @property
    def linear(self) -> float:
        """The linear gain currently applied (mirrors the `gain` parameter)."""
        return float(self.p["gain"])

    def process(self, x: float, ctx) -> float:
        """One sample: `y = gain * x + dc`."""
        g = self.sync(which="db")
        offset = float(self.p["dc"])
        y = g * float(x) + offset
        if not math.isfinite(y):
            return 0.0
        return y
