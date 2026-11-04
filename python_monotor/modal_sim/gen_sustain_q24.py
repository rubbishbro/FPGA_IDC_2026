#!/usr/bin/env python3
"""Generate Q2.24 a1 coefficient tables for the router eng1 path.

This script only *generates* data.  It does not change ``eng1.sv`` and it does
not touch the existing Q2.20 tables.  The output is a 64-byte-per-mode image
(16 x 32-bit big-endian words) matching ``sustain_resources.py``:

    word 0: G  Q2.24 signed 26   (sign-extended to 32 bits)
    word 1: a1 Q2.24 signed 26   (sign-extended to 32 bits)
    word 2: a2 UQ0.24 unsigned 24
    words 3..7: zero
    words 8..15: first-order pitch metadata (P1T1), shared with production

Word 1 is signed 26-bit **a1 Q2.24**, matching the current ``eng1.sv``.
The manifest carries ``a1_format: Q2.24``. Older Q2.20 B images must be regenerated;
the 64-byte record layout is unchanged. The production generator
``rtl/router/tools/sustain_resources.py`` uses the same ``build_b_table`` model.

G is re-calibrated from the *Q2.24* quantised poles (r = sqrt(a2q), theta from
a1q24/a2q), so it is not a copy of the Q2.20 table.  The drive period and the
per-note attack/release hints match ``sustain_resources.py``.

Run
---
    python python_monotor/modal_sim/gen_sustain_q24.py
    python python_monotor/modal_sim/gen_sustain_q24.py --catalog --no-image
    python python_monotor/modal_sim/gen_sustain_q24.py --first-midi 36 --notes 48
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import struct
import sys
from pathlib import Path

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "fft_analysis"))

import core as CORE                                   # noqa: E402
import paths                                          # noqa: E402
import router_eng1 as R                               # noqa: E402
import pitch_linear as PITCH                          # noqa: E402
from sustain_engine import SustainPatch               # noqa: E402

INST = {"flute": 2, "trumpet": 3, "cello": 4, "violin": 5}
FS = R.SR
DEPTH = 64                      # storage modes per note, same as the loader
ENV_ONE = (1 << 31) - 1
A1_FRAC = R.A1_FRAC
A1_BITS = R.A1_BITS


def _hash_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _build_entry(name: str, midi: int, allow_retune: bool):
    patch = _patches.get(name)
    if patch is None:
        patch = SustainPatch(name)
        _patches[name] = patch
    selected = patch._pick_key(midi, "forte")
    if selected[0] != midi and not allow_retune:
        raise ValueError(
            f"{name} MIDI{midi}: no recording (nearest {selected[0]}); "
            "use --allow-retune")
    source_midi, source_dynamic = int(selected[0]), str(selected[1])

    kk, g, w, atk, rel, _ndb, _nwin = patch.modes(midi, "forte")
    if kk.size == 0:
        raise ValueError(f"{name} MIDI{midi}: no usable modes")

    f0 = CORE.midi_to_hz(midi)
    period = max(2, int(round(FS / f0)))
    f_drive = FS / period
    theta = 2.0 * np.pi * (kk * f_drive) / FS
    r = np.exp(-g / FS)

    a1f = -2.0 * r * np.cos(theta)
    # One production coefficient builder: keep this diagnostic export and the
    # Flash/profile generator identical, including gain recalibration.
    table = R.build_b_table(name, midi, "forte")
    Gq, a1q, a2q = table.G, table.a1, table.a2
    rq = np.sqrt(a2q.astype(float) / float(1 << 24))
    cq = -(a1q.astype(float) / float(1 << A1_FRAC)) / np.maximum(2.0 * rq, 1e-12)
    real_poles = int(np.count_nonzero(np.abs(cq) > 1.0 + 1e-12))

    # static pitch error against the ideal float pole, for the report
    def max_static_err(a1_int, frac):
        rr = np.sqrt(a2q.astype(float) / float(1 << 24))
        cc = -(a1_int.astype(float) / float(1 << frac)) / np.maximum(2.0 * rr, 1e-12)
        tt = np.arccos(np.clip(cc, -1.0, 1.0))
        fq = tt * FS / (2.0 * np.pi)
        target = kk * f_drive
        with np.errstate(divide="ignore", invalid="ignore"):
            e = 1200.0 * np.log2(np.maximum(fq, 1e-12) / target)
        return float(np.nanmax(np.abs(e)))

    a1q20 = R.quant(a1f, 20, 22, signed=True).astype(np.int64)
    err20 = max_static_err(a1q20, 20)
    err24 = max_static_err(a1q, A1_FRAC)

    # 64-byte record: coefficients plus first-order pitch metadata
    words = []
    modulation = PITCH.modulation_words(table)
    for m in range(DEPTH):
        if m < kk.size:
            gg, aa1, aa2 = int(Gq[m]), int(a1q[m]), int(a2q[m])
        else:
            gg = aa1 = aa2 = 0
        words.extend([gg, aa1, aa2] + [0] * 5 + modulation[m])
    data = b"".join(struct.pack(">I", v & 0xFFFFFFFF) for v in words)

    attack = max(float(atk), 0.003)
    release = max(float(rel), 0.020)
    entry = dict(
        instrument=INST[name], name=name, midi=int(midi),
        source_midi=source_midi, source_dynamic=source_dynamic,
        retuned=bool(source_midi != midi),
        modes=int(kk.size), period=int(period),
        a_step=max(1, int(ENV_ONE / (attack * FS))),
        r_step=max(1, int(ENV_ONE / (release * FS))),
        attack_s=attack, release_full_scale_s=release,
        a1_min=int(a1q.min()), a1_max=int(a1q.max()),
        g_min=int(Gq.min()), g_max=int(Gq.max()),
        real_poles=real_poles,
        max_static_q20_c=err20, max_static_q24_c=err24,
        coeff_sha256=hashlib.sha256(data).hexdigest(),
    )
    return entry, data, Gq, a1q, a2q


_patches: dict[str, SustainPatch] = {}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path,
                    default=Path(paths.PARAMS) / "sustain_q24")
    ap.add_argument("--catalog", action="store_true",
                    help="all MIDI 0..127, no flash image")
    ap.add_argument("--first-midi", type=int, default=36)
    ap.add_argument("--notes", type=int, default=48, choices=[16, 32, 48, 64])
    ap.add_argument("--allow-retune", action=argparse.BooleanOptionalAction,
                    default=True)
    ap.add_argument("--no-image", action="store_true")
    args = ap.parse_args(argv)

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    midis = range(128) if args.catalog else range(args.first_midi,
                                                  args.first_midi + args.notes)
    if min(midis) < 0 or max(midis) > 127:
        ap.error("MIDI range must be 0..127")

    entries = []
    arrays = dict(G=[], a1=[], a2=[])
    blobs = {}
    for name in INST:
        for midi in midis:
            try:
                entry, data, Gq, a1q, a2q = _build_entry(name, midi,
                                                         args.allow_retune)
            except ValueError as exc:
                if args.catalog:
                    print(f"skip {name} {midi}: {exc}")
                    continue
                raise
            entries.append(entry)
            blobs[(name, midi)] = data
            for key, arr in (("G", Gq), ("a1", a1q), ("a2", a2q)):
                pad = np.zeros(DEPTH, dtype=np.int64)
                pad[:arr.size] = arr
                arrays[key].append(pad)
    if not entries:
        raise SystemExit("no entries generated")

    # ---- flash image (same 6-region layout as sustain_resources.py) ------
    image_path = out / "sustain_flash_q24.bin"
    mem_path = out / "sustain_flash_q24.mem"
    image_info = None
    if not args.catalog and not args.no_image:
        notes = args.notes
        size = notes * DEPTH * 64
        image = bytearray(b"\xff" * (6 * size))
        for entry in entries:
            off = (entry["instrument"] * size
                   + (entry["midi"] - args.first_midi) * DEPTH * 64)
            data = blobs[(entry["name"], entry["midi"])]
            image[off:off + DEPTH * 64] = data
        image_path.write_bytes(image)
        mem_path.write_text("".join(f"{v:02X}\n" for v in image))
        image_info = dict(path=image_path.name, bytes=len(image),
                          sha256=_hash_file(image_path),
                          first_midi=args.first_midi, notes=notes)

    # ---- npz + manifest ---------------------------------------------------
    npz_path = out / "sustain_q24.npz"
    np.savez_compressed(
        npz_path,
        instrument_id=np.array([e["instrument"] for e in entries], dtype=np.int64),
        name=np.array([e["name"] for e in entries]),
        midi=np.array([e["midi"] for e in entries], dtype=np.int64),
        source_midi=np.array([e["source_midi"] for e in entries], dtype=np.int64),
        source_dynamic=np.array([e["source_dynamic"] for e in entries]),
        retuned=np.array([e["retuned"] for e in entries], dtype=bool),
        n_modes=np.array([e["modes"] for e in entries], dtype=np.int64),
        period=np.array([e["period"] for e in entries], dtype=np.int64),
        attack_s=np.array([e["attack_s"] for e in entries], dtype=float),
        release_s=np.array([e["release_full_scale_s"] for e in entries], dtype=float),
        a_step=np.array([e["a_step"] for e in entries], dtype=np.int64),
        r_step=np.array([e["r_step"] for e in entries], dtype=np.int64),
        G=np.stack(arrays["G"]), a1=np.stack(arrays["a1"]),
        a2=np.stack(arrays["a2"]),
        a1_format=np.array("Q2.24"), a1_frac=np.array(A1_FRAC),
        a1_bits=np.array(A1_BITS), record_bytes=np.array(64),
        note_bytes=np.array(DEPTH * 64),
    )

    manifest = dict(
        resource_fs=FS, storage_modes=DEPTH, active_modes_limit=48,
        a1_format="Q2.24", a1_frac=A1_FRAC, a1_bits=A1_BITS,
        record_bytes=64, note_bytes=DEPTH * 64, record_words=16,
        words_per_note=DEPTH * 16,
        coeff_words=["G", "a1", "a2"],
        pitch_format="P1T1", pitch_slope_frac=PITCH.SLOPE_FRAC,
        note=("a1 is signed 26-bit Q2.24 in word 1, matching current eng1. "
              "Older Q2.20 images must be regenerated."),
        allow_retune=bool(args.allow_retune),
        first_midi=None if args.catalog else args.first_midi,
        notes=None if args.catalog else args.notes,
        sources={name: _hash_file(Path(paths.param(name, "sustain")))
                 for name in INST},
        image=image_info,
        npz=npz_path.name,
        entries=entries,
    )
    (out / "sustain_profiles_q24.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    # ---- small check table ------------------------------------------------
    csv_path = out / "q24_check.csv"
    cols = ["name", "midi", "source_midi", "modes", "period",
            "a1_min", "a1_max", "g_min", "g_max", "real_poles",
            "max_static_q20_c", "max_static_q24_c", "coeff_sha256"]
    with csv_path.open("w", encoding="utf-8") as fh:
        fh.write(",".join(cols) + "\n")
        for e in entries:
            fh.write(",".join(str(e[c]) for c in cols) + "\n")

    # ---- format doc -------------------------------------------------------
    sample = blobs[(entries[0]["name"], entries[0]["midi"])]
    sample_words = struct.unpack(">16I", sample[:64])
    fmt = out / "COEFF_FORMAT.md"
    fmt.write_text(
        "# sustain_q24 coefficient format\n\n"
        "This directory contains **Q2.24 a1** resources for the current eng1.\n"
        "Older Q2.20 B images must be regenerated before use. Q2.24 images\n"
        "without P1T1 metadata play unmodulated and reject pitch controls.\n\n"
        "Record: 64 bytes per mode, 16 big-endian 32-bit words;\n"
        "64 modes per note = 4096 bytes per note.\n\n"
        "| word | field | format |\n"
        "|---:|---|---|\n"
        "| 0 | G | Q2.24 signed 26, sign-extended to 32 |\n"
        "| 1 | a1 | **Q2.24 signed 26**, sign-extended to 32 |\n"
        "| 2 | a2 | UQ0.24 unsigned 24 |\n"
        "| 3..7 | reserved | zero |\n"
        "| 8 | lower a1 bound | Q2.24 |\n"
        "| 9 | nominal a1 | Q2.24 |\n"
        "| 10 | upper a1 bound | Q2.24 |\n"
        "| 11..12 | reserved | zero |\n"
        "| 13 | K = 2r theta sin(theta) | signed25 Q3.22 |\n"
        "| 14 | reserved | zero |\n"
        "| 15 | pitch metadata identity | 0x50315431 (P1T1) |\n\n"
        "The a1 26-bit value is stored in the low bits of word 1; bits\n"
        "[31:26] are the sign extension of bit 25. The current eng1 reads\n"
        "`a12[25:0]` directly, with no left shift.\n\n"
        "G is re-calibrated from the Q2.24-quantised poles:\n"
        "`r = sqrt(a2q/2^24)`, `theta = acos(-a1q/(2r))`, `G = w/A_unit`.\n\n"
        f"First record example ({entries[0]['name']} MIDI{entries[0]['midi']}):\n"
        "```\n"
        f"G  = 0x{sample_words[0]:08X}\n"
        f"a1 = 0x{sample_words[1]:08X}\n"
        f"a2 = 0x{sample_words[2]:08X}\n"
        "```\n\n"
        "Files:\n"
        "- `sustain_q24.npz` — signed arrays, padded to 64 modes\n"
        "- `sustain_profiles_q24.json` — manifest with `a1_format: Q2.24`\n"
        "- `sustain_flash_q24.bin/.mem` — 6-region flash image\n"
        "- `q24_check.csv` — per-entry static pitch error, Q2.20 vs Q2.24\n",
        encoding="utf-8")

    print(f"wrote {out}")
    print(f"  entries={len(entries)}  a1_format=Q2.24  record=64B")
    print(f"  npz: {npz_path.name}  manifest: sustain_profiles_q24.json")
    if image_info:
        print(f"  image: {image_path.name} ({image_info['bytes']} bytes, "
              f"MIDI {args.first_midi}..{args.first_midi + args.notes - 1})")
    print("  format: current eng1 Q2.24; regenerate older Q2.20 B images.")
    for name in INST:
        rows = [e for e in entries if e["name"] == name]
        if not rows:
            continue
        print(f"  {name:7s}: {len(rows):3d} entries, "
              f"max static Q2.20 {max(e['max_static_q20_c'] for e in rows):.2f} c, "
              f"Q2.24 {max(e['max_static_q24_c'] for e in rows):.2f} c, "
              f"real poles {sum(e['real_poles'] for e in rows)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
