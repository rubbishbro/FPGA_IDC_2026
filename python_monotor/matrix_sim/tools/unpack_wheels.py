"""Unpack downloaded wheels into a single local site directory.

Companion to tools/fetch_wheels.py -- see that file for why pip cannot be used
directly in this environment.

Usage:
    python python_monotor/matrix_sim/tools/unpack_wheels.py            # unpack every wheel in <repo>/_wheels/
    python python_monotor/matrix_sim/tools/unpack_wheels.py numba      # only wheels whose name contains numba

Directories default to `<repo>/_wheels` and `<repo>/_libs`, found by walking up from
this file (it lives at `python_monotor/matrix_sim/tools/`, so the repo root is three levels up). Override
with `SYNTHLAB_WHEELS_DIR` / `SYNTHLAB_LIBS_DIR`.
"""

from __future__ import annotations

import os
import sys
import zipfile
from pathlib import Path

#: Repository root. `parents[3]` is `python_monotor/matrix_sim/tools/ -> python_monotor/matrix_sim/ -> python_monotor/ -> <repo>`.
ROOT = Path(os.environ.get("SYNTHLAB_REPO_ROOT") or Path(__file__).resolve().parents[3])
SRC = Path(os.environ.get("SYNTHLAB_WHEELS_DIR") or (ROOT / "_wheels"))
DEST = Path(os.environ.get("SYNTHLAB_LIBS_DIR") or (ROOT / "_libs"))


def main() -> int:
    filters = sys.argv[1:]
    wheels = sorted(SRC.glob("*.whl"))
    if filters:
        wheels = [w for w in wheels if any(f in w.name for f in filters)]
    if not wheels:
        print(f"no wheels found in {SRC}")
        return 1

    DEST.mkdir(exist_ok=True)
    for wheel in wheels:
        with zipfile.ZipFile(wheel) as zf:
            zf.extractall(DEST)
        print(f"unpacked {wheel.name}")
    print(f"\n{DEST} is now on the import path when you set PYTHONPATH to it.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
