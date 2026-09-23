import sys
from pathlib import Path
# Dependencies live in <repo>/_libs (sibling of python/), and this file sits in
# python/, so both the repo root and _libs are one level up.
if __package__ in (None, ""):
    _HERE = Path(__file__).resolve().parent
    sys.path.insert(0, str(_HERE.parent / "_libs"))
    sys.path.insert(0, str(_HERE))

import numpy as np
from synthlab.core import Block, Chain, Param, Source, render
from synthlab.ext.processors import Biquad, design_lowpass

_OMEGA_D_FLOOR = 1e-5      # keeps an overdamped omega_d off a 0/0


class StrikeForce(Source):
    """A struck-string exciter: a burst with a linear attack and exp decay.

    `pattern` is one character per sixteenth-note slot: 'x' strike, '-'
    rest, '|' bar line (ignored).
    """

    amplitude = Param(1.4, "N", 0.0, doc="peak force of one strike")
    attack = Param(0.0005, "s", 0.0, 0.05, doc="rise time of the burst")
    tau = Param(0.001, "s", 1e-5, 1.0, doc="decay time constant of the burst")
    bpm = Param(120.0, "bpm", 1.0, 1000.0)
    gain = Param(1.0, doc="scales the whole pattern, so a rest stays silent")

    def __init__(self, pattern: str, bpm: float = 120.0, amplitude: float = 1.4,
                 attack: float = 0.0005, tau: float = 0.001,
                 name: str | None = None):
        marks = [c for c in pattern if c not in "|"]
        if not any(c in "xX" for c in marks):
            raise ValueError(f"pattern {pattern!r} contains no strike ('x')")
        if any(c not in "xX- " for c in marks):
            bad = sorted({c for c in marks if c not in "xX- "})
            raise ValueError(f"pattern {pattern!r} has unknown characters {bad}")
        self.pattern = "".join(marks)
        self._strikes = [i for i, c in enumerate(self.pattern) if c in "xX"]
        super().__init__(name=name, bpm=bpm, amplitude=amplitude,
                         attack=attack, tau=tau)

    def reset(self, ctx) -> None:
        super().reset(ctx)
        self.slot_seconds = 60.0 / (4.0 * self.params.bpm)
        self.period = self.slot_seconds * len(self.pattern)
        self._strike_slots = [i * self.slot_seconds for i in self._strikes]
        self.time_in_pattern = 0.0
        self.age = float("inf")
        self._next = 0

    def process(self, ctx) -> float:
        dt = 1.0 / ctx.sr
        if self._next < len(self._strike_slots):
            if self.time_in_pattern + 1e-12 >= self._strike_slots[self._next]:
                self.age = 0.0
                self._next += 1
        elif self.time_in_pattern + dt >= self.period:
            self.age = 0.0
            self._next = 1

        self.time_in_pattern += dt
        if self.time_in_pattern >= self.period:
            self.time_in_pattern -= self.period

        tau = self.params.tau
        if self.age > 2.5 * tau:
            return 0.0
        amp = self.params.amplitude * self.params.gain
        attack = self.params.attack
        if self.age < attack:
            value = amp * self.age / attack if attack > 0 else amp
        else:
            value = amp * float(np.exp(-(self.age - attack) / tau))
        self.age += dt
        return value


