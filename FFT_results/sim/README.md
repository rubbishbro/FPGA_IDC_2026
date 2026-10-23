# sim — modal synthesis simulation (pure Python)

End-to-end simulation of the agreed architecture, driven by the parameters extracted in
`../`. Outputs are here; run with:

```bash
python python/modal_sim/run.py                 # pitched demos, every instrument
python python/modal_sim/run.py banjo mandolin  # or a subset
python python/modal_sim/song.py                # a real song excerpt
python python/modal_sim/drumkit.py             # drum groove (+ guitar/piano)
python python/modal_sim/drumkit.py --drums     # drums only
python python/modal_sim/roll_compare.py        # roll-vs-repeated-hit experiment
python python/modal_sim/plot_chain.py          # filter-chain figure
```

Currently wired:
* **Class A** — plucked/struck, one-shot pulse into a decaying modal bank:
  **guitar, piano, banjo, mandolin**
* **Class B** — sustained, periodic drive into the same modal bank:
  **flute, trumpet, cello** (extractor: `python/fft_analysis/sustain.py`)
* **Class C** — percussion, modal + noise: **kick, snare, hat, tom, crash, ride**

## Architecture (as specified)

```
excitation = one finite raised-cosine force pulse (tau from velocity)
modes      = N IIR resonators, f_k = k*f0*sqrt(1+B k^2), gamma_k from the table
body       = one fixed 4-biquad (8th-order) shared by all voices
polyphony  = voice pool + scheme-C "kill" (tails accelerate out, never hard-cut)
output     = sum voices -> body -> soft clip -> WAV
```

- **Excitation** is a raised-cosine pulse of length `tau` (forte ≈ 0.15 ms, piano ≈
  0.25 ms) plus a short **enveloped noise burst** (`noise_amp`, ~14 ms) modelling the
  pick/hammer transient. The burst is added on its own path (gently low-passed at
  `noise_lp_hz`) **after** the body. Each mode input is compensated by the pulse's
  spectrum at `f_k` (with a floor on the boost) so the partial amplitude equals its
  weight.
- **Modes** are direct 2-pole resonators `y = g*x - a1*y1 - a2*y2` with
  `a1 = -2 r cos(2*pi f dt)`, `a2 = r^2`, `r = exp(-gamma dt)`.
- **Mode weights** are the extracted `a_k`, shape-normalised per note, restricted to the
  **trusted** partials of `../<inst>_partials.npz` (the gates are described in
  `../report.md`: prominence, r², γ, onset amplitude, and a bound on how far `a0` was
  extrapolated). `a_k` already contain the source × string × body colouration, so they
  are used directly — the old "divide by `|Body(f_k)|`" step inflated the fast high
  partials' gains and produced a coherent onset click, and it is gone.
- **Body** is a Levy / minimum-phase rational fit of a **detrended, scaled** version of
  the averaged coloration curve. It is *not* a physical body-only response: the overall
  spectral tilt is already inside `a_k`, so this filter contributes only a mild shared
  colouration (`report.json → body_range_db`, ≈ ±2 dB here).
- **Scheme-C kill**: each sample, if active > high-water, the quietest non-killed tail
  gets `gamma *= kill_factor` (150). It rings out continuously, so no click. Released
  piano keys get a damper (`gamma *= 9`). A hard steal remains only as the final
  fallback.

## Files

| File | Contents |
|---|---|
```
sim/
  README.md, report.json        this file + body/mode/kill/synthesis metrics
  pitched/<inst>_{melody,stress}.wav + {stress,synth_vs_table}.png
  sustained/sustained_trio.{wav,json} + verify_<inst>.png
  drums/drums_{only,band}.{wav,json,png}, cymbal_compare.json + cymbal_<piece>.png,
        kit_eval.json                                          drum kit demos
  song/beyond_chorus.{wav,json,png}        a real song excerpt
  roll_compare/roll_compare.json + rollcmp_*.png             roll experiment
  crosscheck/timbre_{guitar,piano}.png, timbre_check.json, filter_chain.png
  vibrato_coeff/README.md + fig_*.png + coeff_sweep.csv   a1 vibrato-modulation
        experiment (linear approximation vs Q2.20/Q2.24 fixed point)
```

