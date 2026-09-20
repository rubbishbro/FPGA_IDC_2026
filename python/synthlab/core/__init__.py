"""
synthlab.core -- the abstractions, with no concrete DSP in them.

This package is deliberately self-contained: it imports nothing from
`synthlab.ext`, and everything here works without any oscillator, filter or effect
existing. Delete `synthlab/ext` and this still imports and runs.

What lives here
---------------
* `Param`      -- live parameter declaration
* `Block`      -- a per-sample processor
* `Source`     -- a per-sample generator (takes no input)
* `Context`    -- sample rate, sample index, seeded RNG
* `Chain`, `Parallel`, `Modulated`, `Amp` -- composition and routing
* `render`, `render_into`, `render_note`   -- offline rendering

What does not
-------------
Oscillators, filters, envelopes, effects, analysis, audio I/O, plotting. Those are
implementations layered on these abstractions and live in `synthlab.ext`.

The contract for a new block
----------------------------
Subclass `Block` (processor) or `Source` (generator), declare parameters with
`Param`, implement `process`, and clear state in `reset` after calling
`super().reset()`. Combinators call `drive`, which resolves the two shapes for you,
so nothing outside `core.block` needs to know which kind a block is.
"""

from __future__ import annotations

from .block import Block, Param, Source
from .compose import Amp, Chain, Modulated, Parallel
from .context import Context
from .render import render, render_into, render_note

#: Full turn, as a convenience for waveform maths.
TAU = 6.283185307179586

__version__ = "0.3.0"

__all__ = [
    "TAU",
    "Param",
    "Block",
    "Source",
    "Context",
    "Chain",
    "Parallel",
    "Modulated",
    "Amp",
    "render",
    "render_into",
    "render_note",
]
