"""
Measurement functions for judging what a synthesis algorithm actually produced.

This module is deliberately **not** made of `Block`s.  It is a toolbox of pure
functions over numpy arrays: you render something with `synthlab.core.render`,
hand the samples to these functions, and read numbers back.  That is how you
verify a claim like "this oscillator is alias-free" or "tanh drive 4 adds odd
harmonics at -20 dB" instead of believing it.

What is implemented, and why each one is worth having
-----------------------------------------------------
* `spectrum`            windowed rfft in dB, calibrated so a full-scale sine is 0 dB
* `peak_frequencies`    strongest peaks with **parabolic (log-magnitude) sub-bin
                        interpolation** -- an FFT bin is `sr / N` wide, and at
                        48 kHz / 0.25 s that is 4 Hz, far too coarse to check a
                       440 Hz oscillator
* `dominant_frequency`  the above, reduced to one number
* `cents_error`         1200 * log2(measured / target); the ear's own unit
* `harmonic_amplitudes` **Goertzel** DFT at the *exact* harmonic frequencies -- no
                        bin snapping, so 2*f0 is measured where it really is even
                        when it falls between bins
* `thd`                 sqrt(sum of harmonic 2..N squared) / fundamental, a ratio
* `envelope`            sliding-window RMS -> amplitude over time
* `rms` / `peak` / `crest_factor`
* `zero_crossing_rate`  cheap proxy for noisiness / brightness
* `report`              the one-call summary you print in an experiment
* `describe_aliasing`   out-of-band energy above 0.45 * sr (+ a fold-down check
                        against a known f0) -- the direct evidence for or against
                        aliasing

Conventions
-----------
* Inputs are converted with `np.asarray(x, dtype=np.float64).ravel()`; anything
  that looks like a stereo pair `(n, 2)` is averaged to mono.
* Every function is total: empty/one-sample/silent input returns zeros, NaNs or a
  documented empty result instead of raising, because a failed experiment should
  still print a number you can look at.
* Magnitudes are **dBFS**: 0 dB means a full-scale sine, not a full-scale DC or
  square wave (those read +3 dB and +3.9 dB respectively, correctly, because they
  have more energy than a sine of the same peak).

Key spectral definitions
------------------------
    N      = len(window);  df = sr / N      (bin spacing, Hz)
    X[k]   = sum_n w[n] * x[n] * exp(-2j*pi*k*n/N)     (one-sided)
    A[k]   = 2 * |X[k]| / sum(w)                        (amplitude-corrected)
    dB[k]  = 20 * log10(A[k] / 1.0)
The `2 / sum(w)` factor is what makes a full-scale sine read 0 dB; DC and
Nyquist are not doubled in a real two-sided transform, so they read 6 dB high
here -- a documented, harmless edge case for a *relative* spectrum.
"""

from __future__ import annotations

import math
from typing import Any

import numpy as np

__all__ = [
    "HANN",
    "spectrum",
    "peak_frequencies",
    "dominant_frequency",
    "cents_error",
    "harmonic_amplitudes",
    "goertzel",
    "thd",
    "envelope",
    "rms",
    "peak",
    "crest_factor",
    "zero_crossing_rate",
    "report",
    "describe_aliasing",
]

#: dB floor used everywhere a log of zero would otherwise appear (-240 dB).
_DB_FLOOR: float = 1e-12

#: Lowest frequency `peak_frequencies` considers by default (Hz). Below this the
#: window's main lobe and any DC offset dominate.
_MIN_PEAK_HZ: float = 20.0


# ---------------------------------------------------------------------------
# Windowing
# ---------------------------------------------------------------------------

def _hann(n: int) -> np.ndarray:
    """Periodic (DFT-even) Hann window of length `n`.

    `w[i] = 0.5 - 0.5 * cos(2*pi*i/n)` -- the *periodic* form, whose denominator
    is `n` rather than `n-1`.  It is the right choice for spectral analysis
    because it matches the FFT's implicit periodic extension of the signal.
    """
    if n <= 0:
        return np.zeros(0, dtype=np.float64)
    if n == 1:
        return np.ones(1, dtype=np.float64)
    i = np.arange(n, dtype=np.float64)
    return 0.5 - 0.5 * np.cos(2.0 * np.pi * i / n)


