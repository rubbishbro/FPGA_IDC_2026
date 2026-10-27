import sys
from pathlib import Path
# Dependencies live in <repo>/_libs (sibling of sythsound/), and this file sits in
# sythsound/, so both the repo root and _libs are one level up.
if __package__ in (None, ""):
    _HERE = Path(__file__).resolve().parent
    sys.path.insert(0, str(_HERE.parent / "_libs"))
    sys.path.insert(0, str(_HERE))

import numpy as np
from synthlab.core import Block, Chain, Source, Parallel, render
from synthlab.ext.processors import Biquad
from synthlab.ext.plotting import waveform

_OMEGA_D_FLOOR = 1e-5      # keeps an overdamped omega_d off a 0/0

class SF(Source):
    """A struck-string exciter: a burst with a linear attack and exp decay.

    `pattern` is one character per sixteenth-note slot: 'x' strike, '-'
    rest, '|' bar line (ignored).
    """

    def __init__(self, pattern: str, bpm: float = 120.0, amplitude: float = 1.4,
                 attack: float = 0.0005, tau: float = 0.001, 
                 delta: float = 0.01, pulse_num: int = 4):
        invalid_marks = [c for c in pattern if c not in "Xx-|"]
        assert len(invalid_marks) == 0
        
        self.att_ = attack
        # if delta > attack:
        #     self.delta_ = delta
        # else:
        #     self.delta_ = attack
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
                    self.val += (self.rise * (0.7)**self.pulse_cnt)
                    # self.val += (self.rise * 1/(1+self.pulse_cnt))
                elif dt < (self.pulse_cnt+1)*self.delta:
                    self.val *= self.decay
                elif not self.skip:
                    self.pulse_cnt += 1
                    if self.pulse_cnt >= self.pulse_num:
                        self.pulse_cnt = 0
                        self.skip = True
        
        return self.val


class StringSim(Block):
    """Modal string, method A from MATH.md, with the modal frequencies GIVEN.

    A processor: the applied force in newtons is its input, the bridge force comes out.

    Parameters
    ----------
    f0            fundamental in Hz. Measured, not derived -- see the gauge note above.
    damping       one decay rate per mode, in 1/s. `gamma_n` sets the envelope, and a
                  piano partial decays with TWO rates at once; run two of these with
                  different `damping` and sum the outputs to get that.
    inharmonicity B of `f_n = n f0 sqrt(1 + B n^2)`.
    mode_num      mode count; defaults to `len(damping)`. The caller must keep
                  `f_n` below Nyquist.
    strike_pos    beta, the strike point as a fraction of the speaking length.
                  `sin(n pi beta)` is the exciter's comb; it nulls partial n = 1/beta.
    drive         optional per-mode input gain. This is how a bank gets its share of
                  the fast/slow decay split, which varies with frequency.

    Nothing here is a live parameter: a piano string's length and tension are fixed for
    a note, so the tables are built once, in `reset`.
    """

    def __init__(self, f0: float, damping: np.ndarray,
                 inharmonicity: float = 0.0, mode_num: int | None = None,
                 strike_pos: float = 0.125, amplitude: float = 1):
        assert f0 > 0
        assert damping is not None and damping.min() > 0 and damping.size == mode_num

        self.mode_num = mode_num

        self.f0 = float(f0)
        self.inharmonicity = float(inharmonicity)
        self.strike_pos = float(strike_pos)
        self.gamma = damping
        self.amp = amplitude
        self.q = np.zeros(self.mode_num)
        self.q_dot = np.zeros(self.mode_num)

        self._build_modes()
        super().__init__()

    def _build_modes(self) -> None:
        """Everything that depends on f0, B, beta or the drive -- not on the rate."""
        n = np.arange(1, self.mode_num + 1, dtype=float)
        self.f_n = n * self.f0 * np.sqrt(1.0 + self.inharmonicity * n * n)
        self.omega0_sq = (2.0 * np.pi * self.f_n) ** 2
        # static_weight is K_n/omega_n^2 with the gauge factor 2/(mu L) folded away
        self.static_weight = (np.sin(np.pi * n * self.strike_pos) * self.amp / self.omega0_sq)
        # and 8 f0^2 carries T/(mu L^2) = 4 f0^2 together with the absorbed 2
        self.sum_weight = n * ((-1.0) ** n) * 8.0 * self.f0 ** 2

    def reset(self, ctx) -> None:
        super().reset(ctx)
        self.q = np.zeros(self.mode_num)
        self.q_dot = np.zeros(self.mode_num)
        self._build_modes()
        self.damped_omega = np.sqrt(np.clip(self.omega0_sq - self.gamma ** 2, _OMEGA_D_FLOOR, None))
        
        dt = 1.0 / ctx.sr
        decay = np.exp(-self.gamma * dt)
        self.ec = decay * np.cos(self.damped_omega * dt)
        self.es = decay * np.sin(self.damped_omega * dt)

    def sim_step(self, x: float) -> float:
        """Advance one sample under force `x`; returns the bridge force."""
        q = self.q
        q_dot = self.q_dot
        g = self.gamma
        wd = self.damped_omega
        ec = self.ec
        es = self.es

        out = q.dot(self.sum_weight)

        # the exact piecewise-constant-force update from MATH.md section 6.1
        f_over_w = x * self.static_weight
        self.q = (ec * q + es * (q_dot + g * q) / wd
                  + f_over_w * (1.0 - ec - g * es / wd))
        self.q_dot = (ec * q_dot - es * (self.omega0_sq * q + g * q_dot) / wd
                      + f_over_w * (g + self.omega0_sq * es / wd - g * ec))
        return out

    def process(self, x: float, ctx) -> float:
        return self.sim_step(float(x))



