"""Percussion extraction: modal decomposition of a *single hit*.

Percussion is not harmonic, so this does **not** reuse the k*f0 comb. A hit is a set of
inharmonic decaying resonances plus, for drums/cymbals with wire or metal, a broadband
noise component. The extractor therefore:

1. finds the onset and the strongest spectral peaks (``find_peaks``, not k*f0),
2. fits ``a0`` and ``gamma`` per peak with the same envelope machinery as the pitched
   instruments (time-domain demodulation + log-linear fit), but with an early ``t0``
   because a drum decays in tens of ms,
3. reports how much of the hit's energy the picked modes *do not* explain, which is the
   part a noise branch has to carry (snares, cymbals).

Writes ``FFT_results/<kit>.npz`` (one record per hit) and a small report.
"""

from __future__ import annotations

import glob
import json
import os
import re
import sys

import numpy as np
from scipy.signal import find_peaks

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))

import core  # noqa: E402
import instruments  # noqa: E402
import paths  # noqa: E402

MUSIC = paths.MUSIC
OUTDIR = paths.PARAMS

_NAME_RE = re.compile(r"^(?P<name>.+?)__(?P<dur>[^_]+)_(?P<dyn>[^_]+)_(?P<art>.+)$")


def scan_percussion(root: str) -> list[dict]:
    """One entry per mp3 under ``music_resources/percussion/<dir>/``."""
    entries = []
    base = os.path.join(root, "percussion")
    for path in sorted(glob.glob(os.path.join(base, "*", "*.mp3"))):
        stem = os.path.basename(path)[:-4]
        m = _NAME_RE.match(stem)
        if not m:
            continue
        entries.append(dict(path=path, group=os.path.basename(os.path.dirname(path)),
                            name=m.group("name"), duration=m.group("dur"),
                            dynamic=m.group("dyn"), articulation=m.group("art")))
    return entries


