"""
Audio output, WAV file IO, and small buffer utilities.

Design rule
-----------
Nothing in this module imports an *optional* dependency at import time. WAV IO is
built on `scipy.io.wavfile`, which is always present in this environment, so it
works even when no audio device (and no PortAudio shared library) exists. Live
playback/recording needs `sounddevice`, which is imported *inside* `play`, `stop`,
`record`, `devices` and `default_output`; if it is missing you get a ValueError
whose message tells you exactly how to fix the PYTHONPATH.

Units
-----
* amplitude: -1.0 .. +1.0 nominal float64 (see `save_wav` for clipping behaviour)
* sample rate: integer Hz, `SR` = 48000 is the library default
* pan: -1.0 = hard left, 0.0 = centre, +1.0 = hard right

Everything here is numpy + stdlib + scipy only. Use these functions to move
buffers between `synthlab.core.render()` and the outside world.
"""

from __future__ import annotations

import os
from typing import Sequence

import numpy as np

#: Library-wide default sample rate in Hz.
SR = 48_000

#: Shown whenever an optional audio dependency cannot be imported.
_SD_HINT = (
    "sounddevice is not importable; set PYTHONPATH to include _libs, "
    "or `pip install sounddevice`"
)


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

__all__ = [
    "apply_fade",
    "concat",
    "default_output",
    "devices",
    "load_wav",
    "normalize",
    "play",
    "record",
    "save_wav",
    "stop",
    "to_stereo",
]


def _as_float_array(x) -> np.ndarray:
    """Return `x` as a contiguous float64 array (no copy when already one)."""
    arr = np.asarray(x)
    if arr.dtype != np.float64:
        arr = arr.astype(np.float64)
    if not arr.flags["C_CONTIGUOUS"]:
        arr = np.ascontiguousarray(arr)
    return arr


def _check_sr(sr) -> int:
    """Validate a sample rate and return it as a plain `int`."""
    try:
        value = int(sr)
    except (TypeError, ValueError):
        raise ValueError(f"sr must be an integer sample rate in Hz, got {sr!r}") from None
    if value <= 0:
        raise ValueError(f"sr must be positive, got {value}")
    return value


def _import_sounddevice():
    """Import `sounddevice` lazily, or raise a ValueError that says how to fix it.

    Importing inside a function is deliberate: a headless or dependency-free
    machine must still be able to `import synthlab.io` for offline file work.
    """
    try:
        import sounddevice as sd
    except Exception as exc:  # ImportError, OSError from PortAudio, ...
        raise ValueError(_SD_HINT) from exc
    return sd


# ---------------------------------------------------------------------------
# WAV file IO
# ---------------------------------------------------------------------------

