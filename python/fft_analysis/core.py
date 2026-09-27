"""Core FFT analysis: sample library IO, partial tracking, decay fitting, body curve.

Pure numpy/scipy. No dependency on synthlab, so this is runnable anywhere the env has
numpy/scipy/soundfile.

Design summary
--------------
A note is modelled as  y(t) = sum_k a_k(t) * sin(2*pi*f_k*t + phase_k),
so the extraction answers: where are the partials (f_k, inharmonicity B), how loud do
they start (a_k0), and how fast do they die (gamma_k). The body is the *shared*
absolute-frequency coloration, obtained by averaging the per-note partial amplitudes
across many pitches on an absolute frequency axis.

Everything is driven by the exact measured f0, never the nominal note.
"""

from __future__ import annotations

import glob
import json
import os
import re

import numpy as np
import soundfile as sf
from scipy.signal import butter, filtfilt, firwin2, resample_poly

# ---------------------------------------------------------------------------
# constants
# ---------------------------------------------------------------------------

SR = 48_000

# Philharmonia mp3 is lossy: content above ~16 kHz is unreliable.
MP3_BAND_HZ = 16_000.0
# FLAC piano is clean; still stay a little below Nyquist.
FLAC_BAND_HZ = 20_000.0

_NOTE_SEMI = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}

__all__ = [
    "SR", "MP3_BAND_HZ", "FLAC_BAND_HZ",
    "note_to_midi", "midi_to_hz",
    "scan_philharmonia", "scan_piano", "parse_sfz",
    "load_audio", "analyze_note",
    "body_curve", "design_body_fir",
]


# ---------------------------------------------------------------------------
# note names
# ---------------------------------------------------------------------------

def note_to_midi(name: str) -> int:
    """'A2' -> 45, 'As2'/'A#2' -> 46, 'C4' -> 60. Works for both libraries."""
    m = re.match(r"^([A-G])([#s]?)(-?\d+)$", name)
    if not m:
        raise ValueError(f"bad note name {name!r}")
    letter, acc, octave = m.group(1), m.group(2), int(m.group(3))
    semi = _NOTE_SEMI[letter]
    if acc in ("#", "s"):
        semi += 1
    return 12 * (octave + 1) + semi


def midi_to_hz(midi) -> float:
    return 440.0 * 2.0 ** ((np.asarray(midi, dtype=float) - 69.0) / 12.0)


# ---------------------------------------------------------------------------
# library scanning
# ---------------------------------------------------------------------------

def scan_philharmonia(root: str, instrument: str,
                      variations=("normal",), dynamics=None) -> list[dict]:
    """Scan a Philharmonia folder.

    Filename: <instrument>_<note>_<duration>_<dynamic>_<variation>.mp3
    """
    entries = []
    for path in sorted(glob.glob(os.path.join(root, instrument, "*.mp3"))):
        base = os.path.basename(path)[:-4]
        parts = base.split("_")
        if len(parts) < 4:
            continue
        note = parts[1]
        if not re.match(r"^[A-G]s?\d$", note):
            continue
        duration = parts[2]
        dynamic = parts[3]
        variation = parts[4] if len(parts) > 4 else "normal"
        if variations is not None and variation not in variations:
            continue
        if dynamics is not None and dynamic not in dynamics:
            continue
        try:
            midi = note_to_midi(note)
        except ValueError:
            continue
        entries.append(dict(
            path=path, instrument=instrument, note=note, midi=midi,
            duration=duration, dynamic=dynamic, variation=variation,
            loop_start=None, loop_end=None, velocity_layer=None,
        ))
    return entries