def analyze_hit(path: str, sr: int = core.SR, n_modes: int = 48,
                floor_db: float = -45.0, t0: float = 0.005, t1: float = 0.8,
                min_sep: float = 0.5, channel: int | None = None,
                noise_shape: str = "deficit") -> dict:
    """Modal decomposition of one hit.

    Returns ``f``, ``gamma``, ``a`` (length <= n_modes), plus ``env_gamma`` (the
    broadband decay), ``residual_db`` and the noise-branch descriptor.
    ``noise_shape`` selects "deficit" (render-based attribution) or "residual"
    (the older notch-residual definition), so the two can be compared.
    """
    x = core.load_audio(path, sr, channel)
    on = core.detect_onset(x, sr)
    seg = x[on:on + int(t1 * sr)]
    if seg.size < 16:
        seg = x[:max(16, int(0.2 * sr))]
    peak = float(np.max(np.abs(seg))) + 1e-30
    segn = seg / peak

    # --- strongest spectral peaks (inharmonic; no k*f0 assumption) ---
    freqs, X = core._spectrum(segn, sr)
    Xn = X / (float(X.max()) + 1e-30)
    pk, _ = find_peaks(Xn)
    pk = pk[Xn[pk] > 10.0 ** (floor_db / 20.0)]
    if pk.size == 0:
        return dict(f=np.zeros(0), gamma=np.zeros(0), a=np.zeros(0),
                    env_gamma=0.0, residual_db=0.0, peak=peak, onset=on)
    order = pk[np.argsort(-Xn[pk])]
    # keep the strongest, but merge peaks closer than `min_sep` % (one physical mode
    # can split into a doublet; keeping both is fine, keeping 3 bins of one is not)
    chosen = []
    for j in order:
        fj = freqs[j]
        if any(abs(fj - freqs[c]) < min_sep * 0.01 * fj for c in chosen):
            continue
        chosen.append(int(j))
        if len(chosen) >= n_modes:
            break
    chosen = np.asarray(sorted(chosen), int)
    f_sel = freqs[chosen]

    # --- per-mode a0 / gamma ---
    dec = max(1, int(round(sr / 2000.0)))
    a0 = np.full(f_sel.size, np.nan)
    g = np.full(f_sel.size, np.nan)
    r2 = np.full(f_sel.size, np.nan)
    for i, fk in enumerate(f_sel):
        bw = float(np.clip(0.03 * fk, 8.0, 400.0))
        env = core.partial_envelope(segn, sr, float(fk), bw)[::dec]
        fit = core.fit_decay(env, sr / dec, t0=t0, t1=t1, floor_db=-40.0,
                             late_split=None)
        a0[i] = fit["a0"]
        g[i] = fit["gamma"]
        r2[i] = fit["r2"]
    ok = np.isfinite(g) & (g > 0.1) & np.isfinite(a0) & (a0 > 0)
    f_sel, g, a0, r2 = f_sel[ok], g[ok], a0[ok], r2[ok]

    # --- broadband decay: segmented, not one straight line through everything ---
    dec = decay_diagnostics(segn, sr)
    env_gamma = dec["total_env_gamma"]   # fallback; the residual-based value below wins

    # --- residual: the part the picked modes do NOT explain ---
    # The mask has to cover each mode's actual line, not a fixed 2%: a drum's low
    # modes are only a few Hz wide but sit on a continuous skirt, and anything left
    # outside the mask lands in the "noise" band curve, which is then normalised to
    # a broad shape -- i.e. modal skirt energy gets re-emitted as broadband hiss.
    # Measured 2026-09-29: with the fixed 2% mask the kick model was 14-24 dB too
    # loud above 1 kHz on held-out takes.
    resid = Xn.copy()
    for fk, gk in zip(f_sel, g):
        hwhm = gk / (2.0 * np.pi)                     # Lorentzian half-width, Hz
        w = np.abs(freqs - fk) < max(3.0, 0.02 * fk, 4.0 * hwhm)
        resid[w] = 0.0
    total = float((Xn ** 2).sum())
    resid_sq = float((resid ** 2).sum())
    residual_db = float(10.0 * np.log10(max(resid_sq, 1e-30) / max(total, 1e-30)))

    # A noise branch has to carry the residual. Store its 1/3-octave shape and its
    # level relative to the modal peaks, both in the same (peak-normalised) units.
    edges = 100.0 * 2.0 ** (np.arange(0, 25) / 3.0)          # 100 Hz .. ~12.8 kHz
    band = np.array([float((resid[(freqs >= lo) & (freqs < hi)] ** 2).sum())
                     for lo, hi in zip(edges[:-1], edges[1:])])
    band_db = 10.0 * np.log10(band + 1e-30)
    band_db = band_db - band_db.max()

    # --- attack term: a struck cymbal's residual is not one exponential --------
    # The contact transient is broadband and over in a few ms, the wash lasts
    # seconds. With a single exponential the model has no attack: measured
    # 2026-09-29, the ride held 5% of its energy in the first 20 ms where the
    # recording holds 24% (recording crest 33 dB vs model 18 dB). Reject the
    # modal bands in the time domain and fit the residual's own envelope in two
    # windows, then store the fast term relative to the slow one.
    f2 = np.fft.rfftfreq(segn.size, 1.0 / sr)
    keep = np.ones(f2.size, bool)
    for fk, gk in zip(f_sel, g):
        keep &= np.abs(f2 - fk) >= max(3.0, 0.02 * fk, 4.0 * gk / (2.0 * np.pi))
    res = np.fft.irfft(np.fft.rfft(segn) * keep, segn.size)

    k = max(1, int(0.002 * sr))
    e_res = np.convolve(res ** 2, np.ones(k) / k, mode="same")
    t_seg = np.arange(segn.size) / sr
    fast = _exp_fit(t_seg, e_res, 0.002, 0.030)
    # The tail reference cannot be a fitted exponential: on drums and the hat the
    # residual is already at its floor by 0.15 s and the slope comes out NEGATIVE
    # (kick -2.63, hat -5.89), which silently disabled the transient. Use the tail's
    # median level and extrapolate it back to t=0 with the robust energy decay.
    tail_win = (t_seg >= 0.15) & (t_seg <= min(0.8, float(t_seg[-1])))
    tail_med = float(np.median(e_res[tail_win])) if tail_win.sum() > 32 else 0.0
    a_tail_sq = tail_med / max(np.exp(-2.0 * env_gamma * 0.45), 1e-12)
    att_amp, att_gamma = 0.0, 0.0
    # Gate: a contact transient only makes sense where the noise branch actually
    # carries energy. On a kick the residual is 0.09% of the hit, so a "transient"
    # inside it is meaningless and measured badly (kick band error 3.54 -> 8.76 dB
    # with att_amp 27x). Above 5% residual the noise branch is a real component.
    if (USE_ATTACK_TERM and residual_db > -13.0
            and fast and fast[1] > 1.0 and a_tail_sq > 0.0):
        # e_res is a SQUARED envelope, so amplitudes go as the square root.
        ratio = float(np.sqrt(max(fast[0], 0.0) / a_tail_sq))
        if ratio > 1.2:
            att_gamma = float(np.clip(fast[1], 5.0, 20_000.0))
            att_amp = float(np.clip(ratio - 1.0, 0.0, 50.0))

    # The transient gets its OWN band curve. Sharing one curve with the wash made it
    # a low-frequency thump instead of a broadband click (measured 2026-09-29: ride
    # band error 4.21 -> 6.73 dB with a shared curve, envelope fixed either way).
    att_band_db = None
    if att_amp > 0.0:
        n_att = max(128, int(0.030 * sr))
        f_a, X_a = core._spectrum(res[:n_att], sr)
        pw_a = (X_a / (X_a.max() + 1e-30)) ** 2
        band_a = np.array([float(pw_a[(f_a >= lo) & (f_a < hi)].sum())
                           for lo, hi in zip(edges[:-1], edges[1:])])
        db_a = 10.0 * np.log10(band_a + 1e-30)
        db_a = db_a - db_a.max()
        # A 30 ms window cannot resolve the low bands (advisor, 2026-09-29), so
        # below 500 Hz the transient borrows the tail's measured shape rather than
        # pretending the short window resolved it.
        centers = np.sqrt(edges[:-1] * edges[1:])
        db_a[centers < 500.0] = band_db[centers < 500.0]
        att_band_db = db_a

    # Noise decay: kept on the TOTAL signal's envelope inside a fixed 30 dB range.
    # Estimating it from the residual was tried and rejected (measured 2026-09-29):
    # the residual is already at its floor by ~0.15 s, so both the envelope slope and
    # a window energy-ratio fit collapse there -- the hat came out gamma 0.30
    # (T60 23 s) and the snare's tail went 85x over the recording. The total signal
    # still has real energy over the whole window, which is what makes T30 stable.
    residual_gamma, _ = band_decay_energy(res, sr, 60.0, sr / 2)

    # --- two-band decay ---------------------------------------------------------
    # Source: the TOTAL signal's per-band T30 fit, not the residual. Measuring the
    # split on the residual was tried first and collapses -- the residual is at its
    # floor by ~0.15 s, so both an envelope slope and a window energy-ratio fit
    # returned garbage there (snare LF -0.47, hat -0.20, tom 0.00). The total signal
    # keeps real energy across the whole window, so its per-band fits are usable
    # (snare LF 32.6 vs HF 1.8 -- the fast head / slow wires split we are after).
    # Gate: only where the noise branch carries energy (residual > 5%).
    gamma_lf = gamma_hf = 0.0
    amp_hf = 1.0
    if residual_db > -13.0:
        gl = float(dec["total_gamma_lf"])
        gh = float(dec["total_gamma_hf"])
        al = float(dec["total_amp_lf"])
        ah = float(dec["total_amp_hf"])
        if gl > 0.05 and gh > 0.05 and al > 0.0 and ah > 0.0:
            # ... and only when BOTH bands really carry energy. The hat has almost
            # nothing below 1 kHz, so its LF fit is floor-driven (2.25 instead of the
            # ~40 the hit actually decays at) and the two-band noise rang for 2.8 s
            # -- its 150-400 ms tail went 160x over the recording.
            if min(float(dec["share_lf"]), float(dec["share_hf"])) > 0.10:
                gamma_lf, gamma_hf = gl, gh
                amp_hf = float(np.clip(ah / al, 1e-3, 1e3))

    spec = dict(band_edges=edges, band_db=band_db, env_gamma=env_gamma,
                att_amp=att_amp, att_gamma=att_gamma, att_band_db=att_band_db,
                gamma_lf=gamma_lf, gamma_hf=gamma_hf, amp_hf=amp_hf)

    # --- render-domain calibration of the two branches --------------------------
    # `resid_sq/total` is a SPECTRAL energy fraction, but the renderer applies the
    # gain to a unit-RMS time signal, and the fitted modes' own energy is not the
    # energy inside the notch masks either. Assuming instead of measuring was wrong
    # by a lot (measured 2026-09-29: the rendered noise/modal ratio came out 3.4x
    # too high for kick/tom, 200x for the Salamander ride, and the model was then
    # 12-31 dB too bright above 550 Hz). So measure both branches in the render
    # domain and scale them to the measured split.
    frac = float(np.clip(resid_sq / max(total, 1e-30), 0.0, 0.999))
    n_seg = segn.size
    e_seg = float((segn ** 2).sum())
    a0 = a0 * np.sqrt(max((1.0 - frac) * e_seg, 0.0)
                      / max(modal_energy(a0, g, n_seg, sr), 1e-30))

    # Noise band curve. "residual" = zero the spectrum around every picked peak
    # and treat the rest as noise (mixes modal skirt into the noise, and everything
    # left after notching is then re-emitted across the whole band). "deficit" =
    # render the modal branch through the same windows/FFT and take the per-window
    # deficit, smoothed and clipped at zero.
    if noise_shape == "deficit":
        db_deficit, _ = render_deficit_band_db(segn, a0, g, f_sel, edges, sr)
        if db_deficit is not None:
            band_db = db_deficit
    spec["band_db"] = band_db

    # --- render-domain fit of the decays ----------------------------------------
    # The audible tail problem is modal (the resonators outlast the recording), so
    # scale the modal decay first; the noise decay stays at the T30 value (fitting
    # it alone made things worse: ride band error 4.15 -> 6.84 dB).
    modal_gamma_scale = 1.0
    if FIT_NOISE_DECAY:
        n_fit = int(FIT_LEN_S * sr)
        xf = core.load_audio(path, sr, channel)[on:on + n_fit]
        if xf.size >= n_fit and frac > 0.0:
            xf = xf / (float(np.max(np.abs(xf))) + 1e-30)
            modal_gamma_scale = fit_modal_gamma_scale(xf, a0, g, f_sel, spec, frac,
                                                      e_seg, n_seg, sr)
            if modal_gamma_scale != 1.0:
                g = g * modal_gamma_scale
                spec["band_edges"] = edges

    noise_gain = float(np.sqrt(max(frac * e_seg, 0.0)
                               / max(noise_energy(spec, n_seg, sr), 1e-30)))

    return dict(f=f_sel, gamma=g, a=a0, r2=r2, env_gamma=env_gamma,
                residual_db=residual_db, noise_gain=noise_gain,
                modal_gamma_scale=modal_gamma_scale,
                att_amp=att_amp, att_gamma=att_gamma, att_band_db=att_band_db,
                gamma_lf=gamma_lf, gamma_hf=gamma_hf, amp_hf=amp_hf,
                band_edges=edges, band_db=band_db, peak=peak, onset=on,
                **dec)