def save_wav(path, x: np.ndarray, sr: int = SR, subtype: str = "PCM_16") -> str:
    """Write a float buffer to a WAV file with scipy, creating parent dirs.

    Parameters
    ----------
    path:
        Destination file path (str or os.PathLike). Missing parent directories
        are created.
    x:
        Signal samples. Floats in -1.0 .. +1.0 are expected; a (N,) mono or
        (N, 2) stereo array is written as-is. Anything else is passed through
        scipy's writer, which may reject unusual shapes.
    sr:
        Sample rate in Hz (default `SR` = 48000).
    subtype:
        The on-disk sample format:

        * ``"PCM_16"`` (default) -- 16-bit signed integer, the interoperable
          choice; 96 dB of theoretical dynamic range.
        * ``"FLOAT"`` -- 32-bit IEEE float, no quantisation at all (about
          -150 dB noise floor at 24-bit-equivalent precision); bigger files and
          some older players cannot read it.
        * ``"PCM_32"`` -- 32-bit signed integer.
        * ``"DOUBLE"`` -- 64-bit IEEE float, for archival.

        The name is case-insensitive and the common aliases (``"int16"``,
        ``"float32"``, ...) are accepted.

    Returns
    -------
    str
        The path that was written, so callers can chain/log it.

    Clipping, not wrapping
    ----------------------
    For the integer subtypes input is scaled by 32767 (PCM_16) and then
    **clipped** to [-32768, +32767]. A sample of +1.4 becomes +32767, not a
    wrapped-around negative value, so a hot mix distorts as flat-topped clipping
    instead of producing digital screech. The 32767 (not 32768) scale keeps
    +1.0 exactly representable, so a full-scale sine round-trips at the cost of
    about 3e-5 peak error (one 16-bit LSB is 3.05e-5).

    How the format is chosen
    ------------------------
    scipy's writer picks the WAV format tag from the numpy dtype of the array it
    is handed, so this function does the conversion (and the clipping) itself and
    passes the dtype through. In scipy >= 1.18 `wavfile.write` no longer takes a
    `subtype` keyword at all, which is why the scaling happens here rather than
    being delegated.
    """
    from scipy.io import wavfile  # always available in this environment

    sr = _check_sr(sr)
    arr = _as_float_array(x)
    sub = str(subtype).upper().replace("-", "_")

    if sub in ("PCM_16", "PCM16", "INT16", "16", "PCM"):
        scaled = np.clip(arr * 32767.0, -32768.0, 32767.0)
        payload = np.rint(scaled).astype(np.int16)
    elif sub in ("FLOAT", "FLOAT32", "F32", "IEEE_FLOAT"):
        payload = arr.astype(np.float32)
    elif sub in ("PCM_32", "PCM32", "INT32", "32"):
        scaled = np.clip(arr * 2147483647.0, -2147483648.0, 2147483647.0)
        payload = np.rint(scaled).astype(np.int32)
    elif sub in ("DOUBLE", "FLOAT64", "F64"):
        payload = arr.astype(np.float64)
    elif sub in ("UINT8", "PCM_U8", "PCM_8", "8"):
        scaled = np.clip(arr * 127.0 + 128.0, 0.0, 255.0)
        payload = np.rint(scaled).astype(np.uint8)
    else:
        raise ValueError(
            f"unknown subtype {subtype!r}; use 'PCM_16', 'FLOAT', 'PCM_32', "
            "'DOUBLE' or 'UINT8'"
        )

    out_path = os.fspath(path)
    parent = os.path.dirname(os.path.abspath(out_path))
    if parent:
        os.makedirs(parent, exist_ok=True)

    wavfile.write(out_path, sr, payload)
    return out_path


def load_wav(path) -> tuple[np.ndarray, int]:
    """Read a WAV file as float64 samples in [-1.0, 1.0].

    Returns
    -------
    (samples, sample_rate):
        ``samples`` is the raw channel layout of the file -- (N,) for mono,
        (N, 2) for stereo -- as float64. ``sample_rate`` is an `int` in Hz.

    Normalisation
    -------------
    Integer PCM is divided by the full-scale magnitude of its own dtype, so the
    mapping is exact and dtype-independent:

    * ``int16``  -> ``x / 32768.0``   (one LSB = 3.0518e-5)
    * ``int32``  -> ``x / 2147483648.0``
    * ``uint8``  -> ``(x.astype(float64) - 128.0) / 128.0``  (WAV 8-bit is
      *unsigned* with a 128 midpoint, not two's complement)
    * ``float32``/``float64`` -> used as stored, **not** rescaled.

    Dividing int16 by 32768 rather than 32767 means -32768 maps to exactly -1.0
    and +32767 maps to +0.99997: the result is guaranteed to stay inside
    [-1.0, 1.0] and never clip when re-saved. A `save_wav`/`load_wav` round trip
    of a full-scale sine therefore differs by at most one LSB (~3.1e-5).
    """
    from scipy.io import wavfile

    sr, data = wavfile.read(os.fspath(path))

    if data.dtype == np.int16:
        out = data.astype(np.float64) / 32768.0
    elif data.dtype == np.int32:
        out = data.astype(np.float64) / 2147483648.0
    elif data.dtype == np.uint8:
        out = (data.astype(np.float64) - 128.0) / 128.0
    elif data.dtype in (np.float32, np.float64):
        out = data.astype(np.float64)
    elif data.dtype == np.int64:
        out = data.astype(np.float64) / 9223372036854775808.0
    else:
        # Unknown/rare dtype: fall back to a conservative integer or float read.
        if np.issubdtype(data.dtype, np.integer):
            info = np.iinfo(data.dtype)
            scale = float(max(abs(info.min), info.max))
            out = data.astype(np.float64) / scale
        else:
            out = data.astype(np.float64)

    return np.ascontiguousarray(out), int(sr)


# ---------------------------------------------------------------------------
# Live playback / recording (optional sounddevice)
# ---------------------------------------------------------------------------

