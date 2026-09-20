# SythSound

An electronic music synthesis experiment bench for Python. You write the
algorithms; this gives you the plumbing (per-sample blocks, composition,
modulation, rendering, playback, measurement) without hiding any of the maths.

The design rule is: **if you want a different sound, change the algorithm, not a
parameter.** Every generator, filter and effect is a per-sample state machine whose
coefficients and internal state are public attributes, so the usual way to add a
feature is to subclass a block and rewrite one method.

```python
from synthlab import Oscillator, MoogLadder, ADSR, Chain, Modulated, LFO, Amp, render
from synthlab.ext.io import play

osc  = Oscillator(freq=110.0, wave="saw", antialias="polyblep")
filt = MoogLadder(cutoff=1200.0, resonance=0.6, drive=1.5)
env  = ADSR(attack=0.01, decay=0.3, sustain=0.5, release=0.4, gate=1.0)
lfo  = LFO(rate=0.6, depth=600.0, unipolar=1.0)

patch = Chain(osc, Modulated(filt, lfo, "cutoff", base=900.0), Amp(env))
play(render(patch, 2.0))
```

Note `Amp(env)` rather than a bare `env`. An envelope is a *control* generator that
ignores its input, so it has to be multiplied into the signal rather than appended
to the chain. This is the single mistake that costs everyone an hour -- see the
gotchas below.

## Setup

Nothing in the library needs a compiler or a service. `numpy` and `scipy` are the
only hard dependencies.

```
pip install numpy scipy
pip install sounddevice        # only for play()/record()
pip install matplotlib         # only for synthlab.ext.plotting
pip install numba              # only for synthlab.ext.jit (optional speed)
```

### Installing in this workspace

This sandbox denies writes to the user site-packages, so `pip install` fails
outright. The wheels are fetched and unpacked into `_libs/` instead, and
`PYTHONPATH` points at it:

```powershell
python tools/fetch_wheels.py numpy sounddevice cffi numba llvmlite
python tools/unpack_wheels.py
$env:PYTHONPATH = (Resolve-Path .\_libs).Path
```

On a normal machine, ignore all of the above and just use pip or a venv.

## Layout

The library is two layers. `core` holds the abstractions and nothing else; `ext`
holds every concrete algorithm, built on core. Nothing in core imports ext, and
`synthlab/core/` works if you delete `synthlab/ext/` — there is a test that proves it
rather than a comment that claims it.

### `synthlab/core/` — abstractions

| File | What it holds |
|---|---|
| `parameter.py` | `Param` — live, introspectable parameters |
| `block.py` | `Block` (processor) and `Source` (generator), and the `eval` dispatch between them |
| `context.py` | `Context` — sample rate, sample index, seeded RNG |
| `compose.py` | `Chain`, `Parallel`, `Modulated`, `Amp` |
| `render.py` | `render`, `render_into`, `render_note` |

### `synthlab/ext/` — implementations

| File | What it holds | Kind |
|---|---|---|
| `generators.py` | Oscillator, wavetable, FM, additive, supersaw, noise, PolyBLEP | `Source` |
| `modulators.py` | ADSR, AD, LFO, ramp, sample & hold, smoothing, envelope follower | `Source` |
| `processors.py` | Biquad (RBJ), state-variable, Moog ladder, one-pole, lowpass gate | `Block` |
| `effects.py` | Delay, allpass, comb, reverb, chorus, flanger, phaser, waveshapers, bitcrush | `Block` |
| `voices.py` | `Voice`, `Polyphony`, pitch helpers | `Source` |
| `presets.py` | `patch_subtractive`, `patch_fm`, … — opinions, nothing depends on them | — |
| `analysis.py` | Spectrum, peak finding, harmonic amplitudes, THD, aliasing, reports | — |
| `io.py` | WAV save/load, playback, recording, stereo, fades | — |
| `plotting.py` | Waveform, spectrum, spectrogram, envelope, A/B comparison | — |
| `jit.py` | Optional numba fusion for hot custom loops | — |

Plus `experiments/` (runnable studies that change the algorithm at each layer) and
`tests/` (numerical assertions on measured signal properties, including the
layering tests).

Read `core/block.py` first. Everything else follows the same shape.

### Importing

```python
# Everything, via a lazy convenience surface (no matplotlib/sounddevice pulled in)
from synthlab import Oscillator, MoogLadder, ADSR, Chain, Modulated, Amp, render

# Or the layer you actually want
from synthlab.core import Block, Param, Context, render      # abstractions only
from synthlab.ext import generators, effects                 # specific DSP
from synthlab.ext.io import play                             # audio out
```

