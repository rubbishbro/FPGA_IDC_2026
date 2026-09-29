# FPGA_IDC_2026 — modal-synthesis audio engine for a Gowin FPGA

Real-time audio synthesis on a **Tang Mega 138K** (Gowin), for the IDC competition.
The engine is **modal synthesis**: an excitation is fed into N decaying resonators
(IIR), a shared body filter colours them, and voices are summed. Sample libraries
are used **offline only** — parameters are extracted from them and the board plays
parameters, never audio.

Three instrument classes:

| Class | Excitation | Instruments |
|---|---|---|
| **A** plucked / struck | one finite force pulse | guitar, piano, banjo, mandolin |
| **B** sustained | periodic impulse train | flute, trumpet, cello (violin/oboe extracted too) |
| **C** percussion | pulse + shaped noise | kick, snare, tom, hat, ride, crash |

## Pipeline

```
music_resources/            read-only sample libraries (see its folders)
        │  extract
        ▼
python/fft_analysis/        f0 / partials / damping / sustain / percussion extractors
        │  write
        ▼
FFT_results/params/*.npz    the parameter tables the engine loads
        │  load
        ▼
python/modal_sim/           pure-Python engine + verification + demos
        │  write
        ▼
FFT_results/sim/            audio, figures and metrics per topic
```

## Layout

```
python/                     the FPGA audio pipeline
  paths.py                  SINGLE SOURCE OF TRUTH for every output path
  instruments.py            instrument registry (source / model / band / mode count)
  requirements.txt          numpy, scipy, matplotlib, soundfile
  fft_analysis/             extraction:  core.py, run.py, sustain.py, percussion.py
  modal_sim/                synthesis:   engine.py, sustain_engine.py, drumkit.py,
                            params.py, song.py, kit_eval.py, cymbal_compare.py ...
  MATH.md                   the maths behind the engine (string model, exact update)

legacy_sythsound/           a SEPARATE, earlier project (general modular-synth
                            library): synthlab/ + its own tests/ experiments/ tools/
                            and README. Shares nothing with the pipeline above.

FFT_results/
  README.md report.md       extraction overview + summary table
  params/                   extracted tables (the engine's input)
  figures/<inst>/           extraction diagnostics
  sim/<topic>/              one folder per topic, each with its own audio+figures+data
                            pitched/ sustained/ drums/ song/ roll_compare/ crosscheck/

music_resources/            sample libraries (read-only): Philharmonia Orchestra for
                            the pitched instruments, AVL Drumkits for kick/snare/tom,
                            Salamander Drumkit (public domain) for the cymbals

reference_agent_readfirst/  board + competition docs (start at fpga_platform.md)
rtl/                        SystemVerilog implementation — see rtl/README.md for the
                            working agreement and the staged roadmap
top.sv                      FPGA scratch (matrix keyboard scanner), not the engine
```

> The earlier MATLAB verification of the engine architecture (`schemeA/B/C`,
> `single_voice.m`, `docs/synth_engine.md`) was removed from the working tree in
> commit `3a4d9f1`; it is still in git history if it is ever needed again.

## Running

```bash
# extraction
python python/fft_analysis/run.py                # pitched instruments
python python/fft_analysis/sustain.py            # sustained instruments
python python/fft_analysis/percussion.py         # drum kit  -> params/drums.npz

# synthesis / verification
python python/modal_sim/run.py                   # pitched demos + comparison figures
python python/modal_sim/drumkit.py               # drum groove (+ guitar/piano)
python python/modal_sim/kit_eval.py              # drum held-out verification
python python/modal_sim/song.py                  # a real song excerpt
python python/modal_sim/sustain_demo.py          # Class B
```

Every path is derived from `python/paths.py`; nothing writes outside `FFT_results/`.

## Where to read more

* `reference_agent_readfirst/fpga_platform.md` — board, clocking, I2S, current
  word-width conventions.
* `python/MATH.md` — string model and the exact piecewise-constant update used for
  Class B / time-varying string length.
* `FFT_results/report.md` — extraction summary across instruments.
* `FFT_results/sim/README.md` — what each simulation deliverable is and how it was
  verified.
