"""
Live parameters.

A `Param` declares a scalar a block exposes. It is deliberately *not* an enforced
property: the descriptor hands each instance its own cell in `block.p`, and that
cell is a plain slot so a modulation block can write it at audio rate. Bounds are
metadata used for diagnostics, not a clamp -- clamping on every write would cost
more than it is worth and would silently discard a legal modulation excursion.

Because `p` is a plain dict, a parameter name that collides with a `Block`
attribute would be shadowed by that attribute. `Block.__init__` rejects the one
name that matters (`value`, now `last_output`); see the note there.
"""

from __future__ import annotations

from typing import Any


class Param:
    """Declares a live parameter on a block.

    Example
    -------
        class Osc(Block):
            freq = Param(220.0, "Hz", minimum=0.0)
            wave = Param("sine", doc="sine | saw | square")

    The descriptor stores a class-level default and hands each *instance* its own
    mutable cell, so two instances never share state and a modulation signal can be
    written straight into a parameter per sample.
    """

    __slots__ = ("default", "unit", "minimum", "maximum", "doc", "name")

    def __init__(
        self,
        default: Any = 0.0,
        unit: str = "",
        minimum: float | None = None,
        maximum: float | None = None,
        doc: str = "",
    ):
        self.default = default
        self.unit = unit
        self.minimum = minimum
        self.maximum = maximum
        self.doc = doc
        self.name = ""

    def __set_name__(self, owner: type, name: str) -> None:
        self.name = name
        owner._own_params[name] = self

    def __get__(self, obj, instance_type=None):
        if obj is None:
            return self
        return obj.p[self.name]

    def __set__(self, obj, value) -> None:
        obj.p[self.name] = value

    def __repr__(self) -> str:
        bounds = ""
        if self.minimum is not None or self.maximum is not None:
            bounds = f", range=[{self.minimum}, {self.maximum}]"
        return f"Param({self.default!r}{', ' + repr(self.unit) if self.unit else ''}{bounds})"

    def in_range(self, value: Any) -> bool:
        """Whether `value` obeys the declared bounds.

        Used by `Block._warn_out_of_range` to catch a nonsensical constructor
        argument -- an out-of-range value tends to produce NaN rather than an error,
        which then looks like a bug in the library rather than in the patch.
        Non-numeric parameters (waveform names) have no bounds and always pass.
        """
        try:
            numeric = float(value)
        except (TypeError, ValueError):
            return True
        if self.minimum is not None and numeric < self.minimum:
            return False
        if self.maximum is not None and numeric > self.maximum:
            return False
        return True