#: A 2048-point periodic Hann window, for casual inspection. Sized lazily when
#: the module is imported; `spectrum` builds its own window whenever the input
#: length differs.
HANN: np.ndarray = _hann(2048)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _mono(x: Any) -> np.ndarray:
    """Coerce anything array-ish to a 1-D float64 mono signal.

    `(n, channels)` input is averaged across channels.  Non-finite samples are
    replaced by 0.0 so one NaN cannot poison an entire measurement.
    """
    a = np.asarray(x, dtype=np.float64)
    if a.ndim > 1:
        a = a.mean(axis=1) if a.shape[0] >= a.shape[-1] else a.mean(axis=0)
    a = a.ravel()
    if a.size and not np.isfinite(a).all():
        a = np.nan_to_num(a, nan=0.0, posinf=0.0, neginf=0.0)
    return a


def _safe_db(value: float) -> float:
    v = float(value)
    if not math.isfinite(v) or v <= 0.0:
        return -240.0
    return max(-240.0, 20.0 * math.log10(v))


def goertzel(x: Any, freq_hz: float, sr: float = 48_000.0,
             window: bool = True) -> complex:
    """DFT of `x` at one **exact** frequency, by the Goertzel algorithm.

    Maths
    -----
    The DFT bin at frequency `f` with `k = f * N / sr` (fractional k allowed) is

        X(f) = sum_n w[n] * x[n] * exp(-2j * pi * f * n / sr)

    This is evaluated in O(N) with a second-order recurrence instead of O(N log N)
    or an O(N) complex exponential per sample:

        c    = 2 * cos(2*pi*f/sr)
        s[n] = w[n]*x[n] + c*s[n-1] - s[n-2]
        X    = s[N-1] - exp(-2j*pi*f/sr) * s[N-2]

    which is stable for every f (the poles sit exactly on the unit circle and are
    never accumulated far enough to matter) and needs two floats of state.  Because
    the final step is complex, `X` carries the phase as well as the magnitude.

    A Hann window is applied by default so that a tone falling *between* bins does
    not leak; with `window=False` the full leakage of the rectangular window is
    exposed, which is occasionally useful to see.

    Returns the complex bin `X`; take `abs(X) * 2 / sum(w)` for an amplitude.
    """
    a = _mono(x)
    n = a.size
    if n == 0:
        return 0.0 + 0.0j
    sr = float(sr)
    f = float(freq_hz)
    if not math.isfinite(f) or f <= 0.0 or f >= 0.5 * sr:
        return 0.0 + 0.0j

    w = _hann(n) if window else np.ones(n, dtype=np.float64)
    xw = a * w

    omega = 2.0 * math.pi * f / sr
    c = 2.0 * math.cos(omega)
    s1 = 0.0
    s2 = 0.0
    for i in range(n):
        s0 = float(xw[i]) + c * s1 - s2
        s2 = s1
        s1 = s0
    return complex(s1 - complex(math.cos(omega), -math.sin(omega)) * s2)


# ---------------------------------------------------------------------------
# Spectrum
# ---------------------------------------------------------------------------

