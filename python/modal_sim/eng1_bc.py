#!/usr/bin/env python3
"""B/C synthesis on the same ABC engine as A.

The current RTL has one recursion core for A/B/C::

    y[n] = G*x[n] - a1*y[n-1] - a2*y[n-2]

A/B/C differ only in how the voice is excited and when it is released:

* **A** -- one finite pulse, ``G`` from the note table, ADSR/dyn envelope.
* **B** -- a periodic impulse train at the note's f0, ``G`` from the sustain
  table, AR/ADSR envelope; no NCO in the current router, the drive is
  ``excitation_gen`` with ``PW_LEN=1, GAP_LEN=T-1, N_PULSE=7``.
* **C** -- ``x = 0``; the state is loaded from a seed at note-on, a per-voice
  timer/choke starts a fade, and the same recursion rings out.

This module implements B and C as **configurations of one** ``Eng1Core``.  The
old float ``sustain_engine.SustainSynth`` and additive ``drumkit`` are kept for
the legacy demos/parameter extraction, but the new B/C path does not use a
separate DSP engine.

The C seed is a 64-bit ``{y2, y1}`` per mode, scaled by velocity exactly like
the old ``c_engine_top.scale_seed`` (UQ1.15, round, saturate).  Seeds are
derived from the extracted ``(f, gamma, a)`` of ``drums.npz`` so that the ABC
recursion starts at the intended modal amplitude and phase.  Noise is *not* part
of the RTL C core, so ``CSynth`` is seed-only; the old ``drumkit`` noise branch
remains a legacy extension.

    python python/modal_sim/eng1_bc_demo.py
"""

from __future__ import annotations

import math
import os
import sys
import zlib
from dataclasses import dataclass, field

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "fft_analysis"))

import paths                                    # noqa: E402
import router_eng1 as R                         # noqa: E402

SR = R.SR
SLOTS = R.SLOTS
ENV_ONE = R.ENV_ONE


# ---------------------------------------------------------------------------
# seed helpers (old c_engine_top.scale_seed)
# ---------------------------------------------------------------------------
def _sat32(v: int) -> int:
    return max(R.Y_MIN, min(R.Y_MAX, int(v)))


def scale_seed(y: int, vel: float) -> int:
    """UQ1.15 velocity scale with rounding and 32-bit saturation."""
    vq = int(round(float(vel) * 32768.0))
    vq = max(0, min(32768, vq))
    if vq == 32768:
        return _sat32(y)
    p = int(y) * vq
    return _sat32((p + 16384) >> 15)


def _seed_states(f: np.ndarray, g: np.ndarray, a: np.ndarray,
                 a1q: np.ndarray, a2q: np.ndarray,
                 key: str) -> tuple[np.ndarray, np.ndarray]:
    """``{y2,y1}`` that makes the quantised recursion start at ``a*sin(phi)``."""
    rq = np.sqrt(a2q.astype(float) / float(1 << 24))
    cq = np.clip(-(a1q.astype(float) / float(1 << 20)) /
                 np.maximum(2.0 * rq, 1e-12), -1.0, 1.0)
    thq = np.arccos(cq)
    rng = np.random.default_rng(zlib.crc32(str(key).encode("utf-8")))
    phi = rng.uniform(0.0, 2.0 * np.pi, f.size)
    # y[n] = a*r^n*sin(theta*n+phi); seed the two samples before n=0
    s1 = a / np.maximum(rq, 1e-9) * np.sin(phi - thq)
    s2 = a / np.maximum(rq * rq, 1e-9) * np.sin(phi - 2.0 * thq)
    q1 = np.clip(np.floor(s1 * float(1 << R.Y_FRAC) + 0.5),
                 R.Y_MIN, R.Y_MAX).astype(np.int64)
    q2 = np.clip(np.floor(s2 * float(1 << R.Y_FRAC) + 0.5),
                 R.Y_MIN, R.Y_MAX).astype(np.int64)
    return q1, q2