def parse_sfz(path: str) -> dict:
    """Return {sample_filename: {pitch_keycenter, loop_start, loop_end, loop_mode,
    hivel, lovel}} from a simple SFZ."""
    regions = {}
    group = {}
    cur = None

    def flush():
        if cur and "sample" in cur:
            regions[os.path.basename(cur["sample"])] = dict(cur)

    with open(path, "r", encoding="utf-8", errors="ignore") as fh:
        for raw in fh:
            line = raw.split("//")[0].strip()
            if not line:
                continue
            low = line.lower()
            if low.startswith("<group>"):
                flush()
                cur = None
                group = {}
                continue
            if low.startswith("<region>"):
                flush()
                cur = dict(group)
                continue
            if low.startswith("<"):          # <global>, <control>, ...
                continue
            if "=" not in line or cur is None:
                continue
            key, _, val = line.partition("=")
            cur[key.strip().lower()] = val.strip()
    flush()

    out = {}
    for name, r in regions.items():
        def _int(k):
            try:
                return int(r[k])
            except (KeyError, ValueError):
                return None
        out[name] = dict(
            pitch_keycenter=_int("pitch_keycenter"),
            loop_start=_int("loop_start"),
            loop_end=_int("loop_end"),
            loop_mode=r.get("loop_mode"),
            hivel=_int("hivel"),
            lovel=_int("lovel"),
        )
    return out


def scan_piano(piano_dir: str) -> list[dict]:
    """Scan the Upright Piano KW SFZ library."""
    sfz_files = sorted(glob.glob(os.path.join(piano_dir, "*.sfz")))
    sfz = parse_sfz(sfz_files[0]) if sfz_files else {}
    entries = []
    for path in sorted(glob.glob(os.path.join(piano_dir, "samples", "*.flac"))):
        base = os.path.basename(path)
        m = re.match(r"^([A-G][#s]?\d)v([HL])\.flac$", base)
        if not m:
            continue
        note, layer = m.group(1), m.group(2)
        info = sfz.get(base, {})
        midi = info.get("pitch_keycenter")
        if midi is None:
            midi = note_to_midi(note)
        # SFZ loop points are in the file's own sample rate; store them at the
        # analysis rate so they line up with resampled audio.
        file_sr = sf.info(path).samplerate
        scale = SR / float(file_sr)

        def _scaled(key):
            v = info.get(key)
            return int(round(v * scale)) if v is not None else None

        entries.append(dict(
            path=path, instrument="piano", note=note.replace("#", "s"), midi=midi,
            duration="very-long", dynamic=("forte" if layer == "H" else "piano"),
            variation="normal", loop_start=_scaled("loop_start"),
            loop_end=_scaled("loop_end"), velocity_layer=layer,
        ))
    return entries


# ---------------------------------------------------------------------------
# loading
# ---------------------------------------------------------------------------