# ---------------------------------------------------------------------------
# kit assembly
# ---------------------------------------------------------------------------

def band_envelope(seg: np.ndarray, sr: int, lo: float, hi: float) -> np.ndarray:
    """Smoothed |.| envelope of a band-limited copy of seg."""
    n = seg.size
    f = np.fft.rfftfreq(n, 1.0 / sr)
    X = np.fft.rfft(seg) * ((f >= lo) & (f < hi))
    k = max(1, int(0.010 * sr))
    return np.convolve(np.abs(np.fft.irfft(X, n)), np.ones(k) / k, mode="same")


def attributable_tail_gamma(env: np.ndarray, sr: int, t_lo: float = 0.06,
                            floor_margin: float = 3.0, range_db: float = 30.0):
    """Decay of the part of the envelope that is still attributable to the hit.

    Segmented on purpose (advisor, 2026-09-29): one straight line through the whole
    envelope mixes the contact transient, the instrument's own tail and the
    room/background floor. Two further variants were measured on held-out takes and
    rejected:

      * fixed -45 dB range -- fixed the snare, broke the hat (its tail took 14x too
        much energy because the fit was dragged into the room decay);
      * two-piece breakpoint search (lowest total residual, keep the first piece) --
        best single value for the tom, but broke the kick badly (13.05 dB).
      * this fixed -30 dB range (the T30 convention) has the best held-out sum
        (38.9 vs 39.3 for the single line, 38.2 for -45, 41.2 for breakpoints).

    Returns (gamma, t_last_attributable, floor, amplitude_at_t0).
    """
    n = env.size
    if n < 64:
        return 0.0, 0.0, 0.0, 0.0
    t = np.arange(n) / sr
    k = max(1, int(0.05 * sr))
    rough = np.convolve(env, np.ones(k) / k, mode="same")
    tail = rough[int(0.6 * n):]
    floor = float(np.percentile(tail, 10)) if tail.size else 0.0
    pk = float(env.max())
    if pk <= 0:
        return 0.0, 0.0, floor, 0.0
    thr = max(floor * floor_margin, pk * 10.0 ** (-range_db / 20.0))
    m = (t >= t_lo) & (env > thr)
    if m.sum() < 32:
        return 0.0, 0.0, floor, 0.0
    slope, icpt = np.polyfit(t[m], np.log(env[m]), 1)
    return float(-slope), float(t[m][-1]), floor, float(np.exp(icpt))