# ---------------------------------------------------------------------------
# B
# ---------------------------------------------------------------------------
@dataclass
class _BSlot:
    active: bool = False
    gate: bool = False
    table: R.Eng1Coeffs | None = None
    period: int = 109
    phase: int = 0
    level: int = 0
    env_lvl: int = 0
    env_state: int = 0        # 0 idle, 1 atk, 2 dec, 3 sus, 4 rel
    a_step: int = 16_777_216
    d_step: int = 1_048_576
    s_level: int = 536_870_912
    r_step: int = 1_048_576
    born: int = 0


class BSynth:
    """Periodic-drive B class on ``Eng1Core``."""

    def __init__(self, instrument: str = "flute", *, slots: int = SLOTS,
                 n_modes: int = R.N_MODES, body: str = "none",
                 reverb: str = "NONE"):
        self.instrument = instrument
        self.slots = int(slots)
        self.core = R.Eng1Core(slots=slots, n_modes=n_modes)
        self.body = R.BodyFilter(instrument=body)
        self.rev = R.ReverbRouter(reverb)
        self.slot = [_BSlot() for _ in range(self.slots)]
        self.n = 0

    # ------------------------------------------------------------------
    def _alloc(self) -> int:
        for i, s in enumerate(self.slot):
            if not s.active:
                return i
        # steal the oldest voice
        i = min(range(self.slots), key=lambda k: self.slot[k].born)
        self.core.clear_slot(i)
        self.slot[i] = _BSlot()
        return i

    def note_on(self, midi: int, vel: float = 0.8, dyn: str = "forte") -> int:
        table = R.build_b_table(self.instrument, int(midi), str(dyn))
        i = self._alloc()
        self.core.load_slot(i, table)
        self.core.nm[i] = table.n_modes
        s = self.slot[i]
        s.active = True
        s.gate = True
        s.table = table
        s.period = int(table.drive_period or max(2, round(SR / 440.0)))
        s.phase = 0
        s.level = max(1, min(255, int(round(float(vel) * 255.0)))) << 22
        s.env_lvl = 0
        s.env_state = 1
        atk = max(float(table.attack_s or 0.02), 0.003)
        rel = max(float(table.release_s or 0.05), 0.02)
        s.a_step = max(1, int(ENV_ONE / (atk * SR)))
        s.r_step = max(1, int(ENV_ONE / (rel * SR)))
        s.d_step = 1_048_576
        s.s_level = ENV_ONE // 4
        s.born = self.n
        return i

    def note_off(self, slot: int):
        self.slot[int(slot)].gate = False
        if self.slot[int(slot)].env_state != 4:
            self.slot[int(slot)].env_state = 4

    # ------------------------------------------------------------------
    def _env_step(self, s: _BSlot):
        if s.gate:
            if s.env_state == 0:
                s.env_state = 1
            if s.env_state == 1:
                s.env_lvl += s.a_step
                if s.env_lvl >= ENV_ONE:
                    s.env_lvl = ENV_ONE
                    s.env_state = 2
            elif s.env_state == 2:
                if s.env_lvl <= s.s_level + s.d_step:
                    s.env_lvl = s.s_level
                    s.env_state = 3
                else:
                    s.env_lvl -= s.d_step
            elif s.env_state == 3:
                s.env_lvl = s.s_level
        else:
            if s.env_lvl > 0:
                s.env_lvl = max(0, s.env_lvl - s.r_step)
            if s.env_lvl == 0:
                s.env_state = 0

    def step(self) -> int:
        x = np.zeros(self.slots, dtype=np.int64)
        gain = np.zeros(self.slots, dtype=np.int64)
        for i, s in enumerate(self.slot):
            if not s.active:
                continue
            if s.gate:
                if s.phase == 0:
                    x[i] = s.level
                    s.phase = max(0, s.period - 1)
                else:
                    s.phase -= 1
            self._env_step(s)
            gain[i] = s.env_lvl
            if not s.gate and s.env_lvl == 0:
                s.active = False
                self.core.clear_slot(i)
        y, _ = self.core.step(x, np.zeros(self.slots, dtype=bool))
        y_env = [R.wrap_signed((int(y[i]) * int(gain[i])) >> 31, 64)
                 for i in range(self.slots)]
        mix = R.wrap_signed(sum(y_env), 64)
        body_y, _mask, _nsat = self.body.step(mix)
        out = self.rev.step(body_y)
        self.n += 1
        return out

    # ------------------------------------------------------------------
    def render(self, events, seconds: float | None = None):
        """``events`` = ``[(t, midi, dur, vel, dyn), ...]``."""
        if seconds is None:
            seconds = max(t + d for t, _m, d, _v, _d in events) + 0.5
        n = max(1, int(round(seconds * SR)))
        out = np.zeros(n, dtype=np.int64)
        ons: dict[int, list] = {}
        offs: dict[int, list] = {}
        for nid, ev in enumerate(events):
            t, midi, dur, vel, dyn = (list(ev) + ["forte"])[:5]
            i0 = max(0, int(round(float(t) * SR)))
            i1 = max(i0 + 1, int(round((float(t) + float(dur)) * SR)))
            ons.setdefault(i0, []).append((nid, int(midi), float(vel), str(dyn)))
            offs.setdefault(i1, []).append(nid)
        slot_of: dict[int, int] = {}
        for i in range(n):
            for nid in offs.get(i, ()):
                if nid in slot_of:
                    self.note_off(slot_of.pop(nid))
            for nid, midi, vel, dyn in ons.get(i, ()):
                slot_of[nid] = self.note_on(midi, vel, dyn)
            out[i] = self.step()
        return out


