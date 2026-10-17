"""
The render context.

A `Context` is the environment handed to every `process` call: the sample rate, the
current sample index, and a seeded random generator. It is plain and mutable because
the render loop advances it once per sample.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np


@dataclass
class Context:
    """Per-render environment, passed to every `process` call.

    Deterministic on purpose: a patch is reproducible from (graph, parameters, seed).
    Random blocks draw from `rng`, never from the global numpy generator, so two
    algorithms can be compared on identical noise and a render can be repeated.

    Parameters
    ----------
    sr:    sample rate in Hz.
    index: the current sample number, 0-based. `render` sets this once per sample;
           blocks that need sample history (delays) read it instead of keeping their
           own counter.
    seed:  seeds `rng`. Passed through from `render(..., seed=...)`.
    """

    sr: int = 48_000
    index: int = 0
    seed: int = 0
    rng: np.random.Generator = field(default=None)  # type: ignore[assignment]

    def __post_init__(self) -> None:
        # A default_factory would be evaluated once per Context; an explicit seed
        # keeps construction cheap and makes the state obvious.
        if self.rng is None:
            self.rng = np.random.default_rng(self.seed)

    @property
    def t(self) -> float:
        """Current time in seconds."""
        return self.index / self.sr

    @property
    def dt(self) -> float:
        """Seconds per sample, `1 / sr`."""
        return 1.0 / self.sr

    def advance(self) -> None:
        """Move to the next sample."""
        self.index += 1

    def reset_time(self) -> None:
        """Restart the sample counter without touching the random state."""
        self.index = 0


__all__ = ["Context"]
