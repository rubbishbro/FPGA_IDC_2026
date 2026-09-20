"""
Architectural tests: the layering must stay real.

These check structure, not DSP. They exist because "core stands alone" was
accidentally false for a while: `synthlab/__init__.py` eagerly imported the
implementations, and Python runs a package's `__init__` before any submodule, so
`import synthlab.core` pulled in every extension. A comment claiming independence is
not independence; these tests are.

    python tests/test_layering.py
"""

from __future__ import annotations

import ast
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

CORE = ROOT / "synthlab" / "core"
EXT = ROOT / "synthlab" / "ext"


def _imports_of(path: Path) -> list[str]:
    """Every module named by an import statement in `path`."""
    tree = ast.parse(path.read_text(encoding="utf-8"))
    found: list[str] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and node.module:
            found.append(node.module)
        elif isinstance(node, ast.Import):
            found.extend(alias.name for alias in node.names)
    return found


def _is_ext(module: str) -> bool:
    """True for `ext`, `synthlab.ext`, `.ext.x`, `..ext` -- but not `context`.

    Matching on the whole dotted name rather than a substring matters: `context`
    contains "ext" and a substring test reports a false dependency.
    """
    parts = [p for p in module.replace(".", " ").split() if p]
    return "ext" in parts


def test_core_never_imports_ext():
    """No module under synthlab/core may reference synthlab.ext, statically."""
    offenders = []
    for path in sorted(CORE.glob("*.py")):
        for module in _imports_of(path):
            if _is_ext(module):
                offenders.append(f"{path.name} imports {module}")
    assert not offenders, "core depends on ext:\n  " + "\n  ".join(offenders)


def test_core_loads_without_ext_in_a_fresh_interpreter():
    """Importing synthlab.core must not import synthlab.ext.

    Static analysis cannot see this: the coupling was through the package
    `__init__`, which runs before the submodule. Only a real import proves it.
    """
    code = (
        "import sys;"
        "import synthlab.core;"
        "assert 'synthlab.ext' not in sys.modules, "
        "'importing synthlab.core pulled in synthlab.ext';"
        "print('ok')"
    )
    result = subprocess.run(
        [sys.executable, "-c", code],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, (
        f"fresh-interpreter check failed:\n{result.stdout}\n{result.stderr}"
    )


def test_top_level_import_is_lazy():
    """`import synthlab` must not load any implementation module."""
    code = (
        "import sys, synthlab;"
        "assert 'synthlab.ext' not in sys.modules, 'bare import loaded ext';"
        "assert 'matplotlib' not in sys.modules, 'bare import loaded matplotlib';"
        "assert 'sounddevice' not in sys.modules, 'bare import loaded sounddevice';"
        "print('ok')"
    )
    result = subprocess.run(
        [sys.executable, "-c", code], cwd=ROOT, capture_output=True, text=True
    )
    assert result.returncode == 0, (
        f"lazy-import check failed:\n{result.stdout}\n{result.stderr}"
    )


def test_the_short_form_still_resolves_every_public_name():
    """`from synthlab import X` must work for core names and ext names alike.

    The lazy loader trades eager imports for attribute access; if a name in
    `__all__` is missing from the loader's map it silently becomes an
    AttributeError only at the point of use.
    """
    import synthlab

    missing = []
    for name in synthlab.__all__:
        try:
            getattr(synthlab, name)
        except AttributeError as exc:
            missing.append(f"{name}: {exc}")
    assert not missing, "names in __all__ that do not resolve:\n  " + "\n  ".join(missing)


def test_core_can_host_a_block_defined_by_the_user():
    """The abstractions must be usable with no extension present at all.

    This is the actual promise of the split: core is not merely "not importing"
    ext, it is sufficient to build and render a working block from scratch.
    """
    import numpy as np

    from synthlab.core import Block, Chain, Param, Source, render

    class OnePole(Block):
        cutoff = Param(1000.0, "Hz")

        def reset(self):
            super().reset()
            self.z = 0.0

        def process(self, x, ctx):
            a = 1.0 - np.exp(-2.0 * np.pi * self.cutoff / ctx.sr)
            self.z += a * (x - self.z)
            return self.z

    class Sine(Source):
        freq = Param(440.0, "Hz")

        def reset(self):
            super().reset()
            self.ph = 0.0

        def process(self, ctx):
            value = float(np.sin(2.0 * np.pi * self.ph))
            self.ph = (self.ph + self.freq / ctx.sr) % 1.0
            return value

    y = render(Chain(Sine(freq=440.0), OnePole(cutoff=2000.0)), 0.1)
    assert y.shape == (4800,)
    assert np.isfinite(y).all()
    assert abs(y).max() > 0.5, "the user-defined chain produced no signal"

    # And the generator/processor distinction holds without any extension.
    assert not Sine().needs_input and OnePole().needs_input


def test_blocks_dispatch_without_isinstance_in_the_callers():
    """`Block.eval` must be the only place the generator/processor split is resolved.

    Before the split, `isinstance(block, Source)` appeared eleven times across core
    and jit. A new kind of block would have meant editing all of them. Checked with
    the AST rather than by substring, because a substring test also trips on the
    prose in a docstring.
    """
    def isinstance_on_source(path: Path) -> list[int]:
        tree = ast.parse(path.read_text(encoding="utf-8"))
        hits = []
        for node in ast.walk(tree):
            if not (isinstance(node, ast.Call) and getattr(node.func, "id", "") == "isinstance"):
                continue
            for arg in node.args[1:]:
                if isinstance(arg, ast.Name) and arg.id == "Source":
                    hits.append(node.lineno)
        return hits

    offenders = [
        f"{path.name}:{line}"
        for path in sorted(CORE.glob("*.py"))
        # `block.py` names Source when *defining* the two kinds; that is the one
        # legitimate place, and even there it does not isinstance-test it.
        if path.name != "block.py"
        for line in isinstance_on_source(path)
    ]
    assert not offenders, (
        "these sites dispatch on block kind instead of using Block.eval:\n  "
        + "\n  ".join(offenders)
    )

    # `needs_input` may only be consulted as a block attribute, never as a type
    # probe duplicated around the library. The exceptions are the three places where
    # a branch on block kind is genuinely meaningful rather than duplicated
    # dispatch: `block.py` defines it, `render.py` validates the root block once,
    # and `Chain.prepare` uses it for a one-off structural check that a generator is
    # not sitting mid-chain. None of them is in the per-sample path.
    allowed = {
        "block.py": "defines the flag and the dispatch",
        "render.py": "validates the root block once, before the loop",
        "compose.py": "Chain.prepare structural check, once per render",
    }
    probes = []
    for path in sorted(CORE.glob("*.py")):
        if path.name in allowed:
            continue
        if ".needs_input" in path.read_text(encoding="utf-8"):
            probes.append(path.name)
    assert not probes, (
        f"these modules branch on needs_input outside a structural check: {probes}"
    )


# ---------------------------------------------------------------------------
# Standalone runner (no pytest required)
# ---------------------------------------------------------------------------

def _run_standalone() -> int:
    tests = [
        (name, obj)
        for name, obj in sorted(globals().items())
        if name.startswith("test_") and callable(obj)
    ]
    failures = []
    for name, fn in tests:
        try:
            fn()
        except Exception as exc:  # noqa: BLE001 - report and continue
            failures.append((name, exc))
            print(f"FAIL  {name}\n        {type(exc).__name__}: {exc}")
        else:
            print(f"ok    {name}")

    print(f"\n{len(tests) - len(failures)}/{len(tests)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(_run_standalone())