def load_audio(path: str, sr: int = SR) -> np.ndarray:
    """Load, down-mix to mono, resample to `sr`. float64."""
    x, file_sr = sf.read(path, always_2d=True)
    x = x.mean(axis=1).astype(np.float64)
    if file_sr != sr:
        from math import gcd
        g = gcd(int(file_sr), int(sr))
        x = resample_poly(x, sr // g, file_sr // g)
    return np.ascontiguousarray(x)


def detect_onset(x: np.ndarray, sr: int = SR, rel: float = 0.20) -> int:
    """Note onset = start of the above-threshold region that contains the loudest frame.

    Several Philharmonia files carry a lead-in of silence, low hum *and* an isolated
    click before the note (guitar A3 has a click at 0.20 s, note at 1.93 s). Walking
    back from the global RMS peak, instead of scanning forward, skips the click.
    """
    win = max(1, int(0.005 * sr))
    m = len(x) // win
    if m < 3:
        return 0
    frames = x[:m * win].reshape(m, win)
    rms = np.sqrt((frames ** 2).mean(axis=1))
    pk = float(rms.max())
    if pk <= 0:
        return 0
    thr = rel * pk
    j = int(np.argmax(rms))
    i = j
    while i > 0 and rms[i - 1] > thr:
        i -= 1
    return int(i * win)


def analysis_region(x: np.ndarray, entry: dict, sr: int = SR, cap: float = 5.0):
    """(start, end) sample indices that hold *real* decay, onset-aligned.

    Piano lower/mid notes are looped: the loop region is a faked steady state, so the
    genuine decay lives before `loop_start`.
    """
    n = len(x)
    onset = detect_onset(x, sr)
    start = max(0, onset - int(0.005 * sr))       # keep a sliver of the very attack
    end = n
    if entry.get("loop_start"):
        end = min(end, int(entry["loop_start"]))
    end = min(end, start + int(cap * sr))
    if end <= start + sr // 10:                   # degenerate: fall back to whole file
        start = 0
        end = min(n, int(cap * sr))
    return start, end


# ---------------------------------------------------------------------------
# f0 and partials
# ---------------------------------------------------------------------------

def _parabolic(logmag: np.ndarray, i: int) -> float:
    """Sub-bin offset from a 3-point parabolic fit on log-magnitude."""
    a, b, c = logmag[i - 1], logmag[i], logmag[i + 1]
    denom = a - 2.0 * b + c
    if denom == 0:
        return 0.0
    return float(np.clip(0.5 * (a - c) / denom, -1.0, 1.0))


def _spectrum(seg: np.ndarray, sr: int):
    w = np.hanning(len(seg))
    scale = w.sum() / 2.0
    nfft = 1 << int(np.ceil(np.log2(len(seg) * 2)))
    X = np.abs(np.fft.rfft(seg * w, nfft)) / max(scale, 1e-12)
    freqs = np.fft.rfftfreq(nfft, 1.0 / sr)
    return freqs, X


def estimate_f0(seg: np.ndarray, sr: int, nominal: float) -> float:
    freqs, X = _spectrum(seg, sr)
    lo, hi = nominal * 0.90, nominal * 1.10
    band = np.where((freqs >= lo) & (freqs <= hi))[0]
    band = band[(band > 1) & (band < len(X) - 1)]
    if band.size == 0:
        return float(nominal)
    logmag = np.log(X + 1e-20)
    i = band[np.argmax(X[band])]
    df = freqs[1] - freqs[0]
    return float((i + _parabolic(logmag, i)) * df)


def find_partials(seg: np.ndarray, sr: int, f0: float, band_hz: float,
                  max_modes: int = 64):
    """Locate partial peaks near k*f0, then fit inharmonicity B.

    Returns dict with k, f_k, amp_k (peak amplitude) and B.
    """
    freqs, X = _spectrum(seg, sr)
    df = freqs[1] - freqs[0]
    logmag = np.log(X + 1e-20)

    # local maxima above a floor, used as candidate partials
    floor = X.max() * 1e-4
    cand = np.where((X[1:-1] > X[:-2]) & (X[1:-1] >= X[2:]) & (X[1:-1] > floor))[0] + 1
    cand_f = freqs[cand]

    def nearest(pred, tol):
        if cand.size == 0:
            return None
        j = int(np.argmin(np.abs(cand_f - pred)))
        if abs(cand_f[j] - pred) > tol:
            return None
        return cand[j]

    # pass 1: low harmonics with a small tolerance, fit B
    ks1, fs1 = [], []
    kmax1 = max(1, min(10, int(band_hz / max(f0, 1e-6))))
    for k in range(1, kmax1 + 1):
        j = nearest(k * f0, 0.35 * f0)
        if j is None:
            continue
        fk = (j + _parabolic(logmag, j)) * df
        if fk > band_hz:
            continue
        ks1.append(k)
        fs1.append(fk)
    B = 0.0
    if len(ks1) >= 3:
        ks1 = np.asarray(ks1, float)
        fs1 = np.asarray(fs1, float)
        y = (fs1 / (ks1 * f0)) ** 2 - 1.0
        x = ks1 ** 2
        B = float(np.sum(x * y) / max(np.sum(x * x), 1e-12))
        B = max(0.0, B)

    # pass 2: full set using the inharmonicity prediction
    ks, fks, amps = [], [], []
    kmax = int(min(max_modes, np.floor(band_hz / max(f0, 1e-6))))
    for k in range(1, kmax + 1):
        pred = k * f0 * np.sqrt(1.0 + B * k * k)
        if pred >= band_hz:
            break
        tol = max(0.35 * f0, 0.02 * pred)
        j = nearest(pred, tol)
        if j is None:
            continue
        fk = (j + _parabolic(logmag, j)) * df
        ks.append(k)
        fks.append(fk)
        amps.append(X[j])

    ks = np.asarray(ks, int)
    fks = np.asarray(fks, float)
    amps = np.asarray(amps, float)
    if len(ks) >= 3:
        y = (fks / (ks * f0)) ** 2 - 1.0
        x = ks.astype(float) ** 2
        B2 = float(np.sum(x * y) / max(np.sum(x * x), 1e-12))
        B = max(0.0, B2)
    return dict(k=ks, f_k=fks, amp_k=amps, B=B)


# ---------------------------------------------------------------------------
# decay
# ---------------------------------------------------------------------------

def partial_envelope(seg: np.ndarray, sr: int, f: float, bw: float):
    """Amplitude envelope of the single partial at `f`, half-bandwidth `bw`.

    Time-domain demodulation (multiply by e^{-j2*pi*f*t}, zero-phase low-pass) then
    |z|. For a real tone A cos(wt) the analytic signal is A/2, so the 2x restores the
    physical amplitude. Unlike an FFT-band extraction this does not wrap the decay
    around the segment boundary, which matters for long, strongly decaying notes.
    """
    n = len(seg)
    if n == 0:
        return np.zeros(0)
    t = np.arange(n) / sr
    z = seg * np.exp(-1j * 2.0 * np.pi * f * t)
    b, a = butter(4, min(bw / (sr / 2.0), 0.95), btype="low")
    return 2.0 * np.abs(filtfilt(b, a, z))


def fit_decay(env: np.ndarray, sr: int, t0: float = 0.05, t1: float = 1.2,
              floor_db: float = -40.0, smooth: float = 0.01,
              late_split: float | None = 1.0) -> dict:
    """Fit a_k(t) = a0 * exp(-gamma*t) over the usable decay, plus a late segment.

    Getting gamma right matters: a light 10 ms smoothing removes string beating without
    flattening fast decays, the fit window is capped (`t1`), and the floor is raised to
    an absolute noise level so a weak partial's noisy tail cannot flatten the slope.
    `a0` is evaluated at the region start (t=0). `gamma2` is the late-segment rate
    (piano double decay); NaN when the note is short.
    """
    n = len(env)
    if smooth and n > 8:
        k = max(1, int(round(smooth * sr)))
        if k > 1:
            env = np.convolve(env, np.ones(k) / k, mode="same")
    t = np.arange(n) / sr
    peak = float(env.max()) + 1e-30
    noise = float(np.percentile(env[int(0.7 * n):], 20)) if n >= 10 else 0.0
    floor = max(peak * 10.0 ** (floor_db / 20.0), 3.0 * noise)
    usable = (t >= t0) & (t <= t1) & (env > floor)
    if usable.sum() < 32:
        usable = (t >= t0) & (t <= t1)
    tt = t[usable]
    ee = env[usable]
    if tt.size < 16:
        return dict(a0=float(peak), gamma=0.0, r2=0.0, gamma2=np.nan, r2_late=0.0,
                    t_fit=(float(t[0]), float(t[-1])))

    def _fit(x, y):
        if x.size < 8:
            return np.nan, np.nan, 0.0
        A = np.vstack([x, np.ones_like(x)]).T
        slope, intercept = np.linalg.lstsq(A, y, rcond=None)[0]
        pred = A @ np.array([slope, intercept])
        ss_res = float(np.sum((y - pred) ** 2))
        ss_tot = float(np.sum((y - y.mean()) ** 2)) + 1e-30
        return -float(slope), float(intercept), 1.0 - ss_res / ss_tot

    y = np.log(ee + 1e-30)
    gamma, ln_a0, r2 = _fit(tt, y)
    a0 = float(np.exp(ln_a0)) if np.isfinite(ln_a0) else float(peak)

    gamma2, r2_late = np.nan, 0.0
    if late_split is not None:
        late = (t >= t0 + late_split) & (env > floor)
        if late.sum() >= 16:
            gamma2, _, r2_late = _fit(t[late], np.log(env[late] + 1e-30))
    return dict(a0=a0, gamma=float(gamma), r2=float(r2), gamma2=float(gamma2),
                r2_late=float(r2_late), t_fit=(float(tt[0]), float(tt[-1])))


# ---------------------------------------------------------------------------
# one note
# ---------------------------------------------------------------------------

def analyze_note(path: str, nominal_midi: int, entry: dict | None = None,
                 sr: int = SR, band_hz: float = MP3_BAND_HZ,
                 max_modes: int = 64) -> dict:
    x = load_audio(path, sr)
    entry = entry or {}
    start, end = analysis_region(x, entry, sr)
    seg = x[start:end].copy()
    peak = float(np.max(np.abs(seg))) + 1e-30
    seg_n = seg / peak

    f0 = estimate_f0(seg_n, sr, midi_to_hz(nominal_midi))
    part = find_partials(seg_n, sr, f0, band_hz, max_modes=max_modes)
    ks, fks, B = part["k"], part["f_k"], part["B"]

    gamma = np.full(ks.size, np.nan)
    a0 = np.full(ks.size, np.nan)
    r2 = np.full(ks.size, np.nan)
    gamma2 = np.full(ks.size, np.nan)
    envs = []
    for i, fk in enumerate(fks):
        bw = min(0.40 * f0, 0.30 * fk)
        env = partial_envelope(seg_n, sr, float(fk), float(bw))
        dec = max(1, int(round(sr / 2000.0)))       # ~2 kHz for the fit/plot
        env = env[::dec]
        fit = fit_decay(env, sr / dec)
        gamma[i] = fit["gamma"]
        gamma2[i] = fit["gamma2"]
        a0[i] = fit["a0"] * peak                    # back to file scale
        r2[i] = fit["r2"]
        if i < 8:
            envs.append(env.astype(np.float32))

    return dict(
        note=entry.get("note", ""), midi=nominal_midi,
        dynamic=entry.get("dynamic", ""), variation=entry.get("variation", ""),
        path=path, sr=sr, f0=f0, B=B,
        k=ks, f_k=fks, amp_k=part["amp_k"], a0=a0, gamma=gamma, gamma2=gamma2, r2=r2,
        region=(start, end), peak=peak, envs=np.asarray(envs) if envs else None,
        env_dt=(1.0 / (sr / max(1, int(round(sr / 2000.0))))),
    )


# ---------------------------------------------------------------------------
# body / coloration
# ---------------------------------------------------------------------------

def body_curve(notes: list[dict], f_lo: float = 40.0, f_hi: float = 16_000.0,
               npts: int = 256, normalize_each: bool = True):
    """Average the per-note partial amplitudes on an absolute-frequency axis.

    Each note contributes its partial magnitudes; a per-note median is removed so the
    result is a *shape*, not a loudness. The comb smears out over many pitches and the
    shared, absolute-frequency structure (box/body coloration) survives.
    """
    grid = np.geomspace(f_lo, f_hi, npts)
    stack = []
    for n in notes:
        fk, ampi = n["f_k"], n["a0"]
        good = np.isfinite(ampi) & (ampi > 0) & (fk >= f_lo) & (fk <= f_hi)
        if good.sum() < 4:
            continue
        db = 20.0 * np.log10(ampi[good])
        if normalize_each:
            db = db - np.median(db)
        stack.append(np.interp(grid, fk[good], db))
    if not stack:
        return grid, np.zeros(npts), np.zeros(npts), 0
    stack = np.asarray(stack)
    return grid, stack.mean(axis=0), stack.std(axis=0), len(stack)


def design_body_fir(grid: np.ndarray, mean_db: np.ndarray, numtaps: int = 129,
                    sr: int = SR):
    """Linear-phase FIR whose magnitude matches the body curve (firwin2)."""
    f_norm = np.clip(grid / (sr / 2.0), 0.0, 1.0)
    gain = 10.0 ** (mean_db / 20.0)
    # strictly increasing, endpoints 0 and 1
    f_norm = np.unique(f_norm)
    gain = gain[:f_norm.size]
    f_full = np.concatenate([[0.0], f_norm, [1.0]])
    g_full = np.concatenate([[gain[0]], gain, [gain[-1]]])
    h = firwin2(numtaps, f_full, g_full)
    h = h / max(np.abs(h).sum(), 1e-12)             # unity DC-ish normalisation
    return h
