"""
synthlab.ext -- concrete implementations, built on `synthlab.core`.

Everything here depends on core; nothing in core depends on here. That is the whole
point of the split: you can read, test or replace this package without touching the
abstractions, and `synthlab.core` still works if you delete this directory.

Layout
------
Generators (`Source` subclasses -- produce signal, take no input)
    generators.py   Oscillator, WavetableOscillator, FMOscillator,
                    AdditiveOscillator, SuperOscillator, Noise, polyblep
    modulators.py   ADSR, AD, LFO, Ramp, Constant, EnvelopeFollower, Smoothed

Processors (`Block` subclasses -- transform the signal they are given)
    processors.py   Biquad, StateVariableFilter, MoogLadder, OnePole,
                    OnePoleHighpass, LowpassGate
    effects.py      DelayLine, Allpass, Comb, Reverb, Chorus, Flanger, Phaser,
                    Waveshaper, Bitcrush, DcBlocker, Gain

Instruments
    voices.py       Voice, Polyphony, note/pitch helpers
    presets.py      patch_subtractive, patch_fm, patch_pluck, ... (opinions, not machinery)

Measurement and I/O
    analysis.py     spectrum, peak_frequencies, thd, harmonic_amplitudes, report, ...
    io.py           save_wav, load_wav, play, record, to_stereo, ...
    plotting.py     waveform, spectrum_plot, spectrogram, compare, ...

Optional acceleration
    jit.py          numba fusion for hot custom loops (not required by anything)

Import the module you need directly:

    from synthlab.ext import generators, effects
    from synthlab.ext.generators import FMOscillator

Submodules are NOT imported here, so `import synthlab.ext` stays cheap and does not
drag in matplotlib (plotting) or sounddevice (io).
"""

from __future__ import annotations

__all__ = [
    "generators",
    "modulators",
    "processors",
    "effects",
    "voices",
    "presets",
    "analysis",
    "io",
    "plotting",
    "jit",
]
