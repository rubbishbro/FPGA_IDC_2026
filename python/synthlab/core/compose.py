"""
Combinators: how blocks are wired together.

Four of them, all processors:

* `Chain`     -- serial. The output of each block feeds the next.
* `Parallel`  -- split the input into several blocks and combine the outputs.
* `Modulated` -- write a source's output into another block's parameter.
* `Amp`       -- a VCA: multiply the signal by another block's output.

None of them test what kind of block they hold. They call `eval`, which resolves
the generator/processor distinction inside `Block`. That is why this module contains
no `isinstance` checks -- the previous version had six, and every new block kind
would have meant editing all of them.
"""

from __future__ import annotations

import numpy as np

from .block import Block, Param


def _as_blocks(items) -> list[Block]:
    """Flatten nested lists/tuples of blocks into one list, rejecting anything else."""
    out: list[Block] = []
    for item in items:
        if isinstance(item, Block):
            out.append(item)
        elif isinstance(item, (list, tuple)):
            out.extend(_as_blocks(item))
        else:
            raise TypeError(f"expected Block, got {type(item).__name__}")
    return out


def _referenced_controls(blocks: list[Block]) -> set[int]:
    """Ids of blocks that another block consumes as a CONTROL signal.

    A generator referenced this way (`Amp(env)`, `Modulated(filt, env, "cutoff")`) is
    driven by the referencing block, once per sample -- so the chain must not drive
    it again, or its state would advance twice per sample and every envelope would
    run at double speed. That bug is invisible in the output's shape, which is why
    the bookkeeping is centralised here.
    """
    controls: set[int] = set()
    for block in blocks:
        for attribute in ("control", "source"):
            referenced = getattr(block, attribute, None)
            if referenced is not None:
                controls.add(id(referenced))
    return controls


class Chain(Block):
    """Serial composition: the output of each block feeds the next.

    The first element is normally a `Source` -- an oscillator or noise generator has
    nothing upstream, so its output becomes the signal.

    A control generator (an envelope, an LFO) is applied by *referencing* it:

        Chain(osc, Amp(env))                        # amplitude envelope
        Chain(osc, Modulated(filt, env, "cutoff"))  # filter envelope

    Appending one directly (`Chain(osc, env)`) is the classic silent mistake: the
    envelope ignores the oscillator and emits its own DC contour, which output
    hardware blocks, so it sounds like a click followed by silence. `reset`
    rejects that shape with a `TypeError`.
    """

    def __init__(self, *blocks, name: str | None = None):
        self.blocks = _as_blocks(blocks)
        super().__init__(name=name)

    def reset(self, ctx) -> None:
        super().reset(ctx)
        self._controls = _referenced_controls(self.blocks)

        seen: set[int] = set()
        for index, block in enumerate(self.blocks):
            if id(block) in seen:
                raise TypeError(
                    f"Chain element {index} is {type(block).__name__}, which is "
                    f"already in this chain. Sharing one instance advances its state "
                    f"twice per sample; give each position its own instance."
                )
            seen.add(id(block))

            if index > 0 and not block.needs_input and id(block) not in self._controls:
                raise TypeError(
                    f"Chain element {index} is {type(block).__name__}, a generator "
                    f"that ignores its input, so it would silently replace the signal "
                    f"built so far. Only the first element may be a generator. To "
                    f"apply a control, reference it: "
                    f"Chain(signal, Amp({type(block).__name__}(...))). To layer two "
                    f"audio sources, use Parallel(a, b)."
                )

        for block in self.blocks:
            block.reset(ctx)

    def process(self, x: float, ctx) -> float:
        controls = getattr(self, "_controls", None)
        if controls is None:
            controls = self._controls = _referenced_controls(self.blocks)

        # Drive each referenced control once, so its `last_output` is current for the
        # Amp/Modulated that reads it.
        for block in self.blocks:
            if id(block) in controls:
                block.eval(x, ctx)

        for block in self.blocks:
            if id(block) in controls:
                continue
            x = block.eval(x, ctx)
        self.last_output = x
        return x

    def describe(self) -> str:
        inner = "\n".join(
            "  " + line for block in self.blocks for line in block.describe().splitlines()
        )
        return f"Chain({self.name})\n{inner}"


