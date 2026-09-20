"""
Voices and polyphony: wiring the primitives into playable instruments.

A `Voice` is a small assembly, not a black box. It holds the blocks that make up
one note and the routing between them, and every part is exposed so you can reach
in and replace it:

    v = Voice()
    v.osc.wave = "saw"           # swap the waveform
    v.filter.mode = 1            # highpass
    v.osc >> v.filter            # (Chain/Parallel combinators still work on the parts)

Ready-made patches built from these classes live in `synthlab.ext.presets`; a real
instrument is just a different assembly of the same primitives.
"""

from __future__ import annotations

import math
from typing import Callable

import numpy as np

from ..core import Amp, Block, Chain, Context, Modulated, Parallel, Param, Source
from .modulators import ADSR, LFO
from .processors import Biquad, MoogLadder


__all__ = [
    "Polyphony",
    "Voice",
    "hz_to_midi",
    "midi_to_hz",
    "note_to_hz",
]


def midi_to_hz(note: float) -> float:
    """MIDI note number to frequency, A4 (note 69) = 440 Hz."""
    return 440.0 * 2.0 ** ((note - 69.0) / 12.0)


def hz_to_midi(freq: float) -> float:
    """Inverse of `midi_to_hz`; fractional values are useful for detune maths."""
    return 69.0 + 12.0 * math.log2(max(freq, 1e-9) / 440.0)


def note_to_hz(name: str) -> float:
    """'A4', 'C#3', 'Bb2' -> frequency in Hz.

    Accidentals are accumulated rather than parsed as a prefix, so 'C#3' and
    'Cb3' both work and so does the (unusual but legal) 'C##3'.
    """
    letters = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
    text = name.strip()
    if not text or text[0].upper() not in letters:
        raise ValueError(f"invalid note name {name!r}; expected e.g. 'A4', 'C#3', 'Bb2'")
    letter = text[0].upper()
    # Everything between the letter and the trailing octave digit is accidentals.
    body, octave = text[1:-1], text[-1]
    if not octave.lstrip("+-").isdigit():
        raise ValueError(f"invalid note name {name!r}; missing octave number")
    semitone = letters[letter]
    for char in body:
        if char == "#":
            semitone += 1
        elif char == "b":
            semitone -= 1
        else:
            raise ValueError(f"invalid accidental {char!r} in {name!r}")
    return midi_to_hz(12 * (int(octave) + 1) + semitone)


class Voice(Source):
    """One note of a synthesizer: source -> shaper -> amplifier.

    Blocks
    ------
    source:  anything producing signal (Oscillator, FMOscillator, Noise, ...)
    shaper:  optional filter in the signal path
    amp:     the envelope that gates the voice

    The routing is rebuilt by `wire()`, so replacing `self.source` and calling
    `wire()` is enough to change the synthesis method.

    `filter_env` optionally drives `shaper.cutoff` by `filter_env_amount`
    semitone-ish units per sample, which is the classic filter sweep. Set
    `filter_env_amount = 0` to disable it.
    """

    freq = Param(440.0, "Hz")
    velocity = Param(1.0, "", 0.0, 1.0)
    level = Param(0.8)

    def __init__(
        self,
        source: Block | None = None,
        shaper: Block | None = None,
        amp: Block | None = None,
        filter_env_amount: float = 0.0,
        name: str | None = None,
        **params,
    ):
        super().__init__(name=name, **params)
        self.source = source if source is not None else Oscillator(freq=440.0, wave="saw")
        self.shaper = shaper if shaper is not None else MoogLadder(cutoff=2000.0, resonance=0.3)
        self.amp = amp if amp is not None else ADSR(attack=0.01, decay=0.2, sustain=0.6, release=0.3)
        self.filter_env_amount = filter_env_amount
        self.filter_env: Block | None = None
        self._base_cutoff = getattr(self.shaper, "cutoff", None)
        self.wire()

    def wire(self) -> None:
        """(Re)build the inner signal path. Call after swapping a component.

        The amplitude envelope is applied through an explicit `Amp` rather than
        being appended to the chain. An envelope is a `Source`: appending it would
        discard everything upstream and output a DC contour, which is silent on real
        hardware. `Amp` also keeps the whole routing visible in `describe()`.
        """
        parts = [self.source]
        if self.shaper is not None:
            if self.filter_env is not None and self.filter_env_amount != 0.0:
                # Route the filter envelope into the cutoff, then filter. The
                # envelope is referenced by the Modulated block (which runs it) and
                # must NOT also be a standalone chain element -- a second copy would
                # be advanced twice per sample.
                parts.append(
                    Modulated(
                        self.shaper,
                        self.filter_env,
                        "cutoff",
                        depth=self.filter_env_amount,
                        base=self._base_cutoff if self._base_cutoff is not None else 1000.0,
                    )
                )
            else:
                parts.append(self.shaper)
        if self.amp is not None:
            # `Amp` runs the envelope itself, so the envelope is only referenced
            # here, never appended.
            parts.append(Amp(self.amp, name="vca"))
        self.chain = Chain(*parts)

    # -- note control ------------------------------------------------------
    def note_on(self, freq: float, velocity: float = 1.0) -> None:
        """Set the pitch and start the envelopes."""
        self.p["freq"] = freq
        self.p["velocity"] = velocity
        if hasattr(self.source, "p") and "freq" in self.source.p:
            self.source.p["freq"] = freq
        if isinstance(self.amp, ADSR):
            self.amp.p["velocity"] = velocity
            self.amp.trigger()
        elif self.amp is not None:
            self.amp.p["gate"] = 1.0
        if self.filter_env is not None and hasattr(self.filter_env, "trigger"):
            self.filter_env.trigger()

    def note_off(self) -> None:
        if isinstance(self.amp, ADSR):
            self.amp.note_off()
        elif self.amp is not None:
            self.amp.p["gate"] = 0.0
        if self.filter_env is not None and hasattr(self.filter_env, "note_off"):
            self.filter_env.note_off()

    @property
    def active(self) -> bool:
        """True while the voice is still producing sound (release included)."""
        if isinstance(self.amp, ADSR):
            return self.amp.stage != ADSR.IDLE
        return True

    # -- Block -------------------------------------------------------------
    def reset(self) -> None:
        super().reset()
        if hasattr(self, "chain"):
            self.chain.reset()

    def prepare(self, ctx) -> None:
        super().prepare(ctx)
        self.chain.prepare(ctx)

    def process(self, ctx) -> float:
        # `Voice` is a Source, so there is no input: it generates its note.
        # Keep the source pitch in sync with the voice when the voice is the
        # authority (so Modulated on the Voice's freq does the right thing).
        if hasattr(self.source, "p") and "freq" in self.source.p:
            self.source.p["freq"] = self.freq
        if self.shaper is not None and self._base_cutoff is not None:
            # Keep the modulation base in step with manual cutoff changes.
            self._base_cutoff = getattr(self.shaper, "cutoff", self._base_cutoff)
        return self.chain.run(0.0, ctx) * self.level


