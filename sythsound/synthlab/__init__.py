"""
synthlab -- a from-scratch electronic music synthesis experiment bench.

Two layers
----------
``synthlab.core``
    The abstractions and nothing else: `Block`, `Source`, `Param`, `Context`, the
    combinators, and the render helpers. No oscillators, no filters, no audio
    device, no plotting. It imports nothing from ``ext`` and runs if you delete
    ``synthlab/ext`` entirely.

``synthlab.ext``
    The concrete DSP built on those abstractions: oscillators, filters, envelopes,
    effects, instruments, analysis, audio I/O, plotting.

This module is a thin, *lazy* convenience surface over both, so the short form
works without the layers bleeding into each other:

    from synthlab import Oscillator, MoogLadder, Chain, Modulated, Amp, render

Names are resolved on first access, not at import time. That matters: without
laziness, importing ``synthlab.core`` would execute this file, which would import
``synthlab.ext``, and the "core stands alone" property would be false. With it,

    import synthlab.core          # loads only the abstractions
    from synthlab.core import Block, Param, render

stays honest, and ``import synthlab`` does not pull in matplotlib or sounddevice.

For the smallest dependency footprint, import from the layer you want directly:

    from synthlab.core import Block, Param, Context, render
    from synthlab.ext import generators, effects
    from synthlab.ext.generators import FMOscillator
"""

from __future__ import annotations

from .core import (
    TAU,
    Amp,
    Block,
    Chain,
    Context,
    Modulated,
    Parallel,
    Param,
    Source,
    render,
    render_into,
    render_note,
)

__version__ = "0.3.0"

# Implementation name -> the ext module that defines it. Used by the lazy loader.
_LAZY: dict[str, str] = {}
for _module, _names in {
    "generators": (
        "FMOscillator", "Noise", "Oscillator", "Scanner", "Shape",
        "SuperOscillator", "expo_shape", "from_harmonics", "from_samples",
        "from_spectrum", "lfo", "morph", "polyblep", "power_shape", "pulse",
        "saw", "sine", "square", "triangle",
    ),
    "processors": (
        "DESIGNS", "Biquad", "LowpassGate", "MoogLadder", "OnePole",
        "OnePoleHighpass", "StateVariableFilter", "biquad", "clamp_cutoff",
        "design_bandpass", "design_highpass", "design_highshelf",
        "design_lowpass", "design_lowshelf", "design_notch", "design_peak",
        "one_pole_alpha",
    ),
    "modulators": (
        "ADSR", "Constant", "EnvelopeFollower", "SampleHold", "Smoothed",
        "curve_expo", "curve_pow",
    ),
    "effects": (
        "Allpass", "Bitcrush", "Chorus", "Comb", "DcBlocker", "DelayLine",
        "Flanger", "Gain", "Phaser", "Reverb", "Waveshaper",
    ),
    "voices": ("Polyphony", "Voice", "hz_to_midi", "midi_to_hz", "note_to_hz"),
    "presets": (
        "PATCHES", "patch_fm", "patch_pluck", "patch_subtractive", "patch_supersaw",
        "patch_wavetable",
    ),
    "analysis": (
        "cents_error", "crest_factor", "describe_aliasing", "dominant_frequency",
        "envelope", "harmonic_amplitudes", "peak_frequencies", "report", "rms",
        "spectrum", "thd",
    ),
}.items():
    for _name in _names:
        _LAZY[_name] = _module


def __getattr__(name: str):
    """Resolve an implementation name on first use (PEP 562).

    Keeps `from synthlab import Oscillator` working while leaving `synthlab.ext`
    unimported until something actually asks for an implementation.
    """
    module = _LAZY.get(name)
    if module is None:
        raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
    from importlib import import_module

    value = getattr(import_module(f".ext.{module}", __name__), name)
    globals()[name] = value  # cache so later lookups skip the loader
    return value


def __dir__() -> list[str]:
    return sorted(set(globals()) | set(_LAZY))


__all__ = [
    # core
    "TAU", "Amp", "Block", "Chain", "Context", "Modulated", "Parallel", "Param",
    "Source", "render", "render_into", "render_note",
    # implementations (resolved lazily)
    *sorted(_LAZY),
    "__version__",
]
