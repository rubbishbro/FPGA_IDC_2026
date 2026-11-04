import sys
from pathlib import Path
# Optional dependencies live in <repo>/_libs; matrix_sim is two levels below the repo root.
if __package__ in (None, ""):
    _HERE = Path(__file__).resolve().parent
    sys.path.insert(0, str(_HERE.parents[1] / "_libs"))
    sys.path.insert(0, str(_HERE))

import numpy as np
from synthlab.core import Block, Chain, Param, Source, render
from synthlab.ext.processors import Biquad
from synthlab.ext.plotting import spectrum_plot, spectrogram


class StrikeForce(Source):
    """A struck-string exciter: a burst with a linear attack and exp decay.

    `pattern` is one character per sixteenth-note slot: 'x' strike, '-'
    rest, '|' bar line (ignored).
    """

    def __init__(self, pattern: str, bpm: float = 120.0, amplitude: float = 1.4,
                 attack: float = 0.0005, tau: float = 0.001, 
                 delta: float = 0.01, pulse_num: int = 1):
        invalid_marks = [c for c in pattern if c not in "Xx-|"]
        assert len(invalid_marks) == 0
        
        self.att_ = attack
        self.delta_ = delta
        
        self.tau = tau
        self.amp = amplitude
        self.bpm = bpm
        self.pulse_num = pulse_num
        
        self.pattern = [c for c in pattern if c in "Xx-"]
        self.p_len = len(self.pattern)
        
        
        super().__init__()

    def reset(self, ctx) -> None:
        super().reset(ctx)
        dt = 1/ctx.sr
        
        self.tick = 60.0 / (4.0 * self.bpm)
        
        self.rise = self.amp*dt/self.att_
        self.decay = np.pow(1/np.e, dt/self.tau)
        self.att = self.att_/self.tick
        self.delta = self.delta_/self.tick
        
        self.pidx = 0
        self.idx = 0
        self.pulse_cnt = 0
        self.val = 0
        
        self.skip = False
        

    def process(self, ctx) -> float:
        t = ctx.index/(ctx.sr*self.tick)
        self.idx = int(np.floor(t))
        if self.pidx != self.idx:
            self.pidx = self.idx
            self.skip = False
        
        if self.idx >= self.p_len:
            self.val *= self.decay
        else:
            c = self.pattern[self.idx]
            if c == 'X' or c == 'x':
                dt = t - self.idx
                if self.pulse_cnt*self.delta < dt and dt < self.pulse_cnt*self.delta + self.att:
                    self.val += (self.rise * (0.6)**self.pulse_cnt)
                elif dt < (self.pulse_cnt+1)*self.delta:
                    self.val *= self.decay
                elif not self.skip:
                    self.pulse_cnt += 1
                    if self.pulse_cnt >= self.pulse_num:
                        self.pulse_cnt = 0
                        self.skip = True
        
        return self.val


_OMEGA_D_FLOOR = 1e-5      # keeps an overdamped omega_d off a 0/0

class StringSim(Block):
    length_r = Param(1.0, "1", 0.9, 1.1, doc="current / default")
    tension_r = Param(1.0, "1", 0.9, 1.1, doc="current / default")

    def __init__(self, f0: float, TL_ratio: float, damping: np.ndarray | None = None, 
                 mode_num: int = 64, pos: float = 0.01):
        assert damping is not None and damping.min() > 0.0

        self.TLr = TL_ratio
        self.f0 = f0
        self.gamma = damping
        self.mode_num = int(mode_num)

        self.P = np.arange(1, mode_num + 1, 1.0) * np.pi
        self.pos = pos

        self.q = np.zeros(mode_num)
        self.q_dot = np.zeros(mode_num)
        self._tables_stale = True

        super().__init__(length_r=1, tension_r=1)

    def param_changed(self, name: str) -> None:
        if name in ("length", "tension"):
            self._tables_stale = True

    def _update_tables(self) -> None:
        lr = float(self.params.length_r)
        tr = float(self.params.tension_r)

        self.omega0_sq = tr/(lr**2) * (self.f0 * 2 * self.P) ** 2
        self.damped_omega = np.sqrt(
            np.clip(self.omega0_sq - self.gamma ** 2, _OMEGA_D_FLOOR, None))

        mode = np.arange(1, self.mode_num + 1, 1.0)
        self.sum_weight = mode * ((-1.0) ** mode) * self.TLr * (lr/tr)

        dt = 1.0 / self.ctx.sr
        decay = np.exp(-self.gamma * dt)
        self.ec = decay * np.cos(self.damped_omega * dt)
        self.es = decay * np.sin(self.damped_omega * dt)
        self._tables_stale = False

    def reset(self, ctx) -> None:
        super().reset(ctx)
        self.q = np.zeros(self.mode_num)
        self.q_dot = np.zeros(self.mode_num)
        self._update_tables()

    def sim_step(self):
        q = self.q
        q_dot = self.q_dot
        g = self.gamma
        wd = self.damped_omega
        ec = self.ec
        es = self.es

        out = q.dot(self.sum_weight)

        self.q = ec * q + es * (q_dot + g * q) / wd
        self.q_dot = ec * q_dot - es * (self.omega0_sq * q + g * q_dot) / wd
        return out

    def process(self, x: float, ctx) -> float:
        if self._tables_stale:
            self._update_tables()
        
        if x > 0.998:
            stimu_mode = np.sin(self.P*self.pos)/((self.P**2)*self.pos*(1-self.pos))
            self.q +=  0.001 * stimu_mode
        
        return self.sim_step()