def spectrum(
    x: Any, sr: float = 48_000.0, remove_dc: bool = True
) -> tuple[np.ndarray, np.ndarray]:
    """One-sided amplitude spectrum in dBFS via a Hann-windowed rfft.

    Algorithm
    ---------
        y     = x - mean(x)                 (when remove_dc)
        w     = periodic Hann window of length N
        X     = rfft(y * w)
        A[k]  = 2 * |X[k]| / sum(w)
        dB[k] = 20 * log10(A[k])

    The `2 / sum(w)` normalisation corrects for both the window's coherent gain
    (`sum(w) / N`) and the one-sided doubling, so **a full-scale sine reads
    0 dB** at its bin.  Frequencies are `k * sr / N` for k = 0 .. N//2, i.e. the
    array covers 0 Hz to Nyquist inclusive with `N//2 + 1` points.

    DC removal is on by default and matters more than it looks. Any signal with an
    amplitude envelope has a non-zero mean (a positive-only envelope times a
    zero-mean carrier leaves a DC term), and a large DC bin leaks through the Hann
    window's sidelobes across the whole low end. That leakage is loud enough to
    beat the true fundamental, so `dominant_frequency` on an enveloped note used to
    report ~20 Hz instead of the actual pitch. Pass `remove_dc=False` if you
    genuinely want to measure an offset.

    Parameters
    ----------
    x         : array-like, coerced to mono float64.
    sr        : sample rate in Hz (default 48000).
    remove_dc : subtract the mean before windowing (default True).

    Returns
    -------
    (freqs, magnitudes_db) -- both float64, length `len(x) // 2 + 1`.
    Empty input gives two empty arrays.  Magnitudes are floored at -240 dB.
    """
    a = _mono(x)
    n = a.size
    if n == 0:
        return np.zeros(0, dtype=np.float64), np.zeros(0, dtype=np.float64)
    sr = float(sr)
    df = sr / n

    if remove_dc:
        a = a - a.mean()

    w = _hann(n)
    wsum = float(w.sum())
    if wsum <= 0.0:
        wsum = float(n) or 1.0

    spec = np.fft.rfft(a * w, n=n)
    # 2 / sum(w): one-sided doubling and the window's coherent gain in one factor.
    # For a full-scale sine exactly on a bin, |X[k]| = A * sum(w) / 2, so this
    # normalisation returns A = 1.0, i.e. 0 dB.
    mags = 2.0 * np.abs(spec) / wsum
    if mags.size:
        # DC and Nyquist are only counted once by rfft, so they are not doubled.
        mags[0] *= 0.5
        if n % 2 == 0 and mags.size > 1:
            mags[-1] *= 0.5

    freqs = np.fft.rfftfreq(n, d=1.0 / sr)
    db = 20.0 * np.log10(np.maximum(mags, _DB_FLOOR))
    return freqs.astype(np.float64), db.astype(np.float64)


# ---------------------------------------------------------------------------
# Peak picking
# ---------------------------------------------------------------------------

def peak_frequencies(
    x: Any,
    sr: float = 48_000.0,
    count: int = 8,
    min_hz: float = _MIN_PEAK_HZ,
) -> list[tuple[float, float]]:
    """The `count` strongest spectral peaks as `(frequency_hz, magnitude_db)`.

    Algorithm
    ---------
    1. Take the dB spectrum and find every strict local maximum
       (`db[i] > db[i-1] and db[i] >= db[i+1]`), ignoring bins below `min_hz`
       (DC, window main lobe) and the Nyquist edge bin.
    2. Sort by magnitude, then greedily accept peaks at least `min_hz / 2` apart
       in frequency so one broad peak cannot be reported several times.
    3. Refine each accepted peak with **parabolic interpolation on the log
       magnitude**:

           d      = 0.5 * (db[i-1] - db[i+1]) / (db[i-1] - 2*db[i] + db[i+1])
           f_peak = (i + d) * sr / N
           a_peak = db[i] - 0.25 * (db[i-1] - db[i+1]) * d

       `d` is in bins and is clamped to +/-0.5.  Interpolating the *log* magnitude
       is what makes this accurate: the main lobe of a window is close to
       parabolic in dB, and for a Hann window this estimator is good to a small
       fraction of a bin (~0.01 bin for well-separated tones).  Without it, a
       440 Hz tone between bins would be reported up to `sr / (2N)` Hz off.

    Note
    ----
    These are the strongest peaks by *energy*, which is not the same as the pitch.
    An amplitude envelope is itself a slow signal, and it imposes sidebands on
    every partial; on a short enveloped note those sidebands can outrank the
    fundamental. Use `fundamental()` (or `report(..., f0=...)`) when you want the
    pitch rather than the loudest bin.

    Parameters
    ----------
    x       : signal (coerced to mono float64).
    sr      : sample rate in Hz.
    count   : how many peaks to return (<= 0 gives an empty list).
    min_hz  : ignore bins below this frequency (default 20 Hz).

    Returns
    -------
    List of `(frequency_hz, magnitude_db)`, strongest first, at most `count` long.
    `[]` for empty or all-silent input.
    """
    a = _mono(x)
    n = a.size
    if n < 4 or int(count) <= 0:
        return []
    sr = float(sr)
    freqs, db = spectrum(a, sr)
    if db.size < 3:
        return []

    lo = max(1, int(math.floor(max(0.0, float(min_hz)) / (sr / n))))
    hi = db.size - 1 if n % 2 == 0 else db.size
    if hi - lo < 3:
        return []

    mid = db[lo:hi]
    left = db[lo - 1:hi - 1]
    right = db[lo + 1:hi + 1]
    idx = np.nonzero((mid > left) & (mid >= right))[0]
    if idx.size == 0:
        return []

    separation = max(1e-9, 0.5 * float(min_hz))
    df = sr / n
    peaks: list[tuple[float, float]] = []
    for i in idx[np.argsort(mid[idx])[::-1]]:
        k = int(i) + lo
        b = float(db[k - 1])
        c = float(db[k])
        e = float(db[k + 1])
        denom = b - 2.0 * c + e
        delta = 0.0 if denom == 0.0 else 0.5 * (b - e) / denom
        delta = float(np.clip(delta, -0.5, 0.5))
        f_peak = (k + delta) * df
        db_peak = c - 0.25 * (b - e) * delta
        if f_peak < float(min_hz):
            continue
        if any(abs(f_peak - f) < separation for f, _ in peaks):
            continue
        peaks.append((float(f_peak), float(db_peak)))
        if len(peaks) >= int(count):
            break
    return peaks


