"""Sustained-tone engine (Class B): a periodic drive into the same modal bank.

The pitched engine fires *one* pulse and lets the modes decay. A wind, brass or bowed
note instead keeps pumping energy in, so its modes reach a **steady state**. The same
resonators are used; only the excitation changes:

    drive = one unit impulse every T = sr/f0 samples, amplitude-shaped by the
            player's envelope (attack / release from the extraction)
    mode  : y[n] = gain_k * drive[n] - a1*y1 - a2*y2   (a1, a2 as in engine.py)

Steady-state calibration
------------------------
Drive one impulse every ``T = sr/f0`` samples. Mode ``k`` sits at ``k*f0``, so the
impulse response sampled at the stroke instants is ``gain_k * r_k^(m*T)`` -- every
stroke arrives in phase and they add: the steady amplitude is
``gain_k / (1 - r_k^T)``. Requiring that to equal ``w_k`` gives::

    gain_k = w_k * (1 - exp(-gamma_k / f0))

``DRIVE_K`` is a single calibration constant (1.0 if the derivation is exact), checked
by measurement rather than assumed -- see ``verify()``.

    python python/modal_sim/sustain_engine.py verify flute
"""

from __future__ import annotations

import json
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "fft_analysis"))

import core as CORE                                  # noqa: E402
import paths                                         # noqa: E402

SR = CORE.SR

#: calibration for the drive gain (unity when the analytic steady-state is right)
DRIVE_K = 1.0
#: calibration for the breath/bow noise level (see note_on)
NOISE_CAL = 1.0


def steady_amp_unit(gamma: float, f_mode: float, f_drive: float, sr: int = SR) -> float:
    """Peak steady amplitude of one resonator at unit drive gain.

    The resonator's impulse response is ``h[n] = r^n sin(theta(n+1)) / sin(theta)``. With
    a unit impulse every ``T = sr/f_drive`` samples the steady response is a geometric
    sum over past strokes::

        A(j) = r^j * Im[ e^{i alpha} / (1 - R e^{i phi}) ],  alpha = theta j + theta,
        R = r^T, phi = theta T

    evaluated over one period ``j = 0..T-1``. This is exact for the linear recursion
    (no small-angle or integer-ratio assumption), so ``gain = w / A_peak``.
    """
    theta = 2.0 * np.pi * f_mode / sr
    r = np.exp(-gamma / sr)
    T = sr / f_drive
    R = np.exp(-gamma * T / sr)
    phi = theta * T
    j = np.arange(max(2, int(np.floor(T))))
    alpha = theta * (j + 1.0)
    denom = 1.0 - R * np.exp(1j * phi)
    amp = (r ** j) * np.abs(np.imag(np.exp(1j * alpha) / denom))
    return float(amp.max() / max(abs(np.sin(theta)), 1e-9))


