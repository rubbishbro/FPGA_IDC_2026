"""Load the extracted modal parameters and fit the fixed body filter.

Reads `music_resources/FFT_results/<inst>_partials.npz` and `<inst>_body.npz` and turns
them into per-note mode tables (frequencies, damping, weights) plus a small body IIR.

Body filter
-----------
The extracted `a_k` are recorded partial amplitudes, i.e. they already contain the
instrument's source x string x body colouration. The engine therefore drives the modes
with *pre-body* weights `a_k / |Body(f_k)|` and applies the shared body IIR at the
output, so the net resynthesis reproduces `a_k` while the body stays fixed in absolute
frequency (correct when a note is transposed). The body is a 4-biquad (8th-order) fit
obtained by Levy's method on a minimum-phase reconstruction of the measured curve.
"""

from __future__ import annotations

import os

import numpy as np
from scipy.signal import sosfilt, sosfreqz, tf2sos
from scipy.ndimage import uniform_filter1d

SR = 48_000

import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(_HERE, "..", ".."))
sys.path.insert(0, os.path.dirname(_HERE))         # python/ -> paths.py
import paths                                        # noqa: E402

FFT_DIR = paths.PARAMS      # extracted tables (was FFT_results/ flat)


def midi_to_hz(midi: float) -> float:
    return 440.0 * 2.0 ** ((midi - 69.0) / 12.0)


# ---------------------------------------------------------------------------
# body: Levy / minimum-phase rational fit -> 4 biquads
# ---------------------------------------------------------------------------

