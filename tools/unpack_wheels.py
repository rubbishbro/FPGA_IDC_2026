"""Unpack downloaded wheels into a single local site directory.

Companion to tools/fetch_wheels.py -- see that file for why pip cannot be used
directly in this environment.

Usage:
    python tools/unpack_wheels.py            # unpack every wheel in _wheels/
    python tools/unpack_wheels.py numba      # only wheels whose name contains numba
"""

from __future__ import annotations

import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "_wheels"
DEST = ROOT / "_libs"


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
