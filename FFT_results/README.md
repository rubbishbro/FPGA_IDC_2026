# FFT_results — guitar & piano parameter extraction (P1)

Deliverable of the P1 FFT analysis: modal parameters extracted from the two sample
libraries, for the "one-shot excitation pulse → N modal resonators (IIR) → fixed body
filter" engine. **These are parameters, not audio** — no sample audio is shipped.

Source libraries (read-only, under `../`):

- **guitar** — Philharmonia Orchestra (`../guitar/*.mp3`), mono 44.1 kHz, lossy.
- **piano** — Upright Piano KW, FreePats/Zenvoid, CC0 (`../UprightPian/samples/*.flac`
  + `UprightPianoKW-20220221.sfz`), stereo 44.1 kHz, 24-bit, looped tails.

All analysis resamples to **48 kHz**, down-mixes to mono, and aligns to the note onset.

## Method (see `report.md` for the summary table)

1. **Onset** — walk back from the global short-time-RMS peak (skips lead-in hum/clicks).
2. **f0** — long-window FFT peak + parabolic interpolation (never the nominal pitch).
3. **Partials** — local spectral peaks assigned to `k·f0`, then
   `f_k = k·f0·√(1 + B·k²)` fitted for the inharmonicity `B`.
4. **Envelope** — time-domain demodulation `x·e^{-j2π f_k t}` + zero-phase low-pass;
   `|z|` is the partial envelope. `γ_k` from a log-linear fit of the (50 ms-smoothed)
   envelope; a second fit gives the piano's late (double) decay `γ2`.
5. **Body** — per-note partial amplitudes averaged over an absolute-frequency grid; a
   129-tap linear-phase FIR is fitted to the mean coloration (one filter, all keys).

Piano lower/mid notes are looped by the sampler; only the region before `loop_start`
holds real decay and is the only part used for `γ`. The loop points are scaled from the
file rate (44.1 kHz) to the analysis rate (48 kHz).

## Files

| File | Contents |
|---|---|
| `guitar_manifest.json`, `piano_manifest.json` | per-file note/midi/dynamic/variation/loop metadata |
| `guitar_partials.npz`, `piano_partials.npz` | the extracted tables (see schema below) |
| `guitar_body.npz`, `piano_body.npz` | `grid`, `mean_db`, `std_db`, `n_used`, `fir` |
| `guitar_summary.json`, `piano_summary.json` | aggregate stats |
| `report.md` | method + summary |
| `figures/<inst>_<note>_<dyn>.png` | waveform / spectrogram / spectrum+partials / envelopes |
| `figures/<inst>_body.png` | averaged coloration ±1σ |
| `figures/<inst>_gamma.png` | γ vs partial frequency |

### `*_partials.npz` schema

Flat (concatenated) arrays; `note_id` indexes the per-note arrays at the end:

| key | meaning |
|---|---|
| `note_id` | index into `f0`/`B`/`midi`/`note`/`dynamic` |
| `k` | harmonic number |
| `f_k` | measured partial frequency (Hz) |
| `amp_k` | spectral peak amplitude (analysis units) |
| `a0` | initial amplitude from the decay fit (larger = louder partial) |
| `gamma` | decay rate 1/s (amplitude `e^{-γt}`) |
| `gamma2` | late decay rate (piano double decay), NaN if not fitted |
| `r2` | goodness of the log-linear decay fit |
| `f0`, `B`, `midi`, `note`, `dynamic` | per-note scalars/labels |

## Using it in the synthesis engine

- mode frequency: `f_k` directly, or regenerate as `k·f0·√(1+B k²)` for any f0.
- mode weight: `a0` (normalise per note).
- mode damping: `γ` (use `γ2` for the late piano tail).
- body: apply `body.npz['fir']` (or refit an IIR) to the summed voices, shared by all keys.

## Caveats

- Guitar is MP3: content above ~16 kHz is unreliable, so the analysis band is 16 kHz.
  Piano is FLAC (20 kHz band).
- Piano `B` is only reported where ≥8 partials exist; high notes have too few to
  constrain inharmonicity.
- The body curve is `source × body` coloration (not deconvolved), so it is applied as a
  shared colouration rather than a physical body-only response.
- High piano notes have few partials within the band, so `N` is pitch dependent.
