import sys
from pathlib import Path
# Dependencies live in <repo>/_libs (sibling of python/), and this file sits in
# python/, so both the repo root and _libs are one level up.
# Only when run as a script: as a module the package already resolves normally.
if __package__ in (None, ""):
    _HERE = Path(__file__).resolve().parent
    sys.path.insert(0, str(_HERE.parent / "_libs"))
    sys.path.insert(0, str(_HERE))

import numpy as np
from synthlab.core import Block, Chain, Param, Source, render

# Floor for omega_d^2 = omega_0^2 - gamma^2. Where damping is heavy enough to make
# the square negative the mode is overdamped, and dividing by its omega_d would be
# a 0/0. Clipping to a small positive value keeps those modes finite instead of NaN.
_OMEGA_D_FLOOR = 1e-5

#: Ratio of the strike point to the string length.
STRIKE_POS = 0.01


class StrikeForce(Source):
    """A struck-string exciter: a short burst that decays exponentially.

    Used as a generator in front of `StringSim`, which is a processor::

        Chain(StrikeForce(...), StringSim(...))

    `pattern` is the rhythm, read as one character per slot:

        'x' strike   '-' or ' ' rest   '|' bar line, ignored

    So ``"|x-x-|xxxx|"`` is the figure from the demo. The cycle repeats for as
    long as it is rendered. `bpm` sets the tempo, and a slot is a sixteenth note.

    The burst has a linear attack over `attack` seconds and then falls as
    `exp(-t/tau)`. Contact time matters: `tau` longer than the string's
    fundamental period means the string follows the force instead of ringing, so
    the default 1 ms is shorter than the 5.4 ms period of the demo's 184 Hz
    fundamental. It is a `Source`, so it emits one force value per sample in
    newtons, which `StringSim` turns into modal forces.
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
            raise ValueError(
                f"pattern {pattern!r} has unknown characters {bad}; "
                f"use 'x' for a strike and '-' for a rest"
            )
        self.pattern = "".join(marks)
        self._strikes = [i for i, c in enumerate(self.pattern) if c in "xX"]
        super().__init__(name=name, bpm=bpm, amplitude=amplitude,
                         attack=attack, tau=tau)

    def reset(self) -> None:
        super().reset()
        self.age = float("inf")     # seconds since the current strike, inf = idle

    def prepare(self, ctx) -> None:
        super().prepare(ctx)
        self.slot_seconds = 60.0 / (4.0 * self.bpm)
        self.period = self.slot_seconds * len(self.pattern)
        self._strike_slots = [i * self.slot_seconds for i in self._strikes]
        self.time_in_pattern = 0.0
        self.age = float("inf")
        self._next = 0              # index into _strike_slots

    def process(self, ctx) -> float:
        dt = 1.0 / ctx.sr
        # Onsets sit on a fixed grid, so only the next one ever needs checking, and
        # the position only moves forward.
        if self._next < len(self._strike_slots):
            if self.time_in_pattern + 1e-12 >= self._strike_slots[self._next]:
                self.age = 0.0
                self._next += 1
        elif self.time_in_pattern + dt >= self.period:
            self.age = 0.0             # slot 0 of the next bar
            self._next = 1

        self.time_in_pattern += dt
        if self.time_in_pattern >= self.period:
            self.time_in_pattern -= self.period

        amp = self.amplitude * self.gain
        if self.age > 2.5 * self.tau:
            return 0.0
        if self.age < self.attack:
            value = amp * self.age / self.attack if self.attack > 0 else amp
        else:
            value = amp * float(np.exp(-(self.age - self.attack) / self.tau))
        self.age += dt
        return value


class StringSim(Block):
    """Modal string, method A from MATH.md. A *processor*: the applied force is
    its input.

    The force is an audio-rate signal in newtons, one value per sample, driving
    every mode at once:

        g_n(t) = x(t) * K_n / omega_n^2

    so the string is excited by whatever is upstream -- a `StrikeForce`, an
    envelope, noise, or another voice. Rendering with no input is silent, which
    is what "a processor with no input" should mean.

    `length` and `tension` are live parameters; both already enter the modal
    frequencies (`f_n` scales as `1/L` and as `sqrt(T)`), so a retune rebuilds the
    frequency tables rather than changing the algorithm. They are the two a player
    actually moves: stopping a string shortens it, and vibrato swings both.
    `density` and `stiffness` also feed the frequencies but are physics constants
    of the instrument, so they are plain attributes, not `Param`s.
    """

    length = Param(1.0, "m", 0.05, 5.0, doc="speaking length of the string")
    tension = Param(1200.0, "N", 1.0, 1.0e5, doc="string tension")

    def __init__(self, length: float = 1.0, tension: float = 1200.0,
                 density: float = 0.012, stiffness: float = 0.014,
                 damping: np.ndarray | None = None, mode_num: int = 64,
                 strike_pos: float = STRIKE_POS, name: str | None = None):
        if damping is None:
            damping = np.exp(np.arange(1, mode_num + 1) * 0.18)
        damping = np.asarray(damping, dtype=float)
        if damping.shape != (mode_num,):
            raise ValueError(
                f"damping must have one value per mode, got shape "
                f"{damping.shape} for mode_num={mode_num}"
            )
        if damping.min() < 0.0:
            raise ValueError("damping must be non-negative")

        self.density = float(density)
        self.stiffness = float(stiffness)
        self.strike_pos = float(strike_pos)
        self.gamma = damping
        self.mode_num = int(mode_num)

        # P_n = n*pi, the only mode-indexed shape the update needs. It stays a
        # constant ROM no matter how `length` and `tension` move.
        self.P = np.arange(1, mode_num + 1, 1.0) * np.pi
        self.strike_weight = np.sin(self.P * self.strike_pos)

        self.u = np.zeros(mode_num)
        self.u_dot = np.zeros(mode_num)
        #: The (length, tension) the tables were last built for.
        self._tuned_key: tuple | None = None
        self._built_sr: float | None = None
        #: Seconds per sample. A default until `prepare` supplies the real rate,
        #: so E/C/S always exist and the block is usable without `prepare`.
        self.dt: float = 1.0 / 48000.0

        # The tables must exist before `super().__init__`, because that ends by
        # calling `reset`, which reads them.
        self._update_tables(float(length), float(tension))

        super().__init__(name=name, length=length, tension=tension)

    # -- coefficient tables ------------------------------------------------
    def _update_tables(self, length: float, tension: float) -> None:
        """Rebuild everything that depends on `length` and `tension`.

        `omega_n^2 = (P_n/L)^2 * (A + B*P_n^2)` with `A = T/mu` and
        `B = (S/mu)/L^2`, so two scalars carry the whole dependence on `T` and
        `L`. Keeping them separate is what lets the per-mode work stay a
        multiply-add against a constant `P`.
        """
        density, stiffness = self.density, self.stiffness
        A = tension / density
        B = stiffness / (density * length * length)
        P = self.P

        self.omega0_sq = (A + B * P * P) * (P / length) ** 2
        self.damped_omega = np.sqrt(
            np.clip(self.omega0_sq - self.gamma ** 2, _OMEGA_D_FLOOR, None))

        # K_n = (2/(mu*L)) * sin(n*pi*x_f/L) is the per-mode weight of a point
        # force. `static_weight` folds in 1/omega0^2, so x*static_weight is
        # (x*K_n)/omega0^2 -- the static part of the forced response.
        self.static_weight = (2.0 / (density * length) * self.strike_weight
                              / self.omega0_sq)

        # n*(-1)**n is the mode sign in the bridge-force sum, taken from the
        # integer mode index: P/pi is only integral up to rounding, and
        # (-1.0)**12.99999999 is NaN.
        mode = np.arange(1, self.mode_num + 1, 1.0)
        self.sum_weight = mode * ((-1.0) ** mode) * tension / length

        self._rebuild_dt()

    def _rebuild_dt(self) -> None:
        """Rebuild the coefficients that combine the frequencies with `dt`.

        These are the E, C, S of MATH.md 6.1. They were render constants; now that
        `length` and `tension` can move they are rebuilt whenever the frequency
        tables are, which is why the trig sits here and not in the sample loop.
        """
        dt = self.dt
        self.exp_damp = np.exp(-self.gamma * dt)
        self.cosines = np.cos(self.damped_omega * dt)
        self.sines = np.sin(self.damped_omega * dt)
        # The forced response needs E*C and E*S separately from C and S.
        self.ec = self.exp_damp * self.cosines
        self.es = self.exp_damp * self.sines

    def _retune(self, length: float, tension: float) -> None:
        """Point the tables at a new `(length, tension)`.

        `u = q - x*K_n` and `K_n` carries the frequencies, so `u` is not a physical
        coordinate. But `q = u + x*K_n`, and at the moment of the retune `u` still
        holds `q_old - x*K_n_old` while `K_n` has just become `K_n_new`, so

            q_new = q_old + x*(K_n_new - K_n_old)

        which is exactly the right answer: the displacement stays where it was and
        only its static part is re-expressed. Rewriting `K_n` therefore leaves `q_n`
        continuous with no explicit conversion -- the content of MATH.md 6.1.1.
        Carrying `u` across an old/new table pair instead would step `q` by the same
        amount twice, ~3e-4 at the strike against a signal of ~3e-6, an audible click.

        This is separate from `_update_tables` only to name the reason.
        """
        self._update_tables(length, tension)

    # -- library protocol --------------------------------------------------
    def prepare(self, ctx) -> None:
        super().prepare(ctx)
        self.dt = 1.0 / float(ctx.sr)
        self._rebuild_dt()
        self._tuned_key = self._key()
        self._built_sr = float(ctx.sr)

    def _key(self) -> tuple:
        return (float(self.p["length"]), float(self.p["tension"]))

    def sim_step(self, x: float):
        """Advance one sample under force `x` and return the bridge force.

        Method A from MATH.md 6.1, solved for an *input* rather than a stored
        excitation. The exact solution of `q'' + 2g q' + w q = x(t)*K` over one
        step, with the force held at its value at the start of the step, is

            q'  = EC*q + ES*(q' + g*q)/wd + (x*K/w)*(1 - EC - g*ES/wd)
            q'' = EC*q' - ES*(w*q + g*q')/wd + (x*K/w)*(g + w*ES/wd - g*EC)

        with `EC = E*cos(wd*dt)` and `ES = E*sin(wd*dt)`. Only the first is needed
        for the output; the second carries the state. Both signs are checked against
        the closed form: a constant force from rest must reproduce
        `(x*K/w)*(1 - e^{-gt}(cos(wd t) + (g/wd) sin(wd t)))`, and it does to 3e-10.

        The `x*K` terms are the forced response. Without them the update would only
        ever see the homogeneous variable and a force applied from rest would do no
        work at all -- `q` would sit at its static value and never ring. The
        `(x*K/w)` factor is per mode, which is why the input can stay a single
        number.
        """
        q = self.u
        q_dot = self.u_dot
        g = self.gamma
        wd = self.damped_omega

        out = q.dot(self.sum_weight)

        f_over_w = x * self.static_weight          # (x*K_n) / omega0^2
        free = self.exp_damp * (q * self.cosines
                                + (q_dot + g * q) * self.sines / wd)
        self.u = free + f_over_w * (1.0 - self.ec - g * self.es / wd)

        free_v = self.exp_damp * (q_dot * self.cosines
                                  - (self.omega0_sq * q + g * q_dot)
                                  * self.sines / wd)
        self.u_dot = (free_v + f_over_w
                      * (g + self.omega0_sq * self.es / wd - g * self.ec))
        return out

    def reset(self):
        super().reset()
        self.u = np.zeros(self.mode_num)
        self.u_dot = np.zeros(self.mode_num)

    def process(self, x: float, ctx) -> float:
        sr = float(ctx.sr)
        if self._built_sr != sr:
            # `prepare` was skipped (or the rate changed): stay usable.
            self.dt = 1.0 / sr
            self._rebuild_dt()
            self._built_sr = sr
        key = self._key()
        if key != self._tuned_key:
            self._tuned_key = key
            self._retune(*key)
        return self.sim_step(float(x))


if __name__ == "__main__":
    from synthlab.ext.io import play

    mode_N = 64
    index = np.arange(1, mode_N + 1, 1)
    damping = np.array(list(map(lambda n: np.exp(n * 0.18), index)))

    rhythm = "|x-x-|xxxx|----|"      # eighth notes, sixteenth-note slots at 120 bpm
    sim = StringSim(length=0.86, tension=1400, density=0.012,
                    stiffness=0.014, damping=damping, mode_num=mode_N)
    strike = StrikeForce(rhythm, bpm=90.0, amplitude=1.4)

    audio = render(Chain(strike, sim), 6.0)
    play(audio)