def _min_phase(mag: np.ndarray, n: int = 4096) -> np.ndarray:
    logmag = np.log(np.maximum(mag, 1e-8))
    full = np.concatenate([logmag, logmag[-2:0:-1]])
    ceps = np.fft.ifft(full).real
    w = np.zeros(n)
    w[0] = 1.0
    w[1:n // 2] = 2.0
    w[n // 2] = 1.0
    return np.exp(np.fft.fft(ceps * w))[:n // 2 + 1]


def _levy(Hd, omega, p, q, iters=8):
    z = np.exp(-1j * omega)
    Zk = np.exp(-1j * np.outer(omega, np.arange(0, max(p, q) + 1)))
    a = np.concatenate([[1.0], np.zeros(p)])
    b = np.zeros(q + 1)
    for it in range(iters + 1):
        wt = (1.0 / np.maximum(np.abs(Zk[:, :p + 1] @ a), 1e-6)
              if it > 0 else np.ones_like(omega))
        cols = [Hd * Zk[:, k] for k in range(1, p + 1)]
        cols += [(-Zk[:, k]) for k in range(0, q + 1)]
        M = np.column_stack(cols) * wt[:, None]
        rhs = (-Hd) * wt
        Mr = np.vstack([M.real, M.imag])
        rr = np.concatenate([rhs.real, rhs.imag])
        x, *_ = np.linalg.lstsq(Mr, rr, rcond=None)
        a = np.concatenate([[1.0], x[:p]])
        b = x[p:]
    return b, a


def fit_body(mean_db, grid, n_fft: int = 4096, fs: int = SR, order: int = 8,
             smooth: int = 15, body_scale: float = 0.3):
    """Return (sos, freqs, fit_db, rmse_db) for the body coloration curve.

    The extracted `a_k` already contain the source x string x body colouration, so the
    runtime body filter must not re-apply the overall tilt (double-colouring) and must not
    impose the pitch-to-pitch variance of the averaged curve (that distorts the
    harmonics). It is therefore a *mild, detrended* residual coloration.
    """
    mdb = np.asarray(mean_db, dtype=float)
    if smooth and smooth > 1:
        mdb = uniform_filter1d(mdb, size=int(smooth), mode="nearest")
    trend = uniform_filter1d(mdb, size=max(3, len(mdb) // 3), mode="nearest")
    resid = mdb - trend
    resid = uniform_filter1d(resid, size=max(1, int(smooth) // 2), mode="nearest")
    mdb = resid * float(body_scale)
    fgrid = np.linspace(0.0, fs / 2.0, n_fft // 2 + 1)
    mag = np.interp(fgrid, grid, 10.0 ** (mdb / 20.0),
                    left=10.0 ** (mdb[0] / 20.0),
                    right=10.0 ** (mdb[-1] / 20.0))
    mag = mag / mag[0]
    omega = 2.0 * np.pi * fgrid / fs
    good = fgrid > 30.0
    b, a = _levy(_min_phase(mag, n_fft)[good], omega[good], p=order, q=order)
    sos = tf2sos(b, a)
    _, h = sosfreqz(sos, worN=fgrid[good], fs=fs)
    fit_db = 20.0 * np.log10(np.abs(h) + 1e-12)
    fit_db -= fit_db[0]
    target = np.interp(fgrid[good], grid, mdb)
    target -= np.interp(30.0, grid, mdb)
    rmse = float(np.sqrt(np.mean((fit_db - target) ** 2)))
    return sos, fgrid[good], fit_db, rmse, target


class BodyFilter:
    """Shared fixed body IIR (SOS cascade). Applied to the mix, not per voice."""

    def __init__(self, sos):
        self.sos = np.asarray(sos)

    def process(self, buf):
        return sosfilt(self.sos, buf)

    def magnitude(self, f):
        f = np.atleast_1d(np.asarray(f, dtype=float))
        _, h = sosfreqz(self.sos, worN=np.clip(f, 1.0, SR / 2 - 1), fs=SR)
        return np.abs(h)


# ---------------------------------------------------------------------------
# patch: per-note mode tables
# ---------------------------------------------------------------------------

class Patch:
    def __init__(self, name: str, fft_dir: str = FFT_DIR, max_modes: int = 48,
                 band_hz: float = 16_000.0, min_r2: float = 0.30,
                 body_sections: int = 4):
        self.name = name
        self.max_modes = max_modes
        self.band_hz = band_hz
        self.min_r2 = min_r2
        d = np.load(os.path.join(fft_dir, f"{name}_partials.npz"), allow_pickle=True)
        has_trusted = "trusted" in d.files
        self.by_key = {}
        for nid in range(d["f0"].size):
            m = d["note_id"] == nid
            key = (int(d["midi"][nid]), str(d["dynamic"][nid]))
            self.by_key.setdefault(key, []).append(dict(
                k=d["k"][m].astype(float), f_k=d["f_k"][m].astype(float),
                a0=d["a0"][m].astype(float), gamma=d["gamma"][m].astype(float),
                r2=d["r2"][m].astype(float), B=float(d["B"][nid]),
                trusted=(d["trusted"][m].astype(bool) if has_trusted
                         else np.ones(int(m.sum()), bool)),
            ))
        self.midis = sorted({k[0] for k in self.by_key})

        body = np.load(os.path.join(fft_dir, f"{name}_body.npz"))
        self.grid = body["grid"]
        self.mean_db = body["mean_db"]
        self.fir = body["fir"]
        order = 2 * body_sections
        (self.sos, self._bf, self._bdb, self.body_rmse,
         self.body_target_db) = fit_body(self.mean_db, self.grid, order=order)
        self.body = BodyFilter(self.sos)

        # Optional closed-loop decay calibration (see modal_sim/calibrate_decay.py):
        # the synthesis decayed slower than the recording because a few low partials
        # came out with gamma below the fundamental's. Keyed by (midi, dynamic).
        self.gamma_scale = {}
        gs = os.path.join(fft_dir, f"{name}_gammascale.npz")
        if os.path.exists(gs):
            g = np.load(gs)
            for m, dy, s in zip(g["midi"], g["dynamic"], g["scale"]):
                self.gamma_scale[(int(m), str(dy))] = float(s)

    # ------------------------------------------------------------------
    def _pick_key(self, midi, dynamic):
        for dyn in (dynamic, "forte", "piano"):
            if (midi, dyn) in self.by_key:
                return (midi, dyn)
        near = min(self.midis, key=lambda m: abs(m - midi))
        for dyn in (dynamic, "forte", "piano"):
            if (near, dyn) in self.by_key:
                return (near, dyn)
        return next(iter(self.by_key))

    def _pick(self, midi, dynamic):
        return self.by_key[self._pick_key(midi, dynamic)][0]

    def _scale(self, key, midi, dynamic):
        if not self.gamma_scale:
            return 1.0
        for k in ((midi, dynamic), key, (midi, "forte"), (midi, "piano")):
            if k in self.gamma_scale:
                return self.gamma_scale[k]
        return 1.0

    def body_mag_at(self, f):
        return self.body.magnitude(f)

    def modes(self, midi, dynamic="forte"):
        """(f_k, gamma_k, weight_k) for a note at the played pitch, pre-body weights."""
        key = self._pick_key(midi, dynamic)
        src = self.by_key[key][0]
        f0 = midi_to_hz(midi)
        k = src["k"]
        f = k * f0 * np.sqrt(1.0 + src["B"] * k * k)
        g = src["gamma"].copy() * self._scale(key, midi, dynamic)
        w = src["a0"].copy()
        # `trusted` already encodes prominence / amplitude / extrapolation gates, and
        # gamma is clamped below; do NOT re-gate on r2 here -- that dropped beating and
        # long-string partials (the mandolin fundamental, piano 3rd/4th harmonics).
        good = (np.isfinite(g) & (w > 0) & (f < self.band_hz) & src["trusted"])
        f, g, w = f[good], g[good], w[good]
        if f.size > self.max_modes:
            f, g, w = f[:self.max_modes], g[:self.max_modes], w[:self.max_modes]
        g = np.clip(g, 0.02, 400.0)
        # a_k already contains the source x string x body colouration, so they are the
        # mode weights directly (shape-normalised per note). The shared body filter adds
        # only its detrended residual structure at the output.
        w = w / max(w.max(), 1e-12)
        return f, g, w