One folder per topic: each holds its own audio, figures and data. Cross-instrument
checks live in `crosscheck/`.

## Sustained instruments (Class B)

`python python/fft_analysis/sustain.py` (build `../params/<inst>_sustain.npz`) then
`python python/modal_sim/sustain_demo.py`.

Same resonators as Class A; only the excitation differs — one impulse every
`T = round(sr/f0)` samples, shaped by the player's attack/release from the extraction.
The drive gain is derived, not tuned: a mode whose frequency is a drive harmonic settles
at `gain_k / (1 - r_k^T)`, so `gain_k = w_k / A_unit(gamma_k, f_k, f0)` with `A_unit`
computed exactly from the resonator's impulse response (`steady_amp_unit`).

Verified steady-state partial error (`verify()`): **flute median 0.03 dB, max 0.22 dB**
against the extracted `a_k`, with vibrato/AM/roughness and the noise branch **switched
off** so the number measures the static drive calibration only. The earlier
"flute 0.28 / trumpet 0.02 / cello 0.02 dB" line was not valid for the modulated
default — with vibrato on, a partial is a Bessel sideband comb and a fixed-frequency
coherent sum reads only its carrier, inflating the apparent error to ~15 dB median.
That is modeller/measurement scope, not a calibration failure; it is a static
calibration bound, not an audible-fidelity verdict. `sustained/verify_*.png` are older
artifacts and are not regenerated here.

**Vibrato** — a control-rate LFO scales the drive *and every partial* by the same ratio
(so the modes stay on the drive harmonics and the calibration holds), plus a small
amplitude-vibrato term. Updated every 96 samples, not per sample.

**Breath / bow noise** — white noise shaped by a 257-tap FIR from the measured noise
band curve, gated by the voice envelope. The extraction measures the noise in a *fixed
2-8 kHz reference band* (measuring over the whole band made the number depend on how far
the harmonics reach, so a trumpet read 60 dB cleaner than a flute) and stores the
analysis-window length, since converting a spectral level to a time-domain amplitude
needs it: `sigma/A = level / (2 sqrt(3/2N))`. One global `NOISE_CAL` plus a per-voice
band choice covers the rest.

Known limits: the noise *shape* is measured between partials, so it is contaminated by
partial leakage and only gets a mild HF rolloff (-3 dB at 12 kHz) where the real breath
noise falls more; and the model has no room/reverb, so the recordings' low-frequency
rumble is absent.

**Decision (2026-10-16): noise is OFF by default** — `noise_gain = 0.0` both in the
`SustainSynth` constructor **and** in the demo `VOICE`. A no-noise render is
perceptually close, so the RTL path is omitted to save resources.
The implementation is kept (`sustain_engine.py`: `noise_gain`, `noise_db_cap`, velocity
scaling); set `noise_gain > 0` to re-enable. Recorded in `rtl/DECISIONS.md` (G6).

## Drum kit (Class C — percussion)

`python python/fft_analysis/percussion.py` (build `../params/drums.npz`) then
`python python/modal_sim/drumkit.py [--drums] [--cap SECONDS] [--tag NAME]`.

A hit is rendered as **modal + noise**:

```
modal : sum_k a_k * exp(-gamma_k t) * sin(2*pi f_k t + phi_k)
noise : white noise -> FIR shaped to the hit's residual 1/3-octave curve,
        times exp(-gamma_noise t)
```

Percussion is **not harmonic**, so the extractor finds the strongest spectral peaks
instead of a `k*f0` comb. How much the modes leave unexplained decides the split:
kick −17.9 dB, tom −12.5 dB, cowbell −33 dB (modal instruments) vs snare −8.3 dB,
crash −4.9 dB, ride −3.4 dB (noise-dominated → the noise branch carries it).

Kit: kick, snare, hat, tom, crash, ride. Each piece is peak-normalised and balanced in
`KIT_GAIN`; hit length comes from the **broadband** decay, not the slowest single mode
(sizing by `min(gamma)` made every cymbal ring 3 s and the groove a continuous wash).

