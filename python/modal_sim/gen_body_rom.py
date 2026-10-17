#!/usr/bin/env python
"""gen_body_rom.py -- offline generator for the shared body-filter ROM.

The body filter is the *detrended residual* 4-biquad (8th-order) cascade that
``params.Patch(name).sos`` already fits from the recorded body curve.  This
module only reads ``Patch.sos`` for the four instruments and emits the merged
hardware image used by ``rtl/core/body_filter.sv``:

* ``rtl/rom/body_coeff.mem``    -- 80 lines x 8 hex digits (signed Q2.30 32-bit
  coefficients, four instruments x four sections x five taps).
* ``rtl/rom/body_manifest.json`` -- float SOS, quantised integers, layout,
  source, quantised pole radii and the file hash.

Word layout (frozen by ``rtl/body_design.md`` section 3)::

    line = instrument_index*20 + section*5 + tap
    tap  = 0:b0 1:b1 2:b2 3:a1 4:a2
    instrument order = guitar, piano, banjo, mandolin

Every section is normalised so ``a0 = 1`` and stored as signed Q2.30
(``floor(c*2**30 + 0.5)``).  Coefficients are **never silently clamped**:
non-finite, out-of-int32-range or unstable sections abort the build before any
file is touched, so a bad source cannot half-overwrite a previous good image.

The original ``params.py`` / ``Patch`` is only ever *called*, never modified.
Output is deterministic and byte-for-byte reproducible.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)                       # params.py
sys.path.insert(0, os.path.join(ROOT, "python"))  # paths.py

import paths  # noqa: E402

# ---------------------------------------------------------------------------
# frozen layout constants
# ---------------------------------------------------------------------------
INSTRUMENTS = ["guitar", "piano", "banjo", "mandolin"]
SECTIONS = 4
TAPS = ["b0", "b1", "b2", "a1", "a2"]

COEFF_BITS = 32
COEFF_FRAC = 30
# local body datapath format (mirrors rtl/core/body_filter.sv defaults)
EXTERNAL_BITS = 64
EXTERNAL_FRAC = 30
GUARD_BITS = 4
INTERNAL_BITS = EXTERNAL_BITS + GUARD_BITS      # 68
INTERNAL_FRAC = EXTERNAL_FRAC + GUARD_BITS      # 34
PRODUCT_BITS = INTERNAL_BITS + COEFF_BITS       # 100
ACC_BITS = 104

FS = 48_000

WORDS_PER_INSTRUMENT = SECTIONS * len(TAPS)     # 20
TOTAL_WORDS = len(INSTRUMENTS) * WORDS_PER_INSTRUMENT  # 80

ROM_DIR = os.path.join(ROOT, "rtl", "rom")
COEFF_MEM = "body_coeff.mem"
MANIFEST = "body_manifest.json"

QSCALE = float(1 << COEFF_FRAC)
QMIN = -(1 << (COEFF_BITS - 1))
QMAX = (1 << (COEFF_BITS - 1)) - 1

_HEX = set("0123456789abcdefABCDEF")


class BodyRomError(Exception):
    """Any structural/numerical problem in the source SOS or the build."""


# ---------------------------------------------------------------------------
# quantisation + validation (strict, no silent clamping)
# ---------------------------------------------------------------------------
def quantize_coeff(c: float) -> int:
    """Signed Q2.30, round half up: floor(c*2**30 + 0.5)."""
    c = float(c)
    if not math.isfinite(c):
        raise BodyRomError(f"non-finite coefficient {c!r}")
    q = math.floor(c * QSCALE + 0.5)
    if q < QMIN or q > QMAX:
        raise BodyRomError(
            f"coefficient {c!r} quantises to {q}, outside signed "
            f"{COEFF_BITS}-bit Q2.{COEFF_FRAC} range [{QMIN}, {QMAX}]")
    return int(q)


def validate_section(row) -> dict:
    """Validate one 6-tap SOS row and return its quantised representation.

    ``row`` is ``[b0,b1,b2,a0,a1,a2]``.  ``a0`` is normalised away (must be
    non-zero; the fitted SOS always has ``a0 == 1``).  Rejects non-finite
    coefficients and sections whose *quantised* poles leave the unit circle.
    """
    row = [float(v) for v in row]
    if len(row) != 6:
        raise BodyRomError(f"SOS section must have 6 taps, got {len(row)}")
    b0, b1, b2, a0, a1, a2 = row
    if not all(math.isfinite(v) for v in row):
        raise BodyRomError(f"non-finite SOS section {row!r}")
    if a0 == 0.0:
        raise BodyRomError(f"zero a0 in SOS section {row!r}")
    vals = [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    q = [quantize_coeff(v) for v in vals]
    qb0, qb1, qb2, qa1, qa2 = q

    # Stability on the quantised rational poles:
    #   |a2| < 1, |a1| < 1 + a2   (Jury, real 2nd-order section)
    S = 1 << COEFF_FRAC
    checks = (S + qa1 + qa2 > 0, S - qa1 + qa2 > 0, S - qa2 > 0)
    if not all(checks):
        raise BodyRomError(
            f"unstable quantised section b={q[:3]} a={q[3:]} "
            f"(Jury checks {checks})")

    # Pole radius: sqrt(a2) for a conjugate pair, max |root| for real roots.
    af1 = qa1 / QSCALE
    af2 = qa2 / QSCALE
    disc = af1 * af1 - 4.0 * af2
    if disc <= 0.0:
        radius = math.sqrt(max(af2, 0.0))
    else:
        r = math.sqrt(disc)
        radius = max(abs((-af1 + r) / 2.0), abs((-af1 - r) / 2.0))
    if not (radius < 1.0):
        raise BodyRomError(f"quantised pole radius {radius} >= 1")

    out = {}
    for name, f, i in zip(TAPS, vals, q):
        out[name] = f
        out[name + "_q"] = i
    out["pole_radius"] = radius
    return out


def build_from_sos(sos_by_name, extra: dict | None = None) -> tuple[list[int], dict]:
    """Build ``(words, manifest)`` from an explicit ``{name: sos}`` mapping.

    Nothing is written here, so an invalid source fails without touching any
    existing ROM output.  ``sos_by_name`` must contain exactly the four
    instruments in :data:`INSTRUMENTS` order (a dict is accepted).  ``extra``
    metadata (source file hashes, fit parameters, fs) is merged into the
    manifest when given.
    """
    missing = [n for n in INSTRUMENTS if n not in sos_by_name]
    if missing:
        raise BodyRomError(f"missing instruments {missing}")
    extra_names = [n for n in sos_by_name if n not in INSTRUMENTS]
    if extra_names:
        raise BodyRomError(f"unexpected instruments {extra_names}")

    words: list[int] = []
    per_inst: dict[str, dict] = {}
    for inst_idx, name in enumerate(INSTRUMENTS):
        sos = np.asarray(sos_by_name[name], dtype=float)
        if sos.ndim != 2 or sos.shape[0] != SECTIONS or sos.shape[1] != 6:
            raise BodyRomError(
                f"{name}: SOS shape {sos.shape}, expected ({SECTIONS}, 6)")
        sections = []
        for s in range(SECTIONS):
            sec = validate_section(sos[s])
            for tap in TAPS:
                words.append(sec[tap + "_q"])
            sections.append(sec)
        per_inst[name] = dict(index=inst_idx, base=inst_idx * WORDS_PER_INSTRUMENT,
                              source=f"Patch({name!r}).sos",
                              sos_float=sos.tolist(), sections=sections)

    if len(words) != TOTAL_WORDS:
        raise BodyRomError(f"internal error: {len(words)} words != {TOTAL_WORDS}")

    manifest = dict(
        format=1,
        generator="python/modal_sim/gen_body_rom.py",
        fs=FS,
        coeff_bits=COEFF_BITS,
        coeff_frac=COEFF_FRAC,
        external_bits=EXTERNAL_BITS,
        external_frac=EXTERNAL_FRAC,
        internal_bits=INTERNAL_BITS,
        internal_frac=INTERNAL_FRAC,
        guard_bits=GUARD_BITS,
        product_bits=PRODUCT_BITS,
        acc_bits=ACC_BITS,
        sections=SECTIONS,
        taps=TAPS,
        instrument_order=INSTRUMENTS,
        total_words=TOTAL_WORDS,
        words_per_instrument=WORDS_PER_INSTRUMENT,
        layout="line = instrument_index*20 + section*5 + tap; "
               "tap order b0,b1,b2,a1,a2",
        per_instrument=per_inst,
    )
    if extra:
        overlap = set(extra) & set(manifest)
        if overlap:
            raise BodyRomError(f"extra manifest keys clash: {sorted(overlap)}")
        manifest.update(extra)
    return words, manifest


def _sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def body_source_meta(params_dir: str) -> dict:
    """Source/parameter provenance for the manifest (hashing the body npz)."""
    files = {}
    for name in INSTRUMENTS:
        p = os.path.join(params_dir, f"{name}_body.npz")
        files[name] = dict(path=f"{name}_body.npz",
                           sha256=(_sha256_file(p) if os.path.exists(p) else None))
    return dict(
        sos_fit=dict(method="params.fit_body (Levy / minimum-phase)",
                     order=2 * SECTIONS, sections=SECTIONS,
                     body_scale=0.3, smooth=15, fs=FS),
        source_files=files,
    )


def build_products(params_dir: str | None = None) -> tuple[list[int], dict]:
    """Read the four original ``Patch.sos`` and build the products in memory."""
    from params import Patch

    params_dir = params_dir or paths.PARAMS
    sos_by_name = {}
    for name in INSTRUMENTS:
        patch = Patch(name, fft_dir=params_dir) if params_dir else Patch(name)
        sos_by_name[name] = patch.sos
    return build_from_sos(sos_by_name, extra=body_source_meta(params_dir))


# ---------------------------------------------------------------------------
# output
# ---------------------------------------------------------------------------
def coeff_line(q: int) -> str:
    return f"{q & 0xFFFFFFFF:08X}"


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_products(words, manifest, rom_dir: str = ROM_DIR):
    """Write ``body_coeff.mem`` + ``body_manifest.json`` (after validation).

    All validation/number generation happens before any file is touched, and
    each file is staged as ``*.tmp`` then ``os.replace``-d, so an invalid
    source cannot partially overwrite the existing image.  The two replaces are
    **not** a single global transaction across both files (an OS failure
    between them is out of scope); the manifest hash is computed from the
    in-memory words so each written manifest matches the words it describes.
    """
    if len(words) != TOTAL_WORDS:
        raise BodyRomError(f"refusing to write {len(words)} words")
    os.makedirs(rom_dir, exist_ok=True)
    coeff_path = os.path.join(rom_dir, COEFF_MEM)
    manifest_path = os.path.join(rom_dir, MANIFEST)

    coeff_text = "".join(coeff_line(q) + "\n" for q in words)
    out = dict(manifest)
    out["coeff_file"] = COEFF_MEM
    out["coeff_sha256"] = _sha256_bytes(coeff_text.encode("utf-8"))
    manifest_text = json.dumps(out, indent=2, sort_keys=True) + "\n"

    ctmp = coeff_path + ".tmp"
    mtmp = manifest_path + ".tmp"
    with open(ctmp, "w", encoding="utf-8") as fh:
        fh.write(coeff_text)
    with open(mtmp, "w", encoding="utf-8") as fh:
        fh.write(manifest_text)
    os.replace(ctmp, coeff_path)
    os.replace(mtmp, manifest_path)
    return coeff_path, manifest_path


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--params-dir", default=None,
                    help="directory of <inst>_body.npz/_partials.npz "
                         "(default paths.PARAMS)")
    ap.add_argument("--rom-dir", default=ROM_DIR,
                    help="output directory (default rtl/rom)")
    args = ap.parse_args(argv)

    try:
        words, manifest = build_products(args.params_dir or paths.PARAMS)
        cpath, mpath = write_products(words, manifest, args.rom_dir)
    except BodyRomError as exc:
        print(f"[gen_body_rom] FAIL: {exc}", file=sys.stderr)
        return 1

    print(f"[gen_body_rom] {len(words)} words -> {cpath}")
    for name in INSTRUMENTS:
        pi = manifest["per_instrument"][name]
        radii = ", ".join(f"{s['pole_radius']:.6f}" for s in pi["sections"])
        print(f"[gen_body_rom]   {name:9s} base={pi['base']:2d} poles=[{radii}]")
    print(f"[gen_body_rom] metadata -> {mpath}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
