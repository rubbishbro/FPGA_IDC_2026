"""Fixed-point (integer) reference model -- verification chain step 2.

This is the *table-driven* renderer described in ``rtl/DECISIONS.md`` section D:

    1. float ``engine.ModalSynth``        <- already verified reference
    2. this module (only reads a1,a2,G)   <- RTL must match this, bit for bit
    3. RTL

Formats are the ones frozen in ``rtl/DECISIONS.md`` section C:

    a1   Q2.20    signed    22 bit
    a2   UQ0.24   unsigned  24 bit
    G    Q2.24    signed    26 bit
    y    Q2.30    signed    32 bit   (state, widened from 24 frac to kill the
                                      fixed-point DC trap; two packed into 64 bit)
    x    Q2.30    signed    32 bit   (excitation shares the state scale)
    acc  64 bit                       (26x32 products; see DECISIONS G1)

Rationale for FS=30 (state 32-bit): the direct-form recursion has a non-zero fixed
point at c_max = 2^23 / (1+a1+a2) code units.  At FS=24 that is up to -52.6 dBFS --
above ``free_thr`` -- so a voice traps and never reclaims.  At FS=30 the worst trap is
-88.7 dBFS, below free_thr, so reclaim works.  The coefficient formats (72-bit word)
are unchanged.

The audio datapath is pure integer arithmetic.  Control quantities that are not part
of the audio path (the ``level`` envelope follower used for voice stealing) stay float,
because the RTL may implement them however it likes as long as the *audio* matches.

Only the modal bank is modelled here.  The shared body filter and the noise burst are
separate modules (their fixed-point format is not frozen yet), so this model is compared
against ``ModalSynth.step()``, which returns the pre-body modal sum.
"""

from __future__ import annotations

import numpy as np

SR = 48_000

# ---------------------------------------------------------------------------
# frozen formats (rtl/DECISIONS.md section C)
# ---------------------------------------------------------------------------
A1_BITS, A1_FRAC = 22, 20          # Q2.20 signed
A2_BITS, A2_FRAC = 24, 24          # UQ0.24 unsigned
G_BITS, G_FRAC = 26, 24            # Q2.24 signed
Y_BITS, Y_FRAC = 32, 30            # Q2.30 signed (state)  -- widened from 26/24
X_FRAC = Y_FRAC                    # excitation shares the state scale (2^30)
ACC_BITS = 64                      # products are 26x32=58 bit; sum ~60, +round

C_FRAC = 24                        # coefficient fractional bits (a2/G; a1 rescaled to it)
A1_SHIFT = C_FRAC - A1_FRAC        # 4: a1 Q2.20 -> 2^24 so every product shares 2^(24+FS)

Y_MIN, Y_MAX = -(1 << (Y_BITS - 1)), (1 << (Y_BITS - 1)) - 1
A1_MIN, A1_MAX = -(1 << (A1_BITS - 1)), (1 << (A1_BITS - 1)) - 1
G_MIN, G_MAX = -(1 << (G_BITS - 1)), (1 << (G_BITS - 1)) - 1
A2_MAX = (1 << A2_BITS) - 1

WORD_BITS = A1_BITS + A2_BITS + G_BITS          # 72
WORD_MASK = (1 << WORD_BITS) - 1


# ---------------------------------------------------------------------------
# quantisers ("round half up", then clamp) -- one definition, used everywhere
# ---------------------------------------------------------------------------
def quant(arr, frac: int, bits: int, signed: bool = True) -> np.ndarray:
    s = float(1 << frac)
    q = np.floor(np.asarray(arr, dtype=float) * s + 0.5).astype(np.int64)
    if signed:
        lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    else:
        lo, hi = 0, (1 << bits) - 1
    return np.clip(q, lo, hi)


def q_a1(v) -> np.ndarray:
    return quant(v, A1_FRAC, A1_BITS, True)


def q_a2(v) -> np.ndarray:
    return quant(v, A2_FRAC, A2_BITS, False)


def q_G(v) -> np.ndarray:
    return quant(v, G_FRAC, G_BITS, True)


# ---------------------------------------------------------------------------
# 72-bit word:  [71:46]=G(26) | [45:22]=a2(24) | [21:0]=a1(22)
# ---------------------------------------------------------------------------
def pack_word(a1: int, a2: int, G: int) -> int:
    return ((int(a1) & ((1 << A1_BITS) - 1))
            | ((int(a2) & ((1 << A2_BITS) - 1)) << A1_BITS)
            | ((int(G) & ((1 << G_BITS) - 1)) << (A1_BITS + A2_BITS)))