`synthlab/__init__.py` resolves implementation names on first access, so
`import synthlab.core` genuinely loads only the abstractions.

## The model in one page

**Blocks are per-sample.** `process(x, ctx) -> y` is called once per sample.
This is slower than operating on numpy buffers, but buffer-at-a-time processing
cannot express feedback, one-sample-delay state, or sample-accurate modulation,
and it hides the algebra you are trying to experiment with. Measured on this
machine, a 20-block chain renders **~5x faster than real time** through the pure
Python path, which is plenty for offline work. Reach for `synthlab.ext.jit` when a
specific block is hot.

**Parameters are live.** Declare them with `Param` and they become attributes:

```python
class MyBlock(Block):
    cutoff = Param(1000.0, "Hz", doc="corner frequency")
```

They are per-instance, introspectable (`block.describe()`), modulatable, and
typo-checked — `Oscillator(freq=100, nonsense=1)` raises.

**Modulation is routing.** `Modulated(target, source, "param", depth=..., base=...)`
writes the source's output into the target's parameter cell once per sample, so
audio-rate modulation is exact and visible in the same sample:

```python
Modulated(filt, lfo, "cutoff", base=900.0)        # filter sweep
Modulated(carrier, env, "index", depth=-8, base=8)  # FM timbre envelope
```

**Renders are reproducible.** Random blocks draw from `ctx.rng`, seeded per
render, so two algorithms can be compared on identical noise.

**State is inspectable.** Filter memory, oscillator phase, envelope levels and
delay buffers are ordinary attributes. Nothing is hidden behind a C++ object.

## Where to change the algorithm

This is the point of the library, so here is the map of extension points. Each has
a runnable version in `experiments/01_algorithm_swapping.py`.

| You want to change | Do this |
|---|---|
| The waveform | `Oscillator(wave="custom", shape=my_func)` — a `(phase, pulse_width) -> float` callable |
| The phase law (hard sync, through-zero FM) | Subclass `Oscillator` and override `tick` |
| The anti-aliasing | Subclass and override `tick`, or replace the `polyblep` call |
| The filter's coefficients | Subclass `Biquad` and override `design` (gets parameter handling and `magnitude_at` free) |
| A whole new filter topology | Subclass `Block`; expose your own state |
| The distortion curve | `shaper.shaper = lambda u, k: ...`, or `Waveshaper(shape=my_func)` |
| The envelope shape | `curve_expo(x, k)` / `curve_pow(x, k)`, or pass your own curve |
| An entire new effect | Subclass `Block` and implement `process` |
| The wavetable | `WavetableOscillator.from_harmonics/from_samples/from_spectrum`, or edit `.table` in place |

Example — a custom filter, where only the maths changes:

```python
class MyFilter(sl.Biquad):
    def design(self, cutoff, q, mode, gain_db, sr):
        # Return (b0, b1, b2, a1, a2), normalised so a0 = 1.
        ...
```

Example — a custom oscillator law:

```python
class HardSync(sl.Oscillator):
    slave_ratio = sl.Param(2.5)

    def tick(self, freq, dt):
        # tick OWNS the phase accumulator: whatever you leave in self.ph
        # is what the next sample reads.
        ...
```

## Verifying what you built

Don't trust your ears alone — every claim in the tests is a measured number.

```
python tests/test_core.py        # 43 tests
python tests/test_effects.py     # 21 tests
python tests/test_layering.py    #  6 tests (architecture: core must not need ext)
```

The analysis module is the same toolbox the tests use:

```python
from synthlab import analysis

print(analysis.report(render(patch, 2.0), sr=48000, f0=110.0))
# rms / peak / crest / dominant frequency / cents error / harmonics / THD
```

Concrete findings this workflow produced, as examples of what it catches:

- **Appending an envelope silently produces DC.** `Chain(osc, env)` looks reasonable
  and yields a click followed by silence, because an envelope ignores its input. The
  fix (`Amp`) and the guard that rejects the old form both exist because of this.
- **A parameter named `value` was shadowed** by the attribute used to record block
  output, so `Constant` returned 0 forever and every envelope-driven patch went
  quiet. It is now a construction-time error.
