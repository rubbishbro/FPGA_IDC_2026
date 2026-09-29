"""Run the FFT analysis over the sample libraries and deliver results.

    python python/fft_analysis/run.py --instrument guitar
    python python/fft_analysis/run.py --instrument piano
    python python/fft_analysis/run.py --instrument all

Results land in music_resources/FFT_results/.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import traceback

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))          # python/ -> instruments.py

import core          # noqa: E402
import plots         # noqa: E402
import instruments   # noqa: E402
import paths         # noqa: E402

MUSIC = paths.MUSIC
OUTDIR = paths.PARAMS          # extracted tables
FIGDIR = paths.FIG_EXTRACT     # per-instrument subfolders live under here

INSTRUMENTS = instruments.REGISTRY


def scan(name: str):
    cfg = INSTRUMENTS[name]
    if cfg["source"] == "phil":
        return core.scan_philharmonia(MUSIC, name, variations=cfg["variations"])
    return core.scan_piano(os.path.join(MUSIC, "UprightPian"))


def representative(entries):
    """A few notes spread over the range for diagnostic figures."""
    if not entries:
        return []
    by_midi = {}
    for e in entries:
        by_midi.setdefault(e["midi"], []).append(e)
    mids = sorted(by_midi)
    picks = [mids[len(mids) // 4], mids[len(mids) // 2], mids[(3 * len(mids)) // 4]]
    out = []
    for m in picks:
        # prefer the loudest available dynamic
        cand = sorted(by_midi[m], key=lambda e: e.get("dynamic", ""))
        out.append(cand[0])
    return out


def run_instrument(name: str, limit: int = 0):
    cfg = INSTRUMENTS[name]
    band, max_modes = cfg["band_hz"], cfg["max_modes"]
    figdir = paths.extract_fig_dir(name)
    os.makedirs(figdir, exist_ok=True)
    entries = scan(name)
    if limit:
        entries = entries[:limit]
    print(f"[{name}] {len(entries)} entries, band={band:.0f} Hz, max_modes={max_modes}")

    notes = []
    failures = []
    t0 = time.time()
    for i, e in enumerate(entries, 1):
        try:
            res = core.analyze_note(e["path"], e["midi"], e, band_hz=band,
                                    max_modes=max_modes)
            notes.append(res)
            if i % 20 == 0 or i == len(entries):
                print(f"    {i}/{len(entries)}  ({time.time() - t0:.0f}s)  "
                      f"{e['note']} {e['dynamic']}: f0={res['f0']:.2f} "
                      f"B={res['B']:.2e} modes={res['k'].size}")
        except Exception as exc:                      # keep going on a bad file
            failures.append(dict(path=e["path"], error=f"{type(exc).__name__}: {exc}"))
            print(f"    ! {e['path']}: {exc}")

    # --- manifest ---
    with open(os.path.join(OUTDIR, f"{name}_manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(entries, fh, indent=2, ensure_ascii=False)

    # --- partial tables (concatenated, ragged-aware) ---
    if notes:
        (note_id, ks, fks, amps, a0s, gs, g2s, r2s,
         proms, exprs, trusted) = ([], [], [], [], [], [], [], [], [], [], [])
        for nid, n in enumerate(notes):
            m = n["k"].size
            note_id.append(np.full(m, nid))
            for arr, dst in ((n["k"], ks), (n["f_k"], fks), (n["amp_k"], amps),
                             (n["a0"], a0s), (n["gamma"], gs), (n["gamma2"], g2s),
                             (n["r2"], r2s), (n["prom_db"], proms),
                             (n["extrap"], exprs), (n["trusted"], trusted)):
                dst.append(np.asarray(arr, float))
        np.savez_compressed(
            os.path.join(OUTDIR, f"{name}_partials.npz"),
            note_id=np.concatenate(note_id), k=np.concatenate(ks),
            f_k=np.concatenate(fks), amp_k=np.concatenate(amps),
            a0=np.concatenate(a0s), gamma=np.concatenate(gs),
            gamma2=np.concatenate(g2s), r2=np.concatenate(r2s),
            prom_db=np.concatenate(proms), extrap=np.concatenate(exprs),
            trusted=np.concatenate(trusted),
            f0=np.array([n["f0"] for n in notes]),
            B=np.array([n["B"] for n in notes]),
            midi=np.array([n["midi"] for n in notes]),
            note=np.array([n["note"] for n in notes]),
            dynamic=np.array([n["dynamic"] for n in notes]),
        )

    # --- body ---
    if notes:
        grid, mean_db, std_db, n_used = core.body_curve(
            notes, f_hi=min(band, 16_000.0))
        fir = core.design_body_fir(grid, mean_db)
        np.savez_compressed(os.path.join(OUTDIR, f"{name}_body.npz"),
                            grid=grid, mean_db=mean_db, std_db=std_db,
                            n_used=n_used, fir=fir)
        plots.fig_body(grid, mean_db, std_db, n_used,
                       os.path.join(figdir, "body.png"),
                       title=f"{name}: averaged coloration (source x body)")
        plots.fig_decay_summary(notes, os.path.join(figdir, "gamma.png"),
                                title=f"{name}: per-partial damping γ vs frequency")

    # --- representative note figures ---
    for e in representative(entries):
        match = [n for n in notes if n["path"] == e["path"]]
        if not match:
            continue
        n = match[0]
        x = core.load_audio(n["path"])
        tag = f"{n['note']}_{n['dynamic']}".replace("/", "-")
        plots.fig_note(n, x, n["sr"], os.path.join(figdir, f"{tag}.png"))

    # --- summary ---
    summary = summarize(name, notes, failures, band)
    with open(os.path.join(OUTDIR, f"{name}_summary.json"), "w", encoding="utf-8") as fh:
        json.dump(summary, fh, indent=2, ensure_ascii=False)
    return summary


def summarize(name, notes, failures, band):
    if not notes:
        return dict(instrument=name, n_notes=0, failures=failures)
    g1k = []
    r2s = []
    n_total = n_trusted = 0
    f0_cents = []
    for n in notes:
        fk, g = n["f_k"], n["gamma"]
        good = np.isfinite(g) & (g > 0) & (fk > 0)
        if good.sum() >= 4:
            g1k.append(float(np.interp(1000.0, fk[good], g[good])))
        a0, r2 = n["a0"], n["r2"]
        strong = np.isfinite(a0) & (a0 > 0.05 * np.nanmax(a0)) & np.isfinite(r2)
        if strong.sum():
            r2s.append(float(np.median(r2[strong])))
        n_total += int(fk.size)
        n_trusted += int(np.count_nonzero(n["trusted"]))
        nominal = core.midi_to_hz(n["midi"])
        if nominal > 0 and n["f0"] > 0:
            f0_cents.append((n["note"], n["dynamic"],
                             1200.0 * np.log2(n["f0"] / nominal)))
    bvals = [n["B"] for n in notes if n["k"].size >= 8]
    cents = np.asarray([c for _, _, c in f0_cents], float) if f0_cents else np.zeros(0)
    outliers = sorted((abs(c), nt, dy, c) for nt, dy, c in f0_cents
                      if abs(c) > 50.0)[::-1][:10]
    return dict(
        instrument=name,
        n_notes=len(notes),
        n_failures=len(failures),
        band_hz=band,
        B_median=float(np.median(bvals)) if bvals else None,
        B_max=float(np.max([n["B"] for n in notes])),
        modes_median=float(np.median([n["k"].size for n in notes])),
        modes_min=int(min(n["k"].size for n in notes)),
        modes_max=int(max(n["k"].size for n in notes)),
        gamma_at_1kHz_median=float(np.median(g1k)) if g1k else None,
        r2_median=float(np.median(r2s)) if r2s else None,
        # --- extraction quality (independent of any synthesis) ---
        partials_total=n_total,
        partials_trusted=n_trusted,
        frac_trusted=(n_trusted / n_total) if n_total else 0.0,
        f0_cents_median=float(np.median(cents)) if cents.size else None,
        f0_cents_p90_abs=float(np.percentile(np.abs(cents), 90)) if cents.size else None,
        f0_cents_max_abs=float(np.abs(cents).max()) if cents.size else None,
        f0_outliers=[dict(note=nt, dynamic=dy, cents=round(float(c), 1))
                     for _, nt, dy, c in outliers],
        failures=failures,
    )


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--instrument", default="all",
                    choices=instruments.names() + ["all"])
    ap.add_argument("--limit", type=int, default=0, help="analyse only first N notes")
    args = ap.parse_args(argv)

    paths.makedirs()
    names = list(INSTRUMENTS) if args.instrument == "all" else [args.instrument]
    summaries = []
    for name in names:
        try:
            summaries.append(run_instrument(name, limit=args.limit))
        except Exception:
            traceback.print_exc()

    report = os.path.join(paths.FFT, "report.md")
    with open(report, "w", encoding="utf-8") as fh:
        fh.write("# FFT analysis report\n\n")
        fh.write("Partial-tracking extraction of the guitar and piano sample libraries.\n\n")
        fh.write("## Method\n\n")
        fh.write("- f0 by **two-way mismatch** (TWM) of a harmonic series to the strong\n"
                 "  spectral peaks, searched over nominal*(1±15 %) and estimated on a\n"
                 "  0.2–0.9 s mid window. A single-peak pick locked onto the wrong series on\n"
                 "  low piano (A0 read ~2 semitones sharp) and a harmonic-sum comb did the\n"
                 "  same on banjo/mandolin (a semitone low, from sympathetic strings); TWM\n"
                 "  penalises both unexplained harmonics and unexplained peaks.\n")
        fh.write("- partials assigned to the harmonic series with **unique peak ownership**\n"
                 "  (greedy, low k first), f_k = k f0 sqrt(1+B k^2); B from a **robust,\n"
                 "  amplitude-weighted** fit of the low, strong harmonics\n")
        fh.write("- each partial carries a local **prominence** (peak vs neighbouring\n"
                 "  valley); a partial is `trusted` only when prominence > 6 dB, r² > 0.3,\n"
                 "  γ > 0.02 and a0 > 0\n")
        fh.write("- per-partial amplitude envelope by time-domain demodulation "
                 "(e^{-j2πf_k t}, zero-phase low-pass); γ from a log-linear fit of a\n"
                 "  50 ms-smoothed envelope (beating removed), plus a late-segment fit\n"
                 "  for the piano double decay\n")
        fh.write("- body = per-note partial amplitudes averaged on an absolute-frequency\n"
                 "  axis (this is *source × string/board × room*, not a deconvolved body);\n"
                 "  a linear-phase FIR is fitted to the mean curve\n\n")
        fh.write("## Summary\n\n")
        fh.write("| instrument | notes | B (median) | modes (median) | γ@1kHz (median) | R² | band |\n")
        fh.write("|---|---:|---:|---:|---:|---:|---:|\n")
        for s in summaries:
            if not s.get("n_notes"):
                continue
            b = s["B_median"]
            b_txt = "n/a" if b is None else f"{b:.2e}"
            g = s["gamma_at_1kHz_median"]
            g_txt = "n/a" if g is None else f"{g:.1f}"
            r = s["r2_median"]
            r_txt = "n/a" if r is None else f"{r:.3f}"
            fh.write(f"| {s['instrument']} | {s['n_notes']} | {b_txt} | "
                     f"{s['modes_median']:.0f} | {g_txt} | {r_txt} | "
                     f"{s['band_hz']:.0f} Hz |\n")
        fh.write("\n`B` is only fitted on notes with >= 8 partials (high notes have too "
                 "few to constrain inharmonicity).\n")
        fh.write("\n## Extraction quality\n\n")
        fh.write("| instrument | partials trusted | f0 cents (median) | f0 |cents| p90 | "
                 "f0 outliers |>50c| |\n")
        fh.write("|---|---:|---:|---:|---|\n")
        for s in summaries:
            if not s.get("n_notes"):
                continue
            ft = s.get("frac_trusted", 0.0)
            m = s.get("f0_cents_median")
            p = s.get("f0_cents_p90_abs")
            out = s.get("f0_outliers", [])
            out_txt = ", ".join(f"{o['note']}{o['dynamic'][0]} {o['cents']:+.0f}" for o in out[:6]) or "none"
            fh.write(f"| {s['instrument']} | {s['partials_trusted']}/{s['partials_total']} "
                     f"({ft * 100:.0f} %) | {'n/a' if m is None else f'{m:+.1f}'} | "
                     f"{'n/a' if p is None else f'{p:.1f}'} | {out_txt} |\n")
        fh.write("\nA non-zero f0 offset is not itself a fault: acoustic instruments are\n"
                 "not tuned to A440, and low strings are intentionally stretched. The\n"
                 "outlier list is a *review* aid — a large offset means \u201ccheck whether the\n"
                 "estimator locked onto the wrong series\u201d, not automatically \u201cbad note\u201d\n"
                 "(the piano B0 here is genuinely ~60 cents flat).\n")
        fh.write("\n## Files\n\n")
        fh.write("- `<inst>_manifest.json` — per-file note/dynamic/loop metadata\n")
        fh.write("- `<inst>_partials.npz` — f0, B, k, f_k, amp_k, a0, γ, γ2, R², "
                 "prom_db, trusted\n")
        fh.write("- `<inst>_body.npz` — averaged coloration + fitted FIR\n")
        fh.write("- `figures/<inst>/` — note diagnostics and body/γ summaries\n\n")
        fh.write("## Caveats\n\n")
        fh.write("- guitar is MP3: analysis band limited to 16 kHz; piano is FLAC (20 kHz)\n")
        fh.write("- piano lower/mid notes are looped; only the region before `loop_start`\n"
                 "  is used for decay, the looped sustain is a faked steady state\n")
        fh.write("- the body curve is an averaged *colouration*, not a physical body-only\n"
                 "  response; the runtime IIR is fitted to a mild, detrended version of it\n")
    print(f"\nwrote {report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
