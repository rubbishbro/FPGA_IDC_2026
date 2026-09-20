"""Fetch wheels matched to THIS interpreter's ABI.

Why this exists: in the current sandbox, pip cannot write its own temp directory
or the user site-packages, so `pip install` fails outright. Downloading the wheel
and unpacking it into a local directory is the workaround.

The ABI matching matters: picking the first wheel containing "cp314" selects the
free-threaded `cp314t` build, which a normal CPython 3.14 cannot load.

Usage:
    python tools/fetch_wheels.py numpy sounddevice     # download to _wheels/
    python tools/unpack_wheels.py                      # unpack all into _libs/
"""

from __future__ import annotations

import json
import socket
import sys
import sysconfig
import urllib.request
from pathlib import Path

try:
    import truststore

    truststore.inject_into_ssl()
except Exception:  # truststore is optional; stock certs usually work
    pass

ROOT = Path(__file__).resolve().parent.parent
DEST = ROOT / "_wheels"
socket.setdefaulttimeout(30)


def abi_tags() -> list[str]:
    """ABI tags this interpreter accepts, most specific first."""
    ver = f"cp{sys.version_info.major}{sys.version_info.minor}"
    gil_disabled = bool(sysconfig.get_config_var("Py_GIL_DISABLED"))
    tags = [f"{ver}-{ver}t" if gil_disabled else f"{ver}-{ver}"]
    tags.append(f"{ver}-none")  # abi3 / limited API
    return tags


def pick(files: list[dict], tags: list[str], platform: str = "win_amd64") -> dict | None:
    for tag in tags:
        for f in files:
            if f.get("filename", "").endswith(f"-{tag}-{platform}.whl"):
                return f
    for f in files:
        if f.get("filename", "").endswith("-none-any.whl"):
            return f
    return None


def fetch(name: str) -> Path | None:
    label = name.replace("_", "-")
    try:
        with urllib.request.urlopen(f"https://pypi.org/pypi/{label}/json", timeout=30) as r:
            data = json.load(r)
    except Exception as exc:
        print(f"{label:<18} metadata ERROR {exc}")
        return None

    version = data["info"]["version"]
    files = data["releases"].get(version, [])

    # Prefer a platform wheel: sounddevice's generic wheel omits the PortAudio DLL,
    # so the -none-any- build would import but never make a sound.
    platform = pick(files, abi_tags())
    target = platform or pick(files, abi_tags(), platform="any")
    if not target:
        print(f"{label:<18} latest={version} -> no wheel for {abi_tags()[0]}/win_amd64")
        return None

    out = DEST / target["filename"]
    if out.exists():
        print(f"{label:<18} cached {out.name}")
        return out
    try:
        with urllib.request.urlopen(target["url"], timeout=120) as r:
            out.write_bytes(r.read())
        print(f"{label:<18} downloaded {out.name}")
        return out
    except Exception as exc:
        print(f"{label:<18} download ERROR {exc}")
        return None


def main() -> int:
    names = sys.argv[1:]
    if not names:
        print(__doc__)
        return 1
    DEST.mkdir(exist_ok=True)
    print(f"interpreter {sys.version.split()[0]} | ABI tags {abi_tags()}\n")
    ok = sum(1 for n in names if fetch(n))
    print(f"\n{ok}/{len(names)} wheel(s) in {DEST}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
