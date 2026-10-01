"""Evaluate the drum kit against held-out takes of the same instruments.

Fits come only from ``drums.npz`` (one take per piece). Evaluation also uses other
takes of the same drum/cymbal (AVL: the other velocity layers; Salamander: the other
sample indices and dynamics), so a low error cannot come from fitting that take.

Metrics are scale-free on purpose, and deliberately reported PER TIME WINDOW: the
whole-segment median hides "attack too weak / tail too bright" (advisor review,
2026-09-29). Peak-normalised window RMS is still NOT used -- it is dominated by
crest factor.

  * band shape difference (each 1/3-oct curve normalised by its own max band, so a
    difference is a SHAPE difference, never an absolute-level claim)
  * time-energy distribution (fraction of the segment's energy per window)
  * crest factor, attack rise time, short-time centroid trajectory

Run: python python/modal_sim/kit_eval.py
"""

from __future__ import annotations

import glob
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "fft_analysis"))

import core  # noqa: E402
import drumkit as dk  # noqa: E402
import paths  # noqa: E402
import percussion as pc  # noqa: E402

SR = dk.SR
AVL = "avl-drumkits/Samples"
SAL = "salamanderDrumkitSamplesFixedOnsets/OH"
EDGES = np.geomspace(60.0, 16000.0, 25)
TAKE_S = 2.5

#: energy windows cover the WHOLE segment, so a change in the long tail cannot
#: silently rescale every earlier fraction (advisor review).
E_WINDOWS = ((0, .02), (.02, .05), (.05, .15), (.15, .40), (.40, .80),
             (.80, 1.5), (1.5, 2.0), (2.0, 2.5))
#: band-shape windows, reported separately
B_WINDOWS = ((0, .02), (.02, .05), (.05, .15), (.15, .80), (.80, 2.5))
SEEDS = (1, 2, 3)

FIT_TAKE = {key: os.path.basename(e["path"]) for key, e in pc.KIT.items()}


def _glob(rel):
    hits = sorted(glob.glob(os.path.join(paths.MUSIC, rel)))
    return [os.path.relpath(p, paths.MUSIC) for p in hits]


def _held(rel_list, key):
    return sorted(p for p in rel_list
                  if os.path.basename(p) != FIT_TAKE[key])


HELD_OUT = {
    "kick": _held([f"{AVL}/36-Pearl22Kick-{n}.flac" for n in (1, 2, 3, 4, 5)], "kick"),
    "snare": _held([f"{AVL}/38-PearlSnare-{n}.flac" for n in (1, 2, 3, 4, 5)], "snare"),
    "tom": _held([f"{AVL}/45-Pearl12Tom-{n}.flac" for n in (1, 2, 3, 4, 5)], "tom"),
    "hat": _held(_glob(f"{SAL}/hihatClosed_OH_F_*.wav")
                 + _glob(f"{SAL}/hihatClosed_OH_P_*.wav"), "hat"),
    "ride": _held(_glob(f"{SAL}/ride2_OH_*.wav"), "ride"),
    "crash": _held(_glob(f"{SAL}/crash1_OH_*.wav"), "crash"),
}


def shape_db(x, t0=0.0, t1=0.8):
    s = x[int(t0 * SR):min(len(x), int(t1 * SR))]
    if len(s) < 64:
        return None
    z = np.abs(np.fft.rfft(s * np.hanning(len(s)))) ** 2
    f = np.fft.rfftfreq(len(s), 1 / SR)
    b = np.array([z[(f >= lo) & (f < hi)].sum() for lo, hi in zip(EDGES[:-1], EDGES[1:])])
    return 10 * np.log10((b + 1e-30) / b.max())


def centroid(x, t0=0.0, t1=0.4):
    s = x[int(t0 * SR):min(len(x), int(t1 * SR))]
    if len(s) < 64:
        return np.nan
    z = np.abs(np.fft.rfft(s * np.hanning(len(s))))
    f = np.fft.rfftfreq(len(s), 1 / SR)
    return float((z * f).sum() / (z.sum() + 1e-30))


