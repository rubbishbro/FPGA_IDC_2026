"""
Optional JIT acceleration for custom per-sample algorithms.

You do not need this module. The interpreter path in `synthlab.core` is the
reference implementation and is fast enough for offline work: measured on this
machine, a 20-block chain renders about 5x faster than real time, and a single
block about 23x.

Reach for numba when a block you wrote is genuinely hot -- a per-sample loop doing
heavier maths (ladder filters, physical models, granular clouds) that you want to
run in real time or sweep over thousands of parameter combinations.

Two things to know before using it
----------------------------------
1. numba compiles *functions*, not objects. A kernel takes floats and returns
   floats; the Block wrapper below carries the state and the parameters.
2. The first call pays compilation cost (seconds). Call `warmup()` once, or accept
   the hitch the first time you play.

Example
-------
    import math
    from synthlab.jit import FastBlock

    class OnePole(FastBlock):
        params = ("cutoff", "sr")
        state = ("prev",)
        cutoff = 800.0
        sr = 48000.0

        def kernel(self, x, cutoff, sr, prev):
            a = 1.0 - math.exp(-2.0 * math.pi * cutoff / sr)
            y = prev + a * (x - prev)
            return y, y      # (output, *new_state)

    lp = OnePole()           # or OnePole(cutoff=1200.0) to override a default
    lp2 = OnePole(cutoff=300.0)   # independent parameters and state
"""

from __future__ import annotations

import math
from typing import Callable, Sequence
import numpy as np

from ..core import Block, Param, Source

try:
    from numba import njit

    HAVE_NUMBA = True
except Exception:  # pragma: no cover - numba is optional
    HAVE_NUMBA = False

    def njit(*args, **kwargs):  # type: ignore
        """Fallback: return the plain function, so code keeps working without numba."""
        if args and callable(args[0]):
            return args[0]

        def deco(fn):
            return fn

        return deco


__all__ = [
    "FastBlock",
    "kernel",
    "warmup",
]


def kernel(fn: Callable | None = None, **njit_kwargs):
    """Mark a per-sample function for compilation.

    Use as `@kernel` or `@kernel(cache=True, fastmath=True)`. The signature must
    be all-scalar: `fn(*inputs, *params, *state) -> (output, *new_state)`.

    `fastmath=True` is worth trying for oscillator-heavy code, but it permits
    reassociation -- avoid it for filter accumulators where you care about exact
    denormal and rounding behaviour.
    """
    njit_kwargs.setdefault("cache", False)

    def deco(func: Callable) -> Callable:
        return njit(func, **njit_kwargs)

    if fn is not None:
        return deco(fn)
    return deco


class _FastBlockMeta(type):
    """Builds `_param_defaults` at class-creation time from the `params` mapping.

    Parameters must be declared on the *class*, not injected per instance: the
    graph flattener keys parameters by block instance, and two instances of the
    same class sharing one parameter table would silently cross-talk.
    """

    def __new__(mcls, name, bases, namespace, **kwargs):
        params = namespace.get("params", ())
        cls = super().__new__(mcls, name, bases, namespace)
        for key in params:
            # Defaults were captured in `_defaults` by __init_subclass__.
            default = getattr(cls, "_defaults", {}).get(key, 0.0)
            setattr(cls, key, Param(default))
        return cls


class FastBlock(Block, metaclass=_FastBlockMeta):
    """Wrap a compiled kernel as a Block.

    Declare parameters and state as class attributes:

        class OnePole(FastBlock):
            params = ("cutoff",)
            state = ("prev",)
            cutoff = 800.0          # a plain value, read as the parameter default

            def kernel(self, x, cutoff, prev):
                # must return (output, *new_state)
                ...

    Argument order is `(sample, *params, *state)`, and the return order is
    `(output, *new_state)`.
    """

    params: tuple[str, ...] = ()
    state: tuple[str, ...] = ()

    def __init_subclass__(cls, **kwargs):
        super().__init_subclass__(**kwargs)
        # A class attribute named like a parameter is its default; capture it now
        # because Param will shadow the plain value afterwards.
        cls._defaults = {
            key: getattr(cls, key) for key in cls.params if key != "params"
        }

    def __init__(self, name: str | None = None, **overrides):
        defaults = getattr(type(self), "_defaults", {})
        merged = dict(defaults)
        merged.update(overrides)
        super().__init__(name=name, **merged)
        self._state_values = {key: 0.0 for key in self.state}

    def reset(self) -> None:
        if hasattr(self, "_state_values"):
            self._state_values = {key: 0.0 for key in self.state}

    def declares_state_p(self) -> bool:
        return bool(self.state)

    def read_state(self) -> dict[str, float]:
        return dict(self._state_values)

    def write_state(self, values: dict[str, float]) -> None:
        self._state_values.update(values)

    def kernel(self, x: float, *args):  # pragma: no cover - user supplied
        raise NotImplementedError

    def _compiled(self):
        """Compile the kernel once per class, not once per instance."""
        cls = type(self)
        fn = getattr(cls, "_compiled_kernel", None)
        if fn is None:
            base = cls.kernel
            fn = kernel(base.__func__ if hasattr(base, "__func__") else base)
            cls._compiled_kernel = fn
        return fn

    def process(self, x: float, ctx) -> float:
        fn = self._compiled()
        args = [x]
        args.extend(self.p[key] for key in self.params)
        args.extend(self._state_values[key] for key in self.state)

        result = fn(*args)
        if not self.state:
            return float(result)

        out = float(result[0])
        for slot, key in enumerate(self.state):
            self._state_values[key] = float(result[1 + slot])
        return out


def warmup(*blocks: Block) -> float:
    """Compile the kernels behind `blocks` by rendering a few samples.

    Returns the wall-clock seconds spent, so you can see what compilation costs.
    """
    import time

    from ..core import Context

    ctx = Context(sr=48_000)
    t0 = time.perf_counter()
    for block in blocks:
        block.prepare(ctx)
        is_source = isinstance(block, Source)
        for i in range(4):
            ctx.index = i
            if is_source:
                block.run(ctx)
            else:
                block.run(0.0, ctx)
    return time.perf_counter() - t0
