"""Bit-exact sample-level model of the router's ``eng1`` audio path.

Why this file exists
--------------------
``rtl/router/engines/eng1.sv`` is the ABC recursion used by the current
``voice_router``::

    acc  = G*x - (a1 << 4)*y1 - a2*y2
    ynew = clamp((acc + 2**23) >>> 24, -2**31, 2**31-1)
    y2'  = y1,  y1' = ynew

The old Python side did **not** model this path.  ``fixed_point.FixedModalSynth``
is an A-class polyphonic voice pool (its own allocator, pitch table, kill logic)
and ``sustain_engine.SustainSynth`` is a float periodic-drive synth with vibrato,
noise and note stealing -- neither is the router.  This module is the missing
sample-level model: same integer arithmetic, same 16 slots, same excitation
state machine, same Q1.31 envelope, same Q4.27 body cascade and same comb
reverb.

What is modelled
----------------
``Eng1Core``       ``rtl/router/engines/eng1.sv`` (intended arithmetic)
``ExcitationGen``  ``rtl/router/parts/excitation.sv``
``AdsrEnvelope``   ``rtl/router/parts/envelope.sv`` (intended F08 clamp)
``Envelope('dyn'/'const')``     the other two ``env_router`` modes
``BodyFilter``     ``rtl/router/parts/body_biquad.sv`` + ``body_router`` LUT
``CombReverb``/``ReverbRouter``  ``parts/comb_reverb.sv`` + ``reverb_router``
``RouterEng1``     the per-sample chain: fmap -> hysteresis -> x -> eng1 ->
                   envelope -> sum -> body -> reverb

What is *not* modelled
----------------------
* Cycle timing.  A sample is a sample; the model cannot prove the F07 real-time
  budget.  Use ``tb_throughput`` for that.
* The flash loader and the 64-bit memory addresses.  A slot can be given any
  coefficient triple, which is the data-path contract the loader would have to
  produce (the current loader still fills all slots with the same table, I01).
* The modulation pass.  ``mod_router`` rewrites a1/a2 at note-on; the model
  keeps coefficients static for a note.  (Vibrato is a separate experiment in
  ``vibrato_demo.py``.)
* Voice stealing.  The router has 16 physical slots and no allocator; the
  score renderer refuses to allocate more than ``SLOTS`` simultaneous notes
  unless the caller explicitly asks for a steal.

Known RTL bugs and the two modes
--------------------------------
``rtl_compat=False`` (default) models the *intended* behaviour, including the
fixes described in ``docs/bugs.md``:

* F05 -- the multiplier uses the current mode's state, and ``st_zero`` clears
  every mode.  The RTL currently multiplies with the previous mode's captured
  state and only masks the first captured state.
* F08 -- the attack clamps at ``0x7fffffff`` instead of wrapping negative.
* F09 -- body/reverb products keep the full 96/100-bit result before shifting.

``rtl_compat=True`` reproduces the current RTL where it is inexpensive to do so
(the eng1 state pipeline, F05).  It is a **co-simulation aid**, not the model to
listen to; see ``eng1_cosim.py``.

Formats
-------
==============  ==========================================================
signal          contract
==============  ==========================================================
``x``           signed 32, Q2.30 (1.0 = ``1 << 30``)
``G``           signed 26, Q2.24
``a1``          signed 22, Q2.20; shifted left 4 in the product
``a2``          unsigned 24, UQ0.24
``y1``/``y2``   signed 32, Q2.30
``y``           signed 64, sum of the per-mode ``ynew``
envelope        signed 32, Q1.31 (1.0 = ``0x7fffffff``)
body coefficient signed 32, Q4.27
reverb gain     signed 32, Q4.27
==============  ==========================================================

The model uses Python integers for anything wider than 64 bits (the body
accumulator is 104 bits and the envelope product is 96 bits); ``numpy.int64``
is only used where the RTL word is <= 64 bits and cannot overflow.
"""

from __future__ import annotations

import json
import math
import os
import re
import sys
from dataclasses import dataclass
from typing import Callable, Sequence

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))                 # python/ -> paths
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "fft_analysis"))

import paths  # noqa: E402

# ---------------------------------------------------------------------------
# frozen formats / module constants
# ---------------------------------------------------------------------------
SR = 48_000
SLOTS = 16
N_MODES = 48

#: eng1 state / excitation scale.  ``y1``/``y2``/``x`` are Q2.30.
Y_FRAC = 30
Y_ONE = 1 << Y_FRAC
Y_MIN = -(1 << 31)
Y_MAX = (1 << 31) - 1

#: coefficient scale: the products share 2**(24+30), then shift by 24.
C_FRAC = 24
A1_SHIFT = 4
ENG1_ROUND = 1 << (C_FRAC - 1)

#: envelope Q1.31
ENV_FRAC = 31
ENV_ONE = (1 << 31) - 1

#: body cascade
BODY_FRAC = 27
BODY_GUARD = 4
BODY_TAPS = ("b0", "b1", "b2", "a1", "a2")

#: comb reverb
REV_FRAC = 27
REV_MAX_DELAY = 2048

#: hysteresis thresholds from voice_router.sv
NOTE_ON_TH = 2
NOTE_OFF_TH = 1


# ---------------------------------------------------------------------------
# integer helpers
# ---------------------------------------------------------------------------
def wrap_signed(value: int, bits: int) -> int:
    """Two's-complement truncation to ``bits`` (the SV ``bits'(expr)`` cast)."""
    value = int(value)
    mask = (1 << bits) - 1
    value &= mask
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


def sat_signed(value: int, bits: int) -> int:
    value = int(value)
    lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    return lo if value < lo else hi if value > hi else value


def quant(value, frac: int, bits: int, signed: bool = True) -> np.ndarray:
    """Round-half-up (``floor(v*2**frac + 0.5)``) then clamp, like the RTL table
    generators.  Accepts scalars and arrays; returns ``numpy.int64``."""
    q = np.floor(np.asarray(value, dtype=float) * float(1 << frac) + 0.5)
    q = q.astype(np.int64)
    if signed:
        lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    else:
        lo, hi = 0, (1 << bits) - 1
    return np.clip(q, lo, hi)