def unpack_word(w: int):
    a1 = w & ((1 << A1_BITS) - 1)
    if a1 & (1 << (A1_BITS - 1)):
        a1 -= 1 << A1_BITS
    a2 = (w >> A1_BITS) & ((1 << A2_BITS) - 1)
    G = (w >> (A1_BITS + A2_BITS)) & ((1 << G_BITS) - 1)
    if G & (1 << (G_BITS - 1)):
        G -= 1 << G_BITS
    return a1, a2, G


def word_hex(w: int) -> str:
    """18 hex digits, the width ``$readmemh`` needs for ``logic [71:0]``."""
    return f"{w & WORD_MASK:018X}"


# ---------------------------------------------------------------------------
# coefficient table: key (midi, dynamic) -> quantised arrays, plus 72-bit words
# ---------------------------------------------------------------------------
class CoeffTable:
    def __init__(self):
        self.entries: dict[tuple[int, str], dict] = {}

    def add(self, midi, dyn, a1q, a2q, Gq):
        self.entries[(int(midi), str(dyn))] = dict(
            a1=np.asarray(a1q, dtype=np.int64),
            a2=np.asarray(a2q, dtype=np.int64),
            G=np.asarray(Gq, dtype=np.int64),
        )

    def get(self, midi, dyn):
        return self.entries[(int(midi), str(dyn))]

    def flattened(self):
        """Deterministic order (midi asc, dynamic) -> (words, index)."""
        words, index = [], {}
        for key in sorted(self.entries):
            e = self.entries[key]
            offset = len(words)
            for a1, a2, G in zip(e["a1"], e["a2"], e["G"]):
                words.append(pack_word(int(a1), int(a2), int(G)))
            index[key] = dict(offset=offset, n_modes=int(e["a1"].size))
        return words, index


# ---------------------------------------------------------------------------
# polyphonic fixed-point synth (A-class: static per-note coefficients)
# ---------------------------------------------------------------------------
class FixedModalSynth:
    def __init__(self, table: CoeffTable, sr: int = SR, max_poly: int = 32,
                 max_modes: int = 48, high_water: int | None = None,
                 tau_forte: float = 1.5e-4, tau_piano: float = 2.5e-4,
                 free_thr: float = 2e-4, level_tau: float = 0.01):
        self.table = table
        self.sr = sr
        self.dt = 1.0 / sr
        self.max_poly = max_poly
        self.max_modes = max_modes
        self.high_water = high_water if high_water is not None else max(1, max_poly - 2)
        self.tau_forte, self.tau_piano = tau_forte, tau_piano
        self.free_thr = free_thr
        self.level_decay = float(np.exp(-self.dt / level_tau))
        self.reset()

    # ------------------------------------------------------------------
    def reset(self):
        V, N = self.max_poly, self.max_modes
        self.a1q24 = np.zeros((V, N), dtype=np.int64)   # a1 rescaled to 2^24
        self.a2q = np.zeros((V, N), dtype=np.int64)
        self.Gq = np.zeros((V, N), dtype=np.int64)
        self.y1 = np.zeros((V, N), dtype=np.int64)
        self.y2 = np.zeros((V, N), dtype=np.int64)
        self.nm = np.zeros(V, dtype=int)                # modes in use per voice
        self.pr = np.zeros(V, dtype=int)
        self.plen = np.ones(V, dtype=int)
        self.amp = np.zeros(V)
        self.xq = np.zeros(V, dtype=np.int64)
        self.active = np.zeros(V, dtype=bool)
        self.fast = np.zeros(V, dtype=bool)
        self.level = np.zeros(V)
        self.key = -np.ones(V, dtype=int)
        self.n = 0
        self.sat_count = 0
        self.steal_count = 0

    # ------------------------------------------------------------------
    def note_on(self, midi, vel=1.0):
        dyn = "forte" if vel >= 0.55 else "piano"
        ent = self.table.get(midi, dyn)

        free = np.nonzero(~self.active)[0]
        if free.size == 0:
            v = int(np.argmin(self.level))
            self.active[v] = False
            self.y1[v] = 0
            self.y2[v] = 0
            self.steal_count += 1
            free = np.array([v])
        v = int(free[0])

        n = int(ent["a1"].size)
        self.a1q24[v] = 0
        self.a2q[v] = 0
        self.Gq[v] = 0
        self.a1q24[v, :n] = ent["a1"] << A1_SHIFT
        self.a2q[v, :n] = ent["a2"]
        self.Gq[v, :n] = ent["G"]

        tau = self.tau_forte if vel >= 0.55 else self.tau_piano
        plen = max(2, int(tau * self.sr))
        self.pr[v] = plen
        self.plen[v] = plen
        self.amp[v] = float(vel)
        self.y1[v] = 0
        self.y2[v] = 0
        self.active[v] = True
        self.fast[v] = False
        self.key[v] = int(midi)
        self.nm[v] = n
        self.level[v] = 1e-3
        return v

    def note_off(self, midi):
        # NOTE: hardware note-off (release_factor / scheme-C kill) is not frozen yet,
        # so the model deliberately does not implement it here.
        return None

    # ------------------------------------------------------------------
    def step(self) -> float:
        V, N = self.max_poly, self.max_modes

        # excitation pulse, quantised to 2^24
        xq = np.zeros(V, dtype=np.int64)
        m = self.pr > 0
        if m.any():
            i = (self.plen[m] - self.pr[m]).astype(float)
            xf = self.amp[m] * (0.5 - 0.5 * np.cos(2.0 * np.pi * i / self.plen[m]))
            xq[m] = quant(xf, X_FRAC, X_FRAC + 2, True)
            self.pr[m] -= 1
        self.xq = xq

        # recursion: all three products share scale 2^(24+FS); shift by the
        # coefficient scale C_FRAC (24) to land back on the state scale 2^FS
        acc = self.Gq * xq[:, None] - self.a1q24 * self.y1 - self.a2q * self.y2
        yn = (acc + (1 << (C_FRAC - 1))) >> C_FRAC           # round half up
        sat = (yn > Y_MAX) | (yn < Y_MIN)
        self.sat_count += int(sat.sum())
        yn = np.clip(yn, Y_MIN, Y_MAX)
        self.y2[:] = self.y1
        self.y1[:] = yn

        rawf = self.y1.sum(axis=1) / float(1 << Y_FRAC)
        self.level = np.maximum(np.abs(rawf), self.level * self.level_decay)
        out = float(rawf[self.active].sum())

        # high-water proactive kill (mirrors engine.step); control stays float
        act = int(self.active.sum())
        nfast = int((self.active & self.fast).sum())
        if act > self.high_water and nfast < (act - self.high_water):
            cand = np.nonzero(self.active & ~self.fast)[0]
            if cand.size:
                v = int(cand[np.argmin(self.level[cand])])
                self.fast[v] = True   # real kill rescales a1/a2; not frozen yet

        dead = self.active & (self.level < self.free_thr) & (self.pr == 0)
        if dead.any():
            self.active[dead] = False
            self.y1[dead] = 0
            self.y2[dead] = 0
            self.key[dead] = -1
            self.fast[dead] = False

        self.n += 1
        return out

    # ------------------------------------------------------------------
    def render(self, events, seconds: float) -> np.ndarray:
        out = np.zeros(int(seconds * self.sr))
        onsets, offs = {}, {}
        for t, midi, dur, vel in events:
            onsets.setdefault(int(round(t * self.sr)), []).append((int(midi), float(vel)))
            offs.setdefault(int(round((t + dur) * self.sr)), []).append(int(midi))
        for i in range(out.size):
            for midi, vel in onsets.get(i, ()):
                self.note_on(midi, vel)
            for midi in offs.get(i, ()):
                self.note_off(midi)
            out[i] = self.step()
        return out