class Polyphony(Source):
    """A fixed pool of voices with note allocation and simple voice stealing.

    This is deliberately plain: voices are allocated round-robin with stealing of
    the oldest note when all are busy. Instruments that need a smarter allocator
    (unison, key splits, release-tail priority) should subclass and override
    `allocate`.

    `steal` controls what happens when a new note arrives with no free voice:
    "oldest" (default), "quietest", or "none" (the note is dropped).
    """

    level = Param(1.0)
    max_voices = Param(8.0, doc="informational; the pool size is fixed at construction")

    def __init__(
        self,
        voices: int = 8,
        factory: Callable[[], Voice] | None = None,
        steal: str = "oldest",
        name: str | None = None,
        **params,
    ):
        super().__init__(name=name, **params)
        if voices < 1:
            raise ValueError("need at least one voice")
        if steal not in ("oldest", "quietest", "none"):
            raise ValueError("steal must be 'oldest', 'quietest' or 'none'")
        self.steal = steal
        factory = factory or Voice
        self.voices: list[Voice] = [factory() for _ in range(voices)]
        self.p["max_voices"] = float(voices)
        # Allocation bookkeeping, exposed so you can see what the allocator did.
        self.note_voice: dict[int, int] = {}
        self.age = [0] * voices
        self._counter = 0

    def reset(self) -> None:
        super().reset()
        for voice in getattr(self, "voices", []):
            voice.reset()
        if hasattr(self, "age"):
            self.age = [0] * len(self.voices)
        if hasattr(self, "note_voice"):
            self.note_voice.clear()
        self._counter = 0

    def prepare(self, ctx) -> None:
        super().prepare(ctx)
        for voice in self.voices:
            voice.prepare(ctx)

    def allocate(self, note: int) -> Voice | None:
        """Pick a voice for `note`. Override this to change the policy."""
        for i, voice in enumerate(self.voices):
            if not voice.active:
                return voice
        if self.steal == "none":
            return None
        if self.steal == "quietest":
            idx = min(range(len(self.voices)), key=lambda i: getattr(self.voices[i], "amp", None).level
                      if hasattr(self.voices[i].amp, "level") else 0.0)
        else:
            idx = min(range(len(self.voices)), key=lambda i: self.age[i])
        return self.voices[idx]

    def note_on(self, note: int, velocity: float = 1.0) -> None:
        voice = self.allocate(note)
        if voice is None:
            return
        self._counter += 1
        self.age[self.voices.index(voice)] = self._counter
        self.note_voice[int(note)] = self.voices.index(voice)
        voice.note_on(midi_to_hz(note), velocity)

    def note_off(self, note: int) -> None:
        idx = self.note_voice.pop(int(note), None)
        if idx is not None:
            self.voices[idx].note_off()

    def all_off(self) -> None:
        for voice in self.voices:
            voice.note_off()

    def process(self, ctx) -> float:
        # `Polyphony` is a Source too: it sums its voices' own output.
        total = 0.0
        for voice in self.voices:
            total += voice.run(ctx)
        return total * self.level

    @property
    def active_voices(self) -> int:
        return sum(1 for v in self.voices if v.active)


# ---------------------------------------------------------------------------
