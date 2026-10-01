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
from synthlab.ext.processors import Biquad
from synthlab.ext.plotting import spectrum_plot, spectrogram

_OMEGA_D_FLOOR = 1e-5      # keeps an overdamped omega_d off a 0/0


class StringSim(Block):
    length = Param(1.0, "m", 0.05, 5.0, doc="speaking length of the string")
    tension = Param(1200.0, "N", 1.0, 1.0e5, doc="string tension")

    def __init__(self, length: float = 1.0, tension: float = 1200.0,
                 density: float = 0.012, stiffness: float = 0.014,
                 damping: np.ndarray | None = None, mode_num: int = 64,
                 pos: float = 0.01, name: str | None = None):
        assert damping is not None and damping.min() > 0.0

        self.density = float(density)
        self.stiffness = float(stiffness)
        self.gamma = damping
        self.mode_num = int(mode_num)

        self.P = np.arange(1, mode_num + 1, 1.0) * np.pi
        self.pos = pos

        self.q = np.zeros(mode_num)
        self.q_dot = np.zeros(mode_num)
        self._tables_stale = True
        
        # self.starting_point = -1e5

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

        mode = np.arange(1, self.mode_num + 1, 1.0)
        self.sum_weight = mode * ((-1.0) ** mode) * tension / length

        dt = 1.0 / self.ctx.sr
        decay = np.exp(-self.gamma * dt)
        self.ec = decay * np.cos(self.damped_omega * dt)
        self.es = decay * np.sin(self.damped_omega * dt)
        self._tables_stale = False

    def reset(self, ctx) -> None:
        super().reset(ctx)
        
        # length = float(self.params.length)
        # fac = 0.001*length/((self.P**2)*self.pos*(1-self.pos)*(length**2))
        # self.q = np.sin(self.P*self.pos) * fac
        
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
        
        # t = float(ctx.index/ctx.sr)
        if x > 0.998:
            length = float(self.params.length)
            fac = length/((self.P**2)*self.pos*(1-self.pos)*(length**2))
            init_state = np.sin(self.P*self.pos)*fac
            self.q +=  0.001 * init_state
            # self.starting_point = t
        
        # delta_t = self.starting_point - t
        # envlope = (1+0.35*np.exp(30*delta_t))
        # return self.sim_step() * envlope
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

    # Per-string damping, from a measured lookup table and a per-string scale.
    #
    # Fitted from the recordings: for every partial of every sampled note, `alpha` is the decay rate
    # of its CWT envelope in dB, and that was fitted against ABSOLUTE frequency rather than against
    # harmonic number. Frequency is the physical variable -- air drag goes as omega and internal
    # friction as omega^2 -- whereas `n` is only a proxy that mixes notes: n = 2 is 165 Hz at midi 40
    # and 660 Hz at midi 64.
    #
    # A TABLE rather than a formula. A diagonal power law `gamma = C f^p` was tried first and left a
    # systematic S-shaped residual in every one of the six strings: positive low, negative in the
    # middle, positive again high. Leaving one whole NOTE out at a time (so a note's own partials
    # never appear in both fit and score), the shared shape below reduced the held-out rms in log
    # alpha from 0.451 to 0.419, a 7.1 % improvement, and it won in 14 of 15 combinations of
    # frequency cap and dynamic range gate. A quadratic in log f scored similarly in sample but is
    # rejected: it is a PARABOLA, so it turns over and diverges, and at this synthesis's top mode
    # (53 kHz at mode_num = 100) it produced 6719 /s for E2 and 9.6e6 /s for G3, with the turn-over
    # at 295 Hz and 551 Hz. A held table cannot do that.
    #
    # The shape is the median alpha across ALL strings in each frequency bin, so it is one curve for
    # the instrument; the per-string scale multiplies it, because the strings differ in level. Note
    # that a shared curve plus a per-string OFFSET was also tried and did WORSE than a shared curve
    # alone (0.529 against 0.509), so the strings differ in slope too -- which is why the shape is
    # tabulated and the difference is left in the scale.
    #
    # Bins 9 and 10 are empty of data: no partial within 15 dB of its note's strongest falls between
    # 688 and 1169 Hz, so that stretch is INTERPOLATED, not measured. That hole is why four or six
    # bins are worse than the power law -- with few bins the hole swallows a whole one.
    #
    # VALIDITY. The fit used partials below 2 kHz. Above that the measurements are not usable: at
    # 5 kHz the 29 sampled partials came from 12 different notes and spanned alpha from 0.13 to 14, a
    # factor of 100. Above the last bin the value is HELD, so the damping is flat from 1740 Hz up.
    # That is an assumption, not a measurement.
    DAMP_BIN_HZ = (93.96, 122.52, 159.75, 208.30, 271.60, 354.15,
                   461.78, 602.11, 785.10, 1023.70, 1334.82, 1740.49)
    # natural log of gamma in 1/s at each bin centre
    DAMP_BIN_LN_GAMMA = (0.2148, -0.6427, -0.0040, 0.5375, 0.2490, -0.1477,
                         0.5102, 0.6994, float("nan"), float("nan"), 0.4489, 1.1248)

    if midi < 45:
        midi0 = 40
        t = 115.7
        mu = 0.010149
        damp_scale = 0.7904          # E2, wound
    elif midi < 50:
        midi0 = 45
        t = 133.4
        mu = 0.006572
        damp_scale = 0.8145          # A2, wound
    elif midi < 55:
        midi0 = 50
        t = 133.4
        mu = 0.003689
        damp_scale = 0.8793          # D3, wound
    elif midi < 59:
        midi0 = 55
        t = 133.4
        mu = 0.002070
        damp_scale = 1.1734          # G3, wound
    elif midi < 64:
        midi0 = 59
        t = 102.3
        mu = 0.001
        damp_scale = 1.3362          # B3, plain
    else:
        midi0 = 64
        t = 102.3
        mu = 0.000561
        damp_scale = 1.3023          # E4, plain

    len = 0.6477*2**((midi0 - midi)/12)
    mode_N = 20

    # Interpolate in log frequency and hold the ends; the two NaN bins are skipped by keeping only
    # the finite entries, which is what makes the 688-1169 Hz stretch interpolated.
    _ln_hz = np.log(np.asarray(DAMP_BIN_HZ))
    _ln_g = np.asarray(DAMP_BIN_LN_GAMMA)
    _ok = np.isfinite(_ln_g)
    index = np.arange(1, mode_N + 1, 1)
    f1 = 440.0 * 2.0 ** ((midi - 69) / 12.0)
    damping = 1.6 * damp_scale * np.exp(np.interp(np.log(index * f1), _ln_hz[_ok], _ln_g[_ok]))

    return StringSim(length=len, tension=t, density=mu,
                    stiffness=0, pos=0.14/len, damping=damping, mode_num=mode_N)


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

if __name__ == "__main__":
    from synthlab.ext.io import normalize, save_wav

    OUT = Path(__file__).resolve().parent / "out" / "sim_guitar_song.wav"
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

    # spectrum_plot(patch, 48000, title="strike_spectrum")
    # spectrogram(patch, 48000, title="strike_spectrogram")