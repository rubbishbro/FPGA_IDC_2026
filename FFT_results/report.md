# FFT analysis report

Partial-tracking extraction of the guitar and piano sample libraries.

## Method

- exact measured f0 (FFT peak + parabolic interpolation), onset-aligned
- partials located near k*f0 with inharmonicity f_k = k f0 sqrt(1+B k^2)
- per-partial amplitude envelope by time-domain demodulation (e^{-j2πf_k t}, zero-phase low-pass); γ from a log-linear fit of a
  50 ms-smoothed envelope (beating removed), plus a late-segment fit
  for the piano double decay
- body = per-note partial amplitudes averaged on an absolute-frequency
  axis; a linear-phase FIR is fitted to the mean curve

## Summary

| instrument | notes | B (median) | modes (median) | γ@1kHz (median) | R² | band |
|---|---:|---:|---:|---:|---:|---:|
| guitar | 71 | 2.80e-07 | 48 | 2.5 | 0.977 | 16000 Hz |
| piano | 66 | 5.75e-06 | 11 | 1.9 | 0.832 | 20000 Hz |

`B` is only fitted on notes with >= 8 partials (high notes have too few to constrain inharmonicity).

## Files

- `<inst>_manifest.json` — per-file note/dynamic/loop metadata
- `<inst>_partials.npz` — f0, B, k, f_k, amp_k, a0, γ, γ2, R²
- `<inst>_body.npz` — averaged coloration + fitted FIR
- `figures/*.png` — note diagnostics and body/γ summaries

## Caveats

- guitar is MP3: analysis band limited to 16 kHz; piano is FLAC (20 kHz)
- piano lower/mid notes are looped; only the region before `loop_start`
  is used for decay, the looped sustain is a faked steady state