#: band limits for the LF/HF split of the noise branch
BAND_LF = (60.0, 1000.0)
BAND_HF = (1000.0, 8000.0)
CROSSOVER_HZ = 1000.0


def decay_diagnostics(segn: np.ndarray, sr: int) -> dict:
    e_lf = band_envelope(segn, sr, *BAND_LF)
    e_hf = band_envelope(segn, sr, *BAND_HF)
    g_all, t_attr, floor, _ = attributable_tail_gamma(
        band_envelope(segn, sr, 60.0, sr / 2), sr)
    g_lf, _, _, a_lf = attributable_tail_gamma(e_lf, sr)
    g_hf, _, _, a_hf = attributable_tail_gamma(e_hf, sr)
    s_lf = float((e_lf ** 2).sum())
    s_hf = float((e_hf ** 2).sum())
    tot = s_lf + s_hf + 1e-30
    return dict(total_env_gamma=g_all, t_attr=t_attr, floor=floor,
                total_gamma_lf=g_lf, total_gamma_hf=g_hf,
                total_amp_lf=a_lf, total_amp_hf=a_hf,
                share_lf=s_lf / tot, share_hf=s_hf / tot,
                hf_over_lf=(g_hf / g_lf) if g_lf > 1e-9 else float("nan"))


def crossover_tilt(edges: np.ndarray, xover: float = CROSSOVER_HZ,
                   depth: float = 60.0):
    """(lf_tilt_db, hf_tilt_db): complementary smooth split at `xover`.

    Used to give the low and high halves of the noise branch their own decay
    without designing two unrelated shapes.
    """
    c = np.sqrt(edges[:-1] * edges[1:])
    u = np.clip((np.log2(np.maximum(c, 1.0)) - np.log2(xover)) / (2.0 / 3.0), -1.0, 1.0)
    s = 0.5 * (1.0 + np.tanh(2.0 * u))            # 0 below the crossover, 1 above
    return -depth * s, -depth * (1.0 - s)


def noise_filters(spec: dict, sr: int = core.SR):
    """(h_lf, h_hf, h_att) unit-RMS shaping filters; h_hf/h_att may be None.

    `h_hf` is the second half of the LF/HF split (inactive when gamma_lf/hf are 0).
    `h_att` is the contact transient, which gets its OWN band curve: sharing one
    curve made the transient a low-frequency thump instead of a broadband click
    (measured 2026-09-29: ride band error 4.21 -> 6.73 dB when shared).
    """
    edges, db = spec["band_edges"], spec["band_db"]
    gl, gh = float(spec.get("gamma_lf", 0.0)), float(spec.get("gamma_hf", 0.0))
    if gl > 0.0 and gh > 0.0:
        t_lf, t_hf = crossover_tilt(edges, float(spec.get("crossover_hz", CROSSOVER_HZ)))
        h_lf = noise_filter(edges, db + t_lf, sr=sr)
        h_hf = noise_filter(edges, db + t_hf, sr=sr)
    else:
        h_lf, h_hf = noise_filter(edges, db, sr=sr), None
    att_db = spec.get("att_band_db")
    h_att = (noise_filter(edges, att_db, sr=sr)
             if att_db is not None and float(spec.get("att_amp", 0.0)) > 0.0
             else None)
    return h_lf, h_hf, h_att


