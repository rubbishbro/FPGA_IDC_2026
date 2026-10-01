"""
Matplotlib visualisation for DSP experiments.

Design rule
-----------
`matplotlib` (and `matplotlib.pyplot`) are imported *inside* every function, never
at module top level. That keeps `synthlab.plotting` importable on a headless box,
inside a CI job, or before any display backend exists -- you only pay the import
cost when you actually draw something. When `show=False` the figure is returned
and nothing is displayed, so you can save it, embed it in a notebook, or feed it
to a test harness. `plt.show()` is called at most once per function call and only
when `show=True`.

How to read these plots
-----------------------
* `waveform`        -- amplitude vs time: the raw shape. Use it to spot clicks,
                       DC offset, clipping and asymmetry.
* `spectrum_plot`   -- magnitude vs log frequency in dB: which partials exist and
                       how far down the noise/harmonics sit. Octave gridlines.
* `spectrogram`     -- dB colour vs (time, frequency): how the spectrum *moves*.
                       The right tool for sweeps, modulation and transients.
* `envelope_plot`   -- smoothed amplitude vs time: attack/decay/sustain/release.
* `compare`         -- several signals on one axes, for A/B of two algorithms.
* `multiplot`       -- one stacked axes per signal, for a before/after chain.

Silent (all-zero) input is handled explicitly: logs are floored, so you get a
flat floor line instead of `-inf`, and no "divide by zero in log" warning.
"""

from __future__ import annotations

from typing import Sequence

import numpy as np

#: Library-wide default sample rate in Hz (mirrors `synthlab.io.SR`).
SR = 48_000

#: Power/amplitude floor for log conversions. -240 dB -- low enough that a real
#: signal is never floored, high enough that `log10` never sees an exact zero.
_EPS = 1e-12


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

__all__ = [
    "compare",
    "envelope_plot",
    "multiplot",
    "spectrogram",
    "spectrum_plot",
    "waveform",
]


def _as_float_array(x) -> np.ndarray:
    """Return `x` as a contiguous float64 array (mono (N,) or (N, C))."""
    arr = np.asarray(x)
    if arr.dtype != np.float64:
        arr = arr.astype(np.float64)
    return np.ascontiguousarray(arr)


def _prepare_backend(show: bool) -> None:
    """Force a non-interactive backend when the caller does not want a window.

    Must run *before* pyplot is imported, which is why every public function
    calls it first. If matplotlib is already loaded with a GUI backend we leave
    it alone -- switching backends after import does not take effect anyway.
    """
    if show:
        return
    import sys

    if "matplotlib.pyplot" in sys.modules or "matplotlib.backends" in sys.modules:
        return
    try:
        import matplotlib

        if "agg" not in matplotlib.get_backend().lower():
            matplotlib.use("Agg", force=True)
    except Exception:  # pragma: no cover - matplotlib missing/broken
        return


def _require_pyplot():
    """Import and return `matplotlib.pyplot`, with a clear error if unavailable."""
    try:
        import matplotlib.pyplot as plt
    except Exception as exc:  # pragma: no cover
        raise ValueError(
            "matplotlib is not importable; install it with `pip install matplotlib`"
        ) from exc
    return plt


def _time_axis(n: int, sr: int) -> tuple[np.ndarray, str]:
    """Build a time axis and return it with its unit label.

    Picks milliseconds for buffers shorter than 2 s and seconds otherwise, so a
    one-cycle plot is not squashed against the left edge of a 0..30 s axis.
    """
    if n <= 1:
        return np.zeros(n, dtype=np.float64), "ms"
    duration = n / float(sr)
    if duration < 2.0:
        return np.arange(n, dtype=np.float64) * (1000.0 / sr), "ms"
    return np.arange(n, dtype=np.float64) / sr, "s"


def _octave_ticks(f_min: float, f_max: float) -> list[float]:
    """Return octave frequencies (20, 50, 100, 200, ...) inside the range."""
    if not np.isfinite(f_max) or f_max <= 0:
        return []
    ticks = []
    for decade in (10.0, 100.0, 1000.0, 10000.0, 100000.0):
        for mult in (1.0, 2.0, 5.0):
            f = decade * mult
            if f_min <= f <= f_max:
                ticks.append(f)
    return ticks


