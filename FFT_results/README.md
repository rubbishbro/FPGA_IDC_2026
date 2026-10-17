# FFT_results — instrument parameter extraction

Modal parameters extracted from the sample libraries, for the "one-shot excitation
pulse → N modal resonators (IIR) → fixed body filter" engine. **These are parameters,
not audio** — no sample audio is shipped.

Source libraries (read-only, under `../`):

- **guitar / banjo / mandolin** — Philharmonia Orchestra (`../<inst>/*.mp3`), 44.1 kHz,
  lossy. Only the `normal` articulation is used (tremolo etc. are separate performances).
- **piano** — Upright Piano KW, FreePats/Zenvoid, CC0 (`../UprightPian/samples/*.flac`
  + `UprightPianoKW-20220221.sfz`), stereo 44.1 kHz, 24-bit, looped tails.

The instrument list and per-instrument settings live in `python/instruments.py`; every
output path lives in `python/paths.py`.

## Layout

```
FFT_results/
  README.md, report.md          overview + extraction summary (all instruments)
  params/                       extracted tables the engine loads
      <inst>_partials.npz, <inst>_body.npz, <inst>_manifest.json,
      <inst>_summary.json, drums.npz
  figures/<inst>/               extraction diagnostics per instrument
      body.png, gamma.png, <note>_<dyn>.png
  sim/                          synthesis deliverables (see sim/README.md)
      pitched/  sustained/  drums/  song/  roll_compare/  crosscheck/
```

All analysis resamples to **48 kHz**, down-mixes to mono, and aligns to the note onset.

## Method (see `report.md` for the summary table)

1. **Onset** — walk back from the global short-time-RMS peak (skips lead-in hum/clicks).
2. **f0** — **two-way mismatch** (TWM) of a harmonic series to the strong spectral
   peaks, searched over `nominal·(1±15 %)`, estimated on a 0.2–0.9 s mid window (skips
   the broadband attack and avoids tail components such as sympathetic strings). A
   single-peak pick locked onto the wrong series on low piano (A0 read ~2 semitones
   sharp); a harmonic-sum comb did the same on banjo/mandolin (a semitone low).
3. **Partials** — local spectral peaks assigned to `k·f0` with **unique peak ownership**
   (greedy, low k first), then `f_k = k·f0·√(1 + B·k²)` with `B` from a **robust,
   amplitude-weighted** fit of the low, strong harmonics.
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
| `params/<inst>_manifest.json` | per-file note/midi/dynamic/variation/loop metadata |
| `params/<inst>_partials.npz` | the extracted tables (see schema below) |
| `params/<inst>_body.npz` | `grid`, `mean_db`, `std_db`, `n_used`, `fir` |
| `params/<inst>_summary.json` | aggregate stats + extraction quality |
| `params/drums.npz` | percussion kit (per-hit modes + noise descriptor) |
| `figures/<inst>/` | note diagnostics, body and γ summaries |
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
| `prom_db` | local peak prominence (peak vs neighbouring valley), dB |
| `extrap` | how many e-folds `a0` was extrapolated past the envelope peak |
| `trusted` | bool: prominence > 6 dB, r² > 0.3, γ > 0.02, onset amplitude within −60 dB of the strongest, and `extrap <= 1.5` |
| `f0`, `B`, `midi`, `note`, `dynamic` | per-note scalars/labels |

## Using it in the synthesis engine

- mode frequency: `f_k` directly, or regenerate as `k·f0·√(1+B k²)` for any f0.
- mode weight: `a0` (normalise per note), **gated on `trusted`**.
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
- A partial whose fitted `a0` had to be extrapolated more than 1.5 e-folds past its
  envelope peak is marked untrusted: for very fast partials `a0` is a fit on the noisy
  tail and can be tens of dB too large.