def _band_noise(rng: np.random.Generator, h: np.ndarray, n: int) -> np.ndarray:
    full = np.convolve(rng.standard_normal(n + len(h)), h, mode="full")
    return full[len(h) // 2:len(h) // 2 + n]


def noise_signal(spec: dict, n: int, sr: int, rng: np.random.Generator,
                 filters=None) -> np.ndarray:
    """The noise branch at unit gain, exactly as the renderer builds it.

    Single source of truth: the extractor measures this same function when it
    calibrates the branch, so the two can no longer drift apart.
    """
    filters = noise_filters(spec, sr) if filters is None else filters
    h_lf, h_hf, h_att = filters
    t = np.arange(n) / sr
    if h_hf is None:
        y = _band_noise(rng, h_lf, n) * np.exp(-max(float(spec["env_gamma"]), 0.5) * t)
    else:
        y = (_band_noise(rng, h_lf, n) * np.exp(-max(float(spec["gamma_lf"]), 0.05) * t)
             + float(spec.get("amp_hf", 1.0))
             * _band_noise(rng, h_hf, n) * np.exp(-max(float(spec["gamma_hf"]), 0.05) * t))
    if h_att is not None:
        y = y + (float(spec["att_amp"]) * _band_noise(rng, h_att, n)
                 * np.exp(-max(float(spec["att_gamma"]), 0.5) * t))
    return y


def band_decay_energy(x: np.ndarray, sr: int, lo: float, hi: float,
                      windows=((0.05, 0.15), (0.15, 0.30), (0.30, 0.60))):
    """Decay from band ENERGY in successive windows -- robust for noise-like signals.

    Energy over a window is ~ exp(-2 gamma t) evaluated at the window centre, so a
    log-linear fit of energy vs centre time gives slope = -2 gamma. Fitting the
    smoothed band envelope instead produced negative slopes on the residual
    (measured 2026-09-29: snare -0.47, hat -0.20, tom 0.00): a narrow-band noise
    envelope is dominated by fluctuation, not by the decay.

    Returns (gamma, energy_at_t0). 0.0 when the windows cannot be formed.
    """
    n = x.size
    f = np.fft.rfftfreq(n, 1.0 / sr)
    y = np.fft.irfft(np.fft.rfft(x) * ((f >= lo) & (f < hi)), n)
    ts, es = [], []
    for a, b in windows:
        b = min(b, n / sr)
        s = y[int(a * sr):int(b * sr)]
        if s.size < 32:
            continue
        ts.append(0.5 * (a + b))
        es.append(float((s ** 2).sum()))
    if len(ts) < 3:
        return 0.0, 0.0
    slope, icpt = np.polyfit(ts, np.log(np.array(es) + 1e-30), 1)
    return float(-slope / 2.0), float(np.exp(icpt))


#: windows for the render-domain decay fit: they must cover the whole note, since
#: the audible complaint is a tail that is 6-11x too loud on the crash.
FIT_WINDOWS = ((0.0, 0.02), (0.02, 0.05), (0.05, 0.15), (0.15, 0.40),
               (0.40, 0.80), (0.80, 1.50), (1.50, 2.50))
FIT_LEN_S = 2.5


def window_fractions(x: np.ndarray, windows, sr: int) -> np.ndarray:
    tot = float((x ** 2).sum()) + 1e-30
    return np.array([float((x[int(a * sr):min(len(x), int(b * sr))] ** 2).sum()) / tot
                     for a, b in windows])


def fit_noise_decay(x_fit: np.ndarray, modal_fit: np.ndarray, spec: dict,
                    frac: float, e_seg: float, n_seg: int, sr: int,
                    g0: float) -> float:
    """Pick the noise decay so the RENDERED windowed energy matches the recording.

    The T30 value is fitted on the TOTAL signal, which the modal decay contaminates,
    so it lands too slow and the tail is left 6-11x too loud (crash). Here gamma is
    chosen by rendering: for each candidate the gain is re-calibrated with the same
    rule used at extraction time (the gain and the decay are coupled), then the
    windowed energy fractions of the render are compared with the recording's over
    the full FIT_LEN_S. One free parameter, so a coarse grid plus a local refine is
    enough; it is validated on held-out takes like everything else.
    """
    wins = FIT_WINDOWS
    real_fr = window_fractions(x_fit, wins, sr)
    ok = real_fr > 1e-4

    def score(gamma):
        sp = dict(spec)
        sp["env_gamma"] = float(gamma)
        nz = noise_signal(sp, x_fit.size, sr, np.random.default_rng(1))
        e08 = float((nz[:n_seg] ** 2).sum())
        if e08 <= 0.0:
            return 1e9
        nz = nz * np.sqrt(max(frac * e_seg, 0.0) / e08)
        mf = window_fractions(modal_fit + nz, wins, sr)
        return float(np.sum((np.log(np.maximum(mf, 1e-12))
                             - np.log(np.maximum(real_fr, 1e-12)))[ok] ** 2))

    grid = np.exp(np.linspace(np.log(0.05), np.log(300.0), 25))
    best = min(grid, key=score)
    for _ in range(3):                       # local refine
        lo, hi = best / 1.8, best * 1.8
        cand = np.linspace(lo, hi, 9)
        best = min(cand, key=score)
    if g0 > 0.0 and score(g0) < score(best):
        best = g0
    return float(best)


def fit_modal_gamma_scale(x_fit: np.ndarray, a0: np.ndarray, g: np.ndarray,
                          f_sel: np.ndarray, spec: dict, frac: float, e_seg: float,
                          n_seg: int, sr: int) -> float:
    """Scale the modal decay so the RENDERED windowed energy matches the recording.

    The late tail turned out to be modal, not noise: the ride's fitted per-mode gamma
    is ~0.85 (T60 8 s) while the recording's broadband T60 is ~2.5 s, so no noise
    decay can fix a tail that the resonators are still holding. This is the same
    trick the A-class instruments already use (``params.gamma_scale``), applied per
    drum piece and fitted by rendering, then validated on held-out takes.
    """
    wins = FIT_WINDOWS
    real_fr = window_fractions(x_fit, wins, sr)
    ok = real_fr > 1e-4
    n = x_fit.size
    nz0 = noise_signal(spec, n, sr, np.random.default_rng(1))
    e08 = float((nz0[:n_seg] ** 2).sum())
    nz0 = nz0 * (np.sqrt(max(frac * e_seg, 0.0) / e08) if e08 > 0 else 0.0)

    def score(s):
        m = modal_signal(a0, g * s, f_sel, n, sr, np.random.default_rng(1))
        em = float((m[:n_seg] ** 2).sum())
        if em <= 0.0:
            return 1e9
        m = m * np.sqrt(max((1.0 - frac) * e_seg, 0.0) / em)
        mf = window_fractions(m + nz0, wins, sr)
        return float(np.sum((np.log(np.maximum(mf, 1e-12))
                             - np.log(np.maximum(real_fr, 1e-12)))[ok] ** 2))

    grid = np.exp(np.linspace(np.log(0.2), np.log(20.0), 13))
    best = min(grid, key=score)
    for _ in range(2):
        cand = np.linspace(best / 1.6, best * 1.6, 7)
        best = min(cand, key=score)
    return 1.0 if score(1.0) <= score(best) else float(best)


def noise_filter(band_edges: np.ndarray, band_db: np.ndarray,
                 n_taps: int = 257, sr: int = core.SR) -> np.ndarray:
    """Unit-RMS FIR whose 1/3-octave magnitude follows ``band_db`` (0 dB = peak).

    Single implementation, shared with ``modal_sim/drumkit.py``, so that the
    extractor can measure the branch it is about to hand to the renderer.

    The band curve starts at 100 Hz, so its ends are NOT extended flat to DC and
    Nyquist: a 257-tap FIR would otherwise pass sub-100 Hz energy that was never
    measured. Measured 2026-09-29: the tom model came out 41 dB too loud at 67 Hz
    because the first band's gain was carried down to DC.
    """
    from scipy.signal import firwin2
    centers = np.sqrt(band_edges[:-1] * band_edges[1:])
    f = np.concatenate([[0.0], np.clip(centers / (sr / 2.0), 0.0, 1.0), [1.0]])
    g = np.concatenate([[band_db[0] - DC_TAPER_DB], band_db,
                        [band_db[-1] - DC_TAPER_DB]])
    h = firwin2(n_taps, f, 10.0 ** (g / 20.0))
    return h / (np.sqrt((h ** 2).sum()) + 1e-30)


def modal_energy(a: np.ndarray, gamma: np.ndarray, n: int,
                 sr: int = core.SR) -> float:
    """Energy of ``sum_k a_k exp(-g_k t) sin(2 pi f_k t + phi_k)`` over n samples.

    Phase-independent: cross terms of random phases average out and ``sin^2``
    averages to 1/2, so the energy is ``sum_k a_k^2 * 1/2 * sum_n exp(-2 g_k t)``.
    """
    t = np.arange(n) / sr
    decay = (0.5 * np.exp(-2.0 * gamma[:, None] * t)).sum(axis=1)
    return float(np.sum(a ** 2 * decay))


def noise_energy(spec: dict, n: int, sr: int = core.SR, seed: int = 0) -> float:
    """Energy of the unit noise branch at length n.

    Thin wrapper around ``noise_signal`` on purpose: the extractor must measure the
    very function the renderer runs, or the calibration drifts (that mistake cost
    us a 200x error on the ride, see the note in ``analyze_hit``).
    """
    y = noise_signal(spec, n, sr, np.random.default_rng(seed))
    return float((y ** 2).sum())


def noise_envelope(t: np.ndarray, env_gamma: float,
                   att_amp: float = 0.0, att_gamma: float = 0.0) -> np.ndarray:
    env = np.exp(-max(env_gamma, 0.5) * t)
    if att_amp > 0.0 and att_gamma > 0.0:
        env = env + att_amp * np.exp(-att_gamma * t)
    return env


def _exp_fit(t: np.ndarray, e: np.ndarray, t0: float, t1: float):
    """Fit log(e) ~ a - g t over [t0, t1]; returns (amplitude at t=0, gamma)."""
    m = (t >= t0) & (t <= t1) & (e > 0)
    if m.sum() < 16:
        return None
    slope, icpt = np.polyfit(t[m], np.log(e[m]), 1)
    return float(np.exp(icpt)), float(-slope)


#: Windows used to attribute power to the two branches. The point is that the
#: modal branch's contribution is *rendered* through the same window and FFT as
#: the recording, so it carries the skirts it actually produces, instead of the
#: spectrum around each peak being zeroed and whatever is left being called noise.
NOISE_WINDOWS = ((0.0, 0.05), (0.05, 0.15), (0.15, 0.40), (0.40, 0.80))
SHAPE_SEEDS = 8


def band_power(x: np.ndarray, edges: np.ndarray, sr: int,
               t0: float = 0.0, t1: float = 0.8):
    """1/3-octave power of x over [t0, t1] using the extraction's window+FFT."""
    s = x[int(t0 * sr):min(len(x), int(t1 * sr))]
    if s.size < 64:
        return None
    z = np.abs(np.fft.rfft(s * np.hanning(s.size))) ** 2
    f = np.fft.rfftfreq(s.size, 1.0 / sr)
    return np.array([z[(f >= lo) & (f < hi)].sum() for lo, hi in zip(edges[:-1], edges[1:])])


def modal_signal(a: np.ndarray, gamma: np.ndarray, f: np.ndarray, n: int,
                 sr: int, rng: np.random.Generator) -> np.ndarray:
    """Same modal convention as the renderer, so the attribution is honest."""
    t = np.arange(n) / sr
    ph = rng.uniform(0.0, 2.0 * np.pi, size=len(a))
    y = np.zeros(n)
    for ak, gk, fk, p in zip(a, gamma, f, ph):
        y += ak * np.exp(-gk * t) * np.sin(2.0 * np.pi * fk * t + p)
    return y


def render_deficit_band_db(segn: np.ndarray, a: np.ndarray, gamma: np.ndarray,
                           f: np.ndarray, edges: np.ndarray, sr: int,
                           seeds: int = SHAPE_SEEDS):
    """Noise band curve from the RENDERED modal power left unexplained per window.

    Replaces the "zero the spectrum around every picked peak and call the rest
    noise" definition, which mixes modal skirt into the noise. Here the modal
    branch is rendered through the *same* windows and FFT as the recording, the
    per-window deficit is taken, clipped at zero (a band where the modal render
    already exceeds the recording cannot host noise) and smoothed across bands.

    Returns (band_db, per_window_deficit) or (None, None) when the windows cannot
    be formed. This is model power attribution, not a physical separation: phase
    cross terms between the branches are averaged out over `seeds`.
    """
    n = segn.size
    rng = np.random.default_rng(0)
    modal = np.mean([modal_signal(a, gamma, f, n, sr, np.random.default_rng(s))
                     for s in range(seeds)], axis=0)
    acc = np.zeros(len(edges) - 1)
    per_window = {}
    ok = False
    for t0, t1 in NOISE_WINDOWS:
        r = band_power(segn, edges, sr, t0, t1)
        m = band_power(modal, edges, sr, t0, t1)
        if r is None or m is None:
            continue
        ok = True
        d = np.maximum(r - m, 0.0)
        per_window[(t0, t1)] = d
        acc = acc + d
    if not ok or acc.sum() <= 0:
        return None, None
    # Smooth across bands (1/3-octave neighbours) so the curve cannot copy a
    # single band's noise floor into the shaping filter.
    from scipy.ndimage import gaussian_filter1d
    sm = gaussian_filter1d(acc, 0.8)
    db = 10.0 * np.log10(sm + 1e-30)
    return db - db.max(), per_window


#: The contact-transient term of the noise branch is measured but NOT enabled yet.
#: Sharing one band curve between the transient and the wash made the 0-0.8 s band
#: shape worse (measured 2026-09-29: ride 4.21 -> 6.73 dB, tom 10.5 -> 15.5) while
#: it did fix the envelope (ride crest 18 -> 26 dB, first-20 ms energy 0.2 -> 0.6 of
#: the recording's 0.24). The transient needs its own band curve, measured over the
#: first ~30 ms of the residual signal; until then leave it off.
USE_ATTACK_TERM = True

#: Render-domain fit of the noise decay (see fit_noise_decay). Off = the T30 value.
FIT_NOISE_DECAY = True

#: DC/Nyquist taper of the 1/3-octave noise curve. The curve starts at 100 Hz, so
#: its ends were originally carried flat to DC and Nyquist. Tapering them by 40 dB
#: is the physically tidy choice, but on held-out takes it measured WORSE than no
#: taper (tom 10.5 -> 15.5 dB median band error, snare 6.5 -> 7.0), so the flat
#: extension is kept and the constant left at 0 for the experiment to be repeatable.
DC_TAPER_DB = 0.0

#: GM-ish drum map. Every entry is ``dict(path=..., channel=...)``:
#:   * ``path``    -- relative to ``music_resources``
#:   * ``channel`` -- ``None`` keeps the mono mean; an integer picks ONE channel.
#:     A spaced stereo overhead pair (Salamander) has up to ~5 ms of inter-channel
#:     delay on off-centre hits, so averaging would comb-filter the spectrum and
#:     corrupt the modal fit. Only single hits are used (no rolls / rhythms).
#:
#: The two libraries are deliberately mixed:
#:   * drums (kick/snare/tom)  -- AVL Drumkits: mono, punchier attack.
#:   * cymbals (hat/ride/crash) -- Salamander Drumkit (public domain, 48 kHz/24-bit).
#:     Its tails run unfaded for 10-11 s; the AVL cymbal tails are faded out at
#:     ~2 s, which leaves the slow cymbal modes (the ones this engine struggles
#:     with) with no data to fit.
KIT = {
    "kick":  dict(path="avl-drumkits/Samples/36-Pearl22Kick-3.flac", channel=None),
    "snare": dict(path="avl-drumkits/Samples/38-PearlSnare-3.flac", channel=None),
    "tom":   dict(path="avl-drumkits/Samples/45-Pearl12Tom-3.flac", channel=None),
    "hat":   dict(path="salamanderDrumkitSamplesFixedOnsets/OH/hihatClosed_OH_F_10.wav",
                  channel=0),
    "ride":  dict(path="salamanderDrumkitSamplesFixedOnsets/OH/ride2_OH_MP_4.wav",
                  channel=0),
    "crash": dict(path="salamanderDrumkitSamplesFixedOnsets/OH/crash1_OH_FF_6.wav",
                  channel=0),
}

#: The previous orchestral (Philharmonia) map, kept so that parameter set can still
#: be rebuilt: ``KIT.update(KIT_PHIL)`` then ``build_kit()``.
KIT_PHIL = {
    "kick":  dict(path="percussion/bass drum/bass-drum__025_forte_bass-drum-mallet.mp3",
                  channel=None),
    "snare": dict(path="percussion/snare drum/snare-drum__025_forte_with-snares.mp3",
                  channel=None),
    "hat":   dict(path="percussion/clash cymbals/clash-cymbals__05_forte_damped.mp3",
                  channel=None),
    "tom":   dict(path="percussion/tom-toms/tom-toms__05_mezzo-forte_struck-singly.mp3",
                  channel=None),
    "crash": dict(path="percussion/clash cymbals/clash-cymbals__025_mezzo-forte_undamped.mp3",
                  channel=None),
    "ride":  dict(path="percussion/sizzle cymbal/sizzle-cymbal__long_mezzo-piano_sticks.mp3",
                  channel=None),
}


def source_path(key: str, root: str = MUSIC) -> str:
    return os.path.join(root, KIT[key]["path"])


def load_hit(key: str, sr: int = core.SR, root: str = MUSIC) -> np.ndarray:
    """Load one kit piece as mono float, honouring its per-piece channel choice."""
    return core.load_audio(source_path(key, root), sr, KIT[key].get("channel"))


def build_kit(root: str = MUSIC, n_modes: int = 64) -> dict:
    out = {}
    shape = os.environ.get("KIT_NOISE_SHAPE", "deficit")
    for key in KIT:
        path = source_path(key, root)
        if not os.path.exists(path):
            print(f"  ! missing {key}: {path}")
            continue
        r = analyze_hit(path, n_modes=n_modes, channel=KIT[key].get("channel"),
                        noise_shape=shape)
        out[key] = r
        print(f"  {key:6s} {os.path.basename(path):48s} modes {r['f'].size:3d} "
              f"residual {r['residual_db']:6.1f} dB  noise_gain {r['noise_gain']:.3f}  "
              f"γ {r['env_gamma']:6.2f} 模态×{r['modal_gamma_scale']:5.2f} 起振 {r['att_amp']:5.2f}× "
              f"(总信号高频/低频 {r['hf_over_lf']:4.2f})  可归因段止于 {r['t_attr']:4.2f}s  "
              f"底 {r['floor']:.2e}  shape {shape}")
    return out


def save_kit(kit: dict, path: str):
    flat = {}
    for key, r in kit.items():
        flat[f"{key}__f"] = r["f"]
        flat[f"{key}__gamma"] = r["gamma"]
        flat[f"{key}__a"] = r["a"]
        flat[f"{key}__band_db"] = r["band_db"]
        flat[f"{key}__band_edges"] = r["band_edges"]
        flat[f"{key}__att_band_db"] = (r["att_band_db"] if r.get("att_band_db") is not None
                                       else np.zeros(len(r["band_edges"]) - 1))
        # meta: [noise_gain, env_gamma, residual_db, att_amp, att_gamma,
        #        gamma_lf, gamma_hf, amp_hf]
        flat[f"{key}__meta"] = np.array([r["noise_gain"], r["env_gamma"],
                                         r["residual_db"],
                                         r.get("att_amp", 0.0),
                                         r.get("att_gamma", 0.0),
                                         r.get("gamma_lf", 0.0),
                                         r.get("gamma_hf", 0.0),
                                         r.get("amp_hf", 1.0)])
    np.savez_compressed(path, **flat)


def load_kit(path: str) -> dict:
    # NOTE: this used to silently prefer a sibling ``drums_cal.npz``. That file was
    # produced by a now-deleted closed-loop calibration, its baseline predates the
    # modal-energy fix, and it is not adopted -- so the override was a trap: an old
    # calibration would quietly shadow the table. Calibrations must be applied
    # explicitly.
    d = np.load(path)
    out = {}
    for key in {k.split("__")[0] for k in d.files}:
        g = d[f"{key}__meta"]
        out[key] = dict(f=d[f"{key}__f"], gamma=d[f"{key}__gamma"], a=d[f"{key}__a"],
                        band_db=d[f"{key}__band_db"],
                        band_edges=d[f"{key}__band_edges"],
                        att_band_db=(d[f"{key}__att_band_db"]
                                     if f"{key}__att_band_db" in d.files else None),
                        noise_gain=float(g[0]), env_gamma=float(g[1]),
                        residual_db=float(g[2]),
                        att_amp=float(g[3]) if g.size > 4 else 0.0,
                        att_gamma=float(g[4]) if g.size > 4 else 0.0,
                        gamma_lf=float(g[5]) if g.size > 7 else 0.0,
                        gamma_hf=float(g[6]) if g.size > 7 else 0.0,
                        amp_hf=float(g[7]) if g.size > 7 else 1.0)
    return out


def main(argv=None):
    paths.makedirs()
    print("building drum kit (modal decomposition + noise descriptor):")
    kit = build_kit()
    out = os.path.join(OUTDIR, "drums.npz")
    save_kit(kit, out)
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
