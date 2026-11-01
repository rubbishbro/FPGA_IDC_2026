#!/usr/bin/env python3
"""Offline trumpet texture ("friction / grain / air") sensitivity experiment.

This is an audition-only experiment around the *existing* production ENG1 E4
baseline.  It never re-runs or modifies the RTL, the deployed coefficients, the
old experiment scripts, or the git index.  The baseline raw arrays are loaded
from ``trumpet_body_experiment`` and the candidates are made by adding clearly
documented offline perturbations.

The experiment deliberately separates three hypotheses that are often conflated:

  * aperiodic / residual airflow  -> colored noise added *under* the note envelope
  * harmonic "buzz"               -> unchanged harmonic amplitudes
  * harmonic time variation       -> a small, band-limited AM of the high band

The noise level is a manual sensitivity trial, NOT a claim that the recording's
inter-harmonic residual equals broadband noise.  Window leakage, vibrato,
frequency drift and MP3 band-limiting all enter that residual, so the report
includes an exclusion-bandwidth sensitivity sweep instead of one number.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
import sys
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.signal import (
    butter,
    firwin2,
    freqz,
    lfilter,
    sosfiltfilt,
    sosfreqz,
    stft,
    welch,
)

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "python" / "modal_sim"))
sys.path.insert(0, str(ROOT / "python" / "fft_analysis"))

import core as C  # noqa: E402
import eng1_rtl as E  # noqa: E402
import sustain as S  # noqa: E402
from sustain_engine import SustainPatch  # noqa: E402

OUT = ROOT / "FFT_results/sim/eng1/trumpet_texture_experiment"
BODY = ROOT / "FFT_results/sim/eng1/trumpet_body_experiment"
FS = 48000
MASTER_SEED = 20261031
PEAK_LIMIT = 0.88          # -1.11 dBFS, common safety target for every scene
RMS_CAP = 0.075            # -22.50 dBFS cap used by the earlier body experiment
FADE = 960                 # 20 ms at 48 kHz
AIR_LO_DB = -36.0
AIR_HI_DB = -30.0
AM_DEPTH = 0.04            # 4 % std; same order as the recording's ~0.20 dB hl spread
AM_BAND_HZ = (2.5, 12.0)
AM_HIGHPASS_MULT = 3.5     # high band starts at 3.5*f0 (~1.15 kHz for E4)
NOISE_HP_HZ = 500.0
NOISE_LP_HZ = 14000.0
NOISE_TAPS = 513
EXCLUSION_HZ = (10.0, 20.0, 40.0, 60.0, 100.0, 140.0)
RESIDUAL_BAND_HZ = (1000.0, 12000.0)


# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------
def sha256_file(path: Path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def db20(x, floor=1e-30):
    x = np.asarray(x, dtype=np.float64)
    return 20.0 * np.log10(np.maximum(np.abs(x), floor))


def rms(x):
    x = np.asarray(x, dtype=np.float64)
    return float(np.sqrt(np.mean(x * x))) if x.size else 0.0


def dbfs(x):
    r = rms(x)
    return 20.0 * math.log10(max(r, 1e-30))


def normalise_max(a):
    a = np.asarray(a, dtype=np.float64)
    m = float(np.max(np.abs(a))) if a.size else 0.0
    return a / max(m, 1e-30), m


def json_num(x, digits=12):
    """JSON-safe float with a fixed number of significant digits."""
    if x is None:
        return None
    x = float(x)
    if not math.isfinite(x):
        return None
    return float(f"{x:.{digits}g}")


def fmt_db(x, digits=2):
    if x is None:
        return "n/a"
    x = float(x)
    if not math.isfinite(x):
        return "-inf"
    return f"{x:+.{digits}f}"


def window_info(win, scene):
    return {
        "scene": scene,
        "start_sample": int(win.start),
        "stop_sample": int(win.stop),
        "start_s": float(win.start / FS),
        "stop_s": float(win.stop / FS),
        "sample_count": int(win.stop - win.start),
        "rms_dbfs": None,  # filled by caller
    }


# ---------------------------------------------------------------------------
# analysis of the recording and the synthetic E4
# ---------------------------------------------------------------------------
def fft_f0(seg: np.ndarray, nominal: float) -> float:
    """High-resolution FFT f0 near the nominal, with parabolic peak refinement."""
    n = len(seg)
    pad = 8
    w = np.hanning(n)
    X = np.abs(np.fft.rfft(seg * w, n * pad))
    f = np.fft.rfftfreq(n * pad, 1.0 / FS)
    m = (f > 0.75 * nominal) & (f < 1.25 * nominal)
    if not np.any(m):
        return float(nominal)
    j = int(np.flatnonzero(m)[np.argmax(X[m])])
    if not (0 < j < len(X) - 1):
        return float(f[j])
    la, lb, lc = (
        math.log(X[j - 1] + 1e-30),
        math.log(X[j] + 1e-30),
        math.log(X[j + 1] + 1e-30),
    )
    den = la - 2.0 * lb + lc
    delta = 0.5 * (la - lc) / den if den != 0 else 0.0
    return float((j + delta) * (f[1] - f[0]))


def harmonic_amplitudes(y: np.ndarray, f0: float, n_harm: int = 24):
    """Welch band-power harmonic amplitudes, normalised to the strongest."""
    f, p = welch(y, FS, nperseg=min(32768, len(y)))
    amps = []
    for k in range(1, n_harm + 1):
        width = min(0.4 * f0, max(12.0, 0.015 * k * f0))
        mask = np.abs(f - k * f0) < width
        amps.append(float(np.sqrt(np.sum(p[mask]))))
    a = np.asarray(amps)
    return a / max(float(a.max()), 1e-30)


def interharmonic_residual(y: np.ndarray, f0: float):
    """Median between-partial level and between-partial power fraction.

    The same long FFT is re-used for several harmonic-exclusion widths.  A
    residual that falls sharply as the exclusion grows is dominated by window
    leakage / vibrato skirts, not by independent broadband noise.
    """
    n = len(y)
    X = np.abs(np.fft.rfft(y * np.hanning(n)))
    f = np.fft.rfftfreq(n, 1.0 / FS)
    band = (f >= RESIDUAL_BAND_HZ[0]) & (f <= RESIDUAL_BAND_HZ[1])
    peak = float(X[band].max()) + 1e-30
    kmax = int(math.floor(RESIDUAL_BAND_HZ[1] / f0)) + 1
    out = {"band_hz": list(RESIDUAL_BAND_HZ), "peak_x": peak, "fixed": {}}
    for bw in EXCLUSION_HZ:
        keep = band.copy()
        for k in range(1, kmax + 1):
            keep &= np.abs(f - k * f0) > bw
        x = X[keep]
        out["fixed"][f"{bw:g}"] = {
            "exclusion_halfwidth_hz": float(bw),
            "median_rel_peak_db": float(db20(np.median(x) / peak)),
            "between_power_fraction": float(np.sum(x * x) / max(np.sum(X[band] ** 2), 1e-30)),
            "bins": int(np.count_nonzero(keep)),
        }
    # The older sustain.py-style scheme: exclusion grows with harmonic number.
    keep = band.copy()
    for k in range(1, kmax + 1):
        keep &= np.abs(f - k * f0) > max(10.0, 0.02 * k * f0)
    x = X[keep]
    out["variable_2pct_k"] = {
        "rule": "max(10 Hz, 0.02*k*f0)",
        "median_rel_peak_db": float(db20(np.median(x) / peak)),
        "between_power_fraction": float(np.sum(x * x) / max(np.sum(X[band] ** 2), 1e-30)),
        "bins": int(np.count_nonzero(keep)),
    }
    values = [v["median_rel_peak_db"] for v in out["fixed"].values()]
    out["fixed_range_db"] = float(max(values) - min(values))
    all_values = values + [out["variable_2pct_k"]["median_rel_peak_db"]]
    out["overall_range_db"] = float(max(all_values) - min(all_values))
    return out


def residual_profile(y: np.ndarray, f0: float):
    """1/3-octave between-partial median level (fixed 60 Hz exclusion)."""
    n = len(y)
    X = np.abs(np.fft.rfft(y * np.hanning(n)))
    f = np.fft.rfftfreq(n, 1.0 / FS)
    band = (f >= RESIDUAL_BAND_HZ[0]) & (f <= RESIDUAL_BAND_HZ[1])
    peak = float(X[band].max()) + 1e-30
    edges = np.geomspace(1000.0, 12000.0, 13)
    centers, vals = [], []
    for lo, hi in zip(edges[:-1], edges[1:]):
        m = (f >= lo) & (f < hi)
        for k in range(1, int(math.floor(hi / f0)) + 1):
            m &= np.abs(f - k * f0) > 60.0
        centers.append(float(math.sqrt(lo * hi)))
        vals.append(float(db20(np.median(X[m]) / peak)) if np.any(m) else -200.0)
    return {"centers_hz": centers, "median_rel_peak_db": vals}


def short_time_high_low(y: np.ndarray, f0: float, start: int, stop: int):
    """Short-time high/low harmonic power ratio (dB) and its fluctuation."""
    seg = y[int(start):int(stop)]
    nper, hop = 4096, 512
    f, t, Z = stft(seg, FS, window="hann", nperseg=nper, noverlap=nper - hop,
                   boundary=None, padded=False)
    p = np.abs(Z) ** 2
    amps = []
    for k in range(1, 13):
        m = np.abs(f - k * f0) < max(20.0, 0.12 * f0)
        amps.append(p[m].sum(axis=0))
    amps = np.asarray(amps)
    low = amps[:4].sum(axis=0)
    high = amps[4:12].sum(axis=0)
    total = low + high
    gate = total > 0.01 * float(np.median(total))
    ratio = 10.0 * np.log10(np.maximum(high, 1e-30) / np.maximum(low, 1e-30))
    ratio = ratio[gate]
    t = t[gate] + start / FS
    return {
        "mean_db": float(np.mean(ratio)),
        "std_db": float(np.std(ratio)),
        "p05_db": float(np.percentile(ratio, 5)),
        "p95_db": float(np.percentile(ratio, 95)),
        "range_db": float(np.percentile(ratio, 95) - np.percentile(ratio, 5)),
        "frames": int(ratio.size),
        "nperseg": nper,
        "hop": hop,
        "low_harmonics": [1, 2, 3, 4],
        "high_harmonics": [5, 6, 7, 8, 9, 10, 11, 12],
        "time_s": t.tolist(),
        "ratio_db": ratio.tolist(),
    }


def f0_track(y: np.ndarray, f0_nominal: float, start: int, stop: int):
    """Frame-by-frame f0 track (Hz), reported as cent deviation from its median."""
    seg = y[int(start):int(stop)]
    nper, hop = 4096, 512
    ff = np.fft.rfftfreq(nper, 1.0 / FS)
    vals = []
    for i in range(0, len(seg) - nper, hop):
        Xf = np.abs(np.fft.rfft(seg[i:i + nper] * np.hanning(nper)))
        m = (ff > 0.9 * f0_nominal) & (ff < 1.1 * f0_nominal)
        if not np.any(m):
            continue
        j = int(np.flatnonzero(m)[np.argmax(Xf[m])])
        if not (0 < j < len(Xf) - 1):
            continue
        la, lb, lc = (
            math.log(Xf[j - 1] + 1e-30),
            math.log(Xf[j] + 1e-30),
            math.log(Xf[j + 1] + 1e-30),
        )
        den = la - 2.0 * lb + lc
        d = 0.5 * (la - lc) / den if den != 0 else 0.0
        vals.append((j + d) * (ff[1] - ff[0]))
    v = np.asarray(vals)
    med = float(np.median(v)) if v.size else float(f0_nominal)
    cents = 1200.0 * np.log2(v / med) if v.size else np.array([0.0])
    return {
        "median_hz": med,
        "std_cents": float(np.std(cents)),
        "range_cents": float(np.max(cents) - np.min(cents)),
        "frames": int(v.size),
        "nperseg": nper,
        "hop": hop,
    }


def onset_metrics(y: np.ndarray, on: int, steady_start: int, steady_stop: int):
    env = S._envelope(y, FS, win=0.01)
    steady = float(np.median(env[steady_start:steady_stop]))
    lo, hi = 0.1 * steady, 0.9 * steady
    i10 = i90 = None
    stop = min(len(env), on + int(0.6 * FS))
    r = np.flatnonzero(env[on:stop] >= lo)
    if r.size:
        i10 = int(on + r[0])
        r9 = np.flatnonzero(env[on:stop] >= hi)
        if r9.size:
            i90 = int(on + r9[0])
    attack = None if (i10 is None or i90 is None) else float((i90 - i10) / FS * 1000.0)
    first = rms(y[on:min(len(y), on + int(0.05 * FS))])
    late = rms(y[steady_start:steady_stop])
    return {
        "note_on_sample": int(on),
        "note_on_s": float(on / FS),
        "steady_rms": late,
        "attack_10_90_ms": attack,
        "first_50ms_vs_steady_db": float(db20(first / max(late, 1e-30))),
    }


def spectral_summary(y: np.ndarray):
    f, p = welch(y, FS, nperseg=min(32768, len(y)))
    total = float(np.sum(p))
    return {
        "centroid_hz": float(np.sum(f * p) / max(total, 1e-30)),
        "above_2khz_power_fraction": float(np.sum(p[f >= 2000.0]) / max(total, 1e-30)),
        "above_4khz_power_fraction": float(np.sum(p[f >= 4000.0]) / max(total, 1e-30)),
    }


# ---------------------------------------------------------------------------
# perturbation generators
# ---------------------------------------------------------------------------
def design_noise_filter(patch: SustainPatch):
    """Source-shaped, band-limited colored noise FIR.

    The magnitude follows the mean inter-harmonic noise shape extracted from
    the local trumpet notes (``SustainPatch.noise_shape_db``), then is limited to
    500 Hz .. 14 kHz so the perturbation does not pretend to be low-frequency
    body rumble.  The exact response is measured and stored.
    """
    edges = np.asarray(patch.noise_edges, dtype=float)
    centers = np.sqrt(edges[:-1] * edges[1:])
    shape_db = np.asarray(patch.noise_shape_db, dtype=float)
    f = np.geomspace(100.0, 20000.0, 400)
    shape = np.interp(np.log(f), np.log(centers), shape_db)
    order = 2
    hp = 1.0 / np.sqrt(1.0 + (NOISE_HP_HZ / f) ** (2 * order))
    lp = 1.0 / np.sqrt(1.0 + (f / NOISE_LP_HZ) ** (2 * order))
    g = 10.0 ** (shape / 20.0) * hp * lp
    fn = np.concatenate([[0.0], f / (FS / 2.0), [1.0]])
    gg = np.concatenate([[0.0], g, [0.0]])
    h = firwin2(NOISE_TAPS, fn, gg)
    w, H = freqz(h, worN=8192, fs=FS)
    response_db = 20.0 * np.log10(np.maximum(np.abs(H), 1e-15))
    return h, {
        "taps": NOISE_TAPS,
        "highpass_hz": NOISE_HP_HZ,
        "lowpass_hz": NOISE_LP_HZ,
        "shape_source": "mean of local trumpet SustainPatch.noise_shape_db",
        "shape_edges_hz": edges.tolist(),
        "shape_centers_hz": centers.tolist(),
        "shape_db": shape_db.tolist(),
        "response_freq_hz": w.tolist(),
        "response_db": response_db.tolist(),
        "response_at_hz": {
            str(int(hz)): float(response_db[np.argmin(np.abs(w - hz))])
            for hz in (250, 500, 1000, 2000, 4000, 8000, 12000)
        },
    }


def envelope_follow(base: np.ndarray, active: slice):
    env = S._envelope(base, FS, win=0.01)
    k = max(1, int(0.02 * FS))
    env = np.convolve(env, np.ones(k) / k, mode="same")
    ref = float(np.median(env[active]))
    return np.clip(env / max(ref, 1e-30), 0.0, 2.0)


def activity_gate(base: np.ndarray, active: slice):
    env = S._envelope(base, FS, win=0.01)
    k = max(1, int(0.005 * FS))
    env = np.convolve(env, np.ones(k) / k, mode="same")
    ref = float(np.median(env[active]))
    return np.clip(env / max(0.02 * ref, 1e-30), 0.0, 1.0)


def make_noise(base: np.ndarray, h: np.ndarray, gate_env: np.ndarray,
               active: slice, ratio_db: float, seed: int):
    rng = np.random.default_rng(int(seed))
    w = rng.standard_normal(len(base) + 1024)
    nz = lfilter(h, 1.0, w)[512:512 + len(base)]
    nz = nz * gate_env
    base_rms = rms(base[active])
    raw_rms = rms(nz[active])
    scale = base_rms * 10.0 ** (ratio_db / 20.0) / max(raw_rms, 1e-30)
    nz = nz * scale
    return nz, {
        "requested_rms_db_rel_base": float(ratio_db),
        "realised_rms_db_rel_base": float(db20(rms(nz[active]) / max(base_rms, 1e-30))),
        "seed": int(seed),
        "envelope_follow": "smoothed 10 ms RMS of baseline, 20 ms smoothing, clipped to [0, 2]",
    }


def make_harmonic_am(base: np.ndarray, gate: np.ndarray, active: slice,
                     f0: float, seed: int):
    """Small continuous AM of the high harmonic band only (no pitch change)."""
    hp = butter(4, AM_HIGHPASS_MULT * f0 / (FS / 2.0), btype="high", output="sos")
    high = sosfiltfilt(hp, base)
    rng = np.random.default_rng(int(seed))
    w = rng.standard_normal(len(base) + 2048)
    bp = butter(2, [AM_BAND_HZ[0] / (FS / 2.0), AM_BAND_HZ[1] / (FS / 2.0)],
                btype="band", output="sos")
    m = sosfiltfilt(bp, w)[1024:1024 + len(base)]
    m = m - np.mean(m[active])
    m = m / max(float(np.std(m[active])), 1e-30)
    clipped = int(np.count_nonzero(np.abs(m) > 3.0))
    m = np.clip(m, -3.0, 3.0)
    depth = AM_DEPTH * m * gate
    pert = depth * high
    base_rms = rms(base[active])
    return pert, {
        "depth_std": AM_DEPTH,
        "rate_band_hz": list(AM_BAND_HZ),
        "highpass_hz": float(AM_HIGHPASS_MULT * f0),
        "high_harmonics": ">= 4 (highpass at 3.5*f0)",
        "seed": int(seed),
        "modulation_clipped_samples": clipped,
        "gate": "smoothed baseline RMS envelope, 5 ms, [0, 1]",
        "realised_rms_db_rel_base": float(db20(rms(pert[active]) / max(base_rms, 1e-30))),
        "peak_rel_base_peak_db": float(db20(
            np.max(np.abs(pert)) / max(np.max(np.abs(base)), 1e-30))),
    }


def high_shelf_sos(hz: float, gain_db: float, slope: float = 1.0):
    """RBJ high-shelf biquad in SOS form (same form as the earlier body test)."""
    a = 10.0 ** (gain_db / 40.0)
    w = 2.0 * math.pi * hz / FS
    c, s = math.cos(w), math.sin(w)
    alpha = s / 2.0 * math.sqrt(2.0)
    v = 2.0 * math.sqrt(a) * alpha
    b = [a * ((a + 1) + (a - 1) * c + v),
         -2 * a * ((a - 1) + (a + 1) * c),
         a * ((a + 1) + (a - 1) * c - v)]
    d = [(a + 1) - (a - 1) * c + v,
         2 * ((a - 1) - (a + 1) * c),
         (a + 1) - (a - 1) * c - v]
    row = np.asarray([*b, *d], dtype=np.float64) / d[0]
    return np.asarray([row]), row


def make_static_shelf(base: np.ndarray):
    sos, row = high_shelf_sos(2000.0, 6.0, 1.0)
    y = sosfiltfilt(sos, base)
    w, H = sosfreqz(sos, worN=8192, fs=FS)
    d = 20.0 * np.log10(np.maximum(np.abs(H), 1e-15))
    return y, {
        "shelf_hz": 2000.0,
        "boost_db": 6.0,
        "slope": 1.0,
        "zero_phase": True,
        "coeffs": row.tolist(),
        "response_freq_hz": w.tolist(),
        "response_db": d.tolist(),
        "response_at_hz": {
            str(int(hz)): float(d[np.argmin(np.abs(w - hz))])
            for hz in (250, 500, 1000, 2000, 4000, 8000)
        },
    }


# ---------------------------------------------------------------------------
# candidate assembly, normalisation, verification
# ---------------------------------------------------------------------------
def build_scene(scene: str, f0_syn: float):
    raw_path = BODY / f"baseline_{scene}.npy"
    raw = np.load(raw_path)
    raw_check = np.load(raw_path)
    assert raw.dtype == np.int64 and np.array_equal(raw, raw_check), "baseline npy changed"
    base = raw.astype(np.float64) / float(1 << 24) / 8.0
    assert np.all(np.isfinite(base)) and base.size == raw.size
    active = slice(5760, 466560) if scene == "phrase" else slice(5760, 77760)

    patch = SustainPatch("trumpet")
    h, noise_info = design_noise_filter(patch)
    env = envelope_follow(base, active)
    gate = activity_gate(base, active)
    seed_noise = MASTER_SEED + (1 if scene == "phrase" else 2)
    seed_am = seed_noise + 500

    noise_lo, noise_lo_info = make_noise(base, h, env, active, AIR_LO_DB, seed_noise)
    noise_hi, noise_hi_info = make_noise(base, h, env, active, AIR_HI_DB, seed_noise)
    am_pert, am_info = make_harmonic_am(base, gate, active, f0_syn, seed_am)
    shelf, shelf_info = make_static_shelf(base)

    # Same noise waveform, exactly +6 dB; this is verified, not assumed.
    ratio = rms(noise_hi[active]) / max(rms(noise_lo[active]), 1e-30)
    assert abs(20.0 * math.log10(ratio) - 6.0) < 1e-6, ratio

    candidates = {
        "baseline": (base, {"kind": "none"}),
        "air_lo": (base + noise_lo, {"kind": "air", "rms_db_rel_base": AIR_LO_DB,
                                      "noise": noise_lo_info}),
        "air_hi": (base + noise_hi, {"kind": "air", "rms_db_rel_base": AIR_HI_DB,
                                      "noise": noise_hi_info}),
        "harm_am": (base + am_pert, {"kind": "harmonic_am", "am": am_info}),
        "air_harm": (base + noise_lo + am_pert,
                     {"kind": "air+harmonic_am", "rms_db_rel_base": AIR_LO_DB,
                      "noise": noise_lo_info, "am": am_info}),
        "hf_static": (shelf, {"kind": "static_high_shelf", "shelf": shelf_info}),
    }
    components = {
        "noise_lo": noise_lo,
        "noise_hi": noise_hi,
        "am_pert": am_pert,
        "shelf_minus_base": shelf - base,
    }
    return raw, base, active, candidates, components, {
        "noise_filter": noise_info,
        "am": am_info,
        "shelf": shelf_info,
    }


def normalise_and_write(scene: str, base: np.ndarray, active: slice, candidates):
    info = {}
    for name, (y, _) in candidates.items():
        pre_rms = rms(y[active])
        pre_peak = float(np.max(np.abs(y)))
        info[name] = {
            "pre_norm_active_rms_dbfs": float(db20(pre_rms)),
            "pre_norm_peak_dbfs": float(db20(pre_peak)),
            "pre_norm_active_rms": pre_rms,
            "pre_norm_peak": pre_peak,
            "gain_linear": None,
            "gain_db": None,
        }
    peak_ratios = {
        n: PEAK_LIMIT * info[n]["pre_norm_active_rms"] / max(info[n]["pre_norm_peak"], 1e-30)
        for n in info
    }
    peak_constraint = min(peak_ratios, key=peak_ratios.get)
    target = min(RMS_CAP, peak_ratios[peak_constraint])
    limiting = "rms_cap" if RMS_CAP <= peak_ratios[peak_constraint] else peak_constraint
    for name, (y, meta) in candidates.items():
        gain = target / max(info[name]["pre_norm_active_rms"], 1e-30)
        z = y * gain
        z[-FADE:] *= np.linspace(1.0, 0.0, FADE)
        path = OUT / f"{name}_{scene}.wav"
        sf.write(path, np.repeat(z[:, None], 2, axis=1), FS, subtype="PCM_24")
        check, fs = sf.read(path, always_2d=True)
        assert fs == FS and check.shape == (len(y), 2), (name, fs, check.shape)
        assert np.all(np.isfinite(check)), name
        mono = check[:, 0]
        post_rms = rms(mono[active])
        post_peak = float(np.max(np.abs(check)))
        assert post_peak <= PEAK_LIMIT + 1e-6, (name, post_peak)
        assert abs(post_rms / target - 1.0) < 2e-6, (name, post_rms, target)
        # Baseline must be the untouched raw, only scalar gain + end fade.
        if name == "baseline":
            expected = y * gain
            expected[-FADE:] *= np.linspace(1.0, 0.0, FADE)
            q = 2.5 / float(1 << 23)
            assert np.max(np.abs(mono - expected)) <= q, "baseline WAV differs from raw-derived signal"
        pre_roll = slice(0, int(0.10 * FS))
        tail = slice(int(10.0 * FS), len(mono)) if scene == "phrase" else slice(int(2.05 * FS), len(mono))
        pre_roll_rms = rms(mono[pre_roll])
        tail_rms = rms(mono[tail])
        assert pre_roll_rms <= 1e-6, (name, scene, "pre-roll not silent", pre_roll_rms)
        # The tail may contain a tiny filter/release residue, but must not be a
        # persistent hiss bed.  -80 dBFS is well below the note and the fade.
        assert tail_rms <= 1e-4, (name, scene, "tail not quiet", tail_rms)
        diff = y - base
        diff_rms = rms(diff[active])
        diff_peak = float(np.max(np.abs(diff)))
        meta = dict(meta)
        meta.update({
            "file": path.name,
            "sample_count": int(len(mono)),
            "seconds": float(len(mono) / FS),
            "gain_linear": float(gain),
            "gain_db": float(20.0 * math.log10(gain)),
            "constant_gain_no_compression": True,
            "end_fade_samples": FADE,
            "active_rms_dbfs": float(db20(post_rms)),
            "peak_dbfs": float(db20(post_peak)),
            "peak_linear": post_peak,
            "pre_roll_rms_dbfs": float(db20(pre_roll_rms)),
            "tail_rms_dbfs": float(db20(tail_rms)),
            "added_component_rms_db_rel_base_pre": None if name == "baseline"
            else float(db20(diff_rms / max(rms(base[active]), 1e-30))),
            "added_component_rms_db_rel_base_post": None if name == "baseline"
            else float(db20(diff_rms / max(rms(base[active]), 1e-30))),
            "added_component_peak_db_rel_base_peak": None if name == "baseline"
            else float(db20(diff_peak / max(np.max(np.abs(base)), 1e-30))),
            "pcm24_rail_samples": int(np.count_nonzero(np.abs(check) >= 1.0)),
            "sha256": sha256_file(path),
        })
        info[name]["written"] = meta
    return target, limiting, peak_constraint, info


def candidate_analysis(name: str, y: np.ndarray, base: np.ndarray, f0: float,
                       base_harm: np.ndarray, active: slice):
    steady = y[int(0.8 * FS):int(1.4 * FS)]
    harm = harmonic_amplitudes(steady, f0)
    good = base_harm > 10.0 ** (-40.0 / 20.0)
    err = db20(harm[good] / np.maximum(base_harm[good], 1e-30))
    resid = interharmonic_residual(steady, f0)
    hl = short_time_high_low(y, f0, int(0.8 * FS), int(1.6 * FS))
    sp = spectral_summary(steady)
    diff = y - base
    return {
        "harmonic_normalised_db_rel_max": db20(harm).tolist(),
        "harmonic_rms_error_vs_baseline_db": float(np.sqrt(np.mean(err * err))),
        "harmonic_max_abs_error_db": float(np.max(np.abs(err))),
        "interharmonic_residual": resid,
        "short_time_high_low": {k: hl[k] for k in
                                ("mean_db", "std_db", "p05_db", "p95_db", "range_db",
                                 "frames", "nperseg", "hop", "low_harmonics", "high_harmonics",
                                 "time_s", "ratio_db")},
        "spectral": sp,
        "difference_rms_db_rel_base": float(db20(
            rms(diff[active]) / max(rms(base[active]), 1e-30))),
    }


# ---------------------------------------------------------------------------
# plotting
# ---------------------------------------------------------------------------
def make_figure(analysis, scene_data, noise_info, shelf_info):
    os.environ.setdefault("MPLCONFIGDIR", str(OUT / "mpl"))
    (OUT / "mpl").mkdir(parents=True, exist_ok=True)
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    rec = analysis["recording"]
    syn = analysis["synth"]
    cand = {r["name"]: r for r in analysis["candidates"]}

    fig, axes = plt.subplots(3, 2, figsize=(15, 11))
    ax = axes[0, 0]
    k = np.arange(1, 25)
    ax.plot(k, rec["harmonic_normalised_db_rel_max"], "o-", label="recording E4", lw=1.3)
    ax.plot(k, syn["harmonic_normalised_db_rel_max"], "s--", label="synth baseline", lw=1.3)
    ax.plot(k, cand["hf_static"]["harmonic_normalised_db_rel_max"], "^-.",
            label="synth + static 6 dB HF shelf", lw=1.0, alpha=.8)
    ax.set(xlabel="Harmonic number", ylabel="Relative amplitude (dB)", ylim=(-60, 3),
           title=f"E4 steady harmonic shape (f0 rec {rec['f0_hz']:.2f} Hz, "
                 f"synth {syn['f0_hz']:.2f} Hz)")
    ax.grid(alpha=.25); ax.legend(fontsize=8)

    ax = axes[0, 1]
    bws = list(EXCLUSION_HZ)
    for label, r in [("recording", rec), ("synth baseline", syn),
                     ("air -36 dB", cand["air_lo"]), ("air -30 dB", cand["air_hi"]),
                     ("harm AM", cand["harm_am"]), ("air+AM", cand["air_harm"])]:
        vals = [r["interharmonic_residual"]["fixed"][f"{bw:g}"]["median_rel_peak_db"]
                for bw in bws]
        ax.plot(bws, vals, "o-", label=label, lw=1.2, ms=4)
    ax.set(xlabel="Harmonic exclusion half-width (Hz)",
           ylabel="Inter-harmonic median (dB rel. peak)",
           title="Residual is exclusion-width dependent (not a noise meter)")
    ax.grid(alpha=.25); ax.legend(fontsize=7)
    ax.text(0.02, 0.03,
            f"recording fixed range {rec['interharmonic_residual']['fixed_range_db']:.1f} dB\n"
            f"synth fixed range {syn['interharmonic_residual']['fixed_range_db']:.1f} dB",
            transform=ax.transAxes, fontsize=7, va="bottom")

    ax = axes[1, 0]
    h = rec["short_time_high_low"]
    hs = syn["short_time_high_low"]
    ha = cand["harm_am"]["short_time_high_low"]
    ax.plot(np.asarray(h["time_s"]), h["ratio_db"], label=f"recording (std {h['std_db']:.2f} dB)")
    ax.plot(np.asarray(hs["time_s"]), hs["ratio_db"], label=f"synth baseline (std {hs['std_db']:.2f} dB)")
    ax.plot(np.asarray(ha["time_s"]), ha["ratio_db"], label=f"harm AM (std {ha['std_db']:.2f} dB)", alpha=.8)
    ax.set(xlabel="Time in analysis segment (s)", ylabel="High/low harmonic power (dB)",
           title="Short-time high/low harmonic ratio")
    ax.grid(alpha=.25); ax.legend(fontsize=8)

    # Two spectrograms on the same dB colour scale and frequency range.
    for ax, y, title, st in [
        (axes[1, 1], scene_data["recording_steady"], "Recording E4 steady spectrogram",
         rec["hl_window"]),
        (axes[2, 0], scene_data["synth_steady"], "Synth baseline E4 steady spectrogram",
         syn["hl_window"]),
    ]:
        # Match display RMS so the shared colour scale compares structure.
        y = y * (0.075 / max(rms(y), 1e-30))
        f, t, Z = stft(y, FS, window="hann", nperseg=2048, noverlap=1536,
                       boundary=None, padded=False)
        p = 20.0 * np.log10(np.maximum(np.abs(Z), 1e-12))
        ax.pcolormesh(t + st["start_s"], f, p, shading="auto", cmap="magma",
                      vmin=-110, vmax=-20)
        ax.set(xlabel="Time (s)", ylabel="Frequency (Hz)", ylim=(0, 8000), title=title)

    ax = axes[2, 1]
    w = np.asarray(noise_info["response_freq_hz"])
    d = np.asarray(noise_info["response_db"])
    ax.semilogx(w[1:], d[1:], label="colored-noise filter (measured shape)")
    ws = np.asarray(shelf_info["response_freq_hz"])
    ds = np.asarray(shelf_info["response_db"])
    ax.semilogx(ws[1:], ds[1:], "--", label="static high shelf (+6 dB HF, corner 2 kHz)")
    ax.set(xlim=(100, 16000), ylim=(-35, 10), xlabel="Frequency (Hz)",
           ylabel="Gain (dB)", title="What the perturbations add")
    ax.grid(alpha=.25, which="both"); ax.legend(fontsize=8)

    fig.suptitle(
        "Trumpet texture sensitivity: baseline ENG1 E4, offline additions only; "
        "residual != true noise, no RTL rerun",
        fontsize=11,
    )
    fig.tight_layout(rect=[0, 0, 1, 0.97])
    path = OUT / "texture_analysis.png"
    fig.savefig(path, dpi=160)
    plt.close(fig)
    assert path.exists() and path.stat().st_size > 20000
    return path


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main():
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "mpl").mkdir(parents=True, exist_ok=True)
    assert OUT != BODY

    patch = SustainPatch("trumpet")
    src = patch._pick(64, "forte")
    src_path = ROOT / "music_resources/trumpet" / src["note"]
    file_sr = int(sf.info(src_path).samplerate)
    recording = C.load_audio(str(src_path), FS)
    on, off = S.note_region(recording, FS)
    span = off - on
    rec_steady = recording[on + int(0.30 * span):on + int(0.30 * span) + int(0.60 * FS)]
    f0_rec = float(C.estimate_f0(rec_steady, FS, C.midi_to_hz(64),
                                 band_hz=16000.0, span=0.05))
    f0_rec_fft = fft_f0(rec_steady, f0_rec)
    rec_hl_start = int(on + 0.40 * span)
    rec_hl_stop = min(len(recording), rec_hl_start + int(0.8 * FS))
    rec_harm = harmonic_amplitudes(rec_steady, f0_rec)
    rec_resid = interharmonic_residual(rec_steady, f0_rec)
    rec_hl = short_time_high_low(recording, f0_rec, rec_hl_start, rec_hl_stop)
    rec_f0_track = f0_track(recording, f0_rec, rec_hl_start, rec_hl_stop)
    rec_onset = onset_metrics(recording, on, on + int(0.30 * span), on + int(0.70 * span))
    rec_spectral = spectral_summary(rec_steady)
    rec_resid_profile = residual_profile(rec_steady, f0_rec)

    period = int(E.ResourceBank.build("trumpet", [64]).notes[64].period)
    f0_syn = FS / period
    raw_single_path = BODY / "baseline_single.npy"
    raw_single = np.load(raw_single_path)
    base_single = raw_single.astype(np.float64) / float(1 << 24) / 8.0
    syn_steady = base_single[38400:67200]
    syn_harm = harmonic_amplitudes(syn_steady, f0_syn)
    syn_resid = interharmonic_residual(syn_steady, f0_syn)
    syn_hl = short_time_high_low(base_single, f0_syn, 38400, 76800)
    syn_f0_track = f0_track(base_single, f0_syn, 38400, 76800)
    syn_onset = onset_metrics(base_single, 5760, 38400, 67200)
    syn_spectral = spectral_summary(syn_steady)
    syn_resid_profile = residual_profile(syn_steady, f0_syn)

    good = rec_harm > 10.0 ** (-40.0 / 20.0)
    harm_err = db20(rec_harm[good] / np.maximum(syn_harm[good], 1e-30))
    harmonic_rms_error = float(np.sqrt(np.mean(harm_err * harm_err)))

    analysis = {
        "recording": {
            "source_file": str(src_path.relative_to(ROOT)),
            "source_sha256": sha256_file(src_path),
            "source_file_sample_rate": file_sr,
            "loaded_sample_rate": FS,
            "resample": "one polyphase resample from source rate to 48 kHz (no tuning/stretch)",
            "seconds_loaded": len(recording) / FS,
            "note_on_sample": int(on),
            "note_off_sample": int(off),
            "note_on_s": on / FS,
            "note_off_s": off / FS,
            "note_span_s": span / FS,
            "f0_hz": f0_rec,
            "f0_fft_crosscheck_hz": f0_rec_fft,
            "f0_cents_vs_12tet_E4": float(1200.0 * math.log2(f0_rec / C.midi_to_hz(64))),
            "f0_track": rec_f0_track,
            "steady_window": {"start_sample": int(on + int(0.30 * span)),
                              "stop_sample": int(on + int(0.30 * span) + len(rec_steady)),
                              "start_s": float((on + int(0.30 * span)) / FS),
                              "stop_s": float((on + int(0.30 * span) + len(rec_steady)) / FS)},
            "harmonic_normalised_db_rel_max": db20(rec_harm).tolist(),
            "interharmonic_residual": rec_resid,
            "residual_profile": rec_resid_profile,
            "short_time_high_low": {k: rec_hl[k] for k in
                                    ("mean_db", "std_db", "p05_db", "p95_db", "range_db",
                                     "frames", "nperseg", "hop", "low_harmonics",
                                     "high_harmonics", "time_s", "ratio_db")},
            "hl_window": {"start_s": rec_hl_start / FS, "stop_s": rec_hl_stop / FS},
            "onset": rec_onset,
            "spectral": rec_spectral,
        },
        "synth": {
            "baseline_npy": str(raw_single_path.relative_to(ROOT)),
            "baseline_npy_sha256": sha256_file(raw_single_path),
            "raw_dtype": str(raw_single.dtype),
            "raw_shape": list(raw_single.shape),
            "raw_scale": "int64 Q24, /8 headroom; float = raw / 2**24 / 8",
            "period_samples": period,
            "f0_hz": f0_syn,
            "f0_cents_vs_12tet_E4": float(1200.0 * math.log2(f0_syn / C.midi_to_hz(64))),
            "f0_track": syn_f0_track,
            "steady_window": {"start_sample": 38400, "stop_sample": 67200,
                              "start_s": 0.8, "stop_s": 1.4},
            "harmonic_normalised_db_rel_max": db20(syn_harm).tolist(),
            "interharmonic_residual": syn_resid,
            "residual_profile": syn_resid_profile,
            "short_time_high_low": {k: syn_hl[k] for k in
                                    ("mean_db", "std_db", "p05_db", "p95_db", "range_db",
                                     "frames", "nperseg", "hop", "low_harmonics",
                                     "high_harmonics", "time_s", "ratio_db")},
            "hl_window": {"start_s": 38400 / FS, "stop_s": 76800 / FS},
            "onset": syn_onset,
            "spectral": syn_spectral,
        },
        "comparison": {
            "f0_difference_hz": float(f0_rec - f0_syn),
            "f0_difference_cents": float(1200.0 * math.log2(f0_rec / f0_syn)),
            "harmonic_rms_error_db": harmonic_rms_error,
            "harmonic_max_abs_error_db": float(np.max(np.abs(harm_err))),
            "harmonics_compared": int(np.count_nonzero(good)),
            "residual_metric_note": (
                "Between-partial levels are not a direct measurement of broadband "
                "noise: Hann leakage, vibrato/frequency drift and MP3 band-limiting "
                "all enter. The fixed-width sweep is the sensitivity check."
            ),
        },
        "windows": {
            "normalisation_phrase": {"start_sample": 5760, "stop_sample": 466560,
                                     "start_s": 0.12, "stop_s": 9.72},
            "normalisation_single": {"start_sample": 5760, "stop_sample": 77760,
                                     "start_s": 0.12, "stop_s": 1.62},
            "residual_band_hz": list(RESIDUAL_BAND_HZ),
            "exclusion_halfwidths_hz": list(EXCLUSION_HZ),
        },
    }

    # Build both scenes, normalise, verify, and analyse single candidates.
    scene_results = {}
    scene_data = {}
    for scene in ("phrase", "single"):
        print(f"BUILD {scene}", flush=True)
        raw, base, active, candidates, components, gen_info = build_scene(scene, f0_syn)
        target, limiting, peak_constraint, norm = normalise_and_write(scene, base, active, candidates)
        scene_results[scene] = {
            "raw_npy": str((BODY / f"baseline_{scene}.npy").relative_to(ROOT)),
            "raw_npy_sha256": sha256_file(BODY / f"baseline_{scene}.npy"),
            "sample_count": int(len(base)),
            "seconds": float(len(base) / FS),
            "active_window": {"start_sample": active.start, "stop_sample": active.stop,
                              "start_s": active.start / FS, "stop_s": active.stop / FS},
            "target_active_rms_dbfs": float(db20(target)),
            "peak_limit_linear": PEAK_LIMIT,
            "peak_limit_dbfs": float(db20(PEAK_LIMIT)),
            "rms_cap_dbfs": float(db20(RMS_CAP)),
            "limiting_candidate": limiting,
            "peak_constraint_candidate": peak_constraint,
            "candidates": norm,
            "generation": gen_info,
        }
        scene_data[scene] = {
            "base": base, "candidates": candidates, "components": components,
            "active": active,
        }

    single = scene_data["single"]
    analyses = []
    base_harm = syn_harm
    for name, (y, meta) in single["candidates"].items():
        print(f"ANALYSE {name}", flush=True)
        a = candidate_analysis(name, y, single["base"], f0_syn, base_harm, single["active"])
        a["name"] = name
        a["description"] = {
            "baseline": "production ENG1 raw, no added component",
            "air_lo": "colored aperiodic component at -36 dB RMS rel. baseline active RMS",
            "air_hi": "same colored aperiodic component at -30 dB RMS (+6 dB vs air_lo)",
            "harm_am": "4 % std band-limited (2.5-12 Hz) AM of the >3.5*f0 high band only",
            "air_harm": "air_lo (-36 dB) + harm_am together",
            "hf_static": "static +6 dB high shelf, corner 2 kHz (brightness control; not texture)",
        }[name]
        analyses.append(a)

    # Add the measured candidate metrics to the written scene records.
    by_name = {a["name"]: a for a in analyses}
    for name, a in by_name.items():
        scene_results["single"]["candidates"][name]["written"]["analysis"] = {
            "harmonic_rms_error_vs_baseline_db": a["harmonic_rms_error_vs_baseline_db"],
            "harmonic_max_abs_error_db": a["harmonic_max_abs_error_db"],
            "interharmonic_residual_fixed": a["interharmonic_residual"]["fixed"],
            "interharmonic_residual_variable": a["interharmonic_residual"]["variable_2pct_k"],
            "short_time_high_low": a["short_time_high_low"],
            "spectral": a["spectral"],
        }

    # 2.4 s real-recording reference, aligned at note onset, separate gain.
    ref = np.zeros(115200)
    ref_start = max(0, on - 5760)
    part = recording[ref_start:ref_start + len(ref)]
    ref[:len(part)] = part
    ref_gain = min(
        RMS_CAP / max(rms(ref[5760:77760]), 1e-30),
        PEAK_LIMIT / max(float(np.max(np.abs(ref))), 1e-30),
    )
    ref = ref * ref_gain
    ref[-FADE:] *= np.linspace(1.0, 0.0, FADE)
    ref_path = OUT / "recording_reference_E4.wav"
    sf.write(ref_path, np.repeat(ref[:, None], 2, axis=1), FS, subtype="PCM_24")
    ref_check, ref_fs = sf.read(ref_path, always_2d=True)
    assert ref_fs == FS and ref_check.shape == (115200, 2) and np.all(np.isfinite(ref_check))
    assert np.max(np.abs(ref_check)) <= PEAK_LIMIT + 1e-6

    # Filter response / analysis arrays for reproducibility.
    np.savez(
        OUT / "analysis_arrays.npz",
        exclusion_hz=np.asarray(EXCLUSION_HZ),
        recording_residual_profile_centers=np.asarray(rec_resid_profile["centers_hz"]),
        recording_residual_profile_db=np.asarray(rec_resid_profile["median_rel_peak_db"]),
        synth_residual_profile_centers=np.asarray(syn_resid_profile["centers_hz"]),
        synth_residual_profile_db=np.asarray(syn_resid_profile["median_rel_peak_db"]),
        recording_harmonic_db=np.asarray(db20(rec_harm)),
        synth_harmonic_db=np.asarray(db20(syn_harm)),
        recording_hl_time_s=np.asarray(rec_hl["time_s"]),
        recording_hl_ratio_db=np.asarray(rec_hl["ratio_db"]),
        synth_hl_time_s=np.asarray(syn_hl["time_s"]),
        synth_hl_ratio_db=np.asarray(syn_hl["ratio_db"]),
    )
    h_single, _ = design_noise_filter(patch)
    np.savez(
        OUT / "noise_filter.npz",
        h=h_single,
        freq_hz=np.asarray(scene_results["single"]["generation"]["noise_filter"]["response_freq_hz"]),
        response_db=np.asarray(scene_results["single"]["generation"]["noise_filter"]["response_db"]),
        highpass_hz=NOISE_HP_HZ,
        lowpass_hz=NOISE_LP_HZ,
        taps=NOISE_TAPS,
    )

    figure_data = {"recording_steady": rec_steady, "synth_steady": syn_steady}
    png = make_figure(
        {"recording": analysis["recording"], "synth": analysis["synth"],
         "candidates": analyses},
        figure_data, scene_results["single"]["generation"]["noise_filter"],
        scene_results["single"]["generation"]["shelf"],
    )

    # Baseline consistency with the earlier body experiment: the single target
    # happened to coincide, while the phrase target is the common one for this
    # candidate set.  The raw npy is never modified.
    prior_single_path = BODY / "baseline_single.wav"
    prior_phrase_path = BODY / "baseline_phrase.wav"
    new_single_path = OUT / "baseline_single.wav"
    new_phrase_path = OUT / "baseline_phrase.wav"
    prior_single, _ = sf.read(prior_single_path, always_2d=True)
    new_single_arr, _ = sf.read(new_single_path, always_2d=True)
    prior_phrase, _ = sf.read(prior_phrase_path, always_2d=True)
    new_phrase_arr, _ = sf.read(new_phrase_path, always_2d=True)
    phrase_win = slice(5760, 466560)
    single_win = slice(5760, 77760)
    phrase_delta_db = float(db20(
        rms(new_phrase_arr[phrase_win, 0]) / max(rms(prior_phrase[phrase_win, 0]), 1e-30)))
    baseline_consistency = {
        "prior_experiment_dir": str(BODY.relative_to(ROOT)),
        "single_wav_bit_identical_to_prior_body_experiment": bool(
            sha256_file(prior_single_path) == sha256_file(new_single_path)),
        "single_wav_max_abs_diff": float(np.max(np.abs(prior_single - new_single_arr))),
        "phrase_wav_bit_identical_to_prior_body_experiment": bool(
            sha256_file(prior_phrase_path) == sha256_file(new_phrase_path)),
        "phrase_active_rms_delta_vs_prior_db": phrase_delta_db,
        "explanation": (
            "Raw baseline npy is unchanged. The single target happened to coincide with "
            "the earlier body experiment; the phrase baseline is re-normalised to this "
            "candidate set's common scene target, so it differs by the reported constant dB."
        ),
    }

    summary = {
        "experiment": "trumpet_texture_experiment",
        "purpose": (
            "Bounded offline sensitivity test around the production ENG1 E4 baseline: "
            "colored aperiodic airflow vs harmonic buzz vs high-harmonic time variation. "
            "Candidates are audition-only, not RTL bit-exact renders and not a claim that "
            "the production model has a noise branch."
        ),
        "sample_rate": FS,
        "master_seed": MASTER_SEED,
        "air_levels_db_rel_baseline_active_rms": [AIR_LO_DB, AIR_HI_DB],
        "am_depth_std": AM_DEPTH,
        "production_rtl_modified": False,
        "old_experiment_scripts_modified": False,
        "git_index_touched": False,
        "analysis": analysis,
        "candidates": analyses,
        "scenes": scene_results,
        "recording_reference": {
            "file": ref_path.name,
            "sample_count": int(len(ref)),
            "seconds": len(ref) / FS,
            "start_sample_in_loaded_recording": int(ref_start),
            "zero_padded_tail_samples": int(max(0, len(ref) - len(part))),
            "zero_padded_tail_s": float(max(0, len(ref) - len(part)) / FS),
            "gain_linear": float(ref_gain),
            "gain_db": float(20.0 * math.log10(ref_gain)),
            "active_window_rms_dbfs": float(db20(rms(ref_check[5760:77760, 0]))),
            "peak_dbfs": float(db20(np.max(np.abs(ref_check)))),
            "sha256": sha256_file(ref_path),
            "note": "real local recording excerpt; separate gain, not one of the RMS-matched candidates",
        },
        "figure": {"file": png.name, "sha256": sha256_file(png)},
        "baseline_consistency": baseline_consistency,
        "limitations": [
            "Residual inter-harmonic level is not true broadband noise: Hann leakage, vibrato, frequency drift and MP3 band-limiting contribute; the report shows a 10-140 Hz fixed exclusion sweep plus a sustain.py-style max(10, 0.02*k*f0) variable-width check. The recording's overall span is about 24 dB, so no unique noise level is identifiable.",
            "The -36/-30 dB RMS air levels are manual sensitivity trials, not a fit to the recording. They bracket the recording's fixed/variable-width residual depending on exclusion; no unique level is identifiable from this data.",
            "The colored-noise filter follows the local mean inter-harmonic shape but is high-passed at 500 Hz and low-passed at 14 kHz; it is an artificial excitation, not a measured airflow signal.",
            "The harmonic AM is an artificial 4 % std, 2.5-12 Hz amplitude modulation of the >3.5*f0 band; it does not change pitch and is not vibrato. Its resulting high/low fluctuation is intentionally of the same order as the recording.",
            "The static high shelf (+6 dB asymptotic high-frequency boost, corner 2 kHz; +3.0 dB at 2 kHz) is a brightness control, not a texture/friction candidate.",
            "The E4 recording is a 44.1 kHz MP3 resampled once to 48 kHz; high-frequency content above the MP3 band limit is not recoverable.",
            f"The synthetic E4 period is 146 samples ({analysis['synth']['f0_hz']:.3f} Hz), about {analysis['comparison']['f0_difference_cents']:.1f} cents below the measured recording f0 ({analysis['recording']['f0_hz']:.3f} Hz). Each spectrum is measured at its own f0, so this does not bias the normalized harmonic comparison, but the candidates inherit the synth pitch.",
            "All candidates are offline additions to the existing baseline; they must not be described as production RTL output or as a validated friction model.",
        ],
        "verification": {
            "baseline_raw_loaded_and_unchanged": True,
            "baseline_wav_matches_raw_scaled_gain_and_fade_within_pcm24_quantisation": True,
            "all_wavs_finite": True,
            "all_wavs_peak_below_common_limit": True,
            "all_scene_active_rms_match_target_within_2e-6_relative": True,
            "pre_roll_digital_silence": True,
            "tail_below_-80_dbfs": True,
            "no_pcm24_rail_samples": True,
            "air_hi_minus_air_lo_equals_6_db_before_common_gain": True,
            "single_baseline_wav_bit_identical_to_prior_body_experiment": baseline_consistency[
                "single_wav_bit_identical_to_prior_body_experiment"],
            "phrase_baseline_uses_this_run_common_scene_target": True,
            "no_compression_or_time_varying_gain_except_20ms_end_fade": True,
        },
        "source_hashes": {
            str(p.relative_to(ROOT)): sha256_file(p) for p in [
                Path(__file__),
                ROOT / "python/modal_sim/eng1_rtl.py",
                ROOT / "python/modal_sim/sustain_engine.py",
                ROOT / "python/fft_analysis/sustain.py",
                ROOT / "python/fft_analysis/core.py",
                BODY / "baseline_phrase.npy",
                BODY / "baseline_single.npy",
                src_path,
            ]
        },
    }
    (OUT / "results.json").write_text(
        json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    # Short README with method limits and relative audio paths.
    c = {a["name"]: a for a in analyses}
    sc = scene_results["single"]["candidates"]
    lines = []
    lines.append("# 小号摩擦/颗粒/气流感对照实验（离线听感）\n")
    lines.append(
        "对象是现有生产 ENG1 E4 基线。没有重跑或修改 RTL、部署系数、旧实验脚本或 git 索引。"
        "所有候选只是在 `baseline_*.npy` 上做离线叠加，不能称为 RTL 逐位仿真结果。\n")
    lines.append("## 关键测量\n")
    lines.append(
        f"- 真实录音 `{analysis['recording']['source_file']}`：f0 = "
        f"{analysis['recording']['f0_hz']:.3f} Hz（相对 12-TET E4 "
        f"{analysis['recording']['f0_cents_vs_12tet_E4']:+.2f} cents），"
        f"起音 10–90% = {analysis['recording']['onset']['attack_10_90_ms']:.1f} ms。\n")
    lines.append(
        f"- 合成基线：f0 = {analysis['synth']['f0_hz']:.3f} Hz（"
        f"{analysis['synth']['f0_cents_vs_12tet_E4']:+.2f} cents），周期 "
        f"{analysis['synth']['period_samples']} samples；与录音相差 "
        f"{analysis['comparison']['f0_difference_cents']:+.2f} cents。\n")
    lines.append(
        f"- 归一化谐波分布（24次，录音相对合成）：RMS 误差 "
        f"{analysis['comparison']['harmonic_rms_error_db']:.3f} dB，"
        f"最大绝对误差 {analysis['comparison']['harmonic_max_abs_error_db']:.2f} dB。\n")
    lines.append(
        f"- 谐波间残差（1–12 kHz，相对峰值）：录音在 10/20/40/60/100/140 Hz 排除带宽下为 "
        f"{', '.join(f'{v:+.1f}' for v in [analysis['recording']['interharmonic_residual']['fixed'][f'{bw:g}']['median_rel_peak_db'] for bw in EXCLUSION_HZ])} dB；"
        f"合成基线为 "
        f"{', '.join(f'{v:+.1f}' for v in [analysis['synth']['interharmonic_residual']['fixed'][f'{bw:g}']['median_rel_peak_db'] for bw in EXCLUSION_HZ])} dB。"
        f"录音固定带宽跨度 {analysis['recording']['interharmonic_residual']['fixed_range_db']:.1f} dB；"
        f"把 sustain.py 式 max(10, 0.02·k·f0) 方案也算入，录音总跨度 "
        f"{analysis['recording']['interharmonic_residual']['overall_range_db']:.1f} dB"
        f"（{analysis['recording']['interharmonic_residual']['variable_2pct_k']['median_rel_peak_db']:+.1f} … "
        f"{analysis['recording']['interharmonic_residual']['fixed']['140']['median_rel_peak_db']:+.1f} dB），"
        f"合成基线总跨度 {analysis['synth']['interharmonic_residual']['overall_range_db']:.1f} dB"
        f"（{analysis['synth']['interharmonic_residual']['variable_2pct_k']['median_rel_peak_db']:+.1f} … "
        f"{analysis['synth']['interharmonic_residual']['fixed']['140']['median_rel_peak_db']:+.1f} dB）。"
        f"说明该指标对泄漏/颤音极敏感，不能当作真实噪声级。\n")
    lines.append(
        f"- 短时高/低次谐波比波动（0.8 s，4096/512 STFT）：录音 std = "
        f"{analysis['recording']['short_time_high_low']['std_db']:.2f} dB；合成基线 std = "
        f"{analysis['synth']['short_time_high_low']['std_db']:.2f} dB；"
        f"`harm_am` std = {c['harm_am']['short_time_high_low']['std_db']:.2f} dB。\n")
    lines.append("\n## 候选（同一 scene 内 active RMS 一致）\n")
    lines.append("| 候选 | 改动 | phrase | E4 single | 单音加入成分 RMS 相对基线 | 单音 peak |\n")
    lines.append("|---|---|---|---|---:|---:|\n")
    desc = {
        "baseline": "生产基线，无添加",
        "air_lo": "带色非周期 -36 dB RMS（跟随包络，500 Hz–14 kHz）",
        "air_hi": "同一噪声 +6 dB（-30 dB RMS）",
        "harm_am": "仅高次谐波 4% std、2.5–12 Hz 连续 AM",
        "air_harm": "air_lo + harm_am 组合",
        "hf_static": "静态高频 +6 dB 高架（转折 2 kHz；亮度对照）",
    }
    for name in ("baseline", "air_lo", "air_hi", "harm_am", "air_harm", "hf_static"):
        s = sc[name]["written"]
        add = s["added_component_rms_db_rel_base_pre"]
        add_s = "—" if add is None else f"{add:+.2f} dB"
        lines.append(
            f"| `{name}` | {desc[name]} | "
            f"[{name}_phrase.wav]({name}_phrase.wav) | "
            f"[{name}_single.wav]({name}_single.wav) | {add_s} | "
            f"{s['peak_dbfs']:+.2f} dBFS |\n")
    lines.append(
        "\n所有 WAV 为 PCM24、48 kHz、双声道；phrase 与 single 分开做 scene 内 active RMS 匹配。"
        f"共同峰值安全目标 {db20(PEAK_LIMIT):+.2f} dBFS（linear {PEAK_LIMIT}），"
        "恒定增益、无压缩，末端 20 ms 线性淡出。\n")
    lines.append("\n## 候选单音测量（0.8–1.4 s 稳态）\n")
    lines.append("| 候选 | 谐波形状误差 vs 基线 (dB RMS) | 残差 40 Hz 排除 (dB rel peak) | 残差 140 Hz 排除 (dB rel peak) | 2 kHz+ 功率占比 | 高/低谐波比 std (dB) |\n")
    lines.append("|---|---:|---:|---:|---:|---:|\n")
    for name in ("baseline", "air_lo", "air_hi", "harm_am", "air_harm", "hf_static"):
        a = c[name]
        r40 = a["interharmonic_residual"]["fixed"]["40"]["median_rel_peak_db"]
        r140 = a["interharmonic_residual"]["fixed"]["140"]["median_rel_peak_db"]
        lines.append(
            f"| `{name}` | {a['harmonic_rms_error_vs_baseline_db']:.3f} | "
            f"{r40:+.1f} | {r140:+.1f} | "
            f"{a['spectral']['above_2khz_power_fraction']*100:.1f}% | "
            f"{a['short_time_high_low']['std_db']:.2f} |\n")
    lines.append(
        "\n`air_lo/air_hi` 主要抬高宽带谐波间底噪，基本不改变高/低谐波比的波动；"
        "`harm_am` 主要增加高/低谐波比的短时波动（并产生近谐波边带），对 40/140 Hz 排除的宽带残差影响很小；"
        "`hf_static` 主要抬高平均亮度（2 kHz+ 占比和高/低比均值），不增加纹理波动。\n")
    lines.append("\n## 方法限制\n")
    for item in summary["limitations"]:
        lines.append(f"- {item}\n")
    lines.append("\n## 验证\n")
    lines.append(
        "- 基线 raw 重新载入并逐采样核对；baseline WAV 与 `raw/2**24/8 × 常数增益 × 末端淡出` 的差在 PCM24 量化内。\n"
        "- 所有 WAV 有限、无 PCM24 触轨、峰值 ≤ 共同安全目标；scene 内 active RMS 在 2e-6 相对误差内一致。\n"
        "- 端前静音为数字零；single 尾部（2.05 s 后）低于 -80 dBFS，phrase 尾部（10 s 后）同样低于 -80 dBFS。\n"
        "- `air_hi` 与 `air_lo` 使用同一噪声波形，共同增益前实测差 6.00 dB。\n"
        "- `baseline_single.wav` 与上一轮 body 实验逐字节一致；`baseline_phrase.wav` 因本轮候选组的共同 scene 目标，比上一轮高 "
        f"{baseline_consistency['phrase_active_rms_delta_vs_prior_db']:+.2f} dB；原始 npy 未变。\n"
        "- 没有压缩、没有时变增益（末端 20 ms 淡出除外），没有把真实录音剪进乐句。\n")
    lines.append("\n## 音频与文件（相对本目录）\n")
    lines.append("- 6 组 × 2 scene：`baseline_*.wav`, `air_lo_*.wav`, `air_hi_*.wav`, `harm_am_*.wav`, `air_harm_*.wav`, `hf_static_*.wav`\n")
    lines.append(f"- 2.4 s 真实 E4 参考：[recording_reference_E4.wav](recording_reference_E4.wav)（源 `{analysis['recording']['source_file']}`，2.4 s 窗口，源文件末端不足部分补零；单独增益，不属于 RMS 匹配候选组）\n")
    lines.append("- 图：[texture_analysis.png](texture_analysis.png)\n")
    lines.append("- 数值：[results.json](results.json)\n")
    lines.append("- 数组：[analysis_arrays.npz](analysis_arrays.npz), [noise_filter.npz](noise_filter.npz)\n")
    (OUT / "README.md").write_text("".join(lines), encoding="utf-8")

    # Final sanity: every declared file exists and is non-empty.
    expected = [OUT / f"{n}_{s}.wav" for n in
                ("baseline", "air_lo", "air_hi", "harm_am", "air_harm", "hf_static")
                for s in ("phrase", "single")]
    expected += [OUT / "recording_reference_E4.wav", OUT / "results.json",
                 OUT / "README.md", OUT / "texture_analysis.png",
                 OUT / "analysis_arrays.npz", OUT / "noise_filter.npz"]
    missing = [str(p) for p in expected if not p.exists() or p.stat().st_size == 0]
    assert not missing, missing

    print("PASS", flush=True)
    print(f"recording f0 {f0_rec:.3f} Hz ({analysis['recording']['f0_cents_vs_12tet_E4']:+.2f} cents); "
          f"synth f0 {f0_syn:.3f} Hz ({analysis['synth']['f0_cents_vs_12tet_E4']:+.2f} cents)", flush=True)
    print("residual overall ranges: rec "
          f"{analysis['recording']['interharmonic_residual']['overall_range_db']:.1f} dB, synth "
          f"{analysis['synth']['interharmonic_residual']['overall_range_db']:.1f} dB", flush=True)
    for a in analyses:
        r = a["interharmonic_residual"]
        print(f"{a['name']:9s} harm_err {a['harmonic_rms_error_vs_baseline_db']:6.3f} dB  "
              f"resid40 {r['fixed']['40']['median_rel_peak_db']:7.1f} dB  "
              f"resid140 {r['fixed']['140']['median_rel_peak_db']:7.1f} dB  "
              f"hl_std {a['short_time_high_low']['std_db']:5.2f} dB  "
              f"2k+ {a['spectral']['above_2khz_power_fraction']*100:5.1f}%", flush=True)


if __name__ == "__main__":
    main()