def _as_i64(value, length: int | None = None) -> np.ndarray:
    arr = np.asarray(value, dtype=np.int64).reshape(-1)
    if length is not None:
        if arr.size > length:
            arr = arr[:length]
        elif arr.size < length:
            arr = np.pad(arr, (0, length - arr.size))
    return arr


# ---------------------------------------------------------------------------
# coefficient tables
# ---------------------------------------------------------------------------
@dataclass
class Eng1Coeffs:
    """One slot's per-mode coefficients, already in the RTL formats."""

    G: np.ndarray                 # signed Q2.24, 26 bit
    a1: np.ndarray                # signed Q2.20, 22 bit
    a2: np.ndarray                # unsigned UQ0.24, 24 bit
    n_modes: int
    label: str = ""
    #: for the Class-B periodic drive: integer drive period in samples.  ``None``
    #: means "use the instrument's fixed excitation config" (Class A / C).
    drive_period: int | None = None
    #: Class-B player envelope hints taken from the extraction (seconds).  The
    #: router's ``env_router`` uses fixed ADSR constants; these are only used by
    #: the per-note B synth in ``eng1_bc.py``.
    attack_s: float | None = None
    release_s: float | None = None

    def __post_init__(self):
        self.G = _as_i64(self.G)
        self.a1 = _as_i64(self.a1)
        self.a2 = _as_i64(self.a2)
        size = min(self.G.size, self.a1.size, self.a2.size)
        self.G, self.a1, self.a2 = self.G[:size], self.a1[:size], self.a2[:size]
        self.n_modes = int(self.n_modes)
        if size == 0:
            raise ValueError("an Eng1Coeffs table needs at least one mode")
        if not 0 <= self.n_modes <= size:
            raise ValueError(f"n_modes={self.n_modes} outside 0..{size}")
        for name, arr, lo, hi in (
            ("G", self.G, -(1 << 25), (1 << 25) - 1),
            ("a1", self.a1, -(1 << 21), (1 << 21) - 1),
            ("a2", self.a2, 0, (1 << 24) - 1),
        ):
            if arr.size and (arr.min() < lo or arr.max() > hi):
                raise ValueError(
                    f"{name} outside its frozen format: "
                    f"[{arr.min()}, {arr.max()}] not in [{lo}, {hi}]")

    def padded(self, length: int = N_MODES) -> "Eng1Coeffs":
        """Zero-pad to ``length`` modes (unused modes contribute nothing)."""
        length = int(length)
        if length < self.n_modes:
            raise ValueError("padded length shorter than n_modes")
        if self.a1.size > length:
            return Eng1Coeffs(
                G=self.G[:length], a1=self.a1[:length], a2=self.a2[:length],
                n_modes=self.n_modes, label=self.label,
                drive_period=self.drive_period,
                attack_s=self.attack_s, release_s=self.release_s)
        pad = length - self.a1.size
        if pad == 0:
            return self
        return Eng1Coeffs(
            G=np.pad(self.G, (0, pad)),
            a1=np.pad(self.a1, (0, pad)),
            a2=np.pad(self.a2, (0, pad)),
            n_modes=self.n_modes,
            label=self.label,
            drive_period=self.drive_period,
            attack_s=self.attack_s,
            release_s=self.release_s,
        )


_A_TABLE_CACHE: dict[tuple[str, int, str], Eng1Coeffs] = {}
_B_TABLE_CACHE: dict[tuple[str, int, str, float], Eng1Coeffs] = {}


def unpack_core_word(word: int) -> tuple[int, int, int]:
    """72-bit A-class word -> ``(G, a1, a2)``.

    Layout (``class_format_pkg.core_t`` / ``fixed_point.pack_word``)::

        [71:46] G  Q2.24 signed 26
        [45:22] a2 UQ0.24 unsigned 24
        [21:0]  a1 Q2.20 signed 22
    """
    word = int(word)
    G = (word >> 46) & ((1 << 26) - 1)
    if G & (1 << 25):
        G -= 1 << 26
    a2 = (word >> 22) & ((1 << 24) - 1)
    a1 = word & ((1 << 22) - 1)
    if a1 & (1 << 21):
        a1 -= 1 << 22
    return G, a1, a2


