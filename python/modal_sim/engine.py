"""Modal synthesis engine: pulse excitation -> N modal resonators -> shared body.

Per the agreed architecture:

    excitation = one finite raised-cosine force pulse (tau from velocity)
    modes      = N IIR resonators, f_k = k*f0*sqrt(1+B k^2), gamma_k from the table
    body       = one fixed biquad cascade shared by all voices
    polyphony  = voice pool + scheme-C "kill" (tails accelerate out, never hard-cut)
    output     = sum voices -> body -> VCA/soft-clip
"""

from __future__ import annotations

import numpy as np
from scipy.signal import butter, sosfilt

from params import Patch, SR


class ModalSynth:
    def __init__(self, patch: Patch, max_poly: int = 24, sr: int = SR,
                 high_water: int | None = None,
                 tau_forte: float = 1.5e-4, tau_piano: float = 2.5e-4,
                 kill_factor: float = 150.0, release_factor: float = 1.0,
                 free_thr: float = 2e-4, level_tau: float = 0.01,
                 noise_amp: float = 0.12, noise_ms: float = 14.0,
                 noise_lp_hz: float = 5000.0, seed: int = 0):
        self.patch = patch
        self.sr = sr
        self.dt = 1.0 / sr
        self.max_poly = max_poly
        self.high_water = high_water if high_water is not None else max(1, max_poly - 2)
        self.tau_forte, self.tau_piano = tau_forte, tau_piano
        self.kill_factor, self.release_factor = kill_factor, release_factor
        self.free_thr = free_thr
        self.level_decay = float(np.exp(-self.dt / level_tau))
        self.noise_amp = noise_amp
        self.noise_gain = 1.0
        self.noise_sos = butter(2, min(noise_lp_hz / (sr / 2.0), 0.95), btype="low",
                                output="sos")
        self.blast = max(2, int(noise_ms * 1e-3 * sr))
        self.rng = np.random.default_rng(seed)
        self.Nmax = patch.max_modes
        self.body = patch.body
        self.reset()

    # ------------------------------------------------------------------
    def reset(self):
        V, N = self.max_poly, self.Nmax
        self.f = np.zeros((V, N))
        self.base_gamma = np.zeros((V, N))
        self.gamma = np.zeros((V, N))
        self.gain = np.zeros((V, N))
        self.a1 = np.zeros((V, N))
        self.a2 = np.zeros((V, N))
        self.y1 = np.zeros((V, N))
        self.y2 = np.zeros((V, N))
        self.pr = np.zeros(V, dtype=int)
        self.plen = np.ones(V)
        self.amp = np.zeros(V)
        self.active = np.zeros(V, dtype=bool)
        self.fast = np.zeros(V, dtype=bool)
        self.level = np.zeros(V)
        self.key = -np.ones(V, dtype=int)
        self.burst = np.zeros((V, self.blast))
        self.bi = np.zeros(V, dtype=int)
        self.last_noise = 0.0
        self.n = 0
        self.kill_count = 0
        self.hard_count = 0
        self.kill_jump = 0.0
        self.active_hist = []

    # ------------------------------------------------------------------
    def _set_coeffs(self, v):
        r = np.exp(-self.gamma[v] * self.dt)
        theta = 2.0 * np.pi * self.f[v] * self.dt
        self.a1[v] = -2.0 * r * np.cos(theta)
        self.a2[v] = r * r

    def _set_gain(self, v, w, plen):
        f = self.f[v]
        n = np.arange(plen, dtype=float)
        pulse = 0.5 - 0.5 * np.cos(2.0 * np.pi * n / max(plen, 1))
        p = np.abs(np.exp(-1j * 2.0 * np.pi * np.outer(f, n) / self.sr).dot(pulse))
        # bound the boost: P is tiny for high modes, and dividing by it made their gains
        # explode into a coherent onset click (raw sum ~16x while a mode is ~1).
        p = np.maximum(p, np.max(p) * 0.1)
        theta = 2.0 * np.pi * f * self.dt
        g = w * np.sin(theta) / (p + 1e-9)
        self.gain[v] = np.clip(g, 0.0, 1e4)

    def _kill(self, v, hard=False):
        """Scheme C: accelerate the tail continuously (never cut to zero).

        Changing the pole radius swaps a1/a2 while y1/y2 still hold energy, so the next
        sample steps by `(a1_old-a1_new)*y1 + (a2_old-a2_new)*y2`. That jump is recorded
        (relative to the voice level) so "no click" is a measured claim, not an
        assumption.
        """
        th = 2.0 * np.pi * self.f[v] * self.dt
        ro = np.exp(-self.base_gamma[v] * self.dt)
        rn = np.exp(-self.base_gamma[v] * self.kill_factor * self.dt)
        jump = (2.0 * (rn - ro) * np.cos(th) * self.y1[v]
                + (ro * ro - rn * rn) * self.y2[v])
        self.kill_jump = max(self.kill_jump, float(np.abs(jump).max()))
        self.fast[v] = True
        self.gamma[v] = self.base_gamma[v] * self.kill_factor
        self._set_coeffs(v)
        self.kill_count += 1
        if hard:
            self.hard_count += 1

    # ------------------------------------------------------------------
    def note_on(self, midi, vel=1.0):
        dyn = "forte" if vel >= 0.55 else "piano"
        f, g, w = self.patch.modes(midi, dyn)
        n = f.size

        free = np.nonzero(~self.active)[0]
        if free.size == 0:
            # fallback only: the proactive high-water kill above normally keeps a slot
            # free. If it did not, steal the quietest voice (smallest audible click).
            v = int(np.argmin(self.level))
            self.active[v] = False
            self.y1[v] = 0.0
            self.y2[v] = 0.0
            self.hard_count += 1
            free = np.array([v])

        v = int(free[0])
        tau = self.tau_forte if vel >= 0.55 else self.tau_piano
        plen = max(2, int(tau * self.sr))

        self.f[v] = 0.0
        self.base_gamma[v] = 0.0
        self.gamma[v] = 0.0
        self.gain[v] = 0.0
        self.f[v, :n] = f
        self.base_gamma[v, :n] = g
        self.gamma[v, :n] = g
        wp = np.zeros(self.Nmax)
        wp[:n] = w
        self._set_coeffs(v)
        self._set_gain(v, wp, plen)

        self.pr[v] = plen
        self.plen[v] = plen
        self.amp[v] = float(vel)
        self.y1[v] = 0.0
        self.y2[v] = 0.0
        self.active[v] = True
        self.fast[v] = False
        self.key[v] = int(midi)
        self.level[v] = 1e-3
        # pick/strike transient: a short enveloped noise burst, coloured by the body
        env = np.hanning(self.blast)
        self.burst[v] = self.rng.standard_normal(self.blast) * env * (self.noise_amp * vel)
        self.bi[v] = 0
        return v

    def note_off(self, midi):
        """Damper (chiefly piano): released keys decay fast but continuously."""
        for v in np.nonzero(self.active & (self.key == midi) & ~self.fast)[0]:
            self.gamma[v] = self.base_gamma[v] * self.release_factor
            self._set_coeffs(int(v))

    # ------------------------------------------------------------------
    def step(self):
        x = np.zeros(self.max_poly)
        m = self.pr > 0
        if m.any():
            i = (self.plen[m] - self.pr[m]).astype(float)
            x[m] = self.amp[m] * (0.5 - 0.5 * np.cos(2.0 * np.pi * i / self.plen[m]))
            self.pr[m] -= 1

        y = self.gain * x[:, None] - self.a1 * self.y1 - self.a2 * self.y2
        self.y2[:] = self.y1
        self.y1[:] = y

        raw_h = y.sum(axis=1)
        # broadband transient, kept on a separate path (added after the body filter so a
        # steep body rolloff does not swallow the pick's treble)
        idx = np.clip(self.bi, 0, self.blast - 1)
        noise = self.burst[np.arange(self.max_poly), idx]
        noise = np.where(self.bi < self.blast, noise, 0.0) * self.active
        self.bi = np.minimum(self.bi + 1, self.blast)
        self.last_noise = float(noise.sum())
        self.level = np.maximum(np.abs(raw_h + noise), self.level * self.level_decay)
        out = float(raw_h[self.active].sum())

        # scheme C high-water: proactively accelerate the quietest tail so a slot is
        # free *before* the next note arrives (killing does not free a voice by itself).
        act = int(self.active.sum())
        nfast = int((self.active & self.fast).sum())
        if act > self.high_water and nfast < (act - self.high_water):
            cand = np.nonzero(self.active & ~self.fast)[0]
            if cand.size:
                self._kill(int(cand[np.argmin(self.level[cand])]))

        dead = self.active & (self.level < self.free_thr) & (self.pr == 0)
        if dead.any():
            self.active[dead] = False
            self.y1[dead] = 0.0
            self.y2[dead] = 0.0
            self.key[dead] = -1
            self.fast[dead] = False

        self.n += 1
        self.active_hist.append(int(self.active.sum()))
        return out

    # ------------------------------------------------------------------
    def render(self, events, seconds: float, gain: float = 1.0):
        """events: iterable of (time, midi, duration, velocity); body applied at the end."""
        n = int(seconds * self.sr)
        onsets, offs = {}, {}
        for t, midi, dur, vel in events:
            onsets.setdefault(int(round(t * self.sr)), []).append((int(midi), float(vel)))
            offs.setdefault(int(round((t + dur) * self.sr)), []).append(int(midi))

        buf = np.zeros(n)
        nbuf = np.zeros(n)
        for i in range(n):
            for midi, vel in onsets.get(i, ()):
                self.note_on(midi, vel)
            for midi in offs.get(i, ()):
                self.note_off(midi)
            buf[i] = self.step()
            nbuf[i] = self.last_noise
        buf = self.body.process(buf) + self.noise_gain * sosfilt(self.noise_sos, nbuf)
        return gain * buf
