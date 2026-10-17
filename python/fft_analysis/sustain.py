"""Sustained-tone extraction (Class B): winds, brass, bowed strings.

A sustained note is not a decaying modal sum, so the pitched extractor's
"onset -> fit the decay" pipeline does not apply. Instead:

* **f0 / partials** -- TWM + the same unique-peak assignment, but run on the *steady*
  middle of the note (not the attack).
* **a_k** -- steady-state partial amplitudes (peak-normalised).
* **gamma_k** -- from the partial's **spectral linewidth** (half-power width):
  an exponentially-decaying resonator has a Lorentzian line of FWHM = gamma / pi.
  This is the honest measure for a sustained tone and the opposite of the pitched case,
  where a linewidth fit is useless and a time-decay fit is right.
* **drive envelope** -- attack (10->90 %) and release (90->10 %) times, which the
  synthesiser uses to shape the *player's* excitation (the instrument's own ring-up is
  set by gamma).
* **noise floor** -- the level between partials (breath / bow noise).
"""

from __future__ import annotations

import glob
import json
import os
import re
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))

import core  # noqa: E402
import paths  # noqa: E402

_NAME_RE = re.compile(r"^(?P<name>.+?)_(?P<note>[A-G]s?\d)_(?P<dur>[^_]+)_"
                      r"(?P<dyn>[^_]+)_(?P<art>.+)$")

#: Which libraries are sustained instruments (everything except the plucked/struck set).
SUSTAINED = ("flute", "oboe", "clarinet", "bass clarinet", "bassoon", "contrabassoon",
             "cor anglais", "saxophone", "trumpet", "trombone", "french horn", "tuba",
             "violin", "viola", "cello", "double bass")


def scan_sustained(root: str, instrument: str,
                   durations=("very-long", "long", "15"),
                   dynamics=("forte", "mezzo-forte"),
                   variations=("normal", "arco-normal")) -> list[dict]:
    """Only long notes at one dynamic/articulation: a 0.25 s sample has no steady
    state, and mixing dynamics/articulations mixes different instruments (arco vs
    col-legno, normal vs flutter)."""
    out = []
    for path in sorted(glob.glob(os.path.join(root, instrument, "*.mp3"))):
        stem = os.path.basename(path)[:-4]
        m = _NAME_RE.match(stem)
        if not m:
            continue
        if durations is not None and m.group("dur") not in durations:
            continue
        if dynamics is not None and m.group("dyn") not in dynamics:
            continue
        if variations is not None and m.group("art") not in variations:
            continue
        out.append(dict(path=path, instrument=instrument, note=m.group("note"),
                        midi=core.note_to_midi(m.group("note")),
                        duration=m.group("dur"), dynamic=m.group("dyn"),
                        articulation=m.group("art")))
    return out


def _envelope(x, sr, win=0.01):
    k = max(1, int(win * sr))
    return np.sqrt(np.convolve(x ** 2, np.ones(k) / k, mode="same"))


def note_region(x, sr, thr=0.1):
    """(on, off) from the broadband envelope -- a sustained note has no decay peak, so
    the pitched extractor's peak-back onset detector is the wrong tool."""
    e = _envelope(x, sr)
    idx = np.where(e > thr * e.max())[0]
    if idx.size == 0:
        return 0, len(x)
    return int(idx[0]), int(idx[-1])


def half_power_gamma(freqs, X, j):
    """gamma = pi * FWHM, from the -3 dB width around peak bin `j`."""
    half = X[j] / np.sqrt(2.0)
    lo = j
    while lo > 1 and X[lo] > half and X[lo - 1] < X[lo]:
        lo -= 1
    hi = j
    while hi < len(X) - 2 and X[hi] > half and X[hi + 1] < X[hi]:
        hi += 1
    df = freqs[1] - freqs[0]
    return float(np.pi * (hi - lo) * df), (hi - lo) * df


