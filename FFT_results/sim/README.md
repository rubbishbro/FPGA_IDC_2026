# sim — modal synthesis simulation (pure Python)

End-to-end simulation of the agreed architecture, driven by the parameters extracted in
`../`. Outputs are here; run with:

```bash
python python/modal_sim/run.py        # ~35 s
```

## Architecture (as specified)

```
excitation = one finite raised-cosine force pulse (tau from velocity)   <- time-varying here
modes      = N IIR resonators, f_k = k*f0*sqrt(1+B k^2), gamma_k from the table
body       = one fixed 4-biquad (8th-order) shared by all voices         <- time-invariant
polyphony  = voice pool + scheme-C "kill" (tails accelerate out, never hard-cut)
output     = sum voices -> body -> soft clip -> WAV
```

- **Excitation** is a raised-cosine pulse of length `tau` (forte ≈ 0.15 ms, piano ≈
  0.25 ms) plus a short **enveloped noise burst** (`noise_amp`, ~14 ms) that models the
  pick/hammer transient; both are coloured by the shared body. Each mode input is
  compensated by the pulse's spectrum at `f_k` so the partial amplitude equals `a_k`.
- **Modes** are direct 2-pole resonators `y = g*x - a1*y1 - a2*y2` with
  `a1 = -2 r cos(2*pi f dt)`, `a2 = r^2`, `r = exp(-gamma dt)`.
- **Body** is a Levy / minimum-phase rational fit of the measured coloration
  (guitar RMSE 1.38 dB, piano 1.17 dB). Mode weights are pre-body (`a_k / |Body(f_k)|`)
  so applying the shared body reproduces `a_k` while the body stays fixed in absolute
  frequency when a note is transposed.
- **Scheme-C kill**: each sample, if active > high-water, the quietest non-killed tail
  gets `gamma *= kill_factor` (150). It rings out continuously, so no click. Released
  piano keys get a damper (`gamma *= 9`). A hard steal remains only as the final
  fallback.

## Files

| File | Contents |
|---|---|
| `guitar_melody.wav`, `piano_melody.wav` | 26-note C-major line, natural polyphony (0 kills) |
| `guitar_stress.wav`, `piano_stress.wav` | 12× same-key retrigger at 0.15 s, pool of 6 |
| `report.json` | body fit error, mode counts, kill/hard-steal counts |
| `figures/*_synth_vs_table.png` | synthesised spectrum vs extracted `a_k` |
| `figures/*_stress.png` | output / active voices / retrigger zoom |

## Verified

- stress: `kills=8, hard=0` (piano), `kills=0, hard=0` (guitar) — scheme C never
  hard-cuts; voices ramp to the high-water mark, cycle kill→free, then decay to zero.
- melody: `kills=0, hard=0` (polyphony fits the pool naturally).
- synthesised partials track the extracted `a_k` (the residual is the body-fit error).

## Notes / limitations

- The body is now fitted to a lightly-smoothed target (RMSE ≤ 0.5 dB, no spurious
  notches), and weights are shape-normalised *before* the body division, so every note
  comes out at a consistent level. (Earlier the raw Levy fit had −24/−33 dB notches and
  the weights were re-normalised after the body division, which made some notes sound
  "filtered" and very quiet.)
- Guitar damping was corrected: the extraction's 50 ms smoothing and per-partial floor
  were flattening fast decays (high γ read as ~1–2 instead of 4–8), which made the highs
  ring too long and sound piano-like. Now γ rises with frequency and matches the
  recording (A2 decay now tracks within ~1 dB).
- `N` per note follows the extraction (guitar up to 48, piano up to 48); high piano
  notes have few partials inside the band.
- Voice lifetime is physical (a low guitar/piano note rings seconds); the pool must be
  sized for the expected tail count, not for the render length. With correct damping the
  guitar stress no longer exceeds a 6-voice pool.
- Remaining difference from the recording (`guitar_orig_vs_synth.png`): the mp3 has a
  sustained broadband wash (room/box), which a dry modal model does not reproduce. A
  light body/room noise layer or reverb would close that gap.