def dominant_frequency(x: Any, sr: float = 48_000.0) -> float:
    """Frequency of the strongest spectral peak in Hz, or 0.0 if there is none.

    Thin wrapper over `peak_frequencies(x, sr, count=1)`; the sub-bin parabolic
    interpolation is what makes a clean 440 Hz sine measure as 440.0 and not as
    439.4 or 442.0.

    This is the loudest bin, NOT necessarily the pitch -- see `fundamental()`.
    """
    peaks = peak_frequencies(x, sr=sr, count=1)
    return float(peaks[0][0]) if peaks else 0.0


def cents_error(measured_hz: float, target_hz: float) -> float:
    """Signed interval between two frequencies in cents.

        cents = 1200 * log2(measured / target)

    Positive means the measurement is sharp (above target), negative means flat.
    Equal frequencies give exactly 0.0; an unmeasurable measurement (<= 0 or
    non-finite) or a non-positive target gives 0.0 as well, so callers do not have
    to special-case a failed pitch detection.
    """
    m = float(measured_hz)
    t = float(target_hz)
    if t <= 0.0 or m <= 0.0 or not math.isfinite(m) or not math.isfinite(t):
        if m == t:
            return 0.0
        return 0.0
    if m == t:
        return 0.0
    return float(1200.0 * math.log2(m / t))


# ---------------------------------------------------------------------------
# Harmonic analysis
# ---------------------------------------------------------------------------

def harmonic_amplitudes(
    x: Any,
    f0: float,
    sr: float = 48_000.0,
    count: int = 12,
) -> np.ndarray:
    """Amplitudes at `f0, 2*f0, ... count*f0`, normalised to a fundamental of 1.0.

    Algorithm
    ---------
    Each harmonic is measured with `goertzel` at its **exact** frequency
    `k * f0` -- never snapped to an FFT bin.  That matters: at 48 kHz with a
    2048-point FFT the bins are 23.4 Hz apart, so bin-snapped measurement of the
    3rd harmonic of a 440 Hz tone (1320 Hz) would actually report the energy at
    1312.5 Hz.  The Goertzel recurrence evaluates the DFT at 1320.0 Hz exactly.

    Amplitudes use the same calibration as `spectrum` (`2 * |X| / sum(w)`, Hann
    window), so a full-scale sine measures 1.0.  The result is then divided by the
    fundamental's amplitude, so **`out[0]` is 1.0** whenever any fundamental
    energy at all was found; if the fundamental is silent the raw amplitudes
    (all ~0) are returned unnormalised rather than dividing by zero.

    Parameters
    ----------
    x     : signal.
    f0    : fundamental in Hz. Values <= 0, non-finite, or at/above Nyquist give
            a zero array (silence, not an exception).
    sr    : sample rate in Hz.
    count : how many harmonics (>= 1; `count` harmonics means indices 1..count).

    Returns
    -------
    np.ndarray of length `count`, `[1.0-ish, h2, h3, ...]`.
    """
    a = _mono(x)
    n = int(max(1, int(count)))
    out = np.zeros(n, dtype=np.float64)
    f0 = float(f0)
    if a.size == 0 or not math.isfinite(f0) or f0 <= 0.0 or f0 >= 0.5 * float(sr):
        return out

    w = _hann(a.size)
    wsum = float(w.sum())
    if wsum <= 0.0:
        wsum = float(a.size) or 1.0
    scale = 2.0 / wsum

    for k in range(1, n + 1):
        fk = k * f0
        if fk < 0.5 * float(sr):
            # `goertzel` applies the Hann window itself, so only the one-sided
            # amplitude calibration (2 / sum(w)) is needed here.
            out[k - 1] = scale * abs(goertzel(a, fk, sr, window=True))

    fundamental = float(out[0])
    if fundamental > _DB_FLOOR:
        out = out / fundamental
    return out


