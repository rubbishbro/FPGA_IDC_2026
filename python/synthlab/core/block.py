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

Lifecycle
---------
There is one lifecycle method, `reset(ctx)`, and it is mandatory: a block that has
not been reset raises on use. It both *configures* the block for the sample rate
and *clears* its state, in that order, and it recurses into any blocks a combinator
holds. `render` calls it on the graph root, so a whole patch is initialised by
initialising the root.

Splitting configuration from clearing was the earlier design, and it was worse in
two ways. It needed two mirror-image recursive walks in every combinator, and the
order between the halves was a per-subclass convention -- `Chorus` had to call
`reset` from the end of its own `prepare` because it had just rebuilt an internal
delay line. One method makes the order explicit and impossible to get wrong.
"""

from __future__ import annotations

from typing import Any

from .parameter import Field, Param, Params

#: Names a parameter must not take. A `Param` is a data descriptor, so a parameter
#: named `reset` or `ctx` would swallow every write to that attribute or method and
#: the failure would surface much later, as something like "'float' object is not
#: callable". Rejected when the class is built.
_RESERVED_NAMES = frozenset({
    # instance attributes Block maintains itself
    "p", "params", "name", "ctx", "last_output", "_sampled_index",
    "value",
    # the protocol a block is called through
    "process", "run", "eval", "reset", "describe", "param_table", "param_changed",
    "needs_input", "prepare",
    # class-level bookkeeping
    "_fields", "_own_params", "_param_defaults", "_RESERVED_NAMES",
})


class _Namespace(dict):
    """Class-body namespace that notices a declaration being overwritten.

    A class body executes before the metaclass sees it, so a `Param` replaced by a
    method of the same name is already gone by then -- it is absent from the class,
    from `_fields`, and from the parameter store, leaving no trace to check for.
    The overwrite has to be caught as it happens, which is what this does: the
    earlier value is a `Param` and the later one is not, so the parameter was
    destroyed.
    """

    def __init__(self):
        super().__init__()
        self._lost: list[str] = []

    def __setitem__(self, key, value):
        previous = self.get(key)
        if isinstance(previous, Param) and not isinstance(value, Param):
            self._lost.append(key)
        super().__setitem__(key, value)


class _BlockMeta(type):
    """Gives every Block subclass its own parameter slots and field table.

    This has to happen in a metaclass rather than in a class attribute or
    `__init_subclass__`. A shared table on `Block` would let every subclass append
    to one global list (so `Oscillator` would appear to have `cutoff`, `gate`,
    `attack`, ...), and `__init_subclass__` never runs for `Block` itself.

    Slots are assigned once, here, and never change. The descriptor and the value
    array both address a parameter by its slot, so a name never has to be resolved
    at run time.
    """

    @classmethod
    def __prepare__(mcls, name, bases, **kwargs):
        return _Namespace()

    def __new__(mcls, name, bases, namespace, **kwargs):
        _synthesize(namespace)
        cls = super().__new__(mcls, name, bases, namespace, **kwargs)

        declared: dict[str, Param] = {}
        for klass in reversed(cls.__mro__):
            for key, value in vars(klass).items():
                if isinstance(value, Param):
                    declared[key] = value
        fields = []
        for slot, (key, spec) in enumerate(declared.items()):
            spec.slot = slot
            spec.name = key
            fields.append(Field(key, slot, spec))
        fields = tuple(fields)
        _reject(cls, fields, namespace)
        cls._fields = fields
        return cls


def _synthesize(namespace) -> None:
    """Turn a bare `param_names` tuple into real `Param` declarations.

    A class that declares its parameters by name -- which is what wrapping a
    compiled kernel wants, since the values have to line up with the kernel's
    argument order -- gets the descriptors built here, before they are collected.
    The default for each is the class attribute of the same name, captured now
    because the descriptor replaces it.

    There is a naming trap: a class-body attribute called `params` would shadow the
    instance's parameter store, so the list of names goes in `param_names`. `params`
    is still accepted for compatibility but is rejected if it is not a tuple of
    strings.
    """
    names = namespace.get("param_names")
    if names is None and "state" in namespace:
        legacy = namespace.get("params")
        if legacy is not None and not isinstance(legacy, tuple):
            raise TypeError(
                "a class-body attribute named `params` must be the tuple of "
                "parameter names; it now collides with the instance's parameter "
                "store. Rename it to `param_names`."
            )
        names = legacy
    if not names:
        return
    namespace._defaults = {key: namespace.get(key, 0.0) for key in names}
    for key in names:
        namespace[key] = Param(namespace._defaults[key])


def _reject(cls, fields: tuple, namespace) -> None:
    """Refuse declarations that cannot work, at class-creation time.

    Two ways a parameter name breaks, and the second one is easy to miss:

    * It collides with a `Block` attribute or method, so the descriptor swallows
      writes to that attribute.
    * The class body assigns a *method* of the same name. That assignment replaces
      the `Param` in the class namespace before the metaclass runs, so the
      declaration is destroyed rather than shadowed: the parameter does not exist,
      `params` rejects it, and `self.<name>` is a bound method where a number was
      expected. `ADSR` had a `release` parameter and a `release()` method; the
      method won and the parameter silently vanished. The finished class gives no
      sign of this, which is why the check reads the namespace the body produced.
    """
    names = {f.name for f in fields}
    clashes = sorted(names & _RESERVED_NAMES)
    if clashes:
        raise TypeError(
            f"{cls.__name__} declares parameter(s) "
            f"{', '.join(repr(c) for c in clashes)}, which collide with a Block "
            f"attribute or method of the same name. A `Param` is a data "
            f"descriptor, so it would silently swallow every write to that "
            f"attribute. Rename the parameter."
        )

    lost = sorted(getattr(namespace, "_lost", ()))
    if lost:
        raise TypeError(
            f"{cls.__name__} declares {', '.join(repr(n) for n in lost)} as a "
            f"parameter and then assigns something else of the same name, so the "
            f"`Param` is overwritten and the parameter does not exist. A method and "
            f"a parameter cannot share a name; rename one of the two."
        )


class Block(metaclass=_BlockMeta):
    """A per-sample processor.

    Subclass and implement `process(self, x, ctx)`. Declare parameters with `Param`.
    Keep all state on `self` and clear it in `reset(ctx)`, calling
    `super().reset(ctx)`.
    """

    #: Populated by the metaclass; declared here only so static readers see them.
    _fields: tuple = ()

    #: Whether `process` takes an input sample. Generators set this to False.
    needs_input: bool = True

    def __init__(self, name: str | None = None, **params):
        object.__setattr__(self, "params", Params(self, self._fields))
        for key, value in params.items():
            if key not in self.params:
                raise TypeError(
                    f"{type(self).__name__} has no parameter {key!r}; "
                    f"known: {sorted(self.params.names())}"
                )
        self.params.set_defaults(params)
        self.params.warn_out_of_range()

        self.name = name or type(self).__name__
        self.ctx: Any = None
        #: The most recent output sample, maintained by `eval`/`run`.
        self.last_output: float = 0.0
        #: Context index this block was last driven at, so a reader can tell whether
        #: `last_output` is current for the sample being computed.
        self._sampled_index: int | None = None
        #: Set by `reset(ctx)`; `eval` and `run` refuse to work without it.
        self._initialized: bool = False

    # -- lifecycle ---------------------------------------------------------
    def reset(self, ctx) -> None:
        """Configure for `ctx` and clear state, in that order.

        Subclasses call `super().reset(ctx)` first, then rebuild whatever depends
        on the sample rate and zero their own state. State arrays are sized from
        what the configuration step produced, which is why the order is fixed here
        rather than left to each subclass.

        Idempotent: calling it again with the same context must give the same
        starting conditions, so a block can be re-rendered deterministically.
        """
        self.ctx = ctx
        self.last_output = 0.0
        self._sampled_index = None
        self._initialized = True

    def param_changed(self, name: str) -> None:
        """Called after a parameter of this block is assigned a different value.

        Blocks that cache anything derived from their parameters override this and
        mark the cache stale; the next `process` rebuilds it. The default is to do
        nothing, which is correct for a parameter read fresh every sample.

        This is a hook, not a policy: it does not say *which* parameters matter or
        what "stale" costs. Those are internal to the block.
        """

    def _require_initialized(self) -> None:
        if not self._initialized:
            raise RuntimeError(
                f"{type(self).__name__} was used before it was reset. Call "
                f"reset(ctx) first -- for a graph, reset the root and it will "
                f"propagate."
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
        self._require_initialized()
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
            self._require_initialized()
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
        for field in self._fields:
            value = self.params[field.name]
            shown = f"{value:.5g}" if isinstance(value, (int, float)) else repr(value)
            rows.append(f"    {field.name:<16} {shown:>12} {field.unit}")
        return "\n".join(rows)

    def param_table(self) -> dict[str, Any]:
        """A copy of the live parameter values."""
        return self.params.all()


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
        self._require_initialized()
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
