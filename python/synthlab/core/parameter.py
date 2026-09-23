"""
Parameters: the named, declared scalars a block exposes.

A block declares a parameter as a class attribute::

    class Osc(Block):
        freq = Param(220.0, "Hz", minimum=0.0)
        wave = Param("sine", doc="sine | saw | square")

Each declaration becomes a *slot index*, assigned once per class. The values live
in one per-instance store, `block.params`, and the descriptor reads and writes
that store. So the class attribute is the specification and the instance owns the
value; two instances never share one.

Nothing else may touch the store. Writes go through `Params.set`, which checks the
name was declared, records the change, and calls `Block.param_changed`. That single
choke point is what makes a parameter write observable, and it is why the store is
private: a bare `dict` let a typo become an invisible extra key.
"""

from __future__ import annotations

import warnings
from typing import Any

import numpy as np

__all__ = ["Param", "Params"]


class Field:
    """Per-class metadata for one declared parameter.

    Kept in a tuple on the class, parallel to the value array. `slot` is the index
    into that array and never changes after the class is built.
    """

    __slots__ = ("name", "slot", "default", "unit", "minimum", "maximum", "doc")

    def __init__(self, name: str, slot: int, spec: "Param"):
        self.name = name
        self.slot = slot
        self.default = spec.default
        self.unit = spec.unit
        self.minimum = spec.minimum
        self.maximum = spec.maximum
        self.doc = spec.doc

    def in_range(self, value: Any) -> bool:
        """Whether `value` obeys the declared bounds.

        Used for a warning, not a clamp: clamping on every write would cost more
        than it is worth and would silently discard a legal modulation excursion.
        An out-of-range value tends to produce NaN rather than an error, which then
        looks like a bug in the library instead of in the patch. Non-numeric
        parameters (waveform names) have no bounds and always pass.
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

    def __repr__(self) -> str:
        return f"<field {self.name} slot={self.slot} default={self.default!r}>"


class Params:
    """The parameter store of one block.

    Values live in a `dtype=object` array indexed by slot. Object dtype rather than
    float64 because a parameter may be a string (`wave="saw"`), and because it keeps
    the value as the Python object that was assigned rather than coercing it to
    `np.float64`.

    An array rather than a dict so the storage can be swapped -- a float64 vector
    for the JIT path, a struct of arrays -- without touching any caller.
    """

    __slots__ = ("_owner", "_fields", "_values")

    def __init__(self, owner, fields: tuple):
        object.__setattr__(self, "_owner", owner)
        object.__setattr__(self, "_fields", fields)
        values = np.empty(len(fields), dtype=object)
        for field in fields:
            values[field.slot] = field.default
        object.__setattr__(self, "_values", values)

    # -- reading -----------------------------------------------------------
    def __getattr__(self, name: str) -> Any:
        # Reached only for names not found through the normal path, which for a
        # `__slots__` class means an undeclared attribute: a parameter read or a
        # typo. `_lookup` raises TypeError for the latter.
        return self._values[self._lookup(name).slot]

    def __getitem__(self, name: str) -> Any:
        return self._values[self._lookup(name).slot]

    def __contains__(self, name: object) -> bool:
        return isinstance(name, str) and any(f.name == name for f in self._fields)

    def field(self, name: str) -> Field:
        """The declaration behind a parameter."""
        return self._lookup(name)

    def fields(self) -> tuple:
        return self._fields

    def names(self) -> tuple:
        return tuple(f.name for f in self._fields)

    def all(self) -> dict:
        """A shallow copy of every parameter value."""
        return {f.name: self._values[f.slot] for f in self._fields}

    # -- writing -----------------------------------------------------------
    def __setattr__(self, name: str, value: Any) -> None:
        if name.startswith("_"):
            object.__setattr__(self, name, value)
        else:
            self.set(name, value)

    def __setitem__(self, name: str, value: Any) -> None:
        self.set(name, value)

    def set(self, name: str, value: Any) -> None:
        """Assign a parameter, announcing the change if the value differs.

        The single write path. Re-assigning the same value is not a change and is
        not announced, so a `Modulated` block writing a constant into a parameter
        every sample does not look like a configuration change.
        """
        field = self._lookup(name)
        if self._values[field.slot] != value:
            self._values[field.slot] = value
            self._owner.param_changed(name)

    def set_defaults(self, values: dict) -> None:
        """Assign several parameters at once, without announcing.

        Construction time: these are the starting configuration, not a change.
        """
        for name, value in values.items():
            self._values[self._lookup(name).slot] = value

    # -- diagnostics -------------------------------------------------------
    def warn_out_of_range(self) -> None:
        """Warn about any parameter outside its declared bounds."""
        owner = type(self._owner).__name__
        for field in self._fields:
            value = self._values[field.slot]
            if not field.in_range(value):
                unit = f" {field.unit}" if field.unit else ""
                warnings.warn(
                    f"{owner}({field.name}={value!r}) is outside the supported "
                    f"range [{field.minimum}, {field.maximum}]{unit}. "
                    f"{field.doc or 'Results outside this range are undefined.'}",
                    RuntimeWarning,
                    stacklevel=3,
                )

    # -- internals ---------------------------------------------------------
    def _lookup(self, name: str) -> Field:
        for field in self._fields:
            if field.name == name:
                return field
        known = ", ".join(sorted(f.name for f in self._fields)) or "<none>"
        raise TypeError(
            f"{type(self._owner).__name__} has no parameter {name!r}; known: {known}"
        )

    def __repr__(self) -> str:
        inner = ", ".join(f"{f.name}={self._values[f.slot]!r}" for f in self._fields)
        return f"{type(self._owner).__name__}.params({inner})"


class Param:
    """Declares a parameter on a block.

    The descriptor stores no per-instance data: it forwards to `block.params` at
    the slot its class assigned to it. `__set_name__` records the declared name;
    the `Block` metaclass assigns the slot and builds the `Field` when the class
    is created.
    """

    __slots__ = ("default", "unit", "minimum", "maximum", "doc", "name", "slot")

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
        self.slot = -1

    def __set_name__(self, owner: type, name: str) -> None:
        self.name = name

    def __get__(self, obj, instance_type=None):
        if obj is None:
            return self
        return obj.params._values[self.slot]

    def __set__(self, obj, value) -> None:
        obj.params.set(self.name, value)

    def __repr__(self) -> str:
        bounds = ""
        if self.minimum is not None or self.maximum is not None:
            bounds = f", range=[{self.minimum}, {self.maximum}]"
        unit = f", {self.unit!r}" if self.unit else ""
        return f"Param({self.default!r}{unit}{bounds})"
