import sys
from pathlib import Path
# Optional dependencies live in <repo>/_libs; matrix_sim is two levels below the repo root.
if __package__ in (None, ""):
    _HERE = Path(__file__).resolve().parent
    sys.path.insert(0, str(_HERE.parents[1] / "_libs"))
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


class PianoADSR(Block):
    """Per-note output envelope matching env_router's piano Q1.31 ADSR.

    Score notation follows sim_guitar: x = onset, - = no new onset, | = separator.
    hold_seconds is the actual key-down duration for every onset, independently
    of the excitation burst. Release starts on key-up, including between repeats.
    Only the envelope follows RTL; SF/string/body remain this floating-point model.
    """

    ENV_MAX = 0x7fffffff
    A_STEP = 16_777_216
    D_STEP = 1_048_576
    S_LEVEL = 536_870_912

    def __init__(self, pattern: str, hold_seconds: tuple[float, ...],
                 bpm: float = 100.0, restart_from_zero: bool = True):
        self.restart_from_zero = restart_from_zero
        if any(c not in "Xx-|" for c in pattern) or bpm <= 0:
            raise ValueError("invalid score or tempo")
        self.pattern = pattern.replace("|", "")
        self.holds = tuple(hold_seconds)
        if len(self.holds) != sum(c in "Xx" for c in self.pattern):
            raise ValueError("one key-down duration is required per onset")
        if any(t <= 0 for t in self.holds):
            raise ValueError("key-down durations must be positive")
        self.bpm = bpm
        super().__init__()

    def reset(self, ctx) -> None:
        super().reset(ctx)
        step = ctx.sr * 60.0 / (4.0 * self.bpm)
        starts = [round(i * step) for i, c in enumerate(self.pattern) if c in "Xx"]
        self.events = dict(zip(starts, (round(t * ctx.sr) for t in self.holds)))
        # Same integer round-to-nearest expression as env_router.PIANO_R_STEP.
        self.r_step = (self.S_LEVEL * 1000 + ctx.sr * 200) // (ctx.sr * 400)
        self.lvl = 0
        self.state = "idle"
        self.gate_end = -1

    def process(self, x: float, ctx) -> float:
        onset = ctx.index in self.events
        old_lvl = self.lvl
        if onset:
            self.gate_end = ctx.index + self.events[ctx.index]
            if self.restart_from_zero:
                self.lvl = 0
            self.state = "attack"
        elif ctx.index >= self.gate_end:
            self.lvl = max(0, self.lvl - self.r_step)
            self.state = "release" if self.lvl else "idle"
        elif self.state == "attack":
            self.lvl = min(self.ENV_MAX, self.lvl + self.A_STEP)
            if self.lvl == self.ENV_MAX:
                self.state = "decay"
        elif self.state == "decay":
            self.lvl = max(self.S_LEVEL, self.lvl - self.D_STEP)
            if self.lvl == self.S_LEVEL:
                self.state = "sustain"
        # Legacy piano exports the old level; explicit retrigger exports zero.
        return float(x) * (0 if onset and self.restart_from_zero else old_lvl) / (1 << 31)


class PianoTrack(Source):
    """One pitch/slot, with selectable onset state clearing.

    RTL-style mode clears both modal banks before processing the onset frame,
    resets ADSR, and clears silent state when Release finishes. The shared body
    filter is deliberately kept running. Continuous mode preserves modal state
    and starts Attack at the current envelope level.
    """

    def __init__(self, midi, pattern, holds, bpm=100.0, rtl_restart=True):
        self.exciter = SF(pattern, bpm=bpm, amplitude=1)
        self.modal = piano_generator(midi)
        self.envelope = PianoADSR(pattern, holds, bpm=bpm,
                                  restart_from_zero=rtl_restart)
        self.rtl_restart = rtl_restart
        super().__init__()

    def reset(self, ctx):
        super().reset(ctx)
        for block in (self.exciter, self.modal, self.envelope):
            block.reset(ctx)
        self.onset_checks = []

    def clear_modes(self):
        for bank in self.modal.blocks:
            bank.q.fill(0)
            bank.q_dot.fill(0)

    def process(self, ctx):
        onset = ctx.index in self.envelope.events
        if onset:
            before = max(float(np.max(np.abs(b.q))) for b in self.modal.blocks)
            old_level = self.envelope.lvl
            if self.rtl_restart:
                self.clear_modes()
            after = max(float(np.max(np.abs(b.q))) for b in self.modal.blocks)
            self.onset_checks.append(dict(sample=ctx.index, q_peak_before=before,
                                          q_peak_after=after, envelope_before=old_level))
        force = self.exciter.eval(0.0, ctx)
        vibration = self.modal.eval(force, ctx)
        output = self.envelope.eval(vibration, ctx)
        if self.rtl_restart and self.envelope.state == "idle":
            self.clear_modes()
        return output


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