def energy_frac(x):
    tot = float((x ** 2).sum()) + 1e-30
    out = []
    for a, b in E_WINDOWS:
        if int(b * SR) > len(x):
            out.append(np.nan)
        else:
            out.append(float((x[int(a * SR):int(b * SR)] ** 2).sum()) / tot)
    return out


def crest(x):
    return float(20 * np.log10(np.max(np.abs(x)) / (np.sqrt((x ** 2).mean()) + 1e-30)))


def rise_ms(x):
    """Time from the segment start to 90% of the peak absolute value."""
    pk = float(np.max(np.abs(x)))
    if pk <= 0:
        return np.nan
    idx = np.argmax(np.abs(x) >= 0.9 * pk)
    return 1000.0 * idx / SR


def take(key, rel):
    ch = pc.KIT[key].get("channel")
    x = core.load_audio(os.path.join(paths.MUSIC, rel), SR, ch)
    on = core.detect_onset(x)
    y = x[on:on + int(TAKE_S * SR)]
    return y / (np.max(np.abs(y)) + 1e-30)


def render(hit, seed=1):
    dk._FILT_CACHE.clear()
    rng = np.random.default_rng(seed)
    y = (dk.render_modal(hit, TAKE_S, 1.0, rng)
         + dk.render_noise(hit, TAKE_S, 1.0, rng, 1.0))
    return y / (np.max(np.abs(y)) + 1e-30)


def band_err_by_window(model, real):
    """|shape difference| within each band-shape window (None when too short)."""
    out = {}
    for a, b in B_WINDOWS:
        if int(b * SR) > len(real):
            out[f"{a}-{b}s"] = None
            continue
        ms, rs = shape_db(model, a, b), shape_db(real, a, b)
        out[f"{a}-{b}s"] = None if ms is None else float(np.median(np.abs(ms - rs)))
    return out


def _spread(vals):
    v = np.array([x for x in vals if x is not None and np.isfinite(x)])
    if v.size == 0:
        return None
    return [round(float(np.median(v)), 2), round(float(np.percentile(v, 25)), 2),
            round(float(np.percentile(v, 75)), 2)]