def _vibrato_sweep(x, sr, f0, fks, amps, nfft: int = 4096, hop: int = 256):
    """Peak fractional frequency deviation (vibrato depth) of the tone.

    Vibrato phase-modulates the source, so *every* partial becomes a Bessel sideband
    comb of half-width ~ delta * f_k (delta constant in cents, so the absolute sweep
    grows with the harmonic).  Reading a single spectral peak therefore returns
    ``a_k * |J0(beta_k)|`` with ``beta_k ~ k``, which darkens the upper harmonics; we
    need delta to integrate the sidebands instead (see ``analyze_sustain``).

    Track a well-resolved mid partial (strongest with 600 Hz <= f_k <= 3.5 kHz) over
    short frames and take a high percentile of |f/f_med - 1|.
    """
    band = [i for i, fk in enumerate(fks) if 600.0 <= fk <= 3500.0]
    if not band:
        return 0.0
    fk0 = float(fks[max(band, key=lambda i: amps[i])])
    win = np.hanning(nfft)
    ff = np.fft.rfftfreq(nfft, 1.0 / sr)
    df = float(ff[1] - ff[0])
    dev = []
    for i in range(0, len(x) - nfft, hop):
        Xf = np.abs(np.fft.rfft(x[i:i + nfft] * win))
        m = np.abs(ff - fk0) < 0.03 * fk0
        if not m.any():
            continue
        j = int(np.flatnonzero(m)[np.argmax(Xf[m])])
        if 0 < j < Xf.size - 1:                      # parabolic peak refinement
            la, lb, lc = np.log(Xf[j - 1] + 1e-20), np.log(Xf[j] + 1e-20), np.log(Xf[j + 1] + 1e-20)
            d = 0.5 * (la - lc) / (la - 2.0 * lb + lc) if (la - 2.0 * lb + lc) != 0 else 0.0
            dev.append((j + d) * df)
    if len(dev) < 8:
        return 0.0
    dev = np.asarray(dev)
    frac = np.abs(dev / np.median(dev) - 1.0)
    return float(min(np.percentile(frac, 98), 0.08))