def thd(x: Any, f0: float, sr: float = 48_000.0, count: int = 12) -> float:
    """Total harmonic distortion as a **ratio** (not a percentage).

        THD = sqrt(h2^2 + h3^2 + ... + hN^2) / h1

    where `hk` is the amplitude of the k-th harmonic measured by
    `harmonic_amplitudes`.  Because that function normalises the fundamental to
    1.0, the result is `sqrt(sum(h[1:]**2))` -- dimensionless, 0.0 for a pure
    sine, > 1.0 for a heavily clipped one.  Multiply by 100 for percent.

    Harmonics at or above Nyquist are skipped (they cannot be measured) and a
    missing/silent fundamental gives 0.0 instead of a division by zero.
    """
    h = harmonic_amplitudes(x, f0, sr=sr, count=max(1, int(count)))
    if h.size < 2:
        return 0.0
    rest = h[1:]
    if not np.all(np.isfinite(rest)):
        rest = np.nan_to_num(rest, nan=0.0, posinf=0.0, neginf=0.0)
    total = float(np.sqrt(np.sum(rest * rest)))
    return total if math.isfinite(total) else 0.0


# ---------------------------------------------------------------------------
# Time-domain descriptors
# ---------------------------------------------------------------------------

def envelope(
    x: Any,
    sr: float = 48_000.0,
    window_ms: float = 10.0,
) -> tuple[np.ndarray, np.ndarray]:
    """Sliding-window RMS amplitude over time.

    Algorithm
    ---------
    For a hop of one window, window `w` covers samples `[w*H, w*H + H)` with
    `H = max(1, round(window_ms * sr / 1000))`, and

        amp[w] = sqrt( (1/H) * sum_{i in window} x[i]^2 )      (RMS)

    RMS is used rather than a peak or absolute-value envelope because it is the
    quantity that maps linearly onto perceived loudness for a steady tone, and it
    is what `rms()` reports for the whole signal.  The hop equals the window, so
    the windows do not overlap and the last partial window is dropped; `times[w]`
    is the window's centre in seconds.  Total length is `len(x) // H`.

    Parameters
    ----------
    x         : signal.
    sr        : sample rate in Hz.
    window_ms : window length in milliseconds (<= 0 falls back to 10 ms).

    Returns
    -------
    (times, amplitude) -- two float64 arrays of equal length; empty for empty input
    or a signal shorter than one window.
    """
    a = _mono(x)
    sr = float(sr)
    ms = float(window_ms)
    if not math.isfinite(ms) or ms <= 0.0:
        ms = 10.0
    hop = max(1, int(round(ms * sr / 1000.0)))
    n_windows = a.size // hop
    if n_windows <= 0:
        return np.zeros(0, dtype=np.float64), np.zeros(0, dtype=np.float64)

    trimmed = a[: n_windows * hop].reshape(n_windows, hop)
    amp = np.sqrt(np.mean(trimmed * trimmed, axis=1))
    times = (np.arange(n_windows, dtype=np.float64) + 0.5) * hop / sr
    return times, amp.astype(np.float64)


def rms(x: Any) -> float:
    """Root mean square: `sqrt(mean(x^2))`.

    A full-scale sine reads 0.7071 (-3.01 dB), a full-scale square 1.0; that 3 dB
    gap is the crest factor of the waveform, and comparing the two is a quick way
    to see how much a shaper squared off a signal.
    """
    a = _mono(x)
    if a.size == 0:
        return 0.0
    value = float(np.sqrt(np.mean(a * a)))
    return value if math.isfinite(value) else 0.0


def peak(x: Any) -> float:
    """Largest absolute sample (the *sample* peak, so true-peak inter-sample
    overs are not counted -- this is what a meter without oversampling shows)."""
    a = _mono(x)
    if a.size == 0:
        return 0.0
    value = float(np.max(np.abs(a)))
    return value if math.isfinite(value) else 0.0