# ---------------------------------------------------------------------------
# analytic self-check of the accumulator shift / rounding / saturation
# ---------------------------------------------------------------------------
def _selftest():
    S = 1 << Y_FRAC                    # state / x scale
    CF = 1 << C_FRAC                   # coefficient scale
    ok = True
    cases = [
        # (Gq, a1q24, a2q, y1, y2, xq, expected y, why)
        (CF, 0, 0, 0, 0, S, 1.0, "unity feedthrough G*x"),
        (0, 0, CF >> 2, 0, S, 0, -0.25, "a2=0.25 on y2=1"),
        (0, CF >> 1, 0, S, 0, 0, -0.5, "a1=0.5 on y1=1"),
    ]
    for Gq, a1q24, a2q, y1, y2, xq, want, why in cases:
        acc = Gq * xq - a1q24 * y1 - a2q * y2
        yn = (acc + (1 << (C_FRAC - 1))) >> C_FRAC
        got = yn / float(S)
        good = abs(got - want) < 1e-9
        ok &= good
        print(f"  [{'ok' if good else 'BAD'}] {why}: got {got}, want {want}")

    # a1 = -2 (edge, still inside Q2.20 after <<4) on y1 ~ +2 must saturate
    a1q24 = -(A1_MAX << A1_SHIFT)
    acc = 0 - a1q24 * Y_MAX
    yn = (acc + (1 << (C_FRAC - 1))) >> C_FRAC
    sat = Y_MIN <= max(min(yn, Y_MAX), Y_MIN)
    print(f"  [{'ok' if yn > Y_MAX else 'BAD'}] saturation reachable: raw yn={yn}, "
          f"clamped to {sat}")
    ok &= yn > Y_MAX
    return ok


if __name__ == "__main__":
    print("fixed_point accumulator self-check:")
    raise SystemExit(0 if _selftest() else 1)