def play(x: np.ndarray, sr: int = SR, blocking: bool = True) -> None:
    """Play a buffer through the default output device.

    Parameters
    ----------
    x:
        Mono (N,) or stereo (N, 2) float array, amplitude -1.0 .. +1.0. Values
        outside that range are clipped by the device; nothing here rescales your
        signal behind your back, so keep a `normalize()` in the chain if you want
        headroom control.
    sr:
        Sample rate in Hz. The device is opened at exactly this rate; if the
        hardware refuses it, sounddevice raises.
    blocking:
        ``True`` (default) waits until the buffer has finished playing, which is
        what you want in a script. ``False`` returns immediately and keeps a
        reference to the stream alive inside this module until playback ends (a
        dropped reference would be garbage-collected and cut the sound off).

    Raises
    ------
    ValueError
        If sounddevice is not importable. The message is exactly
        "sounddevice is not importable; set PYTHONPATH to include _libs, or
        `pip install sounddevice`".
    """
    sd = _import_sounddevice()  # imported inside: no top-level device dependency
    sr = _check_sr(sr)
    data = _as_float_array(x)
    if data.ndim == 1:
        channels = 1
    elif data.ndim == 2:
        channels = data.shape[1]
    else:
        raise ValueError(f"audio must be (N,) or (N, channels), got shape {data.shape}")

    if blocking:
        sd.play(data, sr, blocking=True)
        sd.stop()
        return

    global _ACTIVE_STREAMS
    stream = sd.play(data, sr, blocking=False)
    if stream is not None:
        try:
            _ACTIVE_STREAMS.append(stream)
        except NameError:  # pragma: no cover - module-level list always exists
            _ACTIVE_STREAMS = [stream]
    return None


def stop() -> None:
    """Stop any playback started by `play` and drop the retained streams."""
    sd = _import_sounddevice()
    sd.stop()
    streams = globals().get("_ACTIVE_STREAMS")
    if streams is not None:
        streams.clear()


def devices() -> str:
    """Return a human-readable listing of every audio device sounddevice sees.

    Each line is ``index  name  (in: N, out: M, default sr)``, followed by which
    device is the current default in each direction. Useful when you need to know
    the *index* to pass to sounddevice directly for multi-channel work.
    """
    sd = _import_sounddevice()
    listing = sd.query_devices()
    try:
        default_in, default_out = sd.default.device
    except Exception:
        default_in = default_out = None

    lines = []
    for index, dev in enumerate(listing):
        host = dev.get("hostapi", "?")
        lines.append(
            f"[{index:>2}] {dev['name']}  "
            f"(in: {dev['max_input_channels']}, out: {dev['max_output_channels']}, "
            f"sr: {dev['default_samplerate']:.0f}, hostapi: {host})"
        )
    lines.append(f"default input : {default_in}")
    lines.append(f"default output: {default_out}")
    return "\n".join(lines)


def default_output() -> str:
    """Return the name of the default output device as a one-line string.

    Handy as a sanity check before a long render: if this raises, there is no
    usable output device and you should stay offline.
    """
    sd = _import_sounddevice()
    name = sd.query_devices(kind="output")["name"]
    return f"default output: {name}"


def record(seconds: float, sr: int = SR, channels: int = 1) -> np.ndarray:
    """Record from the default input device and return float64 samples.

    Parameters
    ----------
    seconds:
        Duration to capture. Internally the capture length is rounded up to a
        whole number of samples.
    sr:
        Sample rate in Hz.
    channels:
        Number of input channels to capture. With ``channels=1`` the returned
        array is squeezed to shape (N,); with more it stays (N, channels).

    Returns
    -------
    np.ndarray
        float64 in -1.0 .. +1.0, blocking until the capture is complete.

    Typical uses: loop the machine's own output back through the speakers and a
    microphone to measure a room or an effect, or capture external gear through
    an interface.
    """
    sd = _import_sounddevice()
    sr = _check_sr(sr)
    n = int(round(float(seconds) * sr))
    if n <= 0:
        raise ValueError(f"seconds must be > 0, got {seconds!r}")

    data = sd.rec(n, samplerate=sr, channels=int(channels), dtype="float32")
    sd.wait()
    out = np.asarray(data, dtype=np.float64)
    if int(channels) == 1:
        out = out[:, 0]
    return np.ascontiguousarray(out)


