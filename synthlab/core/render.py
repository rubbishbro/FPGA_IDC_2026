"""
Offline rendering: turn a graph into a numpy array.

These are conveniences over the sample loop, not a second execution path -- they call
`Block.drive` exactly like the combinators do, so an offline render and a live one
produce identical samples.
"""

from __future__ import annotations

import numpy as np

from .block import Block
from .context import Context

__all__ = ["render", "render_into", "render_note"]


def render(
    block: Block,
    seconds: float,
    sr: int = 48_000,
    seed: int = 0,
    input_signal: np.ndarray | None = None,
    reset: bool = True,
) -> np.ndarray:
    """Run `block` over `seconds` of audio and return a float64 array.

    Parameters
    ----------
    block:        the graph to render. A generator (a `Source`) is the common case;
                  a processor renders its response to `input_signal` or to silence.
    seconds:      how much audio to produce. Ignored when `input_signal` is shorter.
    sr:           sample rate in Hz.
    seed:         seeds `ctx.rng`, so a render is reproducible.
    input_signal: a buffer to feed in. Passing this for a generator is an error:
                  a generator takes no input, so the samples would have nowhere to go.
    reset:        clear the graph first. `True` is what you want when measuring an
                  algorithm. Pass `False` when you have already configured the graph
                  by hand -- a triggered envelope, a partly run delay, a `Voice` that
                  has received `note_on` -- because resetting would undo that setup.
    """
    n = int(round(seconds * sr))
    ctx = Context(sr=sr, seed=seed)

    if not block.needs_input and input_signal is not None:
        raise TypeError(
            f"{type(block).__name__} is a generator and produces its own signal, so "
            f"it cannot accept an input_signal. Render the generator and feed the "
            f"resulting array through a processor instead."
        )

    if reset:
        block.reset()
    block.prepare(ctx)

    out = np.empty(n, dtype=np.float64)
    if not block.needs_input:
        for i in range(n):
            ctx.index = i
            out[i] = block.eval(0.0, ctx)
        return out

    for i in range(n):
        ctx.index = i
        x = float(input_signal[i]) if input_signal is not None else 0.0
        out[i] = block.eval(x, ctx)
    return out


def render_into(
    block: Block,
    out: np.ndarray,
    sr: int = 48_000,
    seed: int = 0,
    reset: bool = True,
) -> np.ndarray:
    """Render into a caller-owned buffer, avoiding an allocation per call.

    Same semantics as `render`; the buffer's length decides the duration.
    """
    ctx = Context(sr=sr, seed=seed)
    if reset:
        block.reset()
    block.prepare(ctx)
    for i in range(out.size):
        ctx.index = i
        out[i] = block.eval(0.0, ctx)
    return out


def render_note(
    voice: Block,
    freq: float,
    seconds: float,
    sr: int = 48_000,
    velocity: float = 1.0,
    hold: float | None = None,
    seed: int = 0,
) -> np.ndarray:
    """Trigger `voice` and render it -- the convenient path for note-based patches.

    `hold` is how long the gate stays high; the rest of `seconds` is the release
    tail. It defaults to holding for most of the render.

    Works with anything exposing `note_on`/`note_off`, which means `Voice` and
    `Polyphony`; those come from `synthlab.ext`, not from core.
    """
    n = int(round(seconds * sr))
    ctx = Context(sr=sr, seed=seed)
    voice.reset()
    voice.prepare(ctx)

    if hasattr(voice, "note_on"):
        voice.note_on(freq, velocity)
    hold_n = int(round((hold if hold is not None else seconds * 0.6) * sr))

    out = np.empty(n, dtype=np.float64)
    for i in range(n):
        ctx.index = i
        if i == hold_n and hasattr(voice, "note_off"):
            voice.note_off()
        out[i] = voice.eval(0.0, ctx)
    return out