class SustainPatch:
    """Per-note mode tables (f_k, gamma_k, w_k) + attack/release/noise descriptors."""

    def __init__(self, name: str, max_modes: int = 48, band_hz: float = 16_000.0,
                 gamma_scale: float = 1.0):
        self.name = name
        self.max_modes = max_modes
        self.band_hz = band_hz
        self.gamma_scale = gamma_scale
        d = np.load(paths.param(name, "sustain"), allow_pickle=True)
        self.by_key = {}
        for i in range(d["f0"].size):
            m = d["note_id"] == i
            note = str(d["notes"][i])
            key = (self._midi(note), self._dyn(note))
            self.by_key.setdefault(key, []).append(dict(
                k=d["k"][m].astype(float), f=d["f_k"][m].astype(float),
                g=d["gamma"][m].astype(float), a=d["a"][m].astype(float),
                f0=float(d["f0"][i]),
                attack=float(d["attack_s"][i]), release=float(d["release_s"][i]),
                noise_db=float(d["noise_db"][i]),
                noise_win=float(d["noise_win"][i]), note=note))
        self.keys = sorted(self.by_key)
        # one noise shape per instrument (the per-note curves are nearly identical)
        self.noise_shape_db = (d["noise_shape_db"].mean(axis=0)
                               if "noise_shape_db" in d.files else None)
        self.noise_edges = d["noise_edges"] if "noise_edges" in d.files else None

    def noise_fir(self, sr: int = SR, n: int = 257):
        """FIR whose magnitude follows the measured noise shape (0 dB in the reference
        band, so it multiplies the calibrated scalar level without changing it)."""
        if self.noise_shape_db is None:
            return None
        from scipy.signal import firwin2
        edges = self.noise_edges
        centers = np.sqrt(edges[:-1] * edges[1:])
        f = np.concatenate([[0.0], np.clip(centers / (sr / 2.0), 0.0, 1.0), [1.0]])
        g = 10.0 ** (self.noise_shape_db / 20.0)
        g = np.concatenate([[g[0]], g, [g[-1]]])
        return firwin2(n, f, g)

    @staticmethod
    def _midi(note: str) -> int:
        import re
        mm = re.search(r"_([A-G]s?\d)_", note)
        return CORE.note_to_midi(mm.group(1).replace("s", "#")) if mm else 60

    @staticmethod
    def _dyn(note: str) -> str:
        return "piano" if "piano" in note and "mezzo" not in note[:60].split("_")[-2:] else "forte"

    def _pick(self, midi):
        near = min(self.keys, key=lambda k: abs(k[0] - midi))
        return self.by_key[near][0]

    def modes(self, midi: int):
        src = self._pick(midi)
        # Harmonic partials on purpose: the drive is one impulse train at f0, so a mode
        # only sits exactly at resonance if it is an integer multiple of f0. With the
        # measured (slightly detuned) frequencies the steady response lands on the drive
        # harmonics anyway, and the detuned modes lost 7-8 dB. Winds/brass/bowed partials
        # are harmonic to within a few cents, so this is the faithful choice here.
        # Harmonic numbers only; the engine turns them into frequencies from the *actual*
        # drive rate. The drive period is an integer number of samples, so the drive is
        # sr/round(sr/f0), not f0 -- building the modes from f0 would detune every mode
        # and cost several dB on the upper harmonics.
        f0 = CORE.midi_to_hz(midi)
        kk = src["k"]
        f = kk * f0
        g = np.clip(src["g"] * self.gamma_scale, 0.3, 400.0)
        w = src["a"].copy()
        good = (np.isfinite(g) & (f > 20.0) & (f < self.band_hz) & (w > 0))
        kk, g, w = kk[good], g[good], w[good]
        if kk.size > self.max_modes:
            kk, g, w = kk[:self.max_modes], g[:self.max_modes], w[:self.max_modes]
        return (kk, g, w, src["attack"], src["release"], src["noise_db"],
                src["noise_win"])