class Parallel(Block):
    """Split the input into several blocks and combine their outputs.

    `op` is "sum", "mean" or "product". Generators in the mix are driven for their
    own output; processors each receive the same input.
    """

    def __init__(self, *blocks, op: str = "sum", name: str | None = None):
        self.blocks = _as_blocks(blocks)
        self.op = op
        if op not in ("sum", "mean", "product"):
            raise ValueError(f"unknown op {op!r}; known: sum, mean, product")
        super().__init__(name=name)

    def reset(self, ctx) -> None:
        super().reset(ctx)
        for block in self.blocks:
            block.reset(ctx)

    def process(self, x: float, ctx) -> float:
        outs = [block.eval(x, ctx) for block in self.blocks]
        if not outs:
            self.last_output = x
            return x
        if self.op == "sum":
            result = float(np.sum(outs))
        elif self.op == "mean":
            result = float(np.mean(outs))
        else:
            result = 1.0
            for value in outs:
                result *= value
            result = float(result)
        self.last_output = result
        return result

    def describe(self) -> str:
        inner = "\n".join(
            "  " + line for block in self.blocks for line in block.describe().splitlines()
        )
        return f"Parallel({self.name}, op={self.op})\n{inner}"


class Modulated(Block):
    """Write `source`'s output into `target`'s parameter `param`, per sample.

    This is the routing primitive that makes audio-rate modulation possible: it
    writes straight into the target's live parameter cell, so an LFO can sweep a
    filter cutoff or a sine can frequency-modulate an oscillator, and the target sees
    the new value in the same sample.

        Modulated(filt, lfo, "cutoff", base=900.0)         # filter sweep
        Modulated(carrier, env, "index", depth=-8, base=8) # timbre envelope

    Parameters
    ----------
    depth:    scales the modulator before summing into the parameter.
    base:     the value the modulation is added to. Defaults to the parameter's
              value at construction time, so a modulation block is absolute rather
              than accumulating on whatever was written last.
    additive: when False the parameter is *replaced* by `depth * modulator`.
    """

    def __init__(
        self,
        target: Block,
        source: Block,
        param: str,
        depth: float = 1.0,
        base: float | None = None,
        additive: bool = True,
        name: str | None = None,
    ):
        if param not in target.params:
            raise TypeError(
                f"{type(target).__name__} has no parameter {param!r}; "
                f"known: {sorted(target.params.names())}"
            )
        self.target = target
        self.source = source
        self.param = param
        self.depth = depth
        self.additive = additive
        super().__init__(name=name)
        # Default the base to the target's current value so a modulation block is
        # absolute rather than accumulating on the previous write.
        self.base = target.params[param] if base is None else base

    def reset(self, ctx) -> None:
        super().reset(ctx)
        self.target.reset(ctx)
        self.source.reset(ctx)

    def process(self, x: float, ctx) -> float:
        mod = self.source.eval(x, ctx)
        value = mod * self.depth
        if self.additive:
            value = self.base + value
        self.target.params.set(self.param, value)
        result = self.target.eval(x, ctx)
        self.last_output = result
        return result


class Amp(Block):
    """A VCA: multiply the incoming signal by another block's output.

    This is how an envelope becomes an audible amplitude contour:

        Chain(osc, Amp(env))

    The control must be *driven* for the sample before the `Amp` reads it. Either put
    it in the same chain (anywhere -- `Chain` drives referenced controls first) or let
    the `Amp` do it; the `_sampled_index` check guarantees exactly one advance per
    sample either way. Getting that wrong halves every envelope's duration, which
    looks like a mis-tuned envelope rather than a bug, so it is asserted in the tests.

    `gain` scales the result further. `offset` shifts the control, which is what you
    want for a tremolo that should never fully mute. Both are applied as
    `x * (control + offset) * gain`:

        Chain(osc, Amp(sweep, offset=0.5))       # a sweep that stays positive
    """

    gain = Param(1.0, doc="extra multiplier applied after the control signal")
    offset = Param(0.0, doc="added to the control signal before multiplying")

    def __init__(
        self,
        control: Block,
        gain: float = 1.0,
        offset: float = 0.0,
        name: str | None = None,
        **params,
    ):
        if not isinstance(control, Block):
            raise TypeError(
                f"Amp needs a control Block (an ADSR, an oscillator, ...), got "
                f"{type(control).__name__}"
            )
        self.control = control
        super().__init__(name=name, gain=gain, offset=offset, **params)

    def reset(self, ctx) -> None:
        super().reset(ctx)
        self.control.reset(ctx)

    def process(self, x: float, ctx=None) -> float:
        control = self.control
        index = getattr(ctx, "index", None)
        # Run the control only if it has not produced a value for this sample yet.
        if getattr(control, "_sampled_index", None) != index:
            control.eval(x, ctx)
        self.last_output = x * (control.last_output + self.offset) * self.gain
        return self.last_output

    def describe(self) -> str:
        inner = "\n".join("  " + l for l in self.control.describe().splitlines())
        return (
            f"Amp({self.name})\n"
            f"    gain {self.gain}  offset {self.offset}\n"
            f"  control:\n{inner}"
        )


__all__ = ["Chain", "Parallel", "Modulated", "Amp"]