def crest_factor(x: Any) -> float:
    """`peak / rms` -- how "spiky" the signal is.

        sine      1.414   (+3.01 dB)
        square    1.0     (0 dB)
        silence   -> 0.0 (documented instead of a division by zero)
        impulse   -> sqrt(N)

    A waveshaper that squares off a sine moves this from 1.41 toward 1.0, which
    is often easier to read off than a spectrum when debugging a clipper.
    """
    r = rms(x)
    if r <= 0.0 or not math.isfinite(r):
        return 0.0
    value = peak(x) / r
    return value if math.isfinite(value) else 0.0


def zero_crossing_rate(x: Any) -> float:
    """Fraction of adjacent sample pairs that change sign.

        ZCR = count(sign(x[n]) != sign(x[n-1])) / (N - 1)

    in `[0, 1]`.  Roughly proportional to the dominant frequency over the sample
    rate for a sine (`2 * f / sr`), so it doubles when a signal octave-shifts and
    rises sharply for noise.  Exactly 0.0 for constant (including silent) input and
    for fewer than two samples; a sample of exactly 0.0 is treated as positive so
    that a zero-padded impulse does not create a spurious crossing.
    """
    a = _mono(x)
    if a.size < 2:
        return 0.0
    signs = a >= 0.0
    crossings = int(np.count_nonzero(signs[1:] != signs[:-1]))
    value = crossings / float(a.size - 1)
    return value if math.isfinite(value) else 0.0


# ---------------------------------------------------------------------------
# Reports
# ---------------------------------------------------------------------------

def report(x: Any, sr: float = 48_000.0, f0: float | None = None) -> str:
    """A short human-readable summary of `x` -- paste it into an experiment log.

    Reports, always: sample count/duration, RMS, sample peak, crest factor,
    zero-crossing rate, and the dominant frequency with its level and the number
    of spectral peaks found.  When `f0` is given, it additionally reports the
    cents error of the dominant frequency against `f0`, the first five harmonic
    amplitudes (fundamental normalised to 1.0) and the THD.

    Every value is safe to print for silent, empty or NaN-containing input.
    """
    a = _mono(x)
    n = a.size
    lines = ["---- synthlab.analysis.report ----"]
    if n == 0:
        lines.append("  (empty signal)")
        lines.append("-" * 34)
        return "\n".join(lines)

    sr = float(sr)
    dur = n / sr if sr > 0 else 0.0
    dom = dominant_frequency(a, sr)
    peaks = peak_frequencies(a, sr=sr, count=5)
    lines.append(f"  samples      {n}  ({dur:.4f} s at {sr:.0f} Hz)")
    lines.append(f"  rms          {rms(a):.6f}  ({_safe_db(rms(a)):+.2f} dBFS)")
    lines.append(f"  peak         {peak(a):.6f}  ({_safe_db(peak(a)):+.2f} dBFS)")
    lines.append(f"  crest factor {crest_factor(a):.4f}")
    lines.append(f"  zcr          {zero_crossing_rate(a):.6f}")
    lines.append(f"  dominant     {dom:.2f} Hz  ({_safe_db(peak(a)) if dom <= 0 else _dominant_db(peaks):+.2f} dB)")
    if peaks:
        shown = ", ".join(f"{f:.2f}@{m:.1f}dB" for f, m in peaks)
        lines.append(f"  top peaks    {shown}")

    if f0 is not None:
        try:
            f0f = float(f0)
        except (TypeError, ValueError):
            f0f = 0.0
        if f0f > 0.0 and math.isfinite(f0f):
            lines.append(f"  target f0    {f0f:.2f} Hz")
            if dom > 0.0:
                lines.append(
                    f"  cents error  {cents_error(dom, f0f):+.2f} cents "
                    f"({_cents_word(cents_error(dom, f0f))})"
                )
            else:
                lines.append("  cents error  n/a (no measurable peak)")
            h = harmonic_amplitudes(a, f0f, sr=sr, count=5)
            harmonic_txt = "  ".join(
                f"h{i + 1}={h[i]:.4f}" for i in range(min(5, h.size))
            )
            lines.append(f"  harmonics    {harmonic_txt}")
            lines.append(f"  thd          {thd(a, f0f, sr=sr, count=12):.6f}")
    lines.append("-" * 34)
    return "\n".join(lines)


