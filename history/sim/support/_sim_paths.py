"""Repo-root and import-path bootstrap for the categorised sim test tree.

After the classification reorg the sim scripts no longer sit flat in ``sim/``,
so the old ``Path(__file__).parents[1]`` / ``os.path.dirname(_HERE)`` root guess
is wrong.  ``find_repo_root`` walks up from a file until it finds the directory
that owns both ``rtl/`` and ``sim/``.

``bootstrap`` additionally puts every python-bearing directory under ``sim/``
(so the still-unique script stems can be imported by bare name) plus the
``python/`` reference package on ``sys.path``.  The same directories are mirrored
into ``PYTHONPATH`` because ``cocotb_tools.runner`` propagates the *calling*
process ``sys.path`` to the simulator subprocess.

Used by ``sim/run.py``.  Scripts also include a tiny inline copy of the root
walk so they stay runnable on their own; ``_sim_paths`` is the single source of
truth for the central entry point.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

# Directories that never contain importable test modules worth putting on the
# path (build artefacts / byte-code caches / VCS metadata).
_SKIP_DIRS = {"build", "__pycache__", ".git", ".pytest_cache"}


def find_repo_root(start) -> Path:
    """Return the repository root (the directory containing ``rtl/`` and ``sim/``)."""
    p = Path(start).resolve()
    if p.is_file():
        p = p.parent
    for ancestor in (p, *p.parents):
        if (ancestor / "rtl").is_dir() and (ancestor / "sim").is_dir():
            return ancestor
    raise RuntimeError(
        f"repository root (with rtl/ and sim/) not found above {start!r}")


def sim_script_dirs(root: Path):
    """Every directory under ``sim/`` that holds at least one ``.py`` module."""
    sim = root / "sim"
    dirs = []
    for current, subdirs, files in os.walk(sim):
        subdirs[:] = [d for d in subdirs if d not in _SKIP_DIRS]
        if any(name.endswith(".py") for name in files):
            dirs.append(Path(current))
    support = sim / "support"
    if support.is_dir() and support not in dirs:
        dirs.append(support)
    return dirs


def import_dirs(root: Path):
    """Ordered list of sys.path entries for running sim scripts."""
    dirs = [root / "python" / "modal_sim", root / "python", root / "sim"]
    dirs.extend(sim_script_dirs(root))
    return dirs


def _install(dirs):
    added = []
    for directory in dirs:
        text = os.fspath(directory)
        if text and text not in sys.path:
            sys.path.insert(0, text)
            added.append(text)
    if added:
        existing = os.environ.get("PYTHONPATH")
        os.environ["PYTHONPATH"] = os.pathsep.join(
            added + ([existing] if existing else []))
    return added


def bootstrap(start) -> Path:
    """Wire ``sys.path``/``PYTHONPATH`` and return the repo root as a Path."""
    root = find_repo_root(start)
    _install(import_dirs(root))
    return root