def main(argv=None):
    argv = list(argv or [])
    keys = argv if argv else ["kick", "snare", "tom", "hat", "ride", "crash"]
    npz = os.environ.get("KIT_NPZ", os.path.join(paths.PARAMS, "drums.npz"))
    kit = pc.load_kit(npz)
    print(f"# kit: {os.path.basename(npz)}")
    report = {}
    print("留出验证：拟合只用一个 take，下面是同乐器其它 take。"
          "形状差是各自归一后的 SHAPE 差，不是电平差。")
    print(f"{'音件':6s}{'take':>5s}{'形状差 中位[p25-p75]':>22s}"
          f"{'  分窗形状差 0-20/20-50/50-150/150-800/800-2500ms'}")
    for key in keys:
        fit = kit[key]
        rows = []
        for rel in HELD_OUT[key]:
            try:
                r = take(key, rel)
            except Exception:
                continue
            per_seed = []
            for s in SEEDS:
                m = render(fit, s)
                per_seed.append(dict(
                    band=[np.median(np.abs(shape_db(m) - shape_db(r))),
                          np.percentile(np.abs(shape_db(m) - shape_db(r)), 90)],
                    win=band_err_by_window(m, r), frac=energy_frac(m),
                    crest=crest(m), rise=rise_ms(m),
                    cen=[centroid(m, a, b) for a, b in
                         ((0, .05), (.05, .15), (.15, .4), (.4, .8))]))
            rows.append(dict(file=rel,
                             band_med=float(np.mean([x["band"][0] for x in per_seed])),
                             band_p90=float(np.mean([x["band"][1] for x in per_seed])),
                             win={k: float(np.mean([x["win"][k] for x in per_seed
                                                    if x["win"][k] is not None]))
                                  if any(x["win"][k] is not None for x in per_seed) else None
                                  for k in per_seed[0]["win"]},
                             frac=np.nanmean([x["frac"] for x in per_seed], axis=0),
                             crest=float(np.mean([x["crest"] for x in per_seed])),
                             rise=float(np.mean([x["rise"] for x in per_seed])),
                             cen=np.nanmean([x["cen"] for x in per_seed], axis=0),
                             real_frac=energy_frac(r), real_crest=crest(r),
                             real_rise=rise_ms(r),
                             real_cen=[centroid(r, a, b) for a, b in
                                       ((0, .05), (.05, .15), (.15, .4), (.4, .8))]))
        if not rows:
            continue
        win_keys = list(rows[0]["win"])
        report[key] = dict(
            n_takes=len(rows),
            band_med=_spread([r["band_med"] for r in rows]),
            band_p90=_spread([r["band_p90"] for r in rows]),
            band_med_by_window={k: _spread([r["win"][k] for r in rows]) for k in win_keys},
            crest_real=_spread([r["real_crest"] for r in rows]),
            crest_model=_spread([r["crest"] for r in rows]),
            rise_real_ms=_spread([r["real_rise"] for r in rows]),
            rise_model_ms=_spread([r["rise"] for r in rows]),
            centroid_real_khz=[round(float(v), 2) for v in
                               np.nanmedian([r["real_cen"] for r in rows], axis=0) / 1000],
            centroid_model_khz=[round(float(v), 2) for v in
                                np.nanmedian([r["cen"] for r in rows], axis=0) / 1000],
            energy_ratio_model_over_real=[round(float(v), 2) for v in
                                          np.nanmedian(np.array([r["frac"] for r in rows])
                                                       / np.array([r["real_frac"] for r in rows]),
                                                       axis=0)],
            per_take=[dict(file=os.path.basename(r["file"]),
                           band_med=round(r["band_med"], 2),
                           crest_real=round(r["real_crest"], 1),
                           crest_model=round(r["crest"], 1)) for r in rows])
        rep = report[key]
        print(f"{key:6s}{len(rows):5d}{rep['band_med'][0]:12.2f} "
              f"[{rep['band_med'][1]:.1f}-{rep['band_med'][2]:.1f}]      " +
              "  ".join("  n/a " if rep["band_med_by_window"][k] is None
                        else f"{rep['band_med_by_window'][k][0]:6.2f}"
                        for k in win_keys))
        print(f"{'':11s}crest 真{rep['crest_real'][0]:6.1f} 模{rep['crest_model'][0]:5.1f}"
              f" | 上升时间 真{rep['rise_real_ms'][0]:5.1f} 模{rep['rise_model_ms'][0]:5.1f} ms"
              f" | 谱心轨迹(真) {' '.join(f'{v:.1f}' for v in rep['centroid_real_khz'])}"
              f" kHz  (模) {' '.join(f'{v:.1f}' for v in rep['centroid_model_khz'])}")
        print(f"{'':11s}能量比 模型/录音 各窗 " +
              " ".join("n/a" if not np.isfinite(v) else f"{v:.2f}"
                       for v in rep["energy_ratio_model_over_real"]))
    out = os.path.join(paths.SIM_DRUMS, "kit_eval.json")
    os.makedirs(paths.SIM_DRUMS, exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        json.dump({"method": "one take per piece for fitting; held-out takes of the "
                             "same instrument for evaluation; scale-free shape, "
                             "time-energy, crest, rise-time and centroid metrics, "
                             "reported per window",
                   "energy_windows_s": E_WINDOWS, "band_windows_s": B_WINDOWS,
                   "results": report}, fh, indent=2, ensure_ascii=False)
    print("wrote", out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