# ---------------------------------------------------------------------------
# C
# ---------------------------------------------------------------------------
@dataclass
class CTable:
    coeffs: R.Eng1Coeffs
    seed_y1: np.ndarray
    seed_y2: np.ndarray
    length: int
    group: str
    key: str


#: mix balance from the old kit (cymbal modes ring much longer than a kick)
KIT_GAIN = {"kick": 1.0, "snare": 0.8, "hat": 0.30, "tom": 0.8,
            "crash": 0.45, "ride": 0.28}

_C_CACHE: dict[str, CTable] = {}


def build_c_table(key: str, n_modes: int = R.N_MODES,
                  drums_path: str | None = None) -> CTable:
    """Turn one ``drums.npz`` hit into an ABC table + seed/timer/group."""
    key = str(key)
    if key in _C_CACHE and _C_CACHE[key].coeffs.n_modes <= n_modes:
        return _C_CACHE[key]
    path = drums_path or os.path.join(paths.PARAMS, "drums.npz")
    d = np.load(path, allow_pickle=True)
    f = np.asarray(d[f"{key}__f"], dtype=float)
    g = np.asarray(d[f"{key}__gamma"], dtype=float)
    a = np.asarray(d[f"{key}__a"], dtype=float)
    if f.size == 0:
        raise KeyError(f"drums: no hit {key!r}")

    # keep the strongest n_modes; the RTL budget is 48 modes/voice
    order = np.argsort(a)[::-1][:int(n_modes)]
    f, g, a = f[order], g[order], a[order]
    theta = 2.0 * np.pi * f / SR
    r = np.exp(-g / SR)
    a1q = np.clip(np.floor(-2.0 * r * np.cos(theta) * (1 << 20) + 0.5),
                  -(1 << 21), (1 << 21) - 1).astype(np.int64)
    a2q = np.clip(np.floor(r * r * (1 << 24) + 0.5),
                  0, (1 << 24) - 1).astype(np.int64)
    s1, s2 = _seed_states(f, g, a, a1q, a2q, key)
    table = CTable(
        coeffs=R.Eng1Coeffs(G=np.zeros(f.size, dtype=np.int64),
                            a1=a1q, a2=a2q, n_modes=f.size,
                            label=f"drums:{key}"),
        seed_y1=s1, seed_y2=s2,
        length=max(1, int(round(min(3.0, max(0.15, 6.5 / max(g.min(), 0.1))) * SR))),
        group=("hat" if key == "hat" else
               "cymbal" if key in ("crash", "ride") else key),
        key=key,
    )
    _C_CACHE[key] = table
    return table