def render_twinkle_comparison(bpm=100.0, hold_seconds=0.55, long_hold_seconds=1.10, label=""):
    """C4 C4 G4 G4 A4 A4 G4; no sustain pedal."""
    import json
    from synthlab.ext.io import save_wav

    sr, seconds = 48000, 8 * 60.0 / bpm + 0.8
    suffix = f"_{label}" if label else ""
    out_dir = Path(__file__).resolve().parent / "out"
    # One character = a sixteenth note, just as in sim_guitar's tracks.
    # Quarter notes last four slots; the final G lasts eight slots.
    score = [
        (60, "|x---x-----------|----------------|", (hold_seconds, hold_seconds)),  # C4 C4
        (67, "|--------x---x---|--------x-------|", (hold_seconds, hold_seconds, long_hold_seconds)),  # G4 G4 G4
        (69, "|----------------|x---x-----------|", (hold_seconds, hold_seconds)),  # A4 A4
    ]
    patches, onset_checks = {}, {}
    for name, rtl_restart in (("continuous", False), ("rtl_restart", True)):
        tracks = [PianoTrack(midi, pattern, holds, bpm, rtl_restart)
                  for midi, pattern, holds in score]
        patch = sum(render(track, seconds, sr=sr) for track in tracks)
        patch = render(Chain(*(Biquad(*c) for c in PIANO_BODY_BIQUADS_3)),
                       seconds, sr=sr, input_signal=patch)
        if not np.isfinite(patch).all():
            raise ValueError("non-finite audio")
        patches[name] = patch
        onset_checks[name] = [dict(midi=spec[0], onsets=track.onset_checks)
                              for spec, track in zip(score, tracks)]
    # One common gain for A/B: retain differences in level and transients.
    native_peak = max(float(np.max(np.abs(p))) for p in patches.values())
    gain = 10 ** (-2 / 20) / native_peak
    lead_seconds = 0.15
    outputs = {}
    for name, patch in patches.items():
        out = out_dir / f"sim_piano_twinkle_7{suffix}_{name}.wav"
        audio = np.pad(patch * gain, (round(lead_seconds * sr), 0))
        save_wav(out, audio, sr=sr, subtype="PCM_16")
        outputs[name] = str(out)
    events = []
    for midi, pattern, holds in score:
        starts = [i * 60 / (4 * bpm) for i, c in enumerate(pattern.replace("|", "")) if c in "Xx"]
        events.extend(dict(midi=midi, on_s=t + lead_seconds,
                           off_s=t + hold + lead_seconds, hold_s=hold)
                      for t, hold in zip(starts, holds))
    events.sort(key=lambda event: event["on_s"])
    metadata = dict(sr=sr, bpm=bpm, duration_s=len(audio)/sr, pedal=False,
                    a_step=PianoADSR.A_STEP, d_step=PianoADSR.D_STEP,
                    s_level=PianoADSR.S_LEVEL,
                    r_step=(PianoADSR.S_LEVEL * 1000 + sr * 200) // (sr * 400),
                    gain=gain, native_peak=native_peak,
                    peak=max(float(np.max(np.abs(p * gain))) for p in patches.values()),
                    events=events, outputs=outputs, onset_checks=onset_checks,
                    scope="RTL-style onset modal clear and ADSR restart versus continuous state; floating-point SF/string/body, not full bit-exact RTL")
    (out_dir / f"sim_piano_twinkle_7{suffix}_comparison.json").write_text(
        json.dumps(metadata, indent=2) + "\n")
    for out in outputs.values():
        print(f"wrote {out}")
    print(json.dumps(metadata, indent=2))
    return outputs


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--fast", action="store_true", help="240 BPM; retrigger during Release")
    args = parser.parse_args()
    if args.fast:
        render_twinkle_comparison(240.0, 0.18, 0.36, label="fast")
    else:
        render_twinkle_comparison()