def _dominant_db(peaks: list[tuple[float, float]]) -> float:
    return float(peaks[0][1]) if peaks else -240.0


def _cents_word(cents: float) -> str:
    if abs(cents) < 1e-9:
        return "exact"
    if abs(cents) < 5.0:
        return "in tune"
    if abs(cents) < 20.0:
        return "sharp" if cents > 0 else "flat"
    return "badly sharp" if cents > 0 else "badly flat"


def describe_aliasing(x: Any, sr: float = 48_000.0, f0: float | None = None) -> str:
    """Report out-of-band energy, i.e. the direct evidence of aliasing.

    How it works
    ------------
    A signal that is properly band-limited to Nyquist has nothing above `sr / 2`.
    Any energy the analysis finds in the top of the band is either a legitimate
    partial near Nyquist or the result of a non-linearity / discontinuity folding
    high harmonics back down.  Two numbers are printed:

    * **out-of-band ratio**: energy above `0.45 * sr` divided by the total energy
      of the spectrum.  `0.45` rather than `0.5` leaves a margin for the window's
      main lobe so that a clean 440 Hz sine does not look like it is aliasing.
    * **fold-down level** (only when `f0` is given): the strongest peak that is
      *not* within 8% of one of the first 24 harmonics of `f0`, relative to the
      fundamental in dB.  Aliased partials are inharmonic by construction, so this
      catches the classic "a high harmonic of the drive tone mirrored back to
      6 kHz" signature that a spectral centroid would hide.

    Interpretation: `out-of-band < -60 dB` and no anomalously loud inharmonic peak
    means the oscillator under test is effectively band-limited; `> -20 dB` means
    it is generating real aliasing you can hear (and should oversample or use a
    different waveform generator).
    """
    a = _mono(x)
    sr = float(sr)
    lines = ["---- synthlab.analysis.aliasing check ----"]
    if a.size < 8:
        lines.append("  (signal too short to analyse)")
        lines.append("-" * 42)
        return "\n".join(lines)

    freqs, db = spectrum(a, sr)
    lin = 10.0 ** (db / 20.0)
    total = float(np.sum(lin * lin))
    cutoff = 0.45 * sr
    out_band = float(np.sum((lin * lin)[freqs >= cutoff]))
    ratio_db = _safe_db(math.sqrt(out_band / total)) if total > 0.0 else -240.0

    lines.append(f"  sample rate      {sr:.0f} Hz   (Nyquist {0.5 * sr:.0f} Hz)")
    lines.append(f"  analysis bins    {freqs.size}  (df {sr / a.size:.4f} Hz)")
    lines.append(f"  energy > 0.45*sr {out_band:.3e} of {total:.3e}")
    lines.append(f"  out-of-band      {ratio_db:+.2f} dB relative to the whole spectrum")
    if ratio_db > -20.0:
        lines.append("  VERDICT          lots of out-of-band energy -> aliasing likely")
    elif ratio_db > -60.0:
        lines.append("  VERDICT          some out-of-band energy -> check the fold-downs")
    else:
        lines.append("  VERDICT          effectively band-limited")

    if f0 is not None:
        try:
            f0f = float(f0)
        except (TypeError, ValueError):
            f0f = 0.0
        if f0f > 0.0 and math.isfinite(f0f):
            peaks = peak_frequencies(a, sr=sr, count=24, min_hz=max(20.0, f0f * 0.5))
            if peaks:
                fundamental_db = peaks[0][1]
                worst: tuple[float, float] | None = None
                for f, m in peaks:
                    ratio = f / f0f
                    nearest = round(ratio)
                    inharmonic = nearest < 1 or abs(ratio - nearest) > 0.08 * nearest
                    if inharmonic and (worst is None or m > worst[1]):
                        worst = (f, m)
                if worst is not None:
                    lines.append(
                        f"  loudest inharmonic peak  {worst[0]:.2f} Hz at "
                        f"{worst[1] - fundamental_db:+.2f} dB rel. f0"
                    )
                    if worst[1] - fundamental_db > -40.0:
                        lines.append("  (that is loud enough to hear as aliasing)")
                else:
                    lines.append("  loudest inharmonic peak  none above the f0 threshold")
            lines.append(f"  reference f0     {f0f:.2f} Hz")
    lines.append("-" * 42)
    return "\n".join(lines)