def _inline_spectrum(x: np.ndarray, window: np.ndarray) -> np.ndarray:
    """One-sided magnitude spectrum of the last axis, normalised by the window.

    This is the fallback used when `synthlab.analysis` is not importable. It is a
    plain rfft with a coherent-gain window correction: dividing by the sum of the
    window means a full-scale sine reads 0 dB regardless of window choice.

    Output length is ``N // 2 + 1`` and is **not** truncated to the window, so
    the frequency resolution always matches the number of samples you passed in.
    """
    arr = np.atleast_2d(x)
    n = arr.shape[-1]
    if n == 0:
        return np.zeros((arr.shape[0], 0), dtype=np.float64)
    window = np.asarray(window, dtype=np.float64)
    if window.size > n:
        window = window[:n]
    if window.size < n:
        window = np.concatenate([window, np.zeros(n - window.size)])
    norm = float(np.sum(window))
    if norm == 0.0:
        norm = 1.0
    return np.abs(np.fft.rfft(arr * window, axis=-1)) / norm


def _spectrum_1d(x: np.ndarray, sr: int, n_fft: int | None = None):
    """Magnitude spectrum of a 1-D buffer, preferring `synthlab.analysis`.

    `synthlab.analysis` is written in parallel and may not exist (or may be
    broken midway through being written), so it is imported lazily inside a
    try/except and any failure falls back to the inline rfft above. There is no
    hard dependency in either direction.

    Returns
    -------
    (magnitudes, freqs) with matching shapes, both float64.
    """
    from numpy import hanning

    window = hanning(1024)
    if n_fft is not None and n_fft > 0:
        window = hanning(int(n_fft))

    try:
        from .analysis import spectrum  # type: ignore

        result = spectrum(np.asarray(x, dtype=np.float64), sr=sr, window=window)
        if isinstance(result, tuple) and len(result) >= 2:
            freq = np.asarray(result[0], dtype=np.float64).ravel()
            mag = np.asarray(result[1], dtype=np.float64).ravel()
            if freq.size == mag.size and freq.size > 1:
                return mag, freq
        arr = np.asarray(result, dtype=np.float64).ravel()
        if arr.size > 1:
            return arr, np.fft.rfftfreq(x.size, 1.0 / sr)
    except Exception:
        pass  # no analysis module yet, or a different signature: use our own

    mag = _inline_spectrum(x, window)[0]
    return mag, np.fft.rfftfreq(x.size, 1.0 / sr)


def _draw_spectrum(ax, x: np.ndarray, sr: int, min_db: float, label: str) -> None:
    """Plot one signal's dB spectrum onto `ax`, guarding log-of-zero."""
    mag, freq = _spectrum_1d(x, sr)
    if mag.size == 0:
        ax.text(0.5, 0.5, "empty signal", ha="center", va="center", transform=ax.transAxes)
        return

    peak = float(np.max(mag)) if mag.size else 0.0
    if peak <= 0.0:
        # Silent input: a flat line at the floor. No log warning, no crash.
        db = np.full(mag.shape, float(min_db), dtype=np.float64)
    else:
        db = np.maximum(20.0 * np.log10(np.maximum(mag, _EPS) / peak), float(min_db))

    positive = freq > 0
    if not np.any(positive):
        ax.plot(np.arange(mag.size), db, label=label)
        ax.set_xlabel("frequency (Hz)")
    else:
        ax.semilogx(freq[positive], db[positive], label=label)
        f_min = max(float(freq[positive][0]), 1.0)
        f_max = max(float(freq[positive][-1]), 1000.0)
        ax.set_xlim(f_min, f_max)
        ticks = _octave_ticks(f_min, f_max)
        if ticks:
            ax.set_xticks(ticks)
            ax.set_xticklabels([f"{t:g}" for t in ticks])

    ax.set_ylim(float(min_db), 5.0)
    ax.set_ylabel("magnitude (dB, peak = 0)")
    ax.grid(True, which="major", alpha=0.3)
    ax.grid(True, which="minor", alpha=0.12)
    ax.axhline(0.0, color="0.6", linewidth=0.6)


def _apply_title(fig, ax, title) -> None:
    """Apply the caller's title to the axes and the figure, if one was given."""
    if title is None or title == "":
        return
    ax.set_title(str(title))
    try:
        fig.suptitle(str(title))
    except Exception:  # pragma: no cover
        pass