GAMMA_KEY = (0,0,0,0,0,0,0,0,0,0,0,
            1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
            2,2,2,2,2,2,2,2,2,2,2,2,2,2,2)

# GAMMA_SLOW = (
#     # MIDI 36-50   (150 partials, 40 indices)
#     (0.3837, 0.3837, 0.2884, 0.2473, 0.2556, 0.3835, 0.3835, 0.4335, 0.4335, 0.5007,
#      0.5169, 0.4817, 0.5901, 0.6770, 0.6407, 0.7280, 0.9257, 1.0190, 1.2820, 1.2790,
#      1.3470, 1.2940, 1.1590, 0.9567, 0.9543, 1.0420, 1.1160, 1.0260, 0.7887, 0.4765,
#      0.3512, 0.2736, 0.2736, 0.2736, 0.2736, 0.2736, 0.4774, 0.4774, 0.5721, 0.5721),
#     # MIDI 51-65   (107 partials, 35 indices)
#     (1.0800, 1.0800, 0.7359, 0.5668, 0.4673, 0.5466, 0.5466, 0.7449, 0.8121, 0.9258,
#      0.9878, 1.2630, 1.3010, 1.0650, 0.8856, 0.7599, 0.8285, 0.9299, 0.9211, 0.9211,
#      1.0170, 1.0170, 1.0170, 1.0480, 1.0480, 1.0480, 1.1520, 1.1520, 1.1520, 1.1520,
#      1.1520, 1.5180, 1.5180, 1.5180, 1.5180),
#     # MIDI 66-80   (72 partials, 22 indices)
#     (1.4550, 1.4550, 1.6800, 2.3040, 2.2100, 2.1140, 2.0450, 2.0980, 1.9540, 1.7290,
#      1.9160, 2.2040, 1.4260, 1.2610, 1.2610, 1.2610, 1.1950, 1.1950, 1.1950, 1.1950,
#      1.1950, 1.1950),
# )

# 三十二模态足够，听感几乎无差异
GAMMA_SLOW_32 = (
    # MIDI 36-50   (150 partials, 32 indices)
    (0.3837, 0.3837, 0.2884, 0.2473, 0.2556, 0.3835, 0.3835, 0.4335, 0.4335, 0.5007,
     0.5169, 0.4817, 0.5901, 0.6770, 0.6407, 0.7280, 0.9257, 1.0190, 1.2820, 1.2790,
     1.3470, 1.2940, 1.1590, 0.9567, 0.9543, 1.0420, 1.1160, 1.0260, 0.7887, 0.4765,
     0.3512, 0.2736),
    # MIDI 51-65   (107 partials, 32 indices)
    (1.0800, 1.0800, 0.7359, 0.5668, 0.4673, 0.5466, 0.5466, 0.7449, 0.8121, 0.9258,
     0.9878, 1.2630, 1.3010, 1.0650, 0.8856, 0.7599, 0.8285, 0.9299, 0.9211, 0.9211,
     1.0170, 1.0170, 1.0170, 1.0480, 1.0480, 1.0480, 1.1520, 1.1520, 1.1520, 1.1520,
     1.1520, 1.5180),
    # MIDI 66-80   (72 partials, 22 indices)
    (1.4550, 1.4550, 1.6800, 2.3040, 2.2100, 2.1140, 2.0450, 2.0980, 1.9540, 1.7290,
     1.9160, 2.2040, 1.4260, 1.2610, 1.2610, 1.2610, 1.1950, 1.1950, 1.1950, 1.1950,
     1.1950, 1.1950),
)