def load_a_table(instrument: str, midi: int, dynamic: str = "forte") -> Eng1Coeffs:
    """Load one ``(midi, dynamic)`` row from the frozen A-class 72-bit table.

    The files are the ones written by ``gen_coeff_table.py``:
    ``FFT_results/params/<inst>_coeff.mem`` + ``<inst>_coeffindex.json``.
    """
    key = (str(instrument), int(midi), str(dynamic))
    if key in _A_TABLE_CACHE:
        return _A_TABLE_CACHE[key]

    mem_path = paths.param(instrument, "coeff", "mem")
    idx_path = paths.param(instrument, "coeffindex", "json")
    with open(idx_path, "r", encoding="utf-8") as fh:
        index = json.load(fh)
    entry_key = f"{int(midi)}|{dynamic}"
    if entry_key not in index:
        raise KeyError(f"{instrument}: no coefficient row {entry_key!r}")
    meta = index[entry_key]
    offset, n_modes = int(meta["offset"]), int(meta["n_modes"])
    words = []
    with open(mem_path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                words.append(int(line, 16))
    if offset + n_modes > len(words):
        raise ValueError(
            f"{instrument}: row {entry_key} runs past the end of {mem_path}")
    G, A1, A2 = zip(*(unpack_core_word(w)
                      for w in words[offset:offset + n_modes]))
    table = Eng1Coeffs(
        G=np.asarray(G, dtype=np.int64),
        a1=np.asarray(A1, dtype=np.int64),
        a2=np.asarray(A2, dtype=np.int64),
        n_modes=n_modes,
        label=f"{instrument}:{midi}:{dynamic}",
    )
    _A_TABLE_CACHE[key] = table
    return table


def _steady_amp_unit_q(r: float, theta: float, period: int) -> float:
    """Exact steady amplitude of one quantised resonator at unit G.

    Same expression as ``sustain_engine.steady_amp_unit`` but evaluated with the
    *quantised* pole radius/frequency, so the table calibration matches what the
    integer recursion will actually do.
    """
    j = np.arange(max(2, int(math.floor(period))), dtype=float)
    R = r ** period
    phi = theta * period
    denom = 1.0 - R * np.exp(1j * phi)
    alpha = theta * (j + 1.0)
    amp = (r ** j) * np.abs(np.imag(np.exp(1j * alpha) / denom))
    return float(amp.max() / max(abs(math.sin(theta)), 1e-9))


def build_b_table(instrument: str, midi: int, dynamic: str = "forte",
                  gamma_scale: float = 1.0) -> Eng1Coeffs:
    """Build a Class-B ``Eng1Coeffs`` from the extracted sustained table.

    The drive is one unit impulse every ``T = round(sr/f0)`` samples, so the modes
    are placed on the *integer drive rate* ``sr/T`` (not on ``f0``) and the gain is
    calibrated from the quantised poles: ``G = w / A_unit``.  This is the same
    calibration as ``SustainSynth``, but done after quantisation and written into
    eng1's Q2.24 ``G``.
    """
    key = (str(instrument), int(midi), str(dynamic), float(gamma_scale))
    if key in _B_TABLE_CACHE:
        return _B_TABLE_CACHE[key]

    from sustain_engine import SustainPatch          # scipy import inside the call
    import core as CORE

    cached = getattr(build_b_table, "_patch", None)
    if cached is None or cached[0] != (instrument, gamma_scale):
        patch = SustainPatch(instrument, gamma_scale=gamma_scale)
        build_b_table._patch = ((instrument, gamma_scale), patch)
    else:
        patch = cached[1]
    kk, g, w, _atk, _rel, _ndb, _nwin = patch.modes(midi, dynamic)
    f0 = CORE.midi_to_hz(midi)
    period = max(2, int(round(SR / f0)))
    f_drive = SR / period
    f = kk * f_drive
    theta = 2.0 * np.pi * f / SR
    r = np.exp(-g / SR)

    a1f = -2.0 * r * np.cos(theta)
    a2f = r * r
    a1q = quant(a1f, 20, 22, signed=True)
    a2q = quant(a2f, 24, 24, signed=False)

    rq = np.sqrt(a2q.astype(float) / float(1 << 24))
    cq = np.clip(-(a1q.astype(float) / float(1 << 20)) /
                 np.maximum(2.0 * rq, 1e-12), -1.0, 1.0)
    thq = np.arccos(cq)
    Gq = np.empty(kk.size, dtype=np.int64)
    for i, (wi, ri, ti) in enumerate(zip(w, rq, thq)):
        a_unit = _steady_amp_unit_q(float(ri), float(ti), period)
        Gq[i] = int(quant(wi / max(a_unit, 1e-12), 24, 26, signed=True))

    table = Eng1Coeffs(G=Gq, a1=a1q, a2=a2q, n_modes=kk.size,
                       label=f"{instrument}:{midi}:{dynamic}",
                       drive_period=period,
                       attack_s=float(_atk), release_s=float(_rel))
    _B_TABLE_CACHE[key] = table
    return table


# ---------------------------------------------------------------------------
# eng1 core
# ---------------------------------------------------------------------------
class Eng1Core:
    """One eng1 job = one sample for every slot.  State lives in ``self``.

    The intended path loops over every array entry (the RTL gets one global
    ``n_modes`` and relies on the rest of the table being zero).  ``load_slot``
    applies ``Eng1Coeffs.padded`` so unused modes are exactly zero; callers that
    poke ``G``/``y1`` directly must keep that invariant.  ``rtl_compat`` instead
    uses the per-slot ``nm`` count, including the IW-bit truncation.
    """

    def __init__(self, slots: int = SLOTS, n_modes: int = N_MODES,
                 rtl_compat: bool = False):
        self.slots = int(slots)
        self.n_modes = int(n_modes)
        self.rtl_compat = bool(rtl_compat)
        self.IW = max(1, (self.n_modes - 1).bit_length()) if self.n_modes > 1 else 1
        self.reset()

    def reset(self):
        self.G = np.zeros((self.slots, self.n_modes), dtype=np.int64)
        self.a1 = np.zeros((self.slots, self.n_modes), dtype=np.int64)
        self.a2 = np.zeros((self.slots, self.n_modes), dtype=np.int64)
        self.nm = np.zeros(self.slots, dtype=np.int64)
        self.y1 = np.zeros((self.slots, self.n_modes), dtype=np.int64)
        self.y2 = np.zeros((self.slots, self.n_modes), dtype=np.int64)
        # RTL's ``y1_cur/y2_cur``: they are *not* reset in S_IDLE, which is the
        # cross-job leak F05 describes.  Kept only for rtl_compat.
        self._rtl_y1 = np.zeros(self.slots, dtype=np.int64)
        self._rtl_y2 = np.zeros(self.slots, dtype=np.int64)

    # ------------------------------------------------------------------
    def load_slot(self, slot: int, table: Eng1Coeffs, zero_state: bool = True):
        slot = int(slot)
        if not 0 <= slot < self.slots:
            raise IndexError(f"slot {slot} outside 0..{self.slots - 1}")
        t = table.padded(self.n_modes)
        self.G[slot] = t.G
        self.a1[slot] = t.a1
        self.a2[slot] = t.a2
        self.nm[slot] = t.n_modes
        if zero_state:
            self.y1[slot] = 0
            self.y2[slot] = 0
            self._rtl_y1[slot] = 0
            self._rtl_y2[slot] = 0

    def clear_slot(self, slot: int):
        slot = int(slot)
        self.y1[slot] = 0
        self.y2[slot] = 0
        self._rtl_y1[slot] = 0
        self._rtl_y2[slot] = 0

    # ------------------------------------------------------------------
    def step(self, x, st_zero=None):
        """Run one sample for all slots.  Returns ``(y_slots, ynew)``.

        ``x``       : signed Q2.30 per slot (32-bit range)
        ``st_zero`` : bool per slot; in the intended model it clears the whole
                      slot *before* the recursion, in ``rtl_compat`` it only
                      masks the first captured state (F05).
        """
        x = _as_i64(x, self.slots)
        if st_zero is None:
            st_zero = np.zeros(self.slots, dtype=bool)
        else:
            st_zero = np.asarray(st_zero, dtype=bool).reshape(-1)
            if st_zero.size != self.slots:
                raise ValueError("st_zero must have one entry per slot")
        if self.rtl_compat:
            return self._step_rtl(x, st_zero)

        if st_zero.any():
            self.y1[st_zero] = 0
            self.y2[st_zero] = 0
        acc = (self.G * x[:, None]
               - (self.a1 << A1_SHIFT) * self.y1
               - self.a2 * self.y2)
        yn = (acc + ENG1_ROUND) >> C_FRAC
        yn = np.clip(yn, Y_MIN, Y_MAX)
        self.y2[:] = self.y1
        self.y1[:] = yn
        y = yn.sum(axis=1, dtype=np.int64)
        return y, yn

    def _rtl_nmodes(self, slot: int) -> int:
        n = int(self.nm[slot])
        # eng1.sv: ``nmod_lat <= n_modes[IW-1:0]`` -- a full 64/128 count is
        # truncated to zero.  Reproduce only in rtl_compat mode.
        if self.rtl_compat:
            # S_IDLE -> S_RD -> S_MUL always runs mode 0; the ``mi_q+1 >=
            # nmod_lat`` end test only happens in S_WB.  So a truncated zero
            # count still processes one mode.
            n = max(1, n & ((1 << self.IW) - 1))
        return max(0, min(n, self.n_modes))

    def _step_rtl(self, x: np.ndarray, st_zero: np.ndarray):
        """Current RTL pipeline, including the F05 previous-mode multiplier."""
        y_out = np.zeros(self.slots, dtype=np.int64)
        ynew = np.zeros_like(self.y1)
        for s in range(self.slots):
            n = self._rtl_nmodes(s)
            first_done = False
            acc_slot = 0
            for m in range(n):
                mul_y1 = int(self._rtl_y1[s])
                mul_y2 = int(self._rtl_y2[s])
                cap_y1 = 0 if (st_zero[s] and not first_done) else int(self.y1[s, m])
                cap_y2 = 0 if (st_zero[s] and not first_done) else int(self.y2[s, m])
                acc = (int(self.G[s, m]) * int(x[s])
                       - int(self.a1[s, m] << A1_SHIFT) * mul_y1
                       - int(self.a2[s, m]) * mul_y2)
                yn = (acc + ENG1_ROUND) >> C_FRAC
                yn = sat_signed(yn, 32)
                # S_WB: q' = ynew, qdot' = captured q (not the old qdot)
                self.y1[s, m] = yn
                self.y2[s, m] = cap_y1
                self._rtl_y1[s] = cap_y1
                self._rtl_y2[s] = cap_y2
                ynew[s, m] = yn
                first_done = True
                acc_slot += yn
            y_out[s] = wrap_signed(acc_slot, 64)
        return y_out, ynew


# ---------------------------------------------------------------------------
# excitation
# ---------------------------------------------------------------------------
@dataclass
class ExcitationConfig:
    """The four parameters ``exc_router`` passes to ``excitation_gen``."""

    shift: int = 20
    pw_len: int = 1
    gap_len: int = 0
    n_pulse: int = 0

    @classmethod
    def guitar(cls) -> "ExcitationConfig":
        # exc_router: GUITAR SHIFT=18, PW_LEN=2, single pulse
        return cls(shift=18, pw_len=2, gap_len=0, n_pulse=0)

    @classmethod
    def sustained(cls, period: int, shift: int = 22) -> "ExcitationConfig":
        # B/PAD: an impulse every ``period`` samples, held while the key is down.
        # SHIFT=22 maps an 8-bit fmap=255 to ~1.0 in Q2.30, which is the scale
        # the B-table gain calibration assumes.
        return cls(shift=int(shift), pw_len=1,
                   gap_len=max(0, int(period) - 1), n_pulse=7)


class ExcitationGen:
    """``rtl/router/parts/excitation.sv`` as a per-sample function."""

    X_IDLE, X_HIGH, X_GAP = 0, 1, 2

    def __init__(self, slots: int = SLOTS, config: ExcitationConfig | None = None):
        self.slots = int(slots)
        self.config = config or ExcitationConfig()
        self.reset()

    def reset(self):
        self.state = np.zeros(self.slots, dtype=np.int8)
        self.cnt = np.zeros(self.slots, dtype=np.int64)
        self.num = np.zeros(self.slots, dtype=np.int64)
        self.note_q = np.zeros(self.slots, dtype=bool)

    def set_config(self, config: ExcitationConfig):
        self.config = config

    def _more_pulse(self, num: int) -> bool:
        return self.config.n_pulse == 7 or num <= self.config.n_pulse

    def _level(self, fmap: int) -> int:
        return wrap_signed(int(fmap) << int(self.config.shift), 32)

    def step(self, fmap, note_on, clear: bool = False):
        fmap = _as_i64(fmap, self.slots)
        note_on = np.asarray(note_on, dtype=bool).reshape(-1)
        if note_on.size != self.slots:
            raise ValueError("note_on must have one entry per slot")
        cfg = self.config
        x = np.zeros(self.slots, dtype=np.int64)
        for i in range(self.slots):
            on = bool(note_on[i])
            if clear:
                self.state[i] = self.X_IDLE
                self.cnt[i] = 0
                self.num[i] = 0
                x[i] = 0
                continue
            if on and not self.note_q[i]:
                # rising edge: this sample is pulse sample #1
                self.state[i] = self.X_HIGH
                self.cnt[i] = 1
                self.num[i] = 1
                x[i] = self._level(fmap[i])
                continue
            st = int(self.state[i])
            if st == self.X_IDLE:
                x[i] = 0
                self.cnt[i] = 0
                self.num[i] = 0
            elif st == self.X_HIGH:
                if self.cnt[i] >= cfg.pw_len:
                    self.cnt[i] = 0
                    if not on:
                        self.state[i] = self.X_IDLE
                        self.num[i] = 0
                        x[i] = 0
                    elif cfg.gap_len == 0:
                        if self._more_pulse(int(self.num[i])):
                            self.num[i] += 1
                            x[i] = self._level(fmap[i])
                        else:
                            self.state[i] = self.X_IDLE
                            self.num[i] = 0
                            x[i] = 0
                    else:
                        self.state[i] = self.X_GAP
                        self.cnt[i] = 1
                        x[i] = 0
                else:
                    x[i] = self._level(fmap[i])
                    self.cnt[i] += 1
            elif st == self.X_GAP:
                if not on:
                    x[i] = 0
                    self.state[i] = self.X_IDLE
                    self.num[i] = 0
                elif self.cnt[i] >= cfg.gap_len:
                    if self._more_pulse(int(self.num[i])):
                        self.num[i] += 1
                        self.state[i] = self.X_HIGH
                        self.cnt[i] = 1
                        x[i] = self._level(fmap[i])
                    else:
                        self.state[i] = self.X_IDLE
                        self.num[i] = 0
                        self.cnt[i] = 0
                        x[i] = 0
                else:
                    x[i] = 0
                    self.cnt[i] += 1
        self.note_q = note_on.copy()
        return x


# ---------------------------------------------------------------------------
# envelopes
# ---------------------------------------------------------------------------
class AdsrEnvelope:
    """``envelope_ADSR`` with the intended F08 attack clamp.

    The RTL's attack test ``lvl + A_STEP < lvl`` only catches 32-bit wraparound;
    it misses the signed positive overflow at ``0x80000000``.  The intended
    arithmetic is a 33-bit sum clamped to ``0x7fffffff`` followed by E_DEC.
    """

    E_IDLE, E_ATK, E_DEC, E_SUS, E_REL = range(5)

    def __init__(self, slots: int = SLOTS,
                 a_step: int = 16_777_216,
                 d_step: int = 1_048_576,
                 s_level: int = 536_870_912,
                 r_step: int = 1_048_576):
        self.slots = int(slots)
        self.a_step = int(a_step)
        self.d_step = int(d_step)
        self.s_level = int(s_level)
        self.r_step = int(r_step)
        self.reset()

    def reset(self):
        self.state = np.full(self.slots, self.E_IDLE, dtype=np.int8)
        self.lvl = np.zeros(self.slots, dtype=np.int64)
        self.note_on_q = np.zeros(self.slots, dtype=bool)

    def set_params(self, a_step=None, d_step=None, s_level=None, r_step=None):
        if a_step is not None:
            self.a_step = int(a_step)
        if d_step is not None:
            self.d_step = int(d_step)
        if s_level is not None:
            self.s_level = int(s_level)
        if r_step is not None:
            self.r_step = int(r_step)

    def step(self, note_on):
        note_on = np.asarray(note_on, dtype=bool).reshape(-1)
        if note_on.size != self.slots:
            raise ValueError("note_on must have one entry per slot")
        onset = note_on & ~self.note_on_q
        for i in range(self.slots):
            if onset[i]:
                self.lvl[i] = 0
                self.state[i] = self.E_ATK
            elif not note_on[i]:
                if self.lvl[i] <= self.r_step:
                    self.lvl[i] = 0
                    self.state[i] = self.E_IDLE
                else:
                    self.lvl[i] -= self.r_step
                    self.state[i] = self.E_REL
            else:
                st = int(self.state[i])
                if st == self.E_IDLE:
                    if note_on[i]:
                        self.state[i] = self.E_ATK
                elif st == self.E_ATK:
                    nxt = int(self.lvl[i]) + self.a_step
                    if nxt >= ENV_ONE:
                        self.lvl[i] = ENV_ONE
                        self.state[i] = self.E_DEC
                    else:
                        self.lvl[i] = nxt
                elif st == self.E_DEC:
                    if self.lvl[i] <= self.s_level + self.d_step:
                        self.lvl[i] = self.s_level
                        self.state[i] = self.E_SUS
                    else:
                        self.lvl[i] -= self.d_step
                elif st == self.E_SUS:
                    pass
                elif st == self.E_REL:
                    self.state[i] = self.E_IDLE
        self.note_on_q = note_on.copy()
        return self.lvl.astype(np.int64)


class Envelope:
    """``env_router``'s three modes behind one call."""

    MODES = ("adsr", "dyn", "const")

    def __init__(self, mode: str = "adsr", slots: int = SLOTS, **params):
        self.slots = int(slots)
        self.mode = str(mode).lower()
        if self.mode not in self.MODES:
            raise ValueError(f"envelope mode must be one of {self.MODES}")
        self.adsr = AdsrEnvelope(slots=slots, **params) if self.mode == "adsr" else None

    def reset(self):
        if self.adsr is not None:
            self.adsr.reset()

    def set_params(self, **params):
        if self.adsr is not None:
            self.adsr.set_params(**params)

    def step(self, fmap, note_on):
        note_on = np.asarray(note_on, dtype=bool).reshape(-1)
        if self.mode == "adsr":
            return self.adsr.step(note_on)
        fmap = _as_i64(fmap, self.slots)
        if self.mode == "dyn":
            # envelope_dyn0: Q1.31 pressure, gated
            v = np.where(note_on, fmap << 23, 0)
            return np.clip(v, 0, ENV_ONE).astype(np.int64)
        return np.full(self.slots, ENV_ONE, dtype=np.int64)


# ---------------------------------------------------------------------------
# body filter
# ---------------------------------------------------------------------------
def _read_body_router_case(instrument: str) -> list[list[int]] | None:
    """Parse ``body_router.sv``'s constant LUT for one instrument.

    Keeping the coefficients in one place avoids a silent drift between the RTL
    and the Python audio model.  ``None`` means the RTL case is empty (the
    instrument is a passthrough by construction).
    """
    path = os.path.join(ROOT, "rtl", "router", "routers", "body_router.sv")
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    inst = {
        "guitar": "INST_GUITAR",
        "bass": "INST_BASS",
        "piano": "INST_PIANO",
    }.get(str(instrument).lower())
    if inst is None:
        return None
    start = text.find(f"router_pkg::{inst}:")
    if start < 0:
        return None
    rest = text[start + len(f"router_pkg::{inst}:"):]
    stops = [m.start() for m in re.finditer(r"router_pkg::INST_[A-Z_]+:", rest)]
    stops += [m.start() for m in re.finditer(r"\bdefault\s*:", rest)]
    if stops:
        rest = rest[:min(stops)]
    rows: list[list[int]] = []
    for m in re.finditer(
            r"coef_q\[\s*(\d+)\s*\]\s*=\s*(-?)\s*32'sd\s*(\d+)\s*;", rest):
        idx = int(m.group(1))
        val = int(m.group(3))
        if m.group(2) == "-":
            val = -val
        while len(rows) * 5 <= idx:
            rows.append([])
        rows[idx // 5].append(val)
    if not rows:
        return None
    return rows


def body_coeffs(instrument: str = "guitar") -> list[list[int]]:
    """Q4.27 rows for ``body_router``; missing instruments become passthrough."""
    rows = _read_body_router_case(instrument)
    if rows is None:
        rows = [[1 << BODY_FRAC, 0, 0, 0, 0] for _ in range(5)]
    # body_router always emits exactly 5 sections; pad/truncate defensively.
    while len(rows) < 5:
        rows.append([1 << BODY_FRAC, 0, 0, 0, 0])
    rows = rows[:5]
    for r in rows:
        if len(r) != 5:
            raise ValueError(f"body_router_{instrument}: malformed section {r!r}")
    return rows


class BodyFilter:
    """Thin wrapper around ``body_fixed_point.BodyFixedPoint``.

    ``BodyFixedPoint`` already implements the *intended* full-width products and
    the 104-bit accumulator, so the audio model and ``tb_body_biquad`` share one
    arithmetic contract.
    """

    def __init__(self, coeffs=None, instrument: str = "guitar"):
        from body_fixed_point import BodyFixedPoint
        self.coeffs = [list(map(int, r)) for r in
                       (coeffs if coeffs is not None else body_coeffs(instrument))]
        self.core = BodyFixedPoint(coeffs=self.coeffs)
        self.sat_total = 0

    def reset(self):
        self.core.reset()
        self.sat_total = 0

    def step(self, x: int):
        y, mask, nsat = self.core.process_sample(int(x))
        self.sat_total += int(nsat)
        return y, int(mask), int(nsat)


# ---------------------------------------------------------------------------
# reverb
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class ReverbPreset:
    lengths: tuple[int, int, int, int]
    feedback: tuple[int, int, int, int]
    weight: tuple[int, int, int, int]
    dry: int
    wet: int


#: Mirrors ``reverb_router.sv``.  Q4.27 constants kept as integers on purpose.
#: The RTL table is the source of truth: if those literals change, update this
#: dict (and the HALL/BATHROOM test expectations) in the same commit.
_REV_Q_ONE = 1 << REV_FRAC
REVERB_PRESETS: dict[str, ReverbPreset] = {
    "NONE": ReverbPreset((1, 1, 1, 1), (0, 0, 0, 0), (0, 0, 0, 0),
                         _REV_Q_ONE, 0),
    "HALL": ReverbPreset(
        (1214, 1293, 1390, 1476), (120795955,) * 4, (33554432,) * 4,
        93952410, 67108864),
    "BATHROOM": ReverbPreset(
        (557, 613, 691, 743), (110058537,) * 4, (33554432,) * 4,
        107374182, 53687091),
}


class CombReverb:
    """Four parallel comb lines, sample-level, intended full-width products."""

    def __init__(self, n: int = REV_MAX_DELAY, g_frac: int = REV_FRAC):
        self.n = int(n)
        self.g_frac = int(g_frac)
        self.buf = [np.zeros(self.n, dtype=np.int64) for _ in range(4)]
        self.reset()

    def reset(self):
        for b in self.buf:
            b.fill(0)
        self.p = [0, 0, 0, 0]
        self.clr_run = True
        self.clr_cnt = 0

    def step(self, in_data: int, lengths: Sequence[int],
             feedback: Sequence[int], weights: Sequence[int]) -> int:
        din = int(in_data)
        taps = [0, 0, 0, 0]
        for k in range(4):
            p = self.p[k]
            s = 0 if self.clr_run else int(self.buf[k][p])
            fb = (s * int(feedback[k])) >> self.g_frac
            t = (s * int(weights[k])) >> self.g_frac
            # C stage: write din + fb with 65-bit saturation
            self.buf[k][p] = sat_signed(din + fb, 64)
            n = int(lengths[k])
            self.p[k] = 0 if p + 1 >= n else p + 1
            taps[k] = wrap_signed(t, 64)
        wet = wrap_signed(sum(taps), 64)
        if self.clr_run:
            if self.clr_cnt == self.n - 1:
                self.clr_run = False
            else:
                self.clr_cnt += 1
        return wet


class ReverbRouter:
    """``reverb_router.sv``: preset -> wet comb + dry/wet mix."""

    def __init__(self, preset: str = "NONE", n: int = REV_MAX_DELAY):
        self.comb = CombReverb(n=n)
        self.preset = "NONE"
        self.configure(preset)

    def configure(self, preset: str):
        name = str(preset).upper()
        if name not in REVERB_PRESETS:
            raise KeyError(f"unknown reverb preset {preset!r}")
        self.preset = name
        self.params = REVERB_PRESETS[name]
        self.comb.reset()

    def reset(self):
        self.comb.reset()

    def step(self, x: int) -> int:
        p = self.params
        wet = self.comb.step(int(x), p.lengths, p.feedback, p.weight)
        # intended F09: keep the full-width products before the Q4.27 shift.
        # The RTL truncates (``>>>``); so does this model -- only the product
        # width is fixed here, not the rounding rule.
        dry = int(x) * p.dry
        wets = wet * p.wet
        return wrap_signed((dry + wets) >> REV_FRAC, 64)


# ---------------------------------------------------------------------------
# full router chain
# ---------------------------------------------------------------------------
@dataclass
class Frame:
    out: int                 # y_data after reverb
    mix: int                 # y_acc before body
    x: np.ndarray            # per-slot excitation
    emap: np.ndarray         # per-slot Q1.31 envelope
    y: np.ndarray            # per-slot 64-bit engine sum
    note_on: np.ndarray
    body_sat: int = 0


class RouterEng1:
    """The per-sample chained model.  No score logic, no allocation."""

    def __init__(self, *, slots: int = SLOTS, n_modes: int = N_MODES,
                 body: str = "guitar", reverb: str = "NONE",
                 envelope: str = "adsr", envelope_params: dict | None = None,
                 excitation: ExcitationConfig | None = None,
                 rtl_compat: bool = False):
        self.slots = int(slots)
        self.core = Eng1Core(slots=slots, n_modes=n_modes, rtl_compat=rtl_compat)
        self.exc = ExcitationGen(slots=slots, config=excitation or ExcitationConfig())
        self.env = Envelope(mode=envelope, slots=slots, **(envelope_params or {}))
        self.body = BodyFilter(instrument=body)
        self.rev = ReverbRouter(reverb)
        self.reset()

    # ------------------------------------------------------------------
    def reset(self):
        self.core.reset()
        self.exc.reset()
        self.env.reset()
        self.body.reset()
        self.rev.reset()
        self.fmap = np.zeros(self.slots, dtype=np.int64)
        self.gate_r = np.zeros(self.slots, dtype=bool)
        self.note_on_q = np.zeros(self.slots, dtype=bool)
        self.dead_q = np.zeros(self.slots, dtype=bool)

    def set_slot(self, slot: int, coeffs: Eng1Coeffs):
        self.core.load_slot(slot, coeffs)

    def set_excitation(self, config: ExcitationConfig):
        self.exc.set_config(config)

    def set_envelope(self, **params):
        self.env.set_params(**params)

    def gate_off(self, slot: int):
        self.fmap[int(slot)] = 0

    def gate_on(self, slot: int, fmap: int):
        self.fmap[int(slot)] = max(0, min(255, int(fmap)))

    # ------------------------------------------------------------------
    def step(self, clear: bool = False) -> Frame:
        # 1) hysteresis + edge, exactly voice_router.sv
        note_on = np.where(self.gate_r,
                           self.fmap >= NOTE_OFF_TH,
                           self.fmap > NOTE_ON_TH)
        note_ev = note_on & ~self.note_on_q

        # 2) excitation and envelope at this sample
        x = self.exc.step(self.fmap, note_on, clear=clear)
        emap = self.env.step(self.fmap, note_on)

        # 3) st_zero: note-on frame or the frame the envelope just hit zero
        dead = emap < 1
        dead_ev = dead & ~self.dead_q
        zero = note_ev | dead_ev

        # 4) eng1
        y, _ = self.core.step(x, zero)

        # 5) per-slot Q1.31 multiply, then the 64-bit sum
        y_env = [_wrap_mul_shift(int(y[i]), int(emap[i]), ENV_FRAC)
                 for i in range(self.slots)]
        mix = wrap_signed(sum(y_env), 64)

        # 6) body -> reverb
        body_y, _body_mask, body_sat = self.body.step(mix)
        out = self.rev.step(body_y)

        self.gate_r = note_on.copy()
        self.note_on_q = note_on.copy()
        self.dead_q = dead.copy()
        return Frame(out=out, mix=mix, x=x, emap=emap, y=y,
                     note_on=note_on, body_sat=body_sat)


def _wrap_mul_shift(a: int, b: int, shift: int) -> int:
    """``(a*b) >>> shift`` truncated back to signed 64 (the RTL ``y_env``)."""
    return wrap_signed((int(a) * int(b)) >> shift, 64)


# ---------------------------------------------------------------------------
# score rendering
# ---------------------------------------------------------------------------
@dataclass
class NoteEvent:
    t: float
    midi: int
    dur: float
    vel: float = 0.8
    dyn: str = "forte"


@dataclass
class RenderMeta:
    samples: int
    raw_peak: int
    raw_rms: float
    body_sat: int
    notes: int
    reverb: str
    warnings: list[str]

    def as_dict(self) -> dict:
        return {
            "samples": self.samples,
            "raw_peak_q30": self.raw_peak,
            "raw_peak": self.raw_peak / float(Y_ONE),
            "raw_rms_q30": self.raw_rms,
            "raw_rms": self.raw_rms / float(Y_ONE),
            "body_sat": self.body_sat,
            "notes": self.notes,
            "reverb": self.reverb,
            "warnings": self.warnings,
        }


class ScoreRenderer:
    """Allocate score notes to slots and drive ``RouterEng1`` sample by sample.

    The router itself has no allocator (the pad is 16 physical slots).  This
    renderer is deliberately conservative: it only reuses a slot after at least
    one sample with ``fmap == 0``, so every note gets a real rising edge.  It
    raises when a score asks for more than ``slots`` simultaneous notes.
    """

    def __init__(self, table_fn: Callable[[int, str], Eng1Coeffs], *,
                 slots: int = SLOTS, n_modes: int = N_MODES,
                 body: str = "guitar", reverb: str = "NONE",
                 envelope: str = "adsr", envelope_params: dict | None = None,
                 excitation_fn: Callable[[Eng1Coeffs], ExcitationConfig] | None = None,
                 tail_s: float = 0.5, rtl_compat: bool = False):
        self.table_fn = table_fn
        self.slots = int(slots)
        self.tail_s = float(tail_s)
        self.router = RouterEng1(
            slots=slots, n_modes=n_modes, body=body, reverb=reverb,
            envelope=envelope, envelope_params=envelope_params,
            rtl_compat=rtl_compat)
        self.excitation_fn = excitation_fn or _default_excitation
        self._reset_slots()

    def _reset_slots(self):
        self.note = [None] * self.slots
        self.off_at = [-1] * self.slots
        self.last_off = [-10] * self.slots
        self._period: dict[int, int] = {}

    # ------------------------------------------------------------------
    def _table_for(self, ev: NoteEvent) -> Eng1Coeffs:
        return self.table_fn(int(ev.midi), str(ev.dyn))

    def render(self, notes: Sequence[NoteEvent], seconds: float | None = None):
        notes = sorted(notes, key=lambda n: (n.t, n.midi))
        if not notes:
            raise ValueError("empty score")
        total = seconds if seconds is not None else (
            max(n.t + n.dur for n in notes) + self.tail_s)
        n_samples = max(1, int(round(float(total) * SR)))
        ons: dict[int, list[NoteEvent]] = {}
        offs: dict[int, list[int]] = {}
        for ev in notes:
            i0 = max(0, int(round(ev.t * SR)))
            i1 = max(i0 + 1, int(round((ev.t + ev.dur) * SR)))
            ons.setdefault(i0, []).append(ev)
            offs.setdefault(i1, []).append(id(ev))

        warnings: list[str] = []
        out = np.zeros(n_samples, dtype=np.int64)
        self.router.reset()
        self._reset_slots()

        for i in range(n_samples):
            # 1) note-offs first, so a slot can be released on this sample
            for nid in offs.get(i, ()):
                slot = self._slot_of(nid)
                if slot is None:
                    continue
                self.router.gate_off(slot)
                self._period.pop(nid, None)
                self.note[slot] = None
                self.off_at[slot] = i
                self.last_off[slot] = i

            # 2) note-ons: a slot needs one clean sample since its last release
            for ev in ons.get(i, ()):
                slot = self._alloc_slot(i)
                table = self._table_for(ev)
                self.router.set_slot(slot, table)
                cfg = self.excitation_fn(table)
                self.router.set_excitation(cfg)
                self.router.gate_on(slot, max(1, int(round(float(ev.vel) * 255.0))))
                self.note[slot] = id(ev)
                self.off_at[slot] = -1
                self._period[id(ev)] = int(table.drive_period or -1)
                if len({p for p in self._period.values() if p > 0}) > 1:
                    warnings.append(
                        "overlapping Class-B notes with different drive "
                        "periods: the RTL excitation config is global")

            frame = self.router.step()
            out[i] = frame.out

        peak = int(np.max(np.abs(out))) if out.size else 0
        rms = float(np.sqrt(np.mean(out.astype(np.float64) ** 2))) if out.size else 0.0
        meta = RenderMeta(
            samples=n_samples, raw_peak=peak, raw_rms=rms,
            body_sat=self.router.body.sat_total, notes=len(notes),
            reverb=self.router.rev.preset,
            warnings=sorted(set(warnings)))
        return out, meta

    # ------------------------------------------------------------------
    def _slot_of(self, nid: int) -> int | None:
        for s, n in enumerate(self.note):
            if n == nid:
                return s
        return None

    def _alloc_slot(self, i: int) -> int:
        # prefer the first slot that has been quiet for at least one sample
        for s in range(self.slots):
            if self.note[s] is None and i - self.last_off[s] >= 1:
                return s
        # a slot released on this very sample is not reusable yet (no edge);
        # pick a truly idle one, else report a real polyphony overflow.
        for s in range(self.slots):
            if self.note[s] is None and self.off_at[s] < 0:
                return s
        raise RuntimeError(
            f"score needs more than {self.slots} simultaneous notes; "
            "the router has no voice allocator")


def _default_excitation(table: Eng1Coeffs) -> ExcitationConfig:
    if table.drive_period:
        return ExcitationConfig.sustained(table.drive_period)
    return ExcitationConfig.guitar()


# ---------------------------------------------------------------------------
# convenience table providers
# ---------------------------------------------------------------------------
class ATable:
    """Callable provider for the frozen A-class tables."""

    def __init__(self, instrument: str):
        self.instrument = str(instrument)

    def __call__(self, midi: int, dynamic: str = "forte") -> Eng1Coeffs:
        return load_a_table(self.instrument, midi, dynamic)


class BTable:
    """Callable provider for the extracted Class-B sustain tables."""

    def __init__(self, instrument: str, gamma_scale: float = 1.0):
        self.instrument = str(instrument)
        self.gamma_scale = float(gamma_scale)

    def __call__(self, midi: int, dynamic: str = "forte") -> Eng1Coeffs:
        return build_b_table(self.instrument, midi, dynamic, self.gamma_scale)


__all__ = [
    "SR", "SLOTS", "N_MODES", "Y_FRAC", "Y_ONE", "ENV_ONE",
    "Eng1Coeffs", "Eng1Core", "ExcitationConfig", "ExcitationGen",
    "AdsrEnvelope", "Envelope", "BodyFilter", "body_coeffs",
    "CombReverb", "ReverbRouter", "REVERB_PRESETS",
    "RouterEng1", "Frame", "NoteEvent", "ScoreRenderer", "RenderMeta",
    "load_a_table", "build_b_table", "ATable", "BTable",
    "unpack_core_word", "quant", "wrap_signed", "sat_signed",
]