# ---------------------------------------------------------------------------
# Public plots
# ---------------------------------------------------------------------------

def waveform(x, sr: int = SR, seconds: float | None = None, title="", show: bool = True):
    """Plot a signal in the time domain: sample amplitude vs time.

    What it shows
    -------------
    The raw waveform. This is where you see the things a spectrum hides: a click
    at a buffer boundary (a vertical step), DC offset (the trace not centred on
    zero), clipping (flat tops), exponential decay shapes, and whether two
    oscillators are actually in tune at the start of a note.

    Parameters
    ----------
    x:
        (N,) float signal, or (N, C) multichannel (each channel is drawn, with a
        legend). Integer input is converted to float64.
    sr:
        Sample rate in Hz, used only to scale the time axis.
    seconds:
        Plot only the first `seconds` of audio. ``None`` (default) shows all of
        it. Use it to zoom into an attack or a few cycles. (Note: despite the
        name, this is a *duration*, in seconds.)
    title:
        Applied to both the axes and the figure when non-empty.
    show:
        ``True`` calls `plt.show()` once (blocking with an interactive backend).
        ``False`` never shows and forces the Agg backend, so it is safe headless.

    Returns
    -------
    matplotlib.figure.Figure
        The figure, so you can `.savefig(...)` it or embed it.
    """
    _prepare_backend(show)
    plt = _require_pyplot()

    arr = _as_float_array(x)
    if arr.ndim == 0:
        raise ValueError("waveform needs a 1-D or 2-D signal, got a scalar")
    if seconds is not None and arr.ndim >= 1:
        limit = int(round(float(seconds) * int(sr)))
        if 0 < limit < arr.shape[0]:
            arr = arr[:limit]

    n = arr.shape[0]
    t, unit = _time_axis(n, int(sr))

    fig, ax = plt.subplots(figsize=(10, 3.2))
    if arr.ndim == 1:
        ax.plot(t, arr, linewidth=0.8)
    else:
        for ch in range(arr.shape[1]):
            ax.plot(t, arr[:, ch], linewidth=0.8, label=f"ch {ch}")
        ax.legend(loc="upper right", fontsize=8)
    ax.set_xlabel(f"time ({unit})")
    ax.set_ylabel("amplitude")
    ax.grid(True, alpha=0.3)
    ax.margins(x=0.0)  # the x axis spans exactly the plotted audio, no padding
    _apply_title(fig, ax, title)
    fig.tight_layout()
    if show:
        plt.show()
    return fig


def spectrum_plot(x, sr: int = SR, min_db: float = -120, title="", show: bool = True):
    """Plot a magnitude spectrum in dB against a logarithmic frequency axis.

    What it shows
    -------------
    Which frequencies are present and how loud they are. 0 dB is the single
    loudest bin in the buffer (everything is normalised to its own peak), so the
    plot answers "how far below the fundamental is this harmonic / this noise
    floor?" rather than "how loud is this file?". Octave gridlines (20, 50, 100,
    200, 500 Hz, ...) make harmonic ratios easy to read off: a partial sitting on
    the 3rd line above the fundamental is the 3rd harmonic.

    Implementation
    --------------
    Prefers `synthlab.analysis.spectrum` and falls back to an inline Hann-windowed
    rfft (coherent-gain normalised) if that module is absent or raises. The import
    happens inside this function, so `synthlab.plotting` never hard-depends on it.

    Parameters
    ----------
    x:
        (N,) signal, or (N, C) multichannel (one curve per channel).
    sr:
        Sample rate in Hz; sets the frequency axis.
    min_db:
        Bottom of the dB axis (default -120). Values below are clamped, which is
        also what keeps an all-zero buffer from producing -inf.
    title / show:
        As in `waveform`.

    Returns
    -------
    matplotlib.figure.Figure
    """
    _prepare_backend(show)
    plt = _require_pyplot()

    arr = _as_float_array(x)
    if arr.ndim == 0:
        raise ValueError("spectrum_plot needs a 1-D or 2-D signal, got a scalar")

    fig, ax = plt.subplots(figsize=(10, 4))
    if arr.ndim == 1:
        _draw_spectrum(ax, arr, int(sr), float(min_db), "signal")
    else:
        for ch in range(arr.shape[1]):
            _draw_spectrum(ax, arr[:, ch], int(sr), float(min_db), f"ch {ch}")
        ax.legend(loc="upper right", fontsize=8)
    ax.set_xlabel("frequency (Hz)")
    _apply_title(fig, ax, title)
    fig.tight_layout()
    if show:
        plt.show()
    return fig