class SustainSynth:
    def __init__(self, patch: SustainPatch, sr: int = SR, max_poly: int = 16,
                 high_water: int | None = None, noise_gain: float = 1.0,
                 noise_hp_hz: float = 400.0, noise_lp_hz: float = 9000.0,
                 vibrato_hz: float = 5.2, vibrato_cents: float = 22.0,
                 vibrato_am: float = 0.14, drift_cents: float = 0.0,
                 coef_interval: int = 96, seed: int = 0):
        self.patch = patch
        self.sr = sr
        self.dt = 1.0 / sr
        self.max_poly = max_poly
        self.high_water = high_water if high_water is not None else max(1, max_poly - 2)
        self.noise_gain = noise_gain
        self.noise_hp_hz = noise_hp_hz
        self.noise_lp_hz = noise_lp_hz
        self.vibrato_hz = vibrato_hz
        self.vibrato_cents = vibrato_cents
        self.vibrato_am = vibrato_am
        self.drift_cents = drift_cents
        self.coef_interval = max(1, int(coef_interval))
        self.rng = np.random.default_rng(seed)
        from scipy.signal import butter
        ny = sr / 2.0
        self.noise_sos = butter(2, [max(noise_hp_hz / ny, 1e-3),
                                    min(noise_lp_hz / ny, 0.95)], btype="band",
                                output="sos")
        self.noise_fir = patch.noise_fir(sr)
        self.Nmax = patch.max_modes
        self.reset()

    def reset(self):
        V, N = self.max_poly, self.Nmax
        self.f = np.zeros((V, N)); self.g = np.zeros((V, N))
        self.base_f = np.zeros((V, N))                 # nominal (un-modulated) partials
        self.gain = np.zeros((V, N)); self.a1 = np.zeros((V, N)); self.a2 = np.zeros((V, N))
        self.y1 = np.zeros((V, N)); self.y2 = np.zeros((V, N))
        self.base_fdrive = np.zeros(V); self.fdrive_inst = np.zeros(V)
        self.phase = np.zeros(V)                       # fractional drive phase [0,1)
        self.lfo_phase = np.zeros(V); self.cents = np.zeros(V)
        self.env = np.zeros(V); self.attack = np.ones(V) * 0.05
        self.release = np.ones(V) * 0.05
        self.am = np.zeros(V)                          # per-note amplitude-vibrato depth
        self.gate = np.zeros(V, dtype=bool)
        self.vel = np.zeros(V); self.nz = np.zeros(V)
        self.active = np.zeros(V, dtype=bool); self.key = -np.ones(V, dtype=int)
        self.kill_count = 0; self.hard_count = 0
        self.active_hist = []
        self.last_env = 0.0
        self.last_nz = 0.0
        self.n = 0

    # ------------------------------------------------------------------
    def note_on(self, midi, vel=1.0):
        kk, g, w, atk, rel, noise_db, noise_win = self.patch.modes(midi)
        n = kk.size
        free = np.nonzero(~self.active)[0]
        if free.size == 0:
            v = int(np.argmin(self.env))
            self.active[v] = False; self.y1[v] = 0.0; self.y2[v] = 0.0
            self.hard_count += 1
            free = np.array([v])
        v = int(free[0])
        f0 = max(CORE.midi_to_hz(midi), 1e-6)
        period = max(2, int(round(self.sr / f0)))
        f_drive = self.sr / period
        f = kk * f_drive                      # modes exactly on the drive harmonics
        theta = 2.0 * np.pi * f * self.dt
        r = np.exp(-g * self.dt)
        self.f[v] = 0.0; self.g[v] = 0.0
        self.a1[v] = 0.0; self.a2[v] = 0.0; self.gain[v] = 0.0
        self.base_f[v] = 0.0
        self.f[v, :n] = f; self.g[v, :n] = g
        self.base_f[v, :n] = f
        self.a1[v, :n] = -2.0 * r * np.cos(theta)
        self.a2[v, :n] = r * r
        # gain_k = w_k / (steady amplitude of that mode at unit drive). The vibrato
        # scales drive and partials by the same ratio, so the calibration (which depends
        # on gamma and k) holds; it is computed once at the nominal pitch.
        a_unit = np.array([steady_amp_unit(gi, fi, f_drive, self.sr)
                           for gi, fi in zip(g, f)])
        self.gain[v, :n] = w / np.maximum(a_unit, 1e-12) * DRIVE_K
        self.base_fdrive[v] = f_drive
        self.fdrive_inst[v] = f_drive
        self.phase[v] = 0.0
        self.lfo_phase[v] = float(self.rng.random())
        self.cents[v] = 0.0
        self.am[v] = self.vibrato_am
        self.env[v] = 0.0
        self.attack[v] = max(float(atk) if np.isfinite(atk) else 0.05, 0.005)
        self.release[v] = max(float(rel), 0.02)
        self.vel[v] = float(vel)
        # breath / bow noise. The stored number is a *spectral* level between partials
        # relative to the peak; for a Hann window of N samples,
        #   |X_noise| / |X_peak| = (2 sigma / A) * sqrt(sum w^2) / sum w
        #                        = (2 sigma / A) * sqrt(3 / (2 N))
        # so the time-domain amplitude ratio is what follows. One global NOISE_CAL
        # covers the residual (filter gain, window details), not a per-instrument fudge.
        sigma = (10.0 ** (noise_db / 20.0)
                 / max(2.0 * np.sqrt(3.0 / (2.0 * max(noise_win, 1.0))), 1e-12))
        self.nz[v] = sigma * NOISE_CAL
        self.gate[v] = True
        self.active[v] = True
        self.key[v] = int(midi)
        self.y1[v] = 0.0; self.y2[v] = 0.0
        return v

    def note_off(self, midi):
        self.gate[self.active & (self.key == midi)] = False

    def _update_coeffs(self):
        """Control-rate pitch update (vibrato).

        Vibrato must move the drive and every partial by the *same* ratio so the modes
        stay on the drive harmonics; that also keeps the drive calibration valid.
        Recomputed at control rate (vibrato is ~5 Hz), not per sample.
        """
        self.lfo_phase = (self.lfo_phase + self.vibrato_hz * self.dt) % 1.0
        self.cents = self.drift_cents + self.vibrato_cents * np.sin(2.0 * np.pi * self.lfo_phase)
        ratio = 2.0 ** (self.cents / 1200.0)
        f = self.base_f * ratio[:, None]
        theta = 2.0 * np.pi * f * self.dt
        r = np.exp(-self.g * self.dt)
        self.a1 = -2.0 * r * np.cos(theta)
        self.a2 = r * r
        self.fdrive_inst = self.base_fdrive * ratio

    def step(self):
        V = self.max_poly
        if (self.vibrato_cents or self.drift_cents) and self.n % self.coef_interval == 0:
            self._update_coeffs()
        # player envelope: exp approach to 1 while gated, to 0 when released
        rise = np.exp(-self.dt / np.maximum(self.attack, 1e-3))
        fall = np.exp(-self.dt / np.maximum(self.release, 1e-3))
        target = np.where(self.gate, 1.0, 0.0)
        self.env = target + (self.env - target) * np.where(self.gate, rise, fall)
        # NOTE: no floor-to-zero here. Clamping a slow attack (cello 0.31 s) back to 0
        # while its per-sample increment is below the clamp locks the envelope at 0
        # forever. Voices are freed by the quiet test below, not by this.
        amp = 1.0 + self.am * np.sin(2.0 * np.pi * self.lfo_phase)
        # fractional impulse train (rate follows the vibrato)
        imp = np.zeros(V)
        at = self.active & self.gate
        self.phase[at] = (self.phase[at] + self.fdrive_inst[at] * self.dt)
        wrap = at & (self.phase >= 1.0)
        imp[wrap] = 1.0
        self.phase[wrap] -= 1.0
        drive = imp * self.env * self.vel * amp
        y = self.gain * drive[:, None] - self.a1 * self.y1 - self.a2 * self.y2
        self.y2[:] = self.y1; self.y1[:] = y
        out = float(y[self.active].sum())
        if self.active.any():
            self.last_env = float(self.env[self.active].max())
            self.last_nz = float((self.nz * self.env)[self.active].max())
        # free a voice once it is silent *and released*: during the attack env starts at
        # 0, so testing the level alone recycled the voice on its first sample.
        quiet = (self.active & ~self.gate & (self.env < 1e-3)
                 & (np.abs(y).sum(axis=1) < 2e-4))
        if quiet.any():
            self.active[quiet] = False
            self.y1[quiet] = 0.0; self.y2[quiet] = 0.0
            self.key[quiet] = -1
        self.n += 1
        self.active_hist.append(int(self.active.sum()))
        return out

    def render(self, events, seconds: float):
        n = int(seconds * self.sr)
        onsets, offs = {}, {}
        for t, midi, dur, vel in events:
            onsets.setdefault(int(round(t * self.sr)), []).append((int(midi), float(vel)))
            offs.setdefault(int(round((t + dur) * self.sr)), []).append(int(midi))
        buf = np.zeros(n)
        envt = np.zeros(n)
        nzt = np.zeros(n)
        for i in range(n):
            for midi, vel in onsets.get(i, ()):
                self.note_on(midi, vel)
            for midi in offs.get(i, ()):
                self.note_off(midi)
            buf[i] = self.step()
            envt[i] = self.last_env
            nzt[i] = self.last_nz
        if self.noise_gain > 0:
            w = self.rng.standard_normal(n + 256)
            if self.noise_fir is not None:
                h = self.noise_fir
                full = np.convolve(w, h, mode="full")
                nz = full[len(h) // 2:len(h) // 2 + n]
            else:
                from scipy.signal import sosfilt
                nz = sosfilt(self.noise_sos, w[:n])
            buf = buf + self.noise_gain * nz * envt * nzt
        return buf


# ---------------------------------------------------------------------------
# verification
# ---------------------------------------------------------------------------

def verify(inst: str, midi: int = 69, seconds: float = 3.0):
    """Measure the synthesised steady-state partials against the extracted a_k."""
    p = SustainPatch(inst)
    s = SustainSynth(p, max_poly=2)
    kk, g, w, atk, rel, ndb = p.modes(midi)
    sr = s.sr
    period = max(2, int(round(sr / CORE.midi_to_hz(midi))))
    f = kk * (sr / period)                    # same rule the engine uses
    y = s.render([(0.2, midi, seconds - 0.4, 1.0)], seconds)
    t0, t1 = 1.5, 2.8
    seg = y[int(t0 * sr):int(t1 * sr)]
    n = np.arange(seg.size)
    wnd = np.hanning(seg.size)
    meas = np.array([abs(np.sum(seg * wnd * np.exp(-2j * np.pi * fk * n / sr)))
                     for fk in f])
    meas = meas / (meas.max() + 1e-30)
    target = w / w.max()
    err = 20 * np.log10((meas + 1e-12) / (target + 1e-12))
    print(f"{inst} midi {midi}: modes {f.size}  attack {atk * 1e3:.0f} ms  "
          f"release {rel * 1e3:.0f} ms")
    print(f"  steady partial dB error: median {np.median(np.abs(err)):.2f}  "
          f"p90 {np.percentile(np.abs(err), 90):.2f}  max {np.abs(err).max():.2f}")


def main(argv=None):
    a = list(argv or [])
    if a and a[0] == "verify":
        verify(a[1] if len(a) > 1 else "flute",
               int(a[2]) if len(a) > 2 else 69)
        return 0
    for inst in ("flute", "trumpet", "cello"):
        verify(inst)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
