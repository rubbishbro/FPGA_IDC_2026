import sys
from pathlib import Path
# Dependencies live in <repo>/_libs (sibling of sythsound/), and this file sits in
# sythsound/, so both the repo root and _libs are one level up.
if __package__ in (None, ""):
    _HERE = Path(__file__).resolve().parent
    sys.path.insert(0, str(_HERE.parent / "_libs"))
    sys.path.insert(0, str(_HERE))

import numpy as np
from synthlab.core import Block, Chain, Param, Source, render
from synthlab.ext.plotting import spectrum_plot, spectrogram

_OMEGA_D_FLOOR = 1e-5      # keeps an overdamped omega_d off a 0/0


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
                pos: float = 0.01, name: str | None = None):
        assert damping is not None and damping.min() > 0.0
        # if damping is None:
        #     damping = np.exp(np.arange(1, mode_num + 1) * 0.18)
        # damping = np.asarray(damping, dtype=float)
        # if damping.shape != (mode_num,):
        #     raise ValueError(
        #         f"damping must have one value per mode, got {damping.shape} "
        #         f"for mode_num={mode_num}")
        # if damping.min() < 0.0:
        #     raise ValueError("damping must be non-negative")

        self.density = float(density)
        self.stiffness = float(stiffness)
        self.gamma = damping
        self.mode_num = int(mode_num)

        self.P = np.arange(1, mode_num + 1, 1.0) * np.pi
        self.mode_weight = np.sin(self.P * pos)
        
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
        self.static_weight = (2.0 / (self.density * length) * self.mode_weight
                                / self.omega0_sq)

        mode = np.arange(1, self.mode_num + 1, 1.0)
        self.sum_weight = mode * ((-1.0) ** mode) * tension / length
        
        dt = 1.0 / self.ctx.sr
        
        self.f = 1.2
        self.force_decay = np.power(0.002, dt)
        
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

    def sim_step(self):
        """Advance one sample under force `x`; returns the bridge force."""
        q = self.q
        q_dot = self.q_dot
        g = self.gamma
        wd = self.damped_omega
        ec = self.ec
        es = self.es

        out = q.dot(self.sum_weight)
        
        #敲击力模拟：力突然出现然后指数衰减
        self.f = self.f  * self.force_decay
        
        f_over_w = self.static_weight * self.f 
        self.q = (ec * q + es * (q_dot + g * q) / wd
                    + f_over_w * (1.0 - ec - g * es / wd))
        self.q_dot = (ec * q_dot - es * (self.omega0_sq * q + g * q_dot) / wd
                        + f_over_w * (g + self.omega0_sq * es / wd - g * ec))
        return out

    def process(self, x: float, ctx) -> float:
        if self._tables_stale:
            self._update_tables()
        return self.sim_step()


if __name__ == "__main__":
    from synthlab.ext.io import normalize, save_wav

    OUT = Path(__file__).resolve().parent / "out" / "sim_strike_L045T800S0015D001P02.wav"
    
    SECONDS = 1.3
    SR = 48000

    mode_N = 32
    index = np.arange(1, mode_N + 1, 1)
    damping = np.array(list(map(lambda n: np.exp(n * 0.14), index)))

    sim = StringSim(length=0.45, tension=800, density=0.01,
                    stiffness=0.015, pos=0.2, damping=damping, mode_num=mode_N)
    
    patch = render(sim, SECONDS, sr=SR)
    save_wav(OUT, patch)
    print(f"wrote {OUT}")
    
    spectrum_plot(patch, SR, title="strike_spectrum")
    spectrogram(patch, SR, title="strike_spectrogram")