@dataclass
class _CSlot:
    active: bool = False
    table: CTable | None = None
    timer: int = 0
    fade: float = 1.0
    born: int = 0


class CSynth:
    """Seed/timer/choke C class on the same ``Eng1Core`` as B."""

    def __init__(self, *, slots: int = SLOTS, n_modes: int = R.N_MODES,
                 body: str = "none", reverb: str = "NONE",
                 fade_tau_s: float = 0.005):   # old c_voice_timer FADE=240 @48k
        self.slots = int(slots)
        self.core = R.Eng1Core(slots=slots, n_modes=n_modes)
        self.body = R.BodyFilter(instrument=body)
        self.rev = R.ReverbRouter(reverb)
        self.slot = [_CSlot() for _ in range(self.slots)]
        self.fade_decay = math.exp(-1.0 / max(fade_tau_s * SR, 1.0))
        self.n = 0

    def _alloc(self) -> int:
        for i, s in enumerate(self.slot):
            if not s.active:
                return i
        i = min(range(self.slots), key=lambda k: self.slot[k].born)
        self.core.clear_slot(i)
        self.slot[i] = _CSlot()
        return i

    def hit(self, key: str, vel: float = 0.8) -> int:
        table = build_c_table(key)
        # choke: a new hit in the same cymbal/hat group fades the old one
        for s in self.slot:
            if s.active and s.table is not None and s.table.group == table.group:
                if table.group in ("hat", "cymbal"):
                    s.timer = 0
        vel = float(vel) * KIT_GAIN.get(key, 1.0)
        i = self._alloc()
        self.core.load_slot(i, table.coeffs)
        self.core.nm[i] = table.coeffs.n_modes
        for m in range(table.coeffs.n_modes):
            self.core.y1[i, m] = scale_seed(int(table.seed_y1[m]), vel)
            self.core.y2[i, m] = scale_seed(int(table.seed_y2[m]), vel)
        s = self.slot[i]
        s.active = True
        s.table = table
        s.timer = table.length
        s.fade = 1.0
        s.born = self.n
        return i

    def step(self) -> int:
        x = np.zeros(self.slots, dtype=np.int64)
        w = np.zeros(self.slots, dtype=float)
        for i, s in enumerate(self.slot):
            if not s.active:
                continue
            if s.timer > 0:
                s.timer -= 1
            else:
                s.fade *= self.fade_decay
            w[i] = s.fade
            if s.fade < 1e-3:
                s.active = False
                self.core.clear_slot(i)
        y, _ = self.core.step(x, np.zeros(self.slots, dtype=bool))
        mix = R.wrap_signed(sum(int(y[i]) * float(w[i])
                                for i in range(self.slots)), 64)
        body_y, _mask, _nsat = self.body.step(int(mix))
        out = self.rev.step(body_y)
        self.n += 1
        return int(out)

    # ------------------------------------------------------------------
    def render(self, events, seconds: float | None = None):
        """``events`` = ``[(t, key, vel), ...]``."""
        if seconds is None:
            seconds = max(t for t, _k, _v in events) + 3.0
        n = max(1, int(round(seconds * SR)))
        out = np.zeros(n, dtype=np.int64)
        hits: dict[int, list] = {}
        for t, key, vel in events:
            hits.setdefault(max(0, int(round(float(t) * SR))), []).append(
                (str(key), float(vel)))
        for i in range(n):
            for key, vel in hits.get(i, ()):
                self.hit(key, vel)
            out[i] = self.step()
        return out


__all__ = ["BSynth", "CSynth", "CTable", "build_c_table", "scale_seed"]
