#!/usr/bin/env python
"""gen_hw_rom.py -- offline generator for the module 2B hardware ROMs.

Reads the frozen, read-only per-instrument coefficient files produced by
``gen_coeff_table.py`` and emits the merged hardware images used by
``rtl/core/coeff_loader.sv``:

* ``rtl/rom/modal_coeff.mem``  -- 5483 lines x 18 hex digits (72-bit coefficients,
  the four original ``*_coeff.mem`` files concatenated in instrument order).
* ``rtl/rom/modal_index.mem``  -- 1024 lines x 5 hex digits (20-bit dense index,
  addressed by ``{instrument[1:0], midi[6:0], dyn}``).
* ``rtl/rom/modal_manifest.json`` -- layout metadata, entry list and file hashes.

Index word layout (frozen by ``rtl/module2BC_design.md`` section 3)::

    [19]    present
    [18:13] n_modes (6 bit, 1..48)
    [12:0]  merged coefficient start offset

Instrument codes are fixed 0=guitar, 1=piano, 2=banjo, 3=mandolin; the dynamic bin
is 0=piano, 1=forte.  The merged ROM is the concatenation of the original per
instrument coefficient files in instrument-code order, so every entry's words are
byte-identical to its original contiguous region.

The generator is strict: it rejects malformed keys, MIDI outside 0..127, unknown
dynamics, non-72-bit words, ``n_modes`` outside 1..48, illegal/overlapping/extra or
uncovered offsets, and duplicate index addresses.  Output is deterministic and
byte-for-byte reproducible.  The original ``python_monotor/results/params/`` files are only
ever opened for reading.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "python_monotor"))

import paths  # noqa: E402

# ---------------------------------------------------------------------------
# frozen layout constants
# ---------------------------------------------------------------------------
INSTRUMENTS = [("guitar", 0), ("piano", 1), ("banjo", 2), ("mandolin", 3)]
DYN_CODE = {"piano": 0, "forte": 1}
DYN_BIN = {v: k for k, v in DYN_CODE.items()}

COEFF_BITS = 72
INDEX_BITS = 20
OFFSET_BITS = 13
N_MODES_BITS = 6
INDEX_DEPTH = 1024
MAX_N = 48

EXPECTED_TOTAL_MODES = 5483
EXPECTED_TOTAL_ENTRIES = 250

ROM_DIR = os.path.join(ROOT, "rtl", "rom")
COEFF_MEM = os.path.join(ROM_DIR, "modal_coeff.mem")
INDEX_MEM = os.path.join(ROM_DIR, "modal_index.mem")
MANIFEST = os.path.join(ROM_DIR, "modal_manifest.json")

_HEX = set("0123456789abcdefABCDEF")


class RomError(Exception):
    """Any structural problem in the source tables or the build request."""


# ---------------------------------------------------------------------------
# source parsing + validation
# ---------------------------------------------------------------------------
def read_mem(path: str):
    words = []
    with open(path, "r", encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            s = line.strip()
            if not s:
                continue
            if len(s) != COEFF_BITS // 4 or any(c not in _HEX for c in s):
                raise RomError(
                    f"{path}:{lineno}: expected an 18-hex-digit 72-bit word, "
                    f"got {s!r}")
            words.append(int(s, 16))
    if not words:
        raise RomError(f"{path}: empty coefficient file")
    return words


def read_index(path: str):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            raw = json.load(fh)
    except OSError as exc:
        raise RomError(f"{path}: cannot read ({exc})") from exc
    except json.JSONDecodeError as exc:
        raise RomError(f"{path}: invalid JSON ({exc})") from exc
    if not isinstance(raw, dict) or not raw:
        raise RomError(f"{path}: index JSON must be a non-empty object")
    return raw


def load_instrument(params_dir: str, name: str):
    """Return (words, entries) for one instrument.

    ``entries`` is a list of ``(midi, dyn, offset, n_modes)`` as stored in the
    original per-instrument file (offsets are relative to that file).
    """
    mem_path = os.path.join(params_dir, f"{name}_coeff.mem")
    idx_path = os.path.join(params_dir, f"{name}_coeffindex.json")
    words = read_mem(mem_path)
    raw = read_index(idx_path)

    covered = [False] * len(words)
    entries = []
    seen = set()
    for key, meta in raw.items():
        if not isinstance(key, str) or key.count("|") != 1:
            raise RomError(f"{idx_path}: malformed entry key {key!r}")
        midi_s, dyn = key.split("|")
        try:
            midi = int(midi_s)
        except ValueError as exc:
            raise RomError(f"{idx_path}: non-integer MIDI in {key!r}") from exc
        if not 0 <= midi <= 127:
            raise RomError(f"{idx_path}: MIDI {midi} outside 0..127 in {key!r}")
        if dyn not in DYN_CODE:
            raise RomError(f"{idx_path}: illegal dynamic {dyn!r} in {key!r}")
        if (midi, dyn) in seen:
            raise RomError(f"{idx_path}: duplicate key {key!r}")
        seen.add((midi, dyn))
        if not isinstance(meta, dict):
            raise RomError(f"{idx_path}: metadata for {key!r} must be an object")
        off = meta.get("offset")
        n = meta.get("n_modes")
        if type(off) is not int or type(n) is not int:
            raise RomError(
                f"{idx_path}: offset/n_modes for {key!r} must be integers "
                f"(got {off!r}/{n!r})")
        if off < 0 or n < 1 or n > MAX_N:
            raise RomError(
                f"{idx_path}: {key!r} has offset={off} n_modes={n} "
                f"(need 0<=offset and 1<=n<={MAX_N})")
        if off + n > len(words):
            raise RomError(
                f"{idx_path}: {key!r} range [{off},{off + n}) exceeds "
                f"{len(words)} words")
        for k in range(off, off + n):
            if covered[k]:
                raise RomError(
                    f"{idx_path}: {key!r} overlaps an earlier entry at word {k}")
            covered[k] = True
        entries.append((midi, dyn, off, n))
    if not all(covered):
        missing = covered.index(False)
        raise RomError(
            f"{mem_path}: {covered.count(False)} coefficient word(s) not covered "
            f"by the index (first uncovered at {missing}); extra words rejected")
    return words, entries


# ---------------------------------------------------------------------------
# merged build
# ---------------------------------------------------------------------------
def build(params_dir: str | None = None):
    """Build and return (coeff_words, index_words, manifest_dict).

    Raises ``RomError`` on any structural problem.  Performs no I/O writes.
    """
    params_dir = params_dir or paths.PARAMS
    coeff_words: list[int] = []
    index_words = [0] * INDEX_DEPTH
    entries = []
    per_inst = {}
    base = 0

    for name, code in INSTRUMENTS:
        words, inst_entries = load_instrument(params_dir, name)
        per_inst[name] = dict(code=code, base=base, modes=len(words),
                              entries=len(inst_entries))
        # deterministic order: MIDI ascending, then dyn bin 0(piano)/1(forte)
        for midi, dyn, off, n in sorted(
                inst_entries, key=lambda e: (e[0], DYN_CODE[e[1]])):
            addr = (code << 8) | (midi << 1) | DYN_CODE[dyn]
            if not 0 <= addr < INDEX_DEPTH:
                raise RomError(f"{name}: index address {addr} out of range")
            if index_words[addr] != 0:
                raise RomError(
                    f"duplicate index address {addr} ({name} midi{midi} {dyn})")
            merged_off = base + off
            if merged_off + n > (1 << OFFSET_BITS):
                raise RomError(
                    f"{name} midi{midi} {dyn}: merged offset {merged_off}+{n} "
                    f"exceeds {OFFSET_BITS}-bit field")
            index_words[addr] = (1 << (INDEX_BITS - 1)) | (n << OFFSET_BITS) \
                | merged_off
            entries.append(dict(addr=addr, instrument=name, code=code, midi=midi,
                                dyn=dyn, dyn_code=DYN_CODE[dyn], n_modes=n,
                                offset=merged_off, source_offset=off))
        coeff_words.extend(words)
        base += len(words)

    if len(coeff_words) > 0xFFFFFFFF:
        raise RomError("coefficient table too large")
    manifest = dict(
        format=1,
        generator="python_monotor/modal_sim/gen_hw_rom.py",
        coeff_bits=COEFF_BITS,
        index_bits=INDEX_BITS,
        offset_bits=OFFSET_BITS,
        n_modes_bits=N_MODES_BITS,
        index_depth=INDEX_DEPTH,
        max_n_modes=MAX_N,
        instrument_order=[n for n, _ in INSTRUMENTS],
        total_modes=len(coeff_words),
        total_entries=len(entries),
        per_instrument=per_inst,
        entries=entries,
    )
    return coeff_words, index_words, manifest


def _sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def write_products(coeff_words, index_words, manifest, rom_dir: str = ROM_DIR):
    os.makedirs(rom_dir, exist_ok=True)
    coeff_mem = os.path.join(rom_dir, "modal_coeff.mem")
    index_mem = os.path.join(rom_dir, "modal_index.mem")
    manifest_path = os.path.join(rom_dir, "modal_manifest.json")

    with open(coeff_mem, "w", encoding="utf-8") as fh:
        for w in coeff_words:
            fh.write(f"{w & ((1 << COEFF_BITS) - 1):018X}\n")
    with open(index_mem, "w", encoding="utf-8") as fh:
        for w in index_words:
            fh.write(f"{w & ((1 << INDEX_BITS) - 1):05X}\n")

    out = dict(manifest)
    out["coeff_file"] = os.path.basename(coeff_mem)
    out["index_file"] = os.path.basename(index_mem)
    out["coeff_sha256"] = _sha256(coeff_mem)
    out["index_sha256"] = _sha256(index_mem)
    with open(manifest_path, "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=2, sort_keys=True)
        fh.write("\n")
    return coeff_mem, index_mem, manifest_path


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--params-dir", default=paths.PARAMS,
                    help="directory of <inst>_coeff.mem / _coeffindex.json")
    ap.add_argument("--rom-dir", default=ROM_DIR,
                    help="output directory (default rtl/rom)")
    args = ap.parse_args(argv)

    try:
        coeff_words, index_words, manifest = build(args.params_dir)
    except RomError as exc:
        print(f"[gen_hw_rom] FAIL: {exc}", file=sys.stderr)
        return 1

    if manifest["total_modes"] != EXPECTED_TOTAL_MODES:
        print(f"[gen_hw_rom] FAIL: expected {EXPECTED_TOTAL_MODES} modes, "
              f"got {manifest['total_modes']}", file=sys.stderr)
        return 1
    if manifest["total_entries"] != EXPECTED_TOTAL_ENTRIES:
        print(f"[gen_hw_rom] FAIL: expected {EXPECTED_TOTAL_ENTRIES} entries, "
              f"got {manifest['total_entries']}", file=sys.stderr)
        return 1

    cpath, ipath, mpath = write_products(coeff_words, index_words, manifest,
                                         args.rom_dir)
    print(f"[gen_hw_rom] {manifest['total_modes']} words -> {cpath}")
    print(f"[gen_hw_rom] {manifest['total_entries']} entries -> {ipath}")
    print(f"[gen_hw_rom] metadata -> {mpath}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