# ---------------------------------------------------------------------------
# Buffer utilities
# ---------------------------------------------------------------------------

def to_stereo(x: np.ndarray, pan: float = 0.0) -> np.ndarray:
    """Spread a mono (or already stereo) buffer across two channels.

    Parameters
    ----------
    x:
        (N,) mono or (N, 2) stereo float array. Mono is panned; stereo is
        returned unchanged as float64 (the pan argument is ignored, since there
        is nothing left to place).
    pan:
        -1.0 hard left, 0.0 centre (default), +1.0 hard right. Clipped to that
        range. Anything in between moves the image smoothly.

    Returns
    -------
    np.ndarray
        Always shape (N, 2), float64, C-contiguous.

    Constant-power panning
    ----------------------
    The gains are read off a quarter circle rather than a straight line, so the
    total power stays constant as the image moves and the perceived loudness does
    not dip in the middle::

        theta = (pan + 1) / 2 * pi/2      # 0 .. pi/2 across the pan range
        left  = cos(theta)
        right = sin(theta)

    At centre both gains are cos(pi/4) = sin(pi/4) = 0.7071, i.e. -3.01 dB each,
    which sums to unity power. Hard left gives (1.0, 0.0). A linear pan would
    instead give (1.0, 0.0) at the extremes and (0.5, 0.5) at centre -- quieter
    in the middle by 3 dB.
    """
    arr = _as_float_array(x)
    if arr.ndim == 2 and arr.shape[1] == 2:
        return np.ascontiguousarray(arr)
    if arr.ndim != 1:
        raise ValueError(
            f"to_stereo expects (N,) mono or (N, 2) stereo, got shape {arr.shape}"
        )

    pan_value = float(np.clip(float(pan), -1.0, 1.0))
    theta = (pan_value + 1.0) * 0.5 * (np.pi * 0.5)
    left = float(np.cos(theta))
    right = float(np.sin(theta))

    out = np.empty((arr.size, 2), dtype=np.float64)
    out[:, 0] = arr * left
    out[:, 1] = arr * right
    return out


def normalize(x: np.ndarray, peak: float = 0.99) -> np.ndarray:
    """Scale a buffer so its largest magnitude sample equals `peak`.

    Parameters
    ----------
    x:
        Any float buffer.
    peak:
        Target absolute peak. ``0.99`` (default) leaves a little headroom below
        full scale, which is what you want before `to_stereo` or a filter that
        can overshoot. Pass ``1.0`` for a truly full-scale file.

    Returns
    -------
    np.ndarray
        float64, same shape. If the input is all zeros (or the peak is 0) the
        input is returned as zeros rather than dividing by zero -- you get
        ``nan`` from a naive implementation, and that would poison everything
        downstream.

    Gain is applied uniformly, so the waveform's shape (and therefore its
    timbre) is untouched.
    """
    arr = _as_float_array(x)
    current = float(np.max(np.abs(arr))) if arr.size else 0.0
    if current == 0.0 or not np.isfinite(current):
        return arr.copy()
    return np.ascontiguousarray(arr * (float(peak) / current))