def analyze_sustain(path: str, midi: int | None = None, dynamic: str = "",
                    sr: int = core.SR, max_modes: int = 48,
                    band_hz: float = core.MP3_BAND_HZ) -> dict:
    x = core.load_audio(path, sr)
    on, off = note_region(x, sr)
    if off - on < int(0.3 * sr):
        on, off = 0, len(x)
    span = off - on
    # steady window: the middle 30-70 % of the note
    t0 = on + int(0.30 * span)
    t1 = on + int(0.70 * span)
    if t1 - t0 < int(0.4 * sr):
        t0, t1 = on + int(0.15 * span), off
    seg = x[t0:t1]
    peak = float(np.max(np.abs(seg))) + 1e-30
    segn = seg / peak

    freqs, X = core._spectrum(segn, sr)
    if midi is None:
        midi = core.note_to_midi(re.sub(
            r"s", "#", re.search(r"([A-G]s?\d)", os.path.basename(path)).group(1)))
    nominal = core.midi_to_hz(midi)
    f0 = core.estimate_f0(segn, sr, nominal, band_hz=band_hz, span=0.08)
    part = core.find_partials(segn, sr, f0, band_hz, max_modes=max_modes)
    ks, fks, amps = part["k"], part["f_k"], part["amp_k"]

    # linewidth gamma for each assigned peak
    g = np.full(ks.size, np.nan)
    fwhm = np.full(ks.size, np.nan)
    for i, fk in enumerate(fks):
        j = int(np.argmin(np.abs(freqs - fk)))
        if 0 < j < len(X) - 1:
            g[i], fwhm[i] = half_power_gamma(freqs, X, j)
    ok = np.isfinite(g) & (g > 0.05)
    # gamma rises with frequency; fill gaps from that trend
    if int(ok.sum()) >= 3:
        lf = np.log(np.maximum(fks, 1.0))
        A = np.vstack([np.ones(int(ok.sum())), lf[ok]]).T
        coef, *_ = np.linalg.lstsq(A, np.log(g[ok]), rcond=None)
        pred = np.exp(coef[0] + coef[1] * lf)
        g[~ok] = np.clip(pred[~ok], 0.3, 400.0)
    g = np.clip(g, 0.3, 400.0)

    # drive envelope: attack and release of the broadband envelope
    e = _envelope(x, sr)
    steady = float(np.median(e[t0:t1]))
    pre = e[max(0, on - int(0.2 * sr)):on]
    thr10, thr90 = 0.1 * steady, 0.9 * steady
    rise = np.where(e[on:off] > thr10)[0]
    atk = np.nan
    if rise.size:
        i10 = rise[0]
        i90 = np.where(e[on:off] > thr90)[0]
        if i90.size:
            atk = float((i90[0] - i10) / sr)
    # Release: the 90 % -> 10 % time of the *decay*, not "the first sample below 10 %
    # after the note region ends".  `off` is the last sample above 10 % of the peak, so
    # it already sits at the 10 % point and scanning past it returned ~0.5 ms for every
    # note.  Take the last sample still at/above 90 % of the steady level as the top of
    # the release, then the first sample after it that falls to 10 %.  This is the
    # measured 90->10 *duration*; the synthesiser uses it as the release time constant,
    # which is a deliberate envelope model choice, not an identity with a true tau.
    # A tail that is truncated (never reaches 10 %) or has no decay has no measurable
    # descent and falls back to 0.0, the historical "no release" value.
    above90 = np.where(e[max(0, on):] >= thr90)[0]
    rlx = 0.0
    if above90.size:
        i90 = int(above90[-1]) + max(0, on)
        below10 = np.where(e[i90:] <= thr10)[0]
        if below10.size:
            rlx = float(below10[0] / sr)

    # Noise floor, measured in a *fixed reference band* (2-8 kHz) between the partials
    # and relative to the strongest peak. Measuring over the whole band made the number
    # depend on how far the harmonics reach, so it could not be compared across
    # instruments (trumpet came out 60 dB cleaner than flute). The analysis-window
    # length is stored too: converting a spectral level to a time-domain amplitude needs
    # it (|X| of noise scales as sqrt(N)).
    mask = (freqs >= 2000.0) & (freqs <= 8000.0)
    for fk in fks:
        mask &= np.abs(freqs - fk) > max(10.0, 0.02 * fk)
    noise_db = float(20 * np.log10((np.median(X[mask]) + 1e-30) / (X.max() + 1e-30))) \
        if mask.any() else -120.0
    win_len = int(t1 - t0)

    # Shape of the noise: 1/3-octave bands from 150 Hz to 16 kHz, relative to the
    # reference band (2-8 kHz) so it multiplies the scalar level without changing it.
    # A *low percentile* (not the median) is taken between the partials: the median is
    # inflated by the skirt of the neighbouring partials, which made the model's noise
    # too loud in the low-mid band (measured +5..8 dB vs the recording); finer bands let
    # the FIR follow the real tilt instead of 8 coarse steps.
    edges = np.geomspace(150.0, 16000.0, 25)

    def _stat(v):
        return float(np.percentile(v, 25)) if v.size else ref

    ref = _stat(X[mask]) if mask.any() else 1e-12
    shape = []
    for lo, hi in zip(edges[:-1], edges[1:]):
        m = (freqs >= lo) & (freqs < hi)
        for fk in fks:
            m &= np.abs(freqs - fk) > max(10.0, 0.02 * fk)
        shape.append(_stat(X[m]))
    shape_db = 20 * np.log10((np.array(shape) + 1e-30) / (ref + 1e-30))
    # Below the 2-8 kHz reference band, the "between partials" level is dominated by the
    # skirt of the neighbouring partials, not by noise (that is why it reads up to +25 dB
    # there). Trusting it made the model's bow noise boom at low frequencies. Cap the
    # shape at the reference so the noise is never boosted below it.
    shape_db = np.minimum(shape_db, 0.0)

    # Partial amplitude: integrate the power over each partial's vibrato sidebands
    # instead of reading the spectral peak.  A phase-modulated partial is a Bessel
    # comb a_k * sum_n J_n(beta_k) with sum_n J_n^2 == 1 for any beta, so the band sum
    # recovers a_k unbiased; the peak returns a_k * |J0(beta_k)| with beta_k ~ k, which
    # is what systematically darkened the upper harmonics.  The band is the measured
    # sweep plus a margin, capped below half the partial spacing so it cannot swallow a
    # neighbour (needs k < 1/(2*delta), fine for delta <= ~25 cents up to k ~ 30).
    delta = _vibrato_sweep(segn, sr, f0, fks, amps)
    a_raw = np.empty(ks.size)
    for i, fk in enumerate(fks):
        bw = min(delta * fk * 1.3 + 5.0, 0.45 * f0)
        m = np.abs(freqs - fk) < bw
        a_raw[i] = np.sqrt(float(np.sum(X[m] ** 2))) if m.any() else 1e-30
    a = a_raw / (a_raw.max() + 1e-30)
    return dict(note=os.path.basename(path), midi=int(midi), dynamic=dynamic,
                f0=f0, ks=ks, fks=fks, a=a, gamma=g,
                fwhm_hz=fwhm, attack_s=atk, release_s=rlx, noise_db=noise_db,
                noise_win=win_len, noise_shape_db=shape_db, noise_edges=edges,
                seconds=len(x) / sr, steady_s=(t1 - t0) / sr, span_s=span / sr,
                env=e[::max(1, int(0.005 * sr))])