- **PolyBLEP sign errors are silent.** The pulse wave has two discontinuities
  needing *opposite* correction signs. With both inverted, aliasing got 2.8x
  *worse* than no correction while still sounding like a plausible square. After
  the fix: saw alias energy down **6.3x**, 50% pulse down **3.4x**.
- **Alias measurement is easy to get wrong.** "Energy not on a harmonic" counts a
  narrow pulse's genuine sinc sidelobes as aliasing, inflating the number by 70x.
  The metric in `tests/test_core.py` excludes each harmonic's own lobe; its
  docstring records where it still over-reports.
- **`LFO(unipolar=1)` did not scale with `depth`.** The mapping was
  `out * 0.5 + 0.5`, correct only at `depth == 1`; at `depth = 600` a cutoff sweep
  collapsed to a near-constant 0.5 mean. There is now a regression test that
  measures the cutoff a `Modulated` filter actually receives.
- **`Waveshaper(shape="cheby", harmonic=n)` ignored `harmonic`** and always
  produced the 2nd harmonic, so the documented "exactly one harmonic" was wrong.
- **`Oscillator.process` overwrote the phase after `tick`**, which silently made
  every custom phase law (hard sync, through-zero FM) impossible while still
  producing a plausible tone at the wrong frequency.

## Known limitations

- `analysis.dominant_frequency` returns the loudest spectral peak, which is not
  always the pitch: an amplitude envelope imposes sidebands that can outrank the
  fundamental (an enveloped 110 Hz saw measures 22.7 Hz). There is deliberately no
  `fundamental()` estimator in this package. Several were attempted
  (autocorrelation, harmonic product spectrum, peak-harmonic scoring,
  spectrum binning) and none was reliable across sustains, attack transients,
  detuned ensembles and inharmonic FM, so `analysis` reports measurements rather
  than guesses. If you need pitch tracking, use `dominant_frequency` on a sustained
  portion, or bring a dedicated library and compare it against these primitives.
- `AdditiveOscillator` sums every partial per sample, so cost grows with the
  partial count. Use `WavetableOscillator` for large harmonic sets.
- The Chamberlin SVF tuning is only accurate while `fc < ~sr/6`; it is clamped
  rather than corrected. Use `Biquad` when you need accurate tuning at high
  cutoffs, and `MoogLadder` when you want the resonance character.

## Gotchas worth knowing

- **An envelope must be applied with `Amp`, not appended.** `ADSR` and `LFO` are
  `Source` blocks: they ignore their input and emit their own contour. So
  `Chain(osc, env)` throws the oscillator away and makes the envelope's raw value
  the audio — a DC ramp, which output hardware blocks. You hear a click and then
  silence. Use `Chain(osc, Amp(env))`. `Chain.prepare` now raises a `TypeError`
  explaining this instead of staying quiet.
- **`release` vs `release()`.** `ADSR` has a `release` *parameter*, so the method
  is `note_off()`. A method of the same name would shadow the parameter.
- **`render()` resets by default.** Pass `reset=False` after manually triggering an
  envelope or building a voice with `note_on`, or the setup is discarded.
  `render_note(voice, freq, seconds)` handles that for you.
- **Stay inside a parameter's declared range.** `MoogLadder(resonance=1.5)` drives
  the ladder feedback past its stability limit and the output becomes NaN within a
  second; `Block.__init__` now warns, and the ladder clamps, but the sound you asked
  for is not the sound you get. `Param` bounds are metadata, not an automatic clamp
  (they cannot be, since modulation writes parameters at audio rate).
- **A parameter may not be called `value`.** `Block.last_output` records each
  block's output for other blocks to read, and a `Param` named `value` would be a
  data descriptor that shadows it, silently swallowing every write. `Block.__init__`
  rejects it. (`Constant`'s parameter is `level`.)
- **Cutoffs are clamped** below Nyquist. RBJ biquads go unstable at Nyquist, and
  the Chamberlin SVF tuning warps badly above ~sr/6.
- **`AdditiveOscillator` costs more than the others** because it sums `count`
  partials every sample. Keep the partial count modest, or use a wavetable.
- **Console encoding.** This shell is GBK; printing device names containing `®` or
  Chinese characters needs `$env:PYTHONIOENCODING="utf-8"`.
- **numba compiles on first call** (seconds of hitch). Call `synthlab.ext.jit.warmup()`
  before playing if the delay matters.

## Status

`synthlab/` is complete and tested for the modules listed above. The two
`experiments/` scripts are runnable studies, not part of the library's API.
