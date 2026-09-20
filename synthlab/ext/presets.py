"""
Ready-made patches.

Each `patch_*` function returns a configured `Voice`. They are starting points to
edit, not a preset system: every value is a plain parameter you can reach in and
change, and the routing is rebuilt by `Voice.wire()` if you swap a component.

    v = patch_subtractive(220.0)
    v.shaper.p["resonance"] = 0.8      # reach in
    v.source.p["wave"] = "square"
    v.wire()                           # re-route after changing components

These live outside `synthlab.ext.voices` because they are opinions about a sound,
while `Voice`/`Polyphony` are machinery. Nothing in the library depends on them.
"""

from __future__ import annotations

from typing import Callable

from ..core import Chain, Modulated, Param
from .effects import Comb
from .generators import FMOscillator, Noise, Oscillator, SuperOscillator, WavetableOscillator
from .modulators import ADSR
from .processors import Biquad, MoogLadder
from .voices import Voice


# Conventional starting points
# ---------------------------------------------------------------------------

__all__ = [
    "patch_fm",
    "patch_pluck",
    "patch_subtractive",
    "patch_supersaw",
    "patch_wavetable",
]


def patch_subtractive(freq: float = 220.0, resonance: float = 0.35,
                      env_amount: float = 1800.0) -> Voice:
    """Saw through a resonant Moog ladder, swept by a dedicated filter envelope."""
    filt_env = ADSR(attack=0.005, decay=0.35, sustain=0.25, release=0.3, curve=3.0)
    voice = Voice(
        source=Oscillator(freq=freq, wave="saw"),
        shaper=MoogLadder(cutoff=900.0, resonance=resonance, drive=1.2),
        amp=ADSR(attack=0.01, decay=0.3, sustain=0.7, release=0.35, curve=2.0),
        filter_env_amount=env_amount,
    )
    voice.filter_env = filt_env
    voice.wire()
    return voice


def patch_fm(freq: float = 261.63, ratio: float = 2.0, index: float = 4.0) -> Voice:
    """Two-operator FM with an enveloped modulation index -- the classic e-piano.

    The timbre envelope must run *before* the carrier writes `index`, so the
    routing is `Modulated(carrier, index_env, "index", depth=-index, base=index)`:
    the envelope starts at 1.0, so the index starts at `index` and falls to 0.
    """
    source = FMOscillator(freq=freq, ratio=ratio, index=index)
    amp = ADSR(attack=0.002, decay=1.1, sustain=0.0, release=0.5, curve=4.0)
    index_env = ADSR(attack=0.001, decay=0.7, sustain=0.0, release=0.4, curve=4.0)

    voice = Voice(source=source, shaper=None, amp=amp, name="fm")
    # Replace the plain source with the modulated one, then re-wire.
    voice.source = Modulated(source, index_env, "index", depth=-index, base=index)
    voice.index_env = index_env
    voice.index_source = source
    voice.wire()
    return voice


def patch_pluck(freq: float = 164.81, decay: float = 0.997) -> Voice:
    """Karplus-Strong style pluck: a noise burst into a tuned comb delay.

    The comb's `delay` is the string length (seconds) and `feedback` its decay, so
    this patch is really a demonstration of tuning a delay line as an instrument.
    The amp envelope is a short gate; the string itself provides the tail.
    """
    from .effects import Comb

    burst = Chain(Noise(kind="white", amplitude=1.0, name="exciter"),
                  Biquad(cutoff=2500.0, q=0.7, mode="lowpass"))
    comb = Comb(delay=1.0 / freq, feedback=decay, feedforward=0.0, name="string")

    voice = Voice(source=burst, shaper=comb, amp=None, name="pluck")
    voice.freq = freq
    voice.wire()
    return voice


def patch_wavetable(harmonics: list[float] | None = None, freq: float = 220.0) -> Voice:
    """Additive wavetable oscillator with an amplitude envelope."""
    table = WavetableOscillator.from_harmonics(harmonics or [1.0, 0.5, 0.3, 0.2, 0.1])
    return Voice(
        source=WavetableOscillator(table=table, freq=freq),
        shaper=Biquad(cutoff=6000.0, q=0.7, mode="lowpass"),
        amp=ADSR(attack=0.02, decay=0.4, sustain=0.7, release=0.6),
    )


def patch_supersaw(freq: float = 220.0, voices: int = 7) -> Voice:
    """Detuned supersaw into a gentle filter -- the trance lead."""
    return Voice(
        source=SuperOscillator(freq=freq, voices=voices, detune=0.14),
        shaper=Biquad(cutoff=4000.0, q=0.9, mode="lowpass"),
        amp=ADSR(attack=0.02, decay=0.3, sustain=0.8, release=0.5, curve=2.0),
    )


PATCHES: dict[str, Callable[[], Voice]] = {
    "subtractive": patch_subtractive,
    "fm": patch_fm,
    "pluck": patch_pluck,
    "wavetable": patch_wavetable,
    "supersaw": patch_supersaw,
}