def spectrogram(
    x,
    sr: int = SR,
    window: int = 1024,
    hop: int = 256,
    title="",
    show: bool = True,
):
    """Plot a short-time Fourier transform as a dB colour map.

    What it shows
    -------------
    Frequency (vertical) against time (horizontal), with brightness = magnitude
    in dB. Read it left to right to watch a spectrum evolve: a filter sweep is a
    moving ridge, an LFO on a cutoff is a wobbling edge, a transient is a
    vertical stripe at one instant, and steady noise is a uniform haze.

    Trade-off to know about
    -----------------------
    `window` sets the frequency resolution (bin spacing = sr / window; at
    sr=48000 and window=1024 that is 46.9 Hz) and the time resolution together.
    A long window resolves close partials but smears fast attacks; a short window
    does the opposite. `hop` is how many samples each frame advances (256 gives
    75% overlap, a good default for seeing movement).

    Implementation
    --------------
    Frames are cut and rfft'd here rather than via `plt.specgram`, so the axis
    units are unambiguous (Hz and seconds, not normalised units) and the dB
    scaling is the same coherent-gain convention as `spectrum_plot`.

    Parameters
    ----------
    x:
        (N,) mono signal. For stereo, plot each channel separately instead --
        this function takes one channel.
    sr:
        Sample rate in Hz.
    window:
        FFT size in samples (Hann window). Default 1024.
    hop:
        Frame advance in samples. Default 256.
    title / show:
        As in `waveform`.

    Returns
    -------
    matplotlib.figure.Figure
        A silent buffer still plots: the dB floor makes it a uniform dark field
        rather than raising or warning.
    """
    _prepare_backend(show)
    plt = _require_pyplot()

    arr = _as_float_array(x)
    if arr.ndim != 1:
        if arr.ndim == 2 and arr.shape[1] == 1:
            arr = arr[:, 0]
        else:
            raise ValueError(
                f"spectrogram expects a 1-D signal, got shape {arr.shape}; "
                "plot channels one at a time"
            )
    sr = int(sr)

    n_fft = int(window)
    hop_n = int(hop)
    if n_fft < 8:
        raise ValueError(f"window must be >= 8 samples, got {window}")
    if hop_n < 1:
        raise ValueError(f"hop must be >= 1 sample, got {hop}")

    n = arr.size
    if n < n_fft:
        arr = np.concatenate([arr, np.zeros(n_fft - n, dtype=np.float64)])
        n = arr.size

    win = np.hanning(n_fft)
    norm = float(np.sum(win)) or 1.0
    frames = 1 + (n - n_fft) // hop_n

    spec = np.empty((n_fft // 2 + 1, frames), dtype=np.float64)
    for i in range(frames):
        segment = arr[i * hop_n : i * hop_n + n_fft]
        spec[:, i] = np.abs(np.fft.rfft(segment * win)) / norm

    peak = float(np.max(spec))
    if peak <= 0.0:
        # All-zero input: draw the floor instead of -inf.
        spec_db = np.full(spec.shape, -150.0, dtype=np.float64)
    else:
        spec_db = 20.0 * np.log10(np.maximum(spec, _EPS) / peak)

    freqs = np.fft.rfftfreq(n_fft, 1.0 / sr)
    times = (np.arange(frames, dtype=np.float64) * hop_n + n_fft * 0.5) / sr

    fig, ax = plt.subplots(figsize=(10, 4.2))
    mesh = ax.pcolormesh(
        times,
        freqs,
        spec_db,
        shading="auto",
        cmap="magma",
        vmin=-120.0,
        vmax=0.0,
    )
    cbar = fig.colorbar(mesh, ax=ax)
    cbar.set_label("magnitude (dB, peak = 0)")
    ax.set_xlabel("time (s)")
    ax.set_ylabel("frequency (Hz)")
    ax.set_ylim(0.0, sr / 2.0)
    _apply_title(fig, ax, title)
    fig.tight_layout()
    if show:
        plt.show()
    return fig


def envelope_plot(x, sr: int = SR, title="", show: bool = True):
    """Plot the amplitude envelope over time.

    What it shows
    -------------
    How loud the signal is moment to moment, with the waveform's oscillation
    smoothed away. This is how you check an ADSR shape, the decay of a plucked
    string, the depth of a tremolo, or whether a compressor's gain reduction
    actually settles.

    The envelope is a moving average of ``|x|`` (a mean-absolute-value envelope)
    over a ~10 ms window, which is short enough to resolve an attack and long
    enough to ride over individual cycles of anything above ~100 Hz. The raw
    waveform and a peak-hold line are drawn faintly underneath for context, and
    the envelope is also reported peak-normalised in the legend.

    Parameters
    ----------
    x:
        (N,) or (N, C) signal.
    sr:
        Sample rate in Hz.
    title / show:
        As in `waveform`.

    Returns
    -------
    matplotlib.figure.Figure
    """
    _prepare_backend(show)
    plt = _require_pyplot()

    arr = _as_float_array(x)
    if arr.ndim == 0:
        raise ValueError("envelope_plot needs a 1-D or 2-D signal, got a scalar")
    if arr.ndim == 2 and arr.shape[1] > 1:
        # Envelope of a multichannel buffer: use the loudest channel at each
        # instant so nothing is hidden by cancellation between channels.
        mono = np.max(np.abs(arr), axis=1)
    else:
        mono = np.abs(arr.ravel())

    n = mono.size
    t, unit = _time_axis(n, int(sr))
    win = max(1, min(n, int(round(0.010 * int(sr))))) if n else 1

    if n == 0:
        env = mono
    else:
        csum = np.concatenate([[0.0], np.cumsum(mono)])
        half = win // 2
        lo = np.clip(np.arange(n) - half, 0, n)
        hi = np.clip(np.arange(n) - half + win, 0, n)
        env = (csum[hi] - csum[lo]) / np.maximum(hi - lo, 1)

    peak = float(np.max(env)) if env.size else 0.0
    env_norm = env / peak if peak > 0 else env

    fig, ax = plt.subplots(figsize=(10, 3.2))
    if arr.ndim == 1 and n:
        ax.plot(t, arr, linewidth=0.5, color="0.8", label="waveform")
    ax.fill_between(t, -env, env, color="tab:orange", alpha=0.25)
    ax.plot(t, env, color="tab:orange", linewidth=1.4,
            label=f"envelope (10 ms MA, peak={peak:.4g})")
    if peak > 0:
        ax.plot(t, env_norm, color="tab:blue", linewidth=1.0, linestyle="--",
                label="envelope, peak-normalised")
    ax.set_xlabel(f"time ({unit})")
    ax.set_ylabel("amplitude")
    ax.grid(True, alpha=0.3)
    ax.margins(x=0.0)
    ax.legend(loc="upper right", fontsize=8)
    _apply_title(fig, ax, title)
    fig.tight_layout()
    if show:
        plt.show()
    return fig


def compare(*signals, sr: int = SR, labels: Sequence[str] | None = None,
            title="", show: bool = True, alpha: float = 0.85):
    """Overlay several signals on one axes to A/B two algorithms.

    What it shows
    -------------
    Two or more waveforms drawn on the same time-and-amplitude axes, so
    differences are visible directly: a filter's phase shift, the extra tail of
    a longer reverb, the overshoot of a resonant ladder against a clean one, or
    whether two oscillators drift apart over time.

    This is the main experiment-workflow plot: render the same source through
    two graphs and overlay the results, rather than squinting at two windows.

    Parameters
    ----------
    *signals:
        The buffers to overlay. Lists/tuples are flattened, so
        ``compare([a, b], [c])`` also works. All must be 1-D (or (N, 1)); a
        multichannel buffer is summed to mono for the comparison.
    sr:
        Sample rate in Hz for the time axis.
    labels:
        One label per signal for the legend. Defaults to ``sig 0``, ``sig 1``, ...
    title / show:
        As in `waveform`.
    alpha:
        Line opacity (0..1). Lower it when many curves overlap.

    Returns
    -------
    matplotlib.figure.Figure
    """
    _prepare_backend(show)
    plt = _require_pyplot()

    flat: list[np.ndarray] = []

    def _collect(items):
        for item in items:
            if isinstance(item, (list, tuple)):
                _collect(item)
            elif item is not None:
                flat.append(_as_float_array(item))

    _collect(signals)
    if not flat:
        raise ValueError("compare needs at least one signal")

    mono: list[np.ndarray] = []
    for arr in flat:
        if arr.ndim == 2:
            arr = np.mean(arr, axis=1)
        elif arr.ndim != 1:
            raise ValueError(f"compare expects 1-D signals, got shape {arr.shape}")
        mono.append(arr)

    if labels is None:
        names = [f"sig {i}" for i in range(len(mono))]
    else:
        names = [str(v) for v in labels]
        if len(names) != len(mono):
            raise ValueError(
                f"got {len(names)} labels for {len(mono)} signals"
            )

    n = max(a.size for a in mono)
    t, unit = _time_axis(n, int(sr))

    fig, ax = plt.subplots(figsize=(10, 4))
    for arr, name in zip(mono, names):
        peak = float(np.max(np.abs(arr))) if arr.size else 0.0
        ax.plot(t[: arr.size], arr, linewidth=0.9, alpha=float(alpha),
                label=f"{name} (peak {peak:.4g})")
    ax.set_xlabel(f"time ({unit})")
    ax.set_ylabel("amplitude")
    ax.grid(True, alpha=0.3)
    if len(mono) > 1 or labels is not None:
        ax.legend(loc="upper right", fontsize=8)
    _apply_title(fig, ax, title)
    fig.tight_layout()
    if show:
        plt.show()
    return fig


def multiplot(signals, sr: int = SR, labels: Sequence[str] | None = None,
              title="", show: bool = True):
    """Stack several signals as separate vertically-aligned subplots.

    What it shows
    -------------
    The same thing `compare` does, but without overlap -- one row per signal,
    sharing a single time axis. Use it for a processing chain (input, filter
    output, envelope, final), or any time the curves are too similar to tell
    apart on top of each other.

    Parameters
    ----------
    signals:
        An iterable of buffers (a list, a tuple, or a single (N, C) 2-D array
        whose columns are treated as separate signals).
    sr:
        Sample rate in Hz for the shared time axis.
    labels:
        One label per signal; defaults to ``sig 0``, ``sig 1``, ...
    title / show:
        As in `waveform`. The title becomes the figure's suptitle.

    Returns
    -------
    matplotlib.figure.Figure
        All axes share the x axis, so a feature in row 1 lines up vertically
        with the same instant in every other row.
    """
    _prepare_backend(show)
    plt = _require_pyplot()

    if isinstance(signals, np.ndarray) and signals.ndim == 2:
        items = [signals[:, i] for i in range(signals.shape[1])]
    else:
        items = list(signals)
    if not items:
        raise ValueError("multiplot needs at least one signal")

    arrays = [_as_float_array(a) for a in items]
    for arr in arrays:
        if arr.ndim != 1:
            raise ValueError(f"multiplot expects 1-D signals, got shape {arr.shape}")

    names = (
        [f"sig {i}" for i in range(len(arrays))]
        if labels is None
        else [str(v) for v in labels]
    )
    if len(names) != len(arrays):
        raise ValueError(f"got {len(names)} labels for {len(arrays)} signals")

    n = max(a.size for a in arrays)
    t, unit = _time_axis(n, int(sr))

    fig, axes = plt.subplots(
        len(arrays), 1, figsize=(10, 1.7 * len(arrays)), sharex=True, squeeze=False
    )
    for ax, arr, name in zip(axes[:, 0], arrays, names):
        ax.plot(t[: arr.size], arr, linewidth=0.8)
        peak = float(np.max(np.abs(arr))) if arr.size else 0.0
        ax.set_ylabel("amplitude")
        ax.set_title(f"{name}  (peak {peak:.4g})", fontsize=9, loc="left")
        ax.grid(True, alpha=0.3)
    axes[-1, 0].set_xlabel(f"time ({unit})")
    if title is not None and title != "":
        fig.suptitle(str(title))
    fig.tight_layout()
    if show:
        plt.show()
    return fig
