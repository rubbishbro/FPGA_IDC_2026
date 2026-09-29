# FFT analysis report

Partial-tracking extraction of the guitar and piano sample libraries.

## Method

- f0 by **two-way mismatch** (TWM) of a harmonic series to the strong
  spectral peaks, searched over nominal*(1±15 %) and estimated on a
  0.2–0.9 s mid window. A single-peak pick locked onto the wrong series on
  low piano (A0 read ~2 semitones sharp) and a harmonic-sum comb did the
  same on banjo/mandolin (a semitone low, from sympathetic strings); TWM
  penalises both unexplained harmonics and unexplained peaks.
- partials assigned to the harmonic series with **unique peak ownership**
  (greedy, low k first), f_k = k f0 sqrt(1+B k^2); B from a **robust,
  amplitude-weighted** fit of the low, strong harmonics
- each partial carries a local **prominence** (peak vs neighbouring
  valley); a partial is `trusted` only when prominence > 6 dB, r² > 0.3,
  γ > 0.02 and a0 > 0
- per-partial amplitude envelope by time-domain demodulation (e^{-j2πf_k t}, zero-phase low-pass); γ from a log-linear fit of a
  50 ms-smoothed envelope (beating removed), plus a late-segment fit
  for the piano double decay
- body = per-note partial amplitudes averaged on an absolute-frequency
  axis (this is *source × string/board × room*, not a deconvolved body);
  a linear-phase FIR is fitted to the mean curve

## Summary

| instrument | notes | B (median) | modes (median) | γ@1kHz (median) | R² | band |
|---|---:|---:|---:|---:|---:|---:|
| guitar | 71 | 6.38e-06 | 48 | 2.5 | 0.976 | 16000 Hz |
| piano | 66 | 1.60e-04 | 12 | 2.1 | 0.838 | 20000 Hz |
| banjo | 74 | 1.28e-05 | 40 | 6.0 | 0.949 | 16000 Hz |
| mandolin | 39 | 1.96e-05 | 25 | 3.9 | 0.903 | 16000 Hz |

`B` is only fitted on notes with >= 8 partials (high notes have too few to constrain inharmonicity).

## Extraction quality

| instrument | partials trusted | f0 cents (median) | f0 |cents| p90 | f0 outliers |>50c| |
|---|---:|---:|---:|---|
| guitar | 1690/3005 (56 %) | +6.3 | 13.8 | none |
| piano | 1281/1366 (94 %) | -1.0 | 29.6 | B0f -60 |
| banjo | 1776/3076 (58 %) | +1.1 | 16.7 | none |
| mandolin | 795/1203 (66 %) | +3.5 | 19.5 | none |

A non-zero f0 offset is not itself a fault: acoustic instruments are
not tuned to A440, and low strings are intentionally stretched. The
outlier list is a *review* aid — a large offset means “check whether the
estimator locked onto the wrong series”, not automatically “bad note”
(the piano B0 here is genuinely ~60 cents flat).

## Files

- `<inst>_manifest.json` — per-file note/dynamic/loop metadata
- `<inst>_partials.npz` — f0, B, k, f_k, amp_k, a0, γ, γ2, R², prom_db, trusted
- `<inst>_body.npz` — averaged coloration + fitted FIR
- `figures/<inst>/` — note diagnostics and body/γ summaries

## Caveats

- guitar is MP3: analysis band limited to 16 kHz; piano is FLAC (20 kHz)
- piano lower/mid notes are looped; only the region before `loop_start`
  is used for decay, the looped sustain is a faked steady state
- the body curve is an averaged *colouration*, not a physical body-only
  response; the runtime IIR is fitted to a mild, detrended version of it