def build(instrument: str, max_modes: int = 48):
    entries = scan_sustained(paths.MUSIC, instrument)
    out = []
    for e in entries:
        try:
            out.append(analyze_sustain(e["path"], midi=e["midi"],
                                       dynamic=e["dynamic"], max_modes=max_modes))
        except Exception as exc:                       # noqa: BLE001
            print("  !", e["path"], exc)
    return out


def main(argv=None):
    names = list(argv) if argv else ["flute", "trumpet", "cello"]
    paths.makedirs()
    summary = {}
    for name in names:
        res = build(name)
        if not res:
            continue
        a = np.concatenate([r["a"] for r in res])
        g = np.concatenate([r["gamma"] for r in res])
        atk = np.array([r["attack_s"] for r in res if np.isfinite(r["attack_s"])])
        fk = np.concatenate([r["fks"] for r in res])
        summary[name] = dict(notes=len(res), partials=int(a.size),
                             gamma_median=round(float(np.median(g)), 2),
                             attack_ms_median=round(float(np.median(atk) * 1e3), 1) if atk.size else None,
                             noise_db_median=round(float(np.median([r["noise_db"] for r in res])), 1),
                             modes_median=int(np.median([r["ks"].size for r in res])))
        np.savez_compressed(paths.param(name, "sustain"),
                            notes=np.array([r["note"] for r in res]),
                            midi=np.array([r["midi"] for r in res], dtype=int),
                            dynamic=np.array([r["dynamic"] for r in res]),
                            f0=np.array([r["f0"] for r in res]),
                            k=np.concatenate([r["ks"] for r in res]),
                            f_k=np.concatenate([r["fks"] for r in res]),
                            a=np.concatenate([r["a"] for r in res]),
                            gamma=np.concatenate([r["gamma"] for r in res]),
                            attack_s=np.array([r["attack_s"] for r in res]),
                            release_s=np.array([r["release_s"] for r in res]),
                            noise_db=np.array([r["noise_db"] for r in res]),
                            noise_win=np.array([r["noise_win"] for r in res]),
                            noise_shape_db=np.stack([r["noise_shape_db"] for r in res]),
                            noise_edges=res[0]["noise_edges"],
                            note_id=np.concatenate([np.full(r["ks"].size, i)
                                                    for i, r in enumerate(res)]))
        print(f"{name:12s} notes {len(res):3d}  gamma median {np.median(g):5.2f} 1/s  "
              f"attack median {summary[name]['attack_ms_median']} ms  "
              f"noise {summary[name]['noise_db_median']} dB")
    with open(os.path.join(paths.PARAMS, "sustain_summary.json"), "w",
              encoding="utf-8") as fh:
        json.dump(summary, fh, indent=2)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
