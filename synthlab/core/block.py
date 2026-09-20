"""
Blocks: the per-sample processing element everything else is built from.

Two kinds exist, and the distinction is the central abstraction of the library:

* `Block` -- a *processor*. It transforms the sample it is given:
  `process(self, x, ctx) -> y`. Filters, effects, and combinators are processors.
* `Source` -- a *generator*. It produces signal from nothing and takes no input:
  `process(self, ctx) -> y`. Oscillators, noise, and envelopes are generators.

Because a generator has no input parameter, feeding one into a chain where it would
replace the signal **cannot be expressed** -- it is a type error, not a silent
behaviour. Earlier versions accepted and ignored an input, which made
`Chain(osc, env)` look like it applied an envelope while actually discarding the
oscillator and emitting DC (a click on real hardware).

The `needs_input` flag and `eval` method below are how the rest of the library
consumes blocks without caring which kind it has. Callers never test `isinstance`.
"""

from __future__ import annotations

import warnings
from typing import Any

import numpy as np

from .parameter import Param


class _BlockMeta(type):
    """Gives every Block subclass its own parameter table, built from the `Param`
    descriptors in its MRO.

    This has to happen in a metaclass rather than in a class attribute or
    `__init_subclass__`. A shared dict on `Block` would let every subclass append to
    one global table (so `Oscillator` would appear to have `cutoff`, `gate`,
    `attack`, ...), and `__init_subclass__` never runs for `Block` itself.
    """

    def __new__(mcls, name, bases, namespace, **kwargs):
        cls = super().__new__(mcls, name, bases, namespace, **kwargs)
        own: dict[str, Param] = {}
        for klass in cls.__mro__:
            for key, value in vars(klass).items():
                if isinstance(value, Param):
                    own[key] = value
        cls._own_params = own
        cls._param_defaults = {k: (p.default, p.unit) for k, p in own.items()}
        return cls