def apply_fade(
    x: np.ndarray,
    fade_in: float = 0.01,
    fade_out: float = 0.05,
    sr: int = SR,
) -> np.ndarray:
    """Apply a raised-cosine fade in/out so trimmed audio does not click.

    Parameters
    ----------
    x:
        Input buffer (mono (N,) or multichannel (N, C); the fade is applied to
        every channel identically).
    fade_in / fade_out:
        Fade durations **in seconds** (default 10 ms in, 50 ms out). 0 disables
        that side. Fades longer than the buffer are clamped so they meet in the
        middle instead of overlapping and inverting.
    sr:
        Sample rate in Hz, used to convert the durations to sample counts.

    Returns
    -------
    np.ndarray
        float64, same shape as the input.

    How to read it
    --------------
    The gain follows ``0.5 * (1 - cos(pi * n / N))``, a raised cosine. It starts
    at exactly 0 and reaches exactly 1 with a continuous first derivative, so
    there is no step discontinuity at either end of the fade -- that step is what
    you hear as a click when you cut a waveform at a non-zero crossing.

    One detail worth knowing: the ramp-up hits gain 1.0 on the first sample
    *after* the fade, and the ramp-down is evaluated at the last buffer sample,
    not at one sample past it. So the final sample's gain is not 0 but
    ``0.5*(1 - cos(pi/N))``, which for the default 50 ms at 48 kHz is 4.3e-07
    (about -127 dB) -- inaudible, and still far below any click threshold.

    A very short buffer (< 2 samples) is returned unchanged, since there is
    nothing meaningful to shape.
    """
    arr = _as_float_array(x)
    if arr.size == 0:
        return arr.copy()
    n = arr.shape[0]
    if n < 2:
        return arr.copy()

    sr = _check_sr(sr)
    in_n = int(round(max(0.0, float(fade_in)) * sr))
    out_n = int(round(max(0.0, float(fade_out)) * sr))
    if in_n + out_n > n:
        # Clamp proportionally so the two ramps exactly meet.
        total = in_n + out_n
        if total > 0:
            in_n = int(round(n * in_n / total))
            out_n = n - in_n

    gain = np.ones(n, dtype=np.float64)
    if in_n > 0:
        k = np.arange(in_n, dtype=np.float64)
        gain[:in_n] = 0.5 * (1.0 - np.cos(np.pi * k / in_n))
    if out_n > 0:
        k = np.arange(out_n, dtype=np.float64)
        gain[n - out_n:] = 0.5 * (1.0 - np.cos(np.pi * (out_n - k) / out_n))

    if arr.ndim == 1:
        return np.ascontiguousarray(arr * gain)
    return np.ascontiguousarray(arr * gain.reshape((-1,) + (1,) * (arr.ndim - 1)))


def concat(*signals, gap: float = 0.0, sr: int = SR) -> np.ndarray:
    """Join buffers end to end, optionally inserting silence between them.

    Parameters
    ----------
    *signals:
        Two forms are accepted:

        * ``concat(a, b, c, gap=0.25)`` -- plain buffers in order.
        * ``concat([a, b], [c, d])`` -- lists/tuples are flattened, so you can
          concatenate groups produced by a sweep.
    gap:
        Silence inserted **between** neighbours, in seconds. A scalar applies to
        every boundary; a sequence gives one value per boundary (length
        ``len(signals) - 1``, or length 1 to mean "this value everywhere").
        Default 0.0 butts the buffers together.
    sr:
        Sample rate in Hz, used to turn `gap` seconds into samples.

    Returns
    -------
    np.ndarray
        float64. Mono inputs give (total,); two-dimensional inputs are stacked
        along the sample axis (all buffers must agree on their other dimensions).

    Note: this does not cross-fade. For click-free edits apply `apply_fade` to
    each piece, or insert a short `gap`, or `to_stereo` and overlap them yourself.
    """
    flat: list[np.ndarray] = []

    def _collect(items):
        for item in items:
            if isinstance(item, (list, tuple)):
                _collect(item)
            elif item is None:
                continue
            else:
                flat.append(_as_float_array(item))

    _collect(signals)
    if not flat:
        raise ValueError("concat needs at least one signal")

    sr = _check_sr(sr)
    boundaries = len(flat) - 1
    if isinstance(gap, (list, tuple, np.ndarray)):
        gaps = [float(g) for g in np.ravel(gap)]
        if len(gaps) == 1:
            # A one-element sequence is broadcast: `gap=(0.1,)` reads naturally
            # as "0.1 s between each pair".
            gaps = gaps * boundaries
        elif len(gaps) != boundaries:
            raise ValueError(
                f"gap sequence has {len(gaps)} values but there are {boundaries} "
                "boundaries; pass a scalar, one value, or one value per boundary"
            )
    else:
        gaps = [float(gap)] * boundaries

    pieces: list[np.ndarray] = []
    for i, arr in enumerate(flat):
        pieces.append(arr)
        if i < boundaries:
            silence_n = int(round(max(0.0, gaps[i]) * sr))
            if silence_n:
                shape = (silence_n,) + arr.shape[1:]
                pieces.append(np.zeros(shape, dtype=np.float64))

    try:
        out = np.concatenate(pieces, axis=0)
    except ValueError as exc:
        shapes = ", ".join(str(p.shape) for p in flat)
        raise ValueError(
            f"cannot concatenate buffers with incompatible shapes: {shapes}"
        ) from exc
    return np.ascontiguousarray(out)


#: Streams kept alive for non-blocking `play` calls (a GC'd stream stops audio).
_ACTIVE_STREAMS: list = []