class StringSim(Block):
    """Modal string, method A from MATH.md. A processor: the applied force in
    newtons is its input.

    `length` and `tension` are live; changing either marks the frequency tables
    stale and they are rebuilt before the next sample.
    """

    length = Param(1.0, "m", 0.05, 5.0, doc="speaking length of the string")
    tension = Param(1200.0, "N", 1.0, 1.0e5, doc="string tension")

    def __init__(self, length: float = 1.0, tension: float = 1200.0,
                 density: float = 0.012, stiffness: float = 0.014,
                 damping: np.ndarray | None = None, mode_num: int = 64,
                 strike_pos: float = 0.01, name: str | None = None):
        if damping is None:
            damping = np.exp(np.arange(1, mode_num + 1) * 0.18)
        damping = np.asarray(damping, dtype=float)
        if damping.shape != (mode_num,):
            raise ValueError(
                f"damping must have one value per mode, got {damping.shape} "
                f"for mode_num={mode_num}")
        if damping.min() < 0.0:
            raise ValueError("damping must be non-negative")

        self.density = float(density)
        self.stiffness = float(stiffness)
        self.gamma = damping
        self.mode_num = int(mode_num)

        self.P = np.arange(1, mode_num + 1, 1.0) * np.pi
        self.strike_weight = np.sin(self.P * float(strike_pos))

        self.q = np.zeros(mode_num)
        self.q_dot = np.zeros(mode_num)
        self._tables_stale = True

        super().__init__(name=name, length=length, tension=tension)

    def param_changed(self, name: str) -> None:
        if name in ("length", "tension"):
            self._tables_stale = True

    def _update_tables(self) -> None:
        length = float(self.params.length)
        tension = float(self.params.tension)
        A = tension / self.density
        B = self.stiffness / (self.density * length * length)

        self.omega0_sq = (A + B * self.P * self.P) * (self.P / length) ** 2
        self.damped_omega = np.sqrt(
            np.clip(self.omega0_sq - self.gamma ** 2, _OMEGA_D_FLOOR, None))

        # static_weight is K_n/omega_n^2.
        self.static_weight = (2.0 / (self.density * length) * self.strike_weight
                              / self.omega0_sq)

        mode = np.arange(1, self.mode_num + 1, 1.0)
        self.sum_weight = mode * ((-1.0) ** mode) * tension / length

        dt = 1.0 / self.ctx.sr
        decay = np.exp(-self.gamma * dt)
        self.ec = decay * np.cos(self.damped_omega * dt)
        self.es = decay * np.sin(self.damped_omega * dt)
        self._tables_stale = False

    def reset(self, ctx) -> None:
        super().reset(ctx)
        self.q = np.zeros(self.mode_num)
        self.q_dot = np.zeros(self.mode_num)
        self._tables_stale = True
        self._update_tables()

    def sim_step(self, x: float):
        """Advance one sample under force `x`; returns the bridge force."""
        q = self.q
        q_dot = self.q_dot
        g = self.gamma
        wd = self.damped_omega
        ec = self.ec
        es = self.es

        out = q.dot(self.sum_weight)

        f_over_w = x * self.static_weight
        self.q = (ec * q + es * (q_dot + g * q) / wd
                  + f_over_w * (1.0 - ec - g * es / wd))
        self.q_dot = (ec * q_dot - es * (self.omega0_sq * q + g * q_dot) / wd
                      + f_over_w * (g + self.omega0_sq * es / wd - g * ec))
        return out

    def process(self, x: float, ctx) -> float:
        if self._tables_stale:
            self._update_tables()
        return self.sim_step(float(x))


if __name__ == "__main__":
    from synthlab.ext.io import normalize, save_wav

    OUT = Path(__file__).resolve().parent / "out" / "sim_marry_song.wav"
    SECONDS = 8.8

    mode_N = 32
    index = np.arange(1, mode_N + 1, 1)
    damping = np.array(list(map(lambda n: np.exp(n * 0.23), index)))

    def string(length):
        return StringSim(length=length, tension=1600, density=0.013,
                         stiffness=0.015, damping=damping, mode_num=mode_N)

    # Lengths solved so mode 1 lands on the note: C4, D4, E4, G4 (A4 = 440).
    # With tension 1600, density 0.013 and stiffness 0.015, the inharmonicity
    # B = pi^2*EI/(T*L^2) comes out 2.1e-4 .. 4.6e-4, rising with pitch -- the
    # range measured on a real piano's middle octaves.
    string_length = {"G": 0.44763, "E": 0.53221, "D": 0.59742, "C": 0.67054}

    #Mary had a little lamb
    tracks = [
        Chain(StrikeForce("-|----|----|----|-xx-|----|----|----|----|---", bpm=60.0, amplitude=1.4),
              string(string_length["G"])),                      # G
        Chain(StrikeForce("-|x---|xxx-|----|x---|x---|xxx-|--x-|----|---", bpm=60.0, amplitude=1.4),
              string(string_length["E"])),                      # E
        Chain(StrikeForce("-|-x-x|----|xxx-|----|-x-x|----|xx-x|----|---", bpm=60.0, amplitude=1.4),
              string(string_length["D"])),                      # D
        Chain(StrikeForce("-|--x-|----|----|----|--x-|----|----|x---|---", bpm=60.0, amplitude=1.4),
              string(string_length["C"])),                      # C
    ]

    
    mix = sum(render(track, SECONDS) for track in tracks)
    
    cab = Biquad(*design_lowpass(2500.0, 0.8, 48000))
    mix = render(cab, SECONDS, input_signal=mix)      # 块 + 数组
    
    save_wav(OUT, normalize(mix, peak=0.9))
    print(f"wrote {OUT}")