OCTAVE_KEY = (33, 45, 57, 69, 81)
OCTAVE_STRETCH = (-4.245724, -2.447415, -1.170808, 0.0, 3.146409)

INHARMONICITY_1024X = (0.173804,0.169186,0.165751,0.163488,0.162397,0.162487,0.163774,0.166284,
                    0.170053,0.175125,0.181557,0.189414,0.198773,0.209725,0.222371,0.236829,
                    0.253230,0.271720,0.292466,0.315651,0.341479,0.370177,0.401996,0.437213,
                    0.476133,0.519096,0.566472,0.618671,0.676145,0.739388,0.808946,0.885418,
                    0.969463,1.061803,1.163232,1.274624,1.396934,1.531214,1.678617,1.840410,2.017981,)

POS_A0, POS_SLOPE = 0.155, 0.00364

def piano_f0(midi: int):
    equal = 440.0 * 2.0 ** ((midi - 69) / 12.0)
    cents = float(np.interp(midi, OCTAVE_KEY, OCTAVE_STRETCH))
    return float(equal * 2.0 ** (cents / 1200.0))

def piano_generator(midi: int):
    assert 40 <= midi and midi <= 80
    
    f0 = piano_f0(midi)
    inharmonicity = INHARMONICITY_1024X[midi-40]/1024
    gamma = np.asarray(GAMMA_SLOW_32[GAMMA_KEY[midi-40]])
    mode_num = gamma.size
    
    strike_pos = POS_A0 * np.exp(-POS_SLOPE * (midi - 21.0))
    
    def bank(amp, offset):
        return StringSim(f0=f0 + offset, damping=gamma, inharmonicity=inharmonicity,
                            mode_num=mode_num, strike_pos=strike_pos, amplitude=amp)

    beat_hz = f0 * 0.0005777895 # f0 * 2 ** (1/1200) - 1
    
    banks = [bank(0.7, 0), bank(0.3, beat_hz)]
    return Parallel(*banks, op="sum")

# The soundboard. Three sections, fitted to the recorded/model partial ratio over MIDI
# 40-80 (`_analysis/_piano_body_fit.py`), with two conventions folded into the numbers
# themselves so that nothing outside this table has to know them:
#
#   * the response sits at 0 dB at the design curve's own dB mean and is scaled by the
#     output gain (0.5). That factor used to be written on the render call below
#     (`0.5*render(...)`); it belongs to the filter, so it is in section 1's numerator and
#     the render call is now plain. Delivered peak 1.220 at 1518 Hz, minimum 0.0096.
#   * the design curve had its shape compressed by 0.5 about its own mean before fitting,
#     which halves the response's excursions (the +13.8 dB resonance that put MIDI 55's
#     third partial into a speaker's clip is +6.9 dB here) without reordering anything.
PIANO_BODY_BIQUADS_3 = (
    (0.004498959, 0.000566257, -0.005333572, -1.843048159, 0.922814888),
    (-3.252736569, 0.607854590, 3.051903151, -0.205053082, -0.703123463),
    (2.230436977, -3.679045601, 1.649319528, -1.904920411, 0.911984039),
)

if __name__ == "__main__":
    SECONDS = 6
    SR = 48000
    from synthlab.ext.io import save_wav
    
    for midi in [40, 41, 42, 43, 44, 45, 47, 50] :
        OUT = Path(__file__).resolve().parent / "out" / f"sim_piano_n32_{midi}.wav"

        ch = Chain(SF("|x---|----", bpm=60.0, amplitude=1), piano_generator(midi))

        patch = render(ch, SECONDS)
        patch = render(Chain(*(Biquad(b0, b1, b2, a1, a2) for b0, b1, b2, a1, a2 in PIANO_BODY_BIQUADS_3)),
                       SECONDS, input_signal=patch)
        
        save_wav(OUT, patch)
        print(f"wrote {OUT}")
        print(f"{midi} max {patch.max()}, min {patch.min()}")
    # w = render(SF("|x---|----", bpm=60.0, amplitude=1), SECONDS, SR)
    # waveform(w, SR, SECONDS)
    