class Block(metaclass=_BlockMeta):
    """A per-sample processor.

    Subclass and implement `process(self, x, ctx)`. Declare parameters with `Param`.
    Keep all state on `self` and clear it in `reset` (calling `super().reset()`).
    """

    # Populated by the metaclass; declared here only so static readers see them.
    _own_params: dict[str, Param] = {}
    _param_defaults: dict[str, tuple] = {}

    #: Whether `process` takes an input sample. Generators set this to False.
    needs_input: bool = True

    #: Names a parameter must not take, because `Param` is a data descriptor and
    #: would silently swallow every write to the attribute or method they name.
    #: Kept explicit rather than computed from the MRO: a heuristic also flags
    #: `_param_defaults` and `_own_params`, which a parameter may legitimately shadow.
    _RESERVED_NAMES = frozenset({
        # instance attributes Block maintains itself
        "p", "name", "ctx", "last_output", "_sampled_index",
        # `value` no longer exists on Block, but it was the name that once shadowed
        # the recorded output and made every envelope-driven patch go silent. It is
        # reserved so the same trap cannot be re-set. (`Constant`'s parameter is
        # `level` for this reason.)
        "value",
        # the protocol a block is called through
        "process", "run", "eval", "prepare", "reset", "describe", "param_table",
        "needs_input",
    })

    def __init__(self, name: str | None = None, **params):
        self._reject_attribute_collisions()
        self.p: dict[str, Any] = {k: v for k, (v, _) in self._param_defaults.items()}
        for key, value in params.items():
            if key not in self.p:
                raise TypeError(
                    f"{type(self).__name__} has no parameter {key!r}; "
                    f"known: {sorted(self.p)}"
                )
            self.p[key] = value
        self._warn_out_of_range()

        self.name = name or type(self).__name__
        self.ctx: Any = None
        #: The most recent output sample, maintained by `eval`/`run`.
        self.last_output: float = 0.0
        #: Context index this block was last driven at, so a reader can tell whether
        #: `last_output` is current for the sample being computed.
        self._sampled_index: int | None = None
        self.reset()

    def _reject_attribute_collisions(self) -> None:
        """Refuse a parameter whose name is already a Block attribute or method.

        `Param` is a data descriptor, so a parameter named `name`, `last_output` or
        `ctx` silently swallows every write to that attribute: `self.name` becomes a
        number, the recorded output stops being the output, and the failure surfaces
        much later as something like "'float' object is not callable". Caught here it
        is a one-line error naming the class and the parameter.
        """
        clashes = sorted(self._RESERVED_NAMES & set(self._param_defaults))
        if clashes:
            raise TypeError(
                f"{type(self).__name__} declares a parameter named "
                f"{', '.join(repr(c) for c in clashes)}, which collides with a Block "
                f"attribute or method of the same name. Because `Param` is a data "
                f"descriptor it would silently swallow every write to that attribute. "
                f"Rename the parameter."
            )

    # -- lifecycle ---------------------------------------------------------
    def reset(self) -> None:
        """Clear state so the block can be re-rendered deterministically.

        Subclasses that keep running state must call `super().reset()` and then
        re-initialise their own fields.
        """
        self.last_output = 0.0

    def prepare(self, ctx) -> None:
        """Called once before a render pass, with the sample rate and timing."""
        self.ctx = ctx

    def _warn_out_of_range(self) -> None:
        """Warn about constructor arguments outside a parameter's declared bounds.

        An out-of-range value is otherwise a silent disaster that looks like a bug in
        the library: `MoogLadder(cutoff=6000, resonance=1.5)` drives the ladder
        feedback past its stability limit and the output becomes NaN within a
        second, with no hint as to why.
        """
        for name, value in self.p.items():
            spec = self._own_params.get(name)
            if isinstance(spec, Param) and not spec.in_range(value):
                unit = f" {spec.unit}" if spec.unit else ""
                warnings.warn(
                    f"{type(self).__name__}({name}={value!r}) is outside the "
                    f"supported range [{spec.minimum}, {spec.maximum}]{unit}. "
                    f"{spec.doc or 'Results outside this range are undefined.'}",
                    RuntimeWarning,
                    stacklevel=3,
                )

    # -- the part you implement --------------------------------------------
    def process(self, x: float, ctx) -> float:
        """Compute one sample from the input. Override this in your blocks."""
        raise NotImplementedError(f"{type(self).__name__}.process")

    # -- the part the library calls ----------------------------------------
    def run(self, x: float, ctx) -> float:
        """Process one sample and record the result in `last_output`.

        Combinators call `eval`, which dispatches here. Direct callers should also
        prefer `eval`; call `run` only when the block kind is already known.
        """
        result = self.process(x, ctx)
        self.last_output = result
        self._sampled_index = ctx.index if ctx is not None else None
        return result

    def eval(self, x: float, ctx) -> float:
        """Produce one sample, whatever kind of block this is.

        This is the single place the generator/processor distinction is resolved.
        Every combinator, the render helpers and the JIT warm-up go through it, so
        adding a new kind of block means changing `Source`, not eleven call sites.
        """
        if not self.needs_input:
            result = self.process(ctx)
            self.last_output = result
            self._sampled_index = ctx.index if ctx is not None else None
            return result
        return self.run(x, ctx)

    def __call__(self, x: float, ctx) -> float:
        """`block(x, ctx)` == `block.eval(x, ctx)`."""
        return self.eval(x, ctx)

    # -- introspection -----------------------------------------------------
    def describe(self) -> str:
        """Human-readable parameter dump -- the replacement for a GUI knob panel."""
        rows = [f"{type(self).__name__}({self.name})"]
        for key, (_, unit) in self._param_defaults.items():
            value = self.p[key]
            shown = f"{value:.5g}" if isinstance(value, (int, float)) else repr(value)
            rows.append(f"    {key:<16} {shown:>12} {unit}")
        return "\n".join(rows)

    def param_table(self) -> dict[str, Any]:
        """A copy of the live parameter values."""
        return dict(self.p)


class Source(Block):
    """A generator: it produces signal from nothing and takes NO input.

    Subclasses implement `process(self, ctx)` -- there is deliberately no input
    argument, so a generator cannot be accidentally inserted where a processor is
    expected without a visible type error.
    """

    needs_input = False

    def process(self, ctx) -> float:
        raise NotImplementedError(f"{type(self).__name__}.process")

    def run(self, ctx) -> float:  # type: ignore[override]
        """Generate one sample and record it in `last_output`."""
        result = self.process(ctx)
        self.last_output = result
        self._sampled_index = ctx.index if ctx is not None else None
        return result

    def eval(self, x: float, ctx) -> float:  # type: ignore[override]
        """Ignore the input and generate a sample.

        Kept so combinators can call `eval` uniformly. The `x` argument is accepted
        and discarded on purpose -- this is the *only* place in the library where an
        input is ignored, and it exists so the callers need no special case.
        """
        return self.run(ctx)

    def __call__(self, ctx) -> float:  # type: ignore[override]
        return self.run(ctx)


__all__ = ["Param", "Block", "Source"]
