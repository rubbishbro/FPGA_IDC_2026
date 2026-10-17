"""
Import bootstrap for the test suite.

Must be imported before anything from synthlab. It does two things an installed
package would not need, both consequences of this project shipping as source:

1. makes `synthlab` importable. The tests are run as scripts
   (`python tests/test_core.py`), so nothing has put `sythsound/` on `sys.path` yet.
2. makes the optional third-party wheels importable. `tools/fetch_wheels.py`
   unpacks them into `<repo>/_libs/` because this environment cannot use pip's
   install path, so it has to be added explicitly.

`_libs` is appended rather than inserted at the front: if a package is properly
installed (numpy, scipy) the installed copy should win, and only genuinely missing
ones should fall through to the unpacked directory.
"""

from __future__ import annotations

import sys
from pathlib import Path

#: `sythsound/` -- the directory holding the synthlab package.
PYTHON_ROOT: Path = Path(__file__).resolve().parent.parent

#: The repository root, one level above `sythsound/`.
REPO_ROOT: Path = PYTHON_ROOT.parent

#: Where tools/fetch_wheels.py unpacks downloaded wheels.
LIBS_DIR: Path = REPO_ROOT / "_libs"


def enable_optional_packages() -> None:
    """Put the unpacked wheels on `sys.path` if they exist."""
    if LIBS_DIR.is_dir():
        path = str(LIBS_DIR)
        if path not in sys.path:
            sys.path.append(path)


def install() -> Path:
    """Make both synthlab and the optional wheels importable. Returns `sythsound/`."""
    path = str(PYTHON_ROOT)
    if path not in sys.path:
        sys.path.insert(0, path)
    enable_optional_packages()
    return PYTHON_ROOT