BODY_BIQUADS = (
    (-0.010317131, 0.019695954, -0.009511816, -0.394281863, 0.039326197),
    (1.960786384, -3.794366238, 1.835753556, -1.475799486, 0.544528826),
    (2.012664683, -1.953590949, 0.475197651, -1.932744057, 0.936110541),
    (1.966105655, -0.514626487, 0.033756291, -1.932888220, 0.936247750),
    (-3.604058764, 6.942119376, -3.373897547, -1.667914762, 0.701919494),
)

def guitar_generator(midi: int) -> StringSim:
    assert 40 <= midi and midi <= 80

    # Per-string damping, from a measured lookup table and a per-string scale
    DAMP_BIN_HZ = (93.96, 122.52, 159.75, 208.30, 271.60, 354.15,
                   461.78, 602.11, 785.10, 1023.70, 1334.82, 1740.49)
    # natural log of gamma in 1/s at each bin centre
    DAMP_BIN_LN_GAMMA = (0.2148, -0.6427, -0.0040, 0.5375, 0.2490, -0.1477,
                         0.5102, 0.6994, float("nan"), float("nan"), 0.4489, 1.1248)

    if midi < 45:
        midi0 = 40
        t = 115.7
        # mu = 0.010149
        damp_scale = 0.7904          # E2, wound
    elif midi < 50:
        midi0 = 45
        t = 133.4
        # mu = 0.006572
        damp_scale = 0.8145          # A2, wound
    elif midi < 55:
        midi0 = 50
        t = 133.4
        # mu = 0.003689
        damp_scale = 0.8793          # D3, wound
    elif midi < 59:
        midi0 = 55
        t = 133.4
        # mu = 0.002070
        damp_scale = 1.1734          # G3, wound
    elif midi < 64:
        midi0 = 59
        t = 102.3
        # mu = 0.001
        damp_scale = 1.3362          # B3, plain
    else:
        midi0 = 64
        t = 102.3
        # mu = 0.000561
        damp_scale = 1.3023          # E4, plain

    len = 0.6477*2**((midi0 - midi)/12)
    mode_N = 20

    # Interpolate in log frequency and hold the ends; the two NaN bins are skipped by keeping only
    # the finite entries, which is what makes the 688-1169 Hz stretch interpolated.
    _ln_hz = np.log(np.asarray(DAMP_BIN_HZ))
    _ln_g = np.asarray(DAMP_BIN_LN_GAMMA)
    _ok = np.isfinite(_ln_g)
    index = np.arange(1, mode_N + 1, 1)
    f0 = 440.0 * 2.0 ** ((midi - 69) / 12.0)
    damping = 1.3 * damp_scale * np.exp(np.interp(np.log(index * f0), _ln_hz[_ok], _ln_g[_ok]))

    return StringSim(f0 = f0, TL_ratio=t/len,
                     pos=0.14/len, damping=damping, mode_num=mode_N)


if __name__ == "__main__":
    from synthlab.ext.io import save_wav

    OUT = Path(__file__).resolve().parent / "out" / "sim_guitar_song_simp3.wav"
    SECONDS = 9

    #outer wilds - travaler
    tracks = [
        Chain(StrikeForce("|--------|--------|--------|------x-|------", bpm=60.0, amplitude=1),
                guitar_generator(62)),                      # D4
        Chain(StrikeForce("|--------|x-------|--------|x-------|------", bpm=60.0, amplitude=1),
                guitar_generator(60)),                      # C4
        Chain(StrikeForce("|----x---|-x---x--|----x---|-x---x-x|------", bpm=60.0, amplitude=1),
                guitar_generator(59)),                      # B3
        Chain(StrikeForce("|--------|--x-x---|--------|--x-x---|------", bpm=60.0, amplitude=1),
                guitar_generator(57)),                      # A3
        Chain(StrikeForce("|--x----x|---x--x-|--x----x|---x----|------", bpm=60.0, amplitude=1),
                guitar_generator(55)),                      # G3
        Chain(StrikeForce("|--------|--------|x-------|--------|------", bpm=60.0, amplitude=1),
                guitar_generator(50)),                      # D3
        Chain(StrikeForce("|x-------|--------|--------|--------|------", bpm=60.0, amplitude=1),
                guitar_generator(48)),                      # C3
    ]

    patch = sum(render(track, SECONDS) for track in tracks)
    patch = render(Chain(*(Biquad(b0, b1, b2, a1, a2) for b0, b1, b2, a1, a2 in BODY_BIQUADS)),
                   SECONDS, input_signal=patch)
    
    save_wav(OUT, patch)
    print(f"wrote {OUT}")
    print(f"max {patch.max()}, min {patch.min()}")