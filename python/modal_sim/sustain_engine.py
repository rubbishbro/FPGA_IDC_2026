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

.. note::
   As of 2026-10-27 the synthesis class ``SustainSynth`` is legacy.  New B
   synthesis uses ``eng1_bc.BSynth`` on the shared ``Eng1Core``; ``SustainPatch``
   in this module remains the parameter/table provider used by
   ``router_eng1.build_b_table``.
"""

from __future__ import annotations

import json
import os
import re
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
        # The extractor stores midi/dynamic as fields (same contract as the pitched
        # <inst>_partials.npz that Patch reads). Older tables only carry the filename,
        # so fall back to parsing the note/dynamic tokens out of it.
        has_key = "midi" in d.files and "dynamic" in d.files
        self.by_key = {}
        for i in range(d["f0"].size):
            m = d["note_id"] == i
            note = str(d["notes"][i])
            if has_key:
                midi, dyn = int(d["midi"][i]), str(d["dynamic"][i])
            else:
                midi, dyn = self._midi(note), self._dyn(note)
            key = (midi, dyn)
            self.by_key.setdefault(key, []).append(dict(
                k=d["k"][m].astype(float), f=d["f_k"][m].astype(float),
                g=d["gamma"][m].astype(float), a=d["a"][m].astype(float),
                f0=float(d["f0"][i]),
                attack=float(d["attack_s"][i]), release=float(d["release_s"][i]),
                noise_db=float(d["noise_db"][i]),
                noise_win=float(d["noise_win"][i]), note=note))
        self.keys = sorted(self.by_key)
        self.midis = sorted({k[0] for k in self.by_key})
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
        mm = re.search(r"_([A-G]s?\d)_", note)
        return CORE.note_to_midi(mm.group(1).replace("s", "#")) if mm else 60

    @staticmethod
    def _dyn(note: str) -> str:
        """Fallback for tables without a ``dynamic`` field: read the dynamic token
        (``<inst>_<note>_<dur>_<dyn>_<art>``) instead of substring-matching 'piano',
        which used to fold mezzo-piano / mezzo-forte into 'forte'."""
        mm = re.search(r"_[A-G]s?\d_[^_]+_([^_]+)_", note)
        return mm.group(1) if mm else "forte"

    def _pick_key(self, midi, dynamic):
        """Key for (midi, dynamic); fall back to *any* recorded dynamic of the same
        pitch first, then to a dynamic of the nearest recorded pitch.

        Python deliberately allows this fallback (the hardware path is the one that
        must reject a missing key), but it must never jump to an unrelated first pitch:
        if a pitch is recorded only at ``mezzo-forte``, a ``forte`` request stays on
        that same pitch instead of landing on whatever key was inserted first.  Both
        levels use the dynamic preference (requested, then forte, then piano, then any
        recorded dynamic of that pitch)."""
        def at(m):
            avail = [k for k in self.keys if k[0] == m]
            if not avail:
                return None
            for dyn in (dynamic, "forte", "piano"):
                if (m, dyn) in self.by_key:
                    return (m, dyn)
            return avail[0]                       # any other legal dynamic, deterministic
        same = at(midi)
        if same is not None:
            return same
        near = min(self.midis, key=lambda m: (abs(m - midi), m))
        return at(near)                           # by_key non-empty => midis non-empty

    def _pick(self, midi, dynamic="forte"):
        return self.by_key[self._pick_key(midi, dynamic)][0]

    def modes(self, midi: int, dynamic: str = "forte"):
        src = self._pick(midi, dynamic)
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
                 high_water: int | None = None, noise_gain: float = 0.0,
                 noise_hp_hz: float = 400.0, noise_lp_hz: float = 9000.0,
                 noise_db_cap: float = 0.0,
                 vibrato_hz: float = 5.2, vibrato_cents: float = 22.0,
                 vibrato_am: float = 0.14, drift_cents: float = 0.0,
                 roughness: float = 0.0, rough_hz: float = 3.5,
                 steal_fade: float = 0.008,
                 coef_interval: int = 96, seed: int = 0):
        self.patch = patch
        self.sr = sr
        self.dt = 1.0 / sr
        self.max_poly = max_poly
        self.high_water = high_water if high_water is not None else max(1, max_poly - 2)
        self.noise_gain = noise_gain
        self.noise_hp_hz = noise_hp_hz
        self.noise_lp_hz = noise_lp_hz
        self.noise_db_cap = noise_db_cap
        self.vibrato_hz = vibrato_hz
        self.vibrato_cents = vibrato_cents
        self.vibrato_am = vibrato_am
        self.drift_cents = drift_cents
        self.coef_interval = max(1, int(coef_interval))
        self.steal_fade = max(float(steal_fade), 1e-4)   # s, voice-steal fade-out time
        self.rng = np.random.default_rng(seed)
        # Bow roughness: a slow amplitude modulation of the whole voice.  A bowed note is
        # not steady: bow pressure / contact make it breathe.  Measured on the recording,
        # every partial's envelope correlates with the *common* (mean) envelope at r=0.74
        # ..0.97, i.e. the fluctuation is almost entirely common-mode -- so modulating each
        # mode independently would cancel out in the mix (central limit) and barely change
        # the note.  Use a per-voice sum of a few random low-frequency sinusoids (discrete
        # spectrum -> no broadband sideband skirt); amplitude std = `roughness`.
        self.roughness = float(roughness)
        self.rough_hz = float(rough_hz)
        if self.roughness:
            _V, _K = max_poly, 10
            _rng = self.rng
            _fr = max(self.rough_hz, 1e-3) * (0.15 + 0.85 * _rng.random((_K, _V)))
            _ph = 2.0 * np.pi * _rng.random((_K, _V))
            _cdt = self.coef_interval / float(sr)
            self._rough_z = np.exp(1j * _ph)
            self._rough_inc = np.exp(1j * 2.0 * np.pi * _fr * _cdt)
            self._rough_norm = 1.0 / np.sqrt(_K / 2.0)     # unit-variance sum
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
        # Note identity: every note_on takes a unique id; note_off(note_id=...) releases
        # exactly that event, so overlapping same-pitch notes stay independent.
        self.note_id = -np.ones(V, dtype=int)
        self.fade = np.ones(V)                         # steal fade-out gain (1 = normal)
        self.pending = []                              # note-ons waiting for a slot
        self._next_note_id = 1
        self.last_note_id = 0
        self.kill_count = 0; self.hard_count = 0
        self.active_hist = []
        self.last_env = 0.0
        self.last_nz = 0.0
        self.rough = np.zeros(V)                       # per-voice bow-roughness AM
        self.n = 0

    # ------------------------------------------------------------------
    def note_on(self, midi, vel=1.0, dynamic="forte"):
        """Start a note.

        Returns the integer voice slot assigned to this note, which is one of:

        * a free slot -- the note starts immediately;
        * a slot that is being faded out (``fade < 1``) to make room for it -- the
          note is queued in ``self.pending`` and **bound** to that slot: it starts
          there once the fade reaches zero, and cancelling another queued note first
          never moves it to a different slot;
        * ``None`` -- the pool is full and every slot is already reserved by an
          earlier pending note.  This note is queued without a slot yet; it will get
          one within a bounded number of steal cycles (see ``step``).

        The unique identity of this note event is always written to
        ``self.last_note_id``.  ``self.note_id[slot]`` only carries that id once the
        note actually starts; while it is queued, ``note_id[slot]`` still holds the
        voice being faded out and ``voice_of(last_note_id)`` returns ``None``.
        ``note_off(note_id=...)`` cancels a queued note by removing it from
        ``pending`` even before it starts.  All pending entries are stored as
        ``(midi, vel, dynamic, note_id, bound_slot_or_None)``.
        """
        nid = self._next_note_id
        self._next_note_id += 1
        self.last_note_id = nid
        free = np.nonzero(~self.active)[0]
        if free.size == 0:
            # Pool full: validate the note, reserve a victim and fade it out; the new
            # note waits in `pending` and starts once that slot is free (never a hard
            # reset).  A slot already fading is reserved for an earlier pending note
            # and is never picked again.
            self.patch.modes(midi, dynamic)
            v = self._pick_victim()
            if v is not None:
                self.gate[v] = False
                self.fade[v] = min(self.fade[v], 1.0 - self.dt / self.steal_fade)
                self.hard_count += 1
            self.pending.append((int(midi), float(vel), dynamic, nid, v))
            return v
        self._start(int(free[0]), midi, vel, dynamic, nid)
        return int(free[0])

    def _pick_victim(self):
        """Slot to steal: a released voice closest to dying, else the oldest note.

        Slots that are already fading (``fade < 1``) are reserved for a pending
        note-on and are skipped, so repeated note-ons cannot all target the same
        faded slot.  Returns ``None`` when every active slot is already reserved.
        A just-started note is never chosen (its id is the newest)."""
        active = np.nonzero(self.active)[0]
        avail = active[self.fade[active] >= 1.0]
        if avail.size == 0:
            return None
        released = avail[~self.gate[avail]]
        if released.size:
            return int(released[np.argmin(self.env[released])])
        return int(avail[np.argmin(self.note_id[avail])])

    def _start(self, v, midi, vel, dynamic, nid):
        kk, g, w, atk, rel, noise_db, noise_win = self.patch.modes(midi, dynamic)
        n = kk.size
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
        # Cap the loudest notes (the extracted bow-noise level of a few notes is up to
        # 10x the median) and scale with velocity, so a forte note does not get an
        # outsized noise burst and softer notes stay proportionally cleaner.
        ndb = min(noise_db, self.noise_db_cap)
        sigma = (10.0 ** (ndb / 20.0)
                 / max(2.0 * np.sqrt(3.0 / (2.0 * max(noise_win, 1.0))), 1e-12))
        self.nz[v] = sigma * NOISE_CAL * float(np.clip(vel, 0.0, 1.0))
        self.gate[v] = True
        self.active[v] = True
        self.key[v] = int(midi)
        self.y1[v] = 0.0; self.y2[v] = 0.0
        self.rough[v] = 0.0
        self.note_id[v] = int(nid)
        self.fade[v] = 1.0
        return v

    def voice_of(self, note_id):
        """Voice slot currently holding ``note_id``, or None."""
        hit = np.nonzero(self.active & (self.note_id == int(note_id)))[0]
        return int(hit[0]) if hit.size else None

    def note_off(self, midi=None, *, note_id=None):
        """Release a note.

        With ``note_id`` only that exact event is released, so overlapping same-pitch
        notes no longer collide.  With a bare ``midi`` every still-held voice of that
        pitch is released -- kept for callers and regressions that predate note ids.
        """
        if note_id is not None:
            self.pending = [p for p in self.pending if p[3] != int(note_id)]
            v = self.voice_of(note_id)
            if v is not None:
                self.gate[v] = False
            return
        # Bare midi: release every held voice of that pitch AND cancel any queued
        # (pending) note-ons of it that have not started yet.  Without the pending
        # sweep a note that was stolen into the queue kept sounding after its
        # Note Off arrived.
        self.gate[self.active & (self.key == midi)] = False
        self.pending = [p for p in self.pending if p[0] != int(midi)]

    def _update_coeffs(self):
        """Control-rate pitch update (vibrato).

        Vibrato must move the drive and every partial by the *same* ratio so the modes
        stay on the drive harmonics; that also keeps the drive calibration valid.
        Recomputed at control rate (vibrato is ~5 Hz), not per sample.

        This routine only *samples* the per-voice LFO phase onto the resonators; the
        phase itself is advanced once per sample in ``step`` (see there).  It therefore
        reflects the true LFO value at the current sample, not a once-per-interval
        approximation.
        """
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
        pitch_mod = bool(self.vibrato_cents) or bool(self.drift_cents)
        lfo_on = pitch_mod or bool(self.vibrato_am)
        if pitch_mod and self.n % self.coef_interval == 0:
            self._update_coeffs()
        if self.roughness and self.n % self.coef_interval == 0:
            self._rough_z *= self._rough_inc
            self.rough = self._rough_norm * self._rough_z.real.sum(axis=0)
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
        # Steal fade: a stolen voice is ramped to zero *before* its slot is reused, so
        # the mix never jumps (no click).  When the ramp reaches zero the slot is freed
        # and any pending note-on starts there.
        fading = self.fade < 1.0
        if fading.any():
            self.fade[fading] = np.maximum(
                self.fade[fading] - self.dt / self.steal_fade, 0.0)
        yout = y
        if self.roughness:
            mod = np.exp(self.roughness * self.rough - 0.5 * self.roughness ** 2)
            yout = y * mod[:, None]
        if fading.any():
            yout = yout * self.fade[:, None]
        out = float(yout[self.active].sum())
        dead = self.active & (self.fade <= 0.0)
        if dead.any():
            self.active[dead] = False
            self.y1[dead] = 0.0; self.y2[dead] = 0.0
            self.key[dead] = -1; self.note_id[dead] = -1; self.fade[dead] = 1.0
        if self.active.any():
            self.last_env = float(self.env[self.active].max())
            self.last_nz = float((self.nz * self.env)[self.active].max())
        # Free a voice once it is silent *and released*: during the attack env starts at
        # 0, so testing the level alone recycled the voice on its first sample.
        # A couple of small *samples* are NOT silence: at low frequency two consecutive
        # samples near a zero crossing can both be tiny while the mode's amplitude is
        # still large -- a 2-sample max(|y[n]|,|y[n-1]|) under-reads by ~sin(theta/2).
        # Recover the phase-independent modal amplitude E from the two state samples and
        # the pole actually in use: a free mode is y[m] = E r^m sin(theta m + phi), and
        #     E^2 = y[n]^2 + ((y[n] cos(theta) - r y[n-1]) / sin(theta))^2
        # For fixed stable poles, E bounds every future |y| of that mode, independent
        # of phase.  With vibrato this is an instantaneous amplitude estimate using
        # this sample's coefficients, not a bound on future time-varying amplification.
        # Modes with r==0 are unused/padding and contribute 0; theta~0/pi (out-of-band
        # or Nyquist) falls back to the 2-sample check (not an amplitude bound at a
        # repeated pole); finite in-band states use the guarded quadrature division.
        r_now = np.sqrt(np.maximum(self.a2, 0.0))
        cos_t = np.clip(
            np.where(r_now > 1e-12, -self.a1 / (2.0 * np.maximum(r_now, 1e-12)), 1.0),
            -1.0, 1.0)
        sin_t = np.sqrt(np.maximum(1.0 - cos_t * cos_t, 0.0))
        quad = np.abs(self.y1 * cos_t - r_now * self.y2)
        two_sample = np.maximum(np.abs(self.y1), np.abs(self.y2))
        env_mode = np.where(
            sin_t > 1e-6,
            np.sqrt(self.y1 * self.y1 + (quad / np.maximum(sin_t, 1e-12)) ** 2),
            two_sample)
        env_mode = np.where(r_now > 1e-12, env_mode, 0.0)   # unused/padding modes
        quiet = (self.active & ~self.gate & (self.env < 1e-3)
                 & (env_mode.sum(axis=1) < 2e-4))
        if quiet.any():
            self.active[quiet] = False
            self.y1[quiet] = 0.0; self.y2[quiet] = 0.0
            self.key[quiet] = -1; self.note_id[quiet] = -1
        # Start note-ons that were waiting for a stolen slot to finish fading.  Each
        # queued note that was promised a slot is *bound* to it (pending entry field 4),
        # so it starts exactly there: cancelling another queued note can never move it
        # to a different slot.  Entries with no slot yet wait for the free-slot and
        # reservation logic below.  FIFO order is kept within each phase.
        if self.pending:
            still = []
            for p in self.pending:
                if p[4] is not None and not self.active[p[4]]:
                    self._start(p[4], p[0], p[1], p[2], p[3])
                else:
                    still.append(p)
            self.pending = still
            # Unbound queued notes fill any slot that is free now, in arrival order.
            if self.pending:
                free = np.nonzero(~self.active)[0]
                if free.size:
                    still = []
                    fi = 0
                    for p in self.pending:
                        if p[4] is None and fi < free.size:
                            self._start(int(free[fi]), p[0], p[1], p[2], p[3])
                            fi += 1
                        else:
                            still.append(p)
                    self.pending = still
            # Still queued without a slot: reserve a fading victim for each and bind it,
            # so a burst larger than the pool keeps making progress instead of starving
            # behind sustained voices.  `fade<1` marks reserved slots; `_pick_victim`
            # skips them, so one slot is never reserved twice.  Same click-free fade.
            if self.pending:
                for i, p in enumerate(self.pending):
                    if p[4] is not None:
                        continue
                    v = self._pick_victim()
                    if v is None:
                        break
                    self.gate[v] = False
                    self.fade[v] = min(self.fade[v], 1.0 - self.dt / self.steal_fade)
                    self.hard_count += 1
                    self.pending[i] = (p[0], p[1], p[2], p[3], v)
        # No active voice left: clear the residual noise envelope on this very sample so
        # render's envt/nzt (and thus the breath/bow noise) stop the moment the last voice
        # is recycled, instead of holding its last value forever.  While any voice remains
        # the original max(env) / max(nz*env) rule is untouched.
        if not self.active.any():
            self.last_env = 0.0
            self.last_nz = 0.0
        # Advance the per-voice LFO by exactly one sample.  The pitch coefficients and the
        # AM factor used *this* sample were sampled from the pre-advance phase, so a note's
        # first sample uses the phase it was initialised with in note_on: there is no jump
        # by a whole coef_interval on the first control tick.  Phase advances whenever any
        # modulation is enabled, so AM-only (cents=drift=0, am!=0) runs at the right rate.
        if lfo_on:
            self.lfo_phase = (self.lfo_phase + self.vibrato_hz * self.dt) % 1.0
        self.n += 1
        self.active_hist.append(int(self.active.sum()))
        return out

    def render(self, events, seconds: float):
        n = int(seconds * self.sr)
        onsets, offs = {}, {}
        for ev in events:
            t, midi, dur, vel = ev[:4]
            dyn = ev[4] if len(ev) > 4 else "forte"
            onsets.setdefault(int(round(t * self.sr)), []).append(
                (int(midi), float(vel), dyn, int(round((t + dur) * self.sr))))
        buf = np.zeros(n)
        envt = np.zeros(n)
        nzt = np.zeros(n)
        for i in range(n):
            # Note Off is matched to the exact note that was started (by id), so a new
            # same-pitch note that begins on this very sample is not swept up with the
            # old one that ends here.
            for midi, vel, dyn, i_off in onsets.get(i, ()):
                self.note_on(midi, vel, dyn)
                offs.setdefault(i_off, []).append(self.last_note_id)
            for nid in offs.get(i, ()):
                self.note_off(note_id=nid)
            buf[i] = self.step()
            envt[i] = self.last_env
            nzt[i] = self.last_nz
        # Bow / breath noise.  KEPT but DISABLED by default (noise_gain defaults to
        # 0.0): a no-noise render is perceptually close and the RTL omits this path.
        # Set noise_gain>0 to re-enable.  See rtl/DECISIONS.md (G6).
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
    """Static-calibration check: synthesised steady partials vs the extracted ``a_k``.

    Scope: this measures the **static** gain calibration only.  Vibrato, amplitude
    modulation and roughness are switched off and the noise branch is disabled, so
    the measured partials are the drive calibration itself.  With modulation left on
    (the previous behaviour) a phase-modulated partial is a Bessel sideband comb and a
    fixed-frequency coherent sum reads only its carrier, so the evaluated error was
    dominated by the sideband energy and not by a calibration mistake.  The verify
    number is therefore a static calibration bound, not an audible-fidelity verdict.

    ``seconds`` is the whole render length; the note is held from 0.2 s to
    ``seconds - 0.2``.  The analysis window defaults to 1.5..2.8 s and is shrunk to
    fit a shorter render; a render too short to contain a usable steady segment
    raises ``ValueError`` instead of silently measuring an empty (NaN) segment.
    """
    p = SustainPatch(inst)
    s = SustainSynth(p, max_poly=2, vibrato_cents=0.0, vibrato_am=0.0,
                     drift_cents=0.0, noise_gain=0.0, roughness=0.0)
    kk, g, w, atk, rel, ndb, nwin = p.modes(midi)  # modes() returns 7 fields
    sr = s.sr
    note_end = seconds - 0.2                       # release starts here
    t0, t1 = 1.5, 2.8
    if note_end <= t1:                             # short render: shrink the window
        t1 = max(0.0, note_end - 0.02)
        t0 = min(t0, 0.6 * t1)
    period = max(2, int(round(sr / CORE.midi_to_hz(midi))))
    f = kk * (sr / period)                    # same rule the engine uses
    y = s.render([(0.2, midi, seconds - 0.4, 1.0)], seconds)
    seg = y[max(0, int(t0 * sr)):max(0, int(t1 * sr))]
    if seg.size < int(0.2 * sr):
        raise ValueError(
            f"verify({inst!r}): seconds={seconds} is too short to hold a steady "
            f"segment (note ends at {note_end:.3f}s, window {t0:.3f}..{t1:.3f}s, "
            f"{seg.size} samples)")
    n = np.arange(seg.size)
    wnd = np.hanning(seg.size)
    meas = np.array([abs(np.sum(seg * wnd * np.exp(-2j * np.pi * fk * n / sr)))
                     for fk in f])
    if not np.all(np.isfinite(meas)):
        raise ValueError(f"verify({inst!r}): non-finite partial magnitude")
    meas = meas / (meas.max() + 1e-30)
    target = w / w.max()
    err = 20 * np.log10((meas + 1e-12) / (target + 1e-12))
    stats = dict(inst=inst, midi=int(midi), modes=int(f.size), seconds=float(seconds),
                 window=(float(t0), float(t1)), samples=int(seg.size),
                 attack_s=float(atk), release_s=float(rel),
                 median_db=float(np.median(np.abs(err))),
                 p90_db=float(np.percentile(np.abs(err), 90)),
                 max_db=float(np.abs(err).max()))
    print(f"{inst} midi {midi}: modes {f.size}  attack {atk * 1e3:.0f} ms  "
          f"release {rel * 1e3:.0f} ms  (static: vib/noise/roughness off)")
    print(f"  steady partial dB error: median {stats['median_db']:.2f}  "
          f"p90 {stats['p90_db']:.2f}  max {stats['max_db']:.2f}")
    return stats


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