Honest state: the groove is recognisable and the low modal instruments (kick/tom) are
good, but the match is coarser than the pitched instruments — a 1/3-octave comparison
against the recordings sits at ~5–20 dB median, because a modal model cannot fully
reproduce the stick/beater click or a dense cymbal's noise field.

### Cymbal comparison (`python python/modal_sim/cymbal_compare.py`)

`cymbal_{crash,hat,ride}.png` + `cymbal_compare.json` put the model next to the
recording:

| cymbal | 1/3-oct err (median/max) | spectral centroid real/model | T60 real/model |
|---|---|---|---|
| crash | 8.8 / 20.8 dB | 6744 / **9432** Hz | 0.31 / 0.32 s |
| hat | 7.3 / 13.7 dB | 5899 / **9559** Hz | 0.73 / 0.78 s |
| ride | 4.2 / 17.7 dB | 8134 / **10842** Hz | 2.49 / 2.49 s |

The **decay matches** (T60 within 0.05 s) but the model is **too bright** (centroid
+1.5…3.7 kHz) and its spectrum is a uniform noise field where the recording has a
peaked one. Cause: the noise branch is **3.7–9.2× louder than the modal part**
(`cymbal_compare` prints this). The residual estimate is to blame — it notches ±2 %
around each mode and calls the rest "noise", but on a cymbal the modes are dense and
their skirts are most of the energy, so the residual swallows the modes themselves.
The 1/3-octave band curve is also too irregular (adjacent bands jump ±20 dB) to serve
as a shaping filter. Fix direction: measure the residual on a *smoothed* spectrum or
closed-loop against the recording, and cap the noise contribution.

## Song demo: Beyond《不可一世》chorus

`python python/modal_sim/song.py` renders the chorus with every class of the engine at
once: **drums** (Class C, 256 hits: kick 1&3, snare 2&4, hats on 8ths, crash per chorus,
tom fill at the end), **rhythm guitar** (Class A, Cm–Ab–Eb–Bb–Cm–Ab–Fm–Bb–Cm, ~150 BPM,
palm-muted stabs), **lead guitar** (transcribed melody), and **piano + bass**. Kills
0/0/0 and `hard=0` on every part.

The chord progression, key and tempo are taken from two independent public chord charts
that agree (Cm, 4/4, ~150 BPM). The **melody is transcribed from public jianpu charts**
(生产队 / 刘传 arrangements, marked `1=Eb`, `6=C` = Cm tonic, `♩=150`), including the
repeated-note hook and the `#4 -> 6` cadence. Free versions of those sheets are
partial/pay-walled, so a note or two in the syllable alignment may still be off.

## Verified (measured, not assumed)

- stress: `kills=8, hard=0` (both); melody: `kills=0, hard=0`. Scheme C never hard-cuts.
- **voice-steal continuity**: swapping a1/a2 at a kill steps the voice by
  `report.json → stress.kill_jump`. It is tens of dB below the voice amplitude, so the
  steal is click-free.
- **partial fidelity**: `report.json → synthesis.partial_err_*_db` compares the synth's
  per-partial `a0` and γ against the table using the **same decay-fit estimator as the
  extraction**. A short raw window would read a fast partial's decay as a level error —
  that is what made the earlier claim unverifiable.
- **body effect**: `report.json → body_range_db` bounds what the shared body filter does
  to the mix, so "mild colouration" is a measured statement.

## Notes / limitations

- The guitar's very fast high partials (γ ≳ 30, decay ≲ 30 ms) are **excluded** by the
  extrapolation gate: their fitted `a0` is an extrapolation of a noisy tail and, left in,
  they injected a spurious ~5 kHz click (the raw recording is −52 dB there). Their attack
  energy is carried by the noise burst instead, which brings the synthesised 2.2–7 kHz
  onset to within ~±4 dB of the recording.
- Voice lifetime is physical (a low guitar/piano note rings for seconds); the pool must be
  sized for the expected tail count, not for the render length.
- Remaining difference from the recording: the mp3 has a sustained broadband wash
  (room/box) that a dry modal model does not reproduce. A light body/room noise layer or
  reverb would close that gap.
