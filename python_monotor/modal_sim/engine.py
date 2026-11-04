"""Modal synthesis engine: pulse excitation -> N modal resonators -> shared body.

Per the agreed architecture:

    excitation = one finite raised-cosine force pulse (tau from velocity)
    modes      = N IIR resonators *per voice*, f_k = k*f0*sqrt(1+B k^2),
                 gamma_k from the extracted table
    voice      = one note: its own N-mode bank, excitation pulse and state
    body       = one fixed biquad cascade shared by all voices
    polyphony  = a pool of `max_poly` voices; once more than `high_water`
                 voices are active, scheme-C "kills" the quietest tail: every
                 mode of that one voice accelerates out, never a hard cut
    output     = sum voices -> body -> VCA/soft-clip

`max_poly` / `high_water` count **voices (notes), not modes**. One voice owns
up to `patch.max_modes` modes (48 in the RTL budget, 64 for the mandolin
demo), so the state is `max_poly x max_modes` resonators. A 40-voice pool with
64 modes is 2560 resonators; `high_water=36` means at most 36 voices ring
without a kill fade, not 36 modes.
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
        """Configure one voice pool.

        max_poly      : number of simultaneous voices (notes), not modes
        high_water    : voice count above which scheme-C kills tails;
                        defaults to max_poly - 2
        kill_factor   : gamma multiplier applied to a killed voice. 150 turns
                        the mandolin's median ~4/s decay into ~1.7 ms, so the
                        fade is fast enough to be inaudible but still smooth
        release_factor: gamma multiplier applied by note_off (damper).
                        1.0 is a no-op; the chop uses 4.0
        free_thr      : per-voice peak level below which a quiet voice is freed
        level_tau     : time constant of the peak follower used to rank kill
                        candidates (not the audio envelope)
        noise_*       : short Hann-windowed pick/strike burst, added after the
                        body so a steep body rolloff does not swallow it
        """
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
        # Per-voice, per-mode state: V voices x N modes. The N axis is the
        # modal bank inside one note, not N polyphonic notes.
        V, N = self.max_poly, self.Nmax
        self.f = np.zeros((V, N))              # mode frequencies (Hz), per voice
        self.base_gamma = np.zeros((V, N))     # table decay rate, before any kill
        self.gamma = np.zeros((V, N))          # current decay; kill/release scale it
        self.gain = np.zeros((V, N))           # excitation-to-mode gain
        self.a1 = np.zeros((V, N))             # IIR coefficient -2*r*cos(theta)
        self.a2 = np.zeros((V, N))             # IIR coefficient r^2
        self.y1 = np.zeros((V, N))             # mode state, previous output
        self.y2 = np.zeros((V, N))             # mode state, two samples back
        self.pr = np.zeros(V, dtype=int)       # samples left in the excitation pulse
        self.plen = np.ones(V)                 # excitation-pulse length (samples)
        self.amp = np.zeros(V)                 # velocity-scaled pulse amplitude
        self.active = np.zeros(V, dtype=bool)  # voice allocated and may ring
        self.fast = np.zeros(V, dtype=bool)    # scheme-C kill already applied
        self.level = np.zeros(V)               # peak follower for kill ranking only
        self.key = -np.ones(V, dtype=int)      # MIDI note, for note_off by pitch
        self.burst = np.zeros((V, self.blast))  # per-voice pick/strike noise
        self.bi = np.zeros(V, dtype=int)       # read index into burst
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
        """Scheme C: accelerate one whole voice's tail (never cut to zero).

        `v` is a voice, so `gamma[v]` is the decay vector of *all* its modes;
        multiplying it by `kill_factor` fades the complete note, not one mode.
        This is the intended granularity: a per-mode kill would leave a
        half-dead, wrong-timbre note behind.

        Changing the pole radius swaps a1/a2 while y1/y2 still hold energy, so
        the next sample steps by
        `(a1_old-a1_new)*y1 + (a2_old-a2_new)*y2`. That jump is recorded
        (relative to the voice level) so "no click" is a measured claim, not an
        assumption.

        `hard=True` only marks the kill as a stolen voice for statistics. The
        pool-full fallback in note_on does its own hard steal (zeroes y1/y2
        before reallocating) instead of calling this helper.
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
        """Allocate one voice for a note and arm its excitation pulse.

        A free voice is taken first. If the pool is full, the quietest voice is
        hard-stolen (y1/y2 zeroed): that is the fallback, expected to be rare
        because the high-water logic in step() frees tails ahead of time.
        """
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
        # Seed the peak follower just above free_thr (2e-4). The attack is not
        # visible yet: the raised-cosine pulse and the Hann noise burst both
        # start at zero, so the first step() sees y=0 and level stays at this
        # seed. A newborn voice must therefore not be a kill candidate; see the
        # FIXME on the high-water mask in step().
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
        """Advance the whole voice pool by one sample.

        Order matters: excite -> run every mode -> update the peak follower ->
        run the high-water voice manager. On a voice's first sample both the
        pulse and the noise burst are zero, so the manager ranks it by the
        `level` seed from note_on, not by its attack peak.
        """
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

        # Scheme C high-water, in voice units: `act` counts allocated notes and
        # `nfast` counts those already fading. Keep at most `high_water`
        # non-fading voices, so a slot is free before the next note arrives
        # (a kill accelerates the tail but does not free the voice by itself).
        #
        # The candidate is the quietest voice by `level`, which must mean an
        # inaudible tail. A voice still emitting its excitation pulse is not a
        # tail: on its first sample y is exactly 0 and `level` is still the
        # 1e-3 seed, so it can look quieter than every ringing tail.
        #
        # FIXME: add `& (self.pr == 0)` to the mask below. Without it, dense
        # passages (mandolin tremolo, high_water=36 of max_poly=40) repeatedly
        # kill the newest voice before its attack: 22 of 136 kills in the
        # Bella Ciao lead happen at age 0. Protecting the 7-sample pulse is
        # enough, because by then the peak follower has risen to the attack
        # level and the voice no longer ranks as quietest.
        act = int(self.active.sum())
        nfast = int((self.active & self.fast).sum())
        if act > self.high_water and nfast < (act - self.high_water):
            cand = np.nonzero(self.active & ~self.fast)[0]
            if cand.size:
                self._kill(int(cand[np.argmin(self.level[cand])]))

        # Free genuinely silent voices only after their pulse has finished, so
        # a just-started note is never declared dead while its attack is 0.
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
        """Render `(time, midi, duration, velocity)` events to audio.

        Events are quantised to whole samples and may overlap; this is what
        makes tremolo (same pitch re-struck every 80 ms) work. `note_off` is
        keyed by MIDI pitch, not voice id: it damps every active voice of that
        pitch that is not already in a kill fade. With release_factor=1.0
        (plucked strings) it is a no-op; the chop uses 4.0.
        """
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
