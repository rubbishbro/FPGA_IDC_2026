"""
Numerical tests for the core DSP.

These are not smoke tests: each one measures a physical property of the output
(frequency, harmonic level, alias energy, filter gain, envelope timing) and
asserts on the number. If you change an algorithm, run these and see which
property moved.

    python -m pytest tests -v          # if pytest is available
    python tests/test_core.py          # standalone, no dependencies
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np

import _bootstrap  # noqa: E402  (must run before importing synthlab)

_bootstrap.install()

import synthlab as sl
from synthlab.core import Amp, Chain, Context, Modulated, Parallel, render, render_note

SR = 48_000


# ---------------------------------------------------------------------------
# Measurement helpers -- shared with the experiments, so tests and your own
# analysis use the same definitions.
# ---------------------------------------------------------------------------

def fft_peak_hz(x: np.ndarray, sr: int = SR) -> float:
    """Dominant frequency by windowed FFT with parabolic peak interpolation."""
    seg = x * np.hanning(x.size)
    spec = np.abs(np.fft.rfft(seg))
    freqs = np.fft.rfftfreq(x.size, 1 / sr)
    spec[:3] = 0
    k = int(np.argmax(spec))
    if 0 < k < spec.size - 1:
        a, b, c = spec[k - 1], spec[k], spec[k + 1]
        den = a - 2 * b + c
        delta = 0.5 * (a - c) / den if den else 0.0
    else:
        delta = 0.0
    return float(freqs[k] + delta * (freqs[1] - freqs[0]))


def band_energy(x: np.ndarray, low: float, high: float, sr: int = SR) -> float:
    """Total spectral magnitude between `low` and `high` Hz."""
    spec = np.abs(np.fft.rfft(x))
    freqs = np.fft.rfftfreq(x.size, 1 / sr)
    mask = (freqs >= low) & (freqs < high)
    return float(spec[mask].sum())


def alias_energy_ratio(
    x: np.ndarray, f0: float, sr: int = SR, lobes: float = 4.0, min_guard_hz: float = 60.0
) -> float:
    """Energy outside every harmonic's own spectral lobe, over the energy inside.

    This is the honest way to measure aliasing. A naive "energy not on a harmonic"
    metric is wrong for narrow pulses: a 25% pulse genuinely contains a lot of
    energy between its harmonics (the sinc sidelobes of each partial), and that
    energy is not aliasing.

    The lobe half-width is `max(lobes * bin_width, min_guard_hz)`, so the window
    around each harmonic contains that partial's main lobe and first sidelobes.

    Known limitation: for very narrow pulses the sidelobes spread wider than any
    fixed lobe window, so this metric will over-report aliasing there. It is
    reliable for sawtooth, ramp, triangle and 50% pulse -- which is what the tests
    assert on.
    """
    spec = np.abs(np.fft.rfft(x * np.hanning(x.size))) ** 2
    freqs = np.fft.rfftfreq(x.size, 1 / sr)
    half_width = max(lobes * (sr / x.size), min_guard_hz)

    keep = np.zeros_like(spec, dtype=bool)
    k = 1
    while k * f0 < freqs[-1]:
        keep |= np.abs(freqs - k * f0) < half_width
        k += 1

    inside = float(spec[keep].sum())
    if inside <= 0.0:
        # No harmonic energy at all (e.g. a pure sine at one bin): undefined ratio.
        return float("inf")
    return float((spec.sum() - inside) / inside)


def harmonic_level(x: np.ndarray, f0: float, k: int, sr: int = SR) -> float:
    """Magnitude at exactly k*f0, via a direct DFT (no FFT bin snapping)."""
    n = x.size
    idx = np.arange(n)
    return float(abs(np.sum(x * np.exp(-2j * np.pi * f0 * k * idx / sr))) / n * 2.0)


def cents(measured: float, target: float) -> float:
    return 1200.0 * math.log2(measured / target)


# ---------------------------------------------------------------------------
# Oscillators
# ---------------------------------------------------------------------------

def test_sine_frequency_is_exact():
    osc = sl.Oscillator(freq=440.0, wave="sine")
    y = render(osc, 1.0)
    measured = fft_peak_hz(y)
    assert abs(cents(measured, 440.0)) < 1.0, f"got {measured:.3f} Hz"


def test_sine_amplitude_and_purity():
    osc = sl.Oscillator(freq=100.0, wave="sine")
    y = render(osc, 0.5)
    # Skip the first sample (initial phase) when measuring peak.
    assert abs(np.abs(y[1:]).max() - 1.0) < 1e-9
    # A pure sine has essentially nothing at the 2nd harmonic.
    h2 = harmonic_level(y, 100.0, 2)
    assert h2 < 1e-9, f"2nd harmonic = {h2}"


def test_saw_harmonics_follow_1_over_k():
    """A sawtooth's odd harmonics sit at 1/k of the fundamental.

    Only odd harmonics are checked: a mathematically ideal saw has every harmonic,
    but the naive `2*ph - 1` ramp sampled on a discrete grid has its even harmonics
    cancel once `freq` divides the sample rate evenly, which is a property of the
    measurement grid rather than a defect worth asserting on.
    """
    osc = sl.Oscillator(freq=100.0, wave="saw")
    y = render(osc, 1.0)
    fundamental = harmonic_level(y, 100.0, 1)
    for k in (3, 5, 7):
        expected = fundamental / k
        actual = harmonic_level(y, 100.0, k)
        # FFT leakage limits how exact this can be; 25% is still a real assertion.
        assert abs(actual - expected) / expected < 0.25, f"h{k}: {actual} vs {expected}"


def test_polyblep_reduces_aliasing():
    """PolyBLEP must measurably lower the *inharmonic* energy of a saw.

    Measured as the fraction of spectral energy not sitting on a harmonic of the
    fundamental, which is exactly what aliasing is. The oscillator runs at 2003 Hz
    -- deliberately not a divisor of 48000, so folded partials cannot land on real
    harmonics and corrupt the measurement.
    """
    freq = 2003.0
    naive = render(sl.Oscillator(freq=freq, wave="saw"), 0.5)
    blep = render(sl.Oscillator(freq=freq, wave="saw", antialias="polyblep"), 0.5)

    ratio_naive = alias_energy_ratio(naive, freq)
    ratio_blep = alias_energy_ratio(blep, freq)

    assert ratio_naive > 0.0, "the naive saw produced no measurable alias energy"
    assert ratio_blep < ratio_naive * 0.5, (
        f"polyblep should at least halve the alias fraction: "
        f"naive={ratio_naive:.6f} blep={ratio_blep:.6f}"
    )


def test_polyblep_pulse_step_polarity_is_correct():
    """A 50% pulse has two discontinuities needing OPPOSITE correction signs: the
    rising step at phase 0 adds the residual, the falling step at the duty-cycle
    edge subtracts it.

    Getting either sign wrong makes aliasing notably worse than not correcting at
    all, so this test exists to catch a silently inverted correction. It is
    restricted to a 50% pulse because the alias metric above over-reports for
    narrow pulses (see its docstring).
    """
    freq = 2003.0
    for pw in (0.5,):
        naive = render(sl.Oscillator(freq=freq, wave="pulse", pulse_width=pw), 0.5)
        blep = render(
            sl.Oscillator(freq=freq, wave="pulse", pulse_width=pw, antialias="polyblep"), 0.5
        )
        ratio_naive = alias_energy_ratio(naive, freq)
        ratio_blep = alias_energy_ratio(blep, freq)
        assert ratio_blep < ratio_naive * 0.5, (
            f"pulse pw={pw}: polyblep should at least halve aliasing "
            f"(naive={ratio_naive:.6f} blep={ratio_blep:.6f}) -- check step polarity"
        )


def test_overriding_tick_actually_changes_the_phase_law():
    """`tick` must own the phase accumulator, so a subclass that overrides it can
    replace the frequency law entirely.

    This is a regression test for a real bug: `Oscillator.process` used to
    overwrite `self.ph` after calling `tick`, which silently discarded whatever the
    override had computed. Hard sync, through-zero FM and any other custom phase law
    were therefore impossible while appearing to work, because the oscillator still
    produced a plausible tone -- just at the wrong frequency.
    """

    class DoubleRate(sl.Oscillator):
        def tick(self, freq, dt):
            value = self.shape(self.ph, self.pulse_width)
            self.ph += 2.0 * freq * dt
            self.ph -= math.floor(self.ph)
            return value

    y = render(DoubleRate(freq=200.0, wave="sine"), 1.0)
    measured = fft_peak_hz(y)
    assert abs(cents(measured, 400.0)) < 5.0, (
        f"override produced {measured:.1f} Hz; expected 400 Hz (2x the parameter)"
    )

    # And the base class must still honour the plain frequency.
    base = render(sl.Oscillator(freq=200.0, wave="sine"), 1.0)
    assert abs(cents(fft_peak_hz(base), 200.0)) < 1.0


def test_hard_sync_forces_slave_to_the_master_period():
    """A hard-synced slave becomes periodic at the master frequency, so its
    partials must land on multiples of the master, not the slave."""

    class HardSync(sl.Oscillator):
        slave_ratio = sl.Param(2.5)

        def reset(self):
            super().reset()
            self.master_ph = 0.0

        def tick(self, freq, dt):
            self.master_ph += freq * dt
            synced = False
            if self.master_ph >= 1.0:
                self.master_ph -= math.floor(self.master_ph)
                synced = True
            value = self.shape(self.ph, self.pulse_width)
            self.ph += freq * self.slave_ratio * dt
            if synced:
                self.ph = 0.0
            self.ph -= math.floor(self.ph)
            return value

    master = 110.0
    y = render(HardSync(freq=master, wave="sine"), 1.0)
    # Energy must appear at 2x and 3x the master.
    h2 = harmonic_level(y, master, 2)
    h1 = harmonic_level(y, master, 1)
    assert h2 > 0.05, f"no sideband energy at the master's 2nd partial: h2={h2:.5f}"
    assert h1 > 0.05, f"master fundamental missing: h1={h1:.5f}"


def test_two_oscillators_do_not_share_state():
    a = sl.Oscillator(freq=100.0, wave="sine")
    b = sl.Oscillator(freq=100.0, wave="sine")
    render(a, 0.01)
    assert a.ph != b.ph or a.p is not b.p
    a.p["freq"] = 500.0
    assert b.p["freq"] == 100.0, "parameters leaked between instances"


def test_wavetable_from_harmonics_matches_sine():
    table = sl.WavetableOscillator.from_harmonics([1.0], size=4096)
    osc = sl.WavetableOscillator(table=table, freq=200.0)
    y = render(osc, 0.5)
    assert abs(cents(fft_peak_hz(y), 200.0)) < 2.0
    # Single-harmonic table should be close to a sine.
    assert harmonic_level(y, 200.0, 2) < 0.05


def test_additive_oscillator_rebuilds_a_square_spectrum():
    """Square = odd harmonics at 1/k. Build it explicitly and check."""
    partials = [1.0 / k if k % 2 == 1 else 0.0 for k in range(1, 16)]
    osc = sl.AdditiveOscillator(partials=partials, freq=200.0)
    y = render(osc, 1.0)
    odd = harmonic_level(y, 200.0, 3)
    even = harmonic_level(y, 200.0, 2)
    assert odd > even * 10.0, f"odd={odd} even={even} (expected even harmonics near zero)"


def test_noise_is_reproducible_from_seed():
    a = render(sl.Noise("white"), 0.05, seed=7)
    b = render(sl.Noise("white"), 0.05, seed=7)
    c = render(sl.Noise("white"), 0.05, seed=8)
    assert np.array_equal(a, b), "same seed produced different noise"
    assert not np.array_equal(a, c), "different seeds produced identical noise"


# ---------------------------------------------------------------------------
# Filters
# ---------------------------------------------------------------------------

def test_biquad_lowpass_is_minus_3db_at_cutoff():
    f = sl.Biquad(cutoff=1000.0, q=0.707, mode="lowpass")
    f.update(SR)
    assert abs(f.magnitude_at(1000.0, SR) - 0.7071) < 0.02
    assert f.magnitude_at(100.0, SR) > 0.99
    assert f.magnitude_at(10000.0, SR) < 0.01


def test_biquad_highpass_and_bandpass_magnitudes():
    hp = sl.Biquad(cutoff=1000.0, q=0.707, mode="highpass")
    hp.update(SR)
    assert hp.magnitude_at(100.0, SR) < 0.01
    assert abs(hp.magnitude_at(1000.0, SR) - 0.7071) < 0.02

    bp = sl.Biquad(cutoff=1000.0, q=0.707, mode="bandpass")
    bp.update(SR)
    # Constant-peak-gain bandpass is 0 dB at the centre.
    assert abs(bp.magnitude_at(1000.0, SR) - 1.0) < 0.02
    assert bp.magnitude_at(100.0, SR) < 0.2


def test_biquad_measured_response_matches_analytic():
    """Feed white noise through the filter and compare the measured magnitude
    response with `magnitude_at`. This validates the implementation against its
    own analytic transfer function."""
    noise = sl.Noise("white")
    filt = sl.Biquad(cutoff=2000.0, q=1.2, mode="lowpass")
    y = render(Chain(noise, filt), 4.0, seed=3)

    # Estimate magnitude at a few frequencies with a simple Goertzel-style probe
    # is noisy for noise input, so compare integrated band energies instead.
    low_band = band_energy(y, 100.0, 400.0) / 300.0
    high_band = band_energy(y, 8000.0, 12000.0) / 4000.0
    analytic_ratio = filt.magnitude_at(10000.0, SR) / filt.magnitude_at(200.0, SR)
    measured_ratio = high_band / low_band
    assert measured_ratio < analytic_ratio * 4.0, (
        f"measured rolloff {measured_ratio:.5f} not near analytic {analytic_ratio:.5f}"
    )


def test_filters_are_stable_on_dc():
    """A stable filter fed DC must converge, not diverge."""
    for block in (
        sl.Biquad(cutoff=500.0, q=5.0, mode="lowpass"),
        sl.MoogLadder(cutoff=500.0, resonance=0.95),
        sl.StateVariableFilter(cutoff=500.0, q=0.5),
    ):
        y = render(block, 1.0, input_signal=np.ones(SR))
        assert np.isfinite(y).all(), f"{type(block).__name__} produced non-finite output"
        assert abs(y[-1]) < 10.0, f"{type(block).__name__} diverged to {y[-1]}"


def test_moog_ladder_resonance_creates_a_peak():
    """Resonance must raise the level near the cutoff relative to no resonance."""
    def response(resonance: float) -> float:
        # Impulse response energy in the band around the cutoff.
        impulse = np.zeros(4096)
        impulse[0] = 1.0
        lad = sl.MoogLadder(cutoff=1000.0, resonance=resonance)
        y = render(lad, 4096 / SR, input_signal=impulse)
        return band_energy(y, 800.0, 1300.0)

    flat = response(0.0)
    resonant = response(0.9)
    assert resonant > flat * 1.5, f"resonance did not peak: flat={flat:.4f} res={resonant:.4f}"


def test_lowpass_gate_closes_at_low_level():
    """With a quiet input the LPG cutoff should shut, attenuating more than a
    plain filter would."""
    quiet = np.full(2000, 0.001)
    gate = sl.LowpassGate(cutoff=8000.0, response=0.0005, depth=1.0)
    y = render(gate, 2000 / SR, input_signal=quiet)
    assert abs(y[-1]) < abs(quiet[-1]), "LPG did not attenuate a quiet signal"


# ---------------------------------------------------------------------------
# Modulation
# ---------------------------------------------------------------------------

def test_adsr_reaches_exactly_one_then_sustains():
    """Ignore the input signal: an envelope is a generator, so trigger it via the
    gate parameter and check the segment boundaries are exact."""
    env = sl.ADSR(attack=0.01, decay=0.01, sustain=0.5, release=0.05, gate=1.0)
    y = render(env, 0.05)
    attack_samples = int(0.01 * SR)
    # Should be exactly 1.0 at the end of the attack.
    assert abs(y[attack_samples - 1] - 1.0) < 1e-6, f"attack peak = {y[attack_samples - 1]}"
    # Sustain is held at 0.5.
    assert abs(y[-1] - 0.5) < 1e-6, f"sustain = {y[-1]}"
    # The first emitted sample is already one step into the attack (the stage
    # advances before it is evaluated), so it is small but not exactly zero.
    assert y[0] < 0.01, f"attack should start near zero, got {y[0]}"
    assert np.all(np.diff(y[:attack_samples]) > 0), "attack is not monotonic"


def test_adsr_release_decays_to_zero():
    env = sl.ADSR(attack=0.001, decay=0.001, sustain=1.0, release=0.02)
    env.trigger()
    ctx = Context(sr=SR)
    env.prepare(ctx)
    for i in range(int(0.01 * SR)):
        ctx.index = i
        env.run(ctx)
    env.note_off()
    for i in range(int(0.05 * SR)):
        ctx.index = i
        value = env.run(ctx)
    assert value == 0.0, f"release did not reach zero: {value}"
    assert env.stage == sl.ADSR.IDLE


def test_adsr_gate_edge_triggers_and_releases():
    """Driving `gate` must behave like a key press, including retrigger."""
    env = sl.ADSR(attack=0.005, decay=0.005, sustain=0.8, release=0.01)
    ctx = Context(sr=SR)
    env.prepare(ctx)

    # Gate high.
    env.p["gate"] = 1.0
    for i in range(100):
        ctx.index = i
        env.run(ctx)
    assert env.stage in (sl.ADSR.ATTACK, sl.ADSR.DECAY, sl.ADSR.SUSTAIN)
    held = env.level
    assert held > 0.0

    # Gate low -> release.
    env.p["gate"] = 0.0
    for i in range(int(0.05 * SR)):
        ctx.index = i
        env.run(ctx)
    assert env.stage == sl.ADSR.IDLE
    assert env.level == 0.0


def test_lfo_frequency_and_range():
    lfo = sl.LFO(rate=10.0, wave=0)
    y = render(lfo, 1.0)
    assert abs(cents(fft_peak_hz(y), 10.0)) < 30.0, f"got {fft_peak_hz(y)}"
    assert y.max() <= 1.0 + 1e-9 and y.min() >= -1.0 - 1e-9
    # A sine LFO spends symmetric time above/below zero.
    assert abs(y.mean()) < 0.05


def test_lfo_unipolar_maps_to_0_1():
    lfo = sl.LFO(rate=10.0, unipolar=1.0)
    y = render(lfo, 0.5)
    assert y.min() >= -1e-9 and y.max() <= 1.0 + 1e-9
    assert abs(y.mean() - 0.5) < 0.05


def test_lfo_unipolar_scales_with_depth():
    """Regression test: `unipolar` must map the WAVEFORM into 0..1 and leave
    `depth` as the amplitude, so the range is 0..depth in both modes.

    The bug was `out * 0.5 + 0.5` applied to the already-scaled output, which is
    only right when depth == 1. At depth 600 it produced -299.5..300.5 (mean 0.5)
    instead of 0..600 -- a cutoff sweep that barely moved, while the min/max still
    looked plausible at a glance.
    """
    depth = 600.0
    y = render(sl.LFO(rate=1.0, depth=depth, unipolar=1.0), 2.0)
    assert y.min() > -1e-6, f"unipolar output went negative: min={y.min()}"
    assert abs(y.min()) < depth * 0.02, f"min should be near 0, got {y.min()}"
    assert abs(y.max() - depth) < depth * 0.02, f"max should be ~600, got {y.max()}"
    assert abs(y.mean() - depth / 2) < depth * 0.02, f"mean should be ~300, got {y.mean()}"

    # Bipolar stays centred on zero with the same amplitude.
    bipolar = render(sl.LFO(rate=1.0, depth=depth), 2.0)
    assert abs(bipolar.mean()) < depth * 0.02
    assert abs(bipolar.min() + depth) < depth * 0.02
    assert abs(bipolar.max() - depth) < depth * 0.02


def test_lfo_driving_cutoff_stays_centred_on_the_base():
    """`Modulated(filt, lfo, "cutoff", base=B)` must sweep centred on B for a
    bipolar LFO, and upward from B for a unipolar one.

    This is the check that would have caught the unipolar scaling bug at the level
    the user actually experiences it: a filter sweep that does not sweep.
    """
    from synthlab.core import Context, Modulated

    filt = sl.MoogLadder(cutoff=1000.0)
    lfo = sl.LFO(rate=1.0, depth=400.0)
    node = Modulated(filt, lfo, "cutoff", base=1000.0)
    ctx = Context(sr=SR)
    node.prepare(ctx)

    observed = []
    for i in range(SR):
        ctx.index = i
        node.run(0.0, ctx)
        observed.append(filt.p["cutoff"])
    observed = np.array(observed)

    assert observed.min() < 700.0, f"bipolar sweep never went low: min={observed.min()}"
    assert observed.max() > 1300.0, f"bipolar sweep never went high: max={observed.max()}"

    # Unipolar should go up from the base and never below it.
    filt2 = sl.MoogLadder(cutoff=1000.0)
    node2 = Modulated(filt2, sl.LFO(rate=1.0, depth=400.0, unipolar=1.0), "cutoff", base=1000.0)
    node2.prepare(ctx)
    observed2 = []
    for i in range(SR):
        ctx.index = i
        node2.run(0.0, ctx)
        observed2.append(filt2.p["cutoff"])
    observed2 = np.array(observed2)

    assert observed2.min() > 990.0, f"unipolar sweep dipped below base: {observed2.min()}"
    assert observed2.max() > 1300.0, f"unipolar sweep never rose: max={observed2.max()}"


def test_lfo_tempo_sync():
    """At 120 bpm, rate=1 should be exactly 2 Hz."""
    lfo = sl.LFO(rate=1.0, sync=1.0, bpm=120.0)
    y = render(lfo, 2.0)
    assert abs(cents(fft_peak_hz(y), 2.0)) < 30.0, f"got {fft_peak_hz(y)}"


def test_modulation_reaches_target_in_same_sample():
    """A modulation write must be applied to the target before it runs, in the same
    sample.

    The observable proof is the parameter's value at the moment the target is
    called, so this asserts on the parameter rather than on `target.last_output` --
    the latter is `run`'s bookkeeping and is tested separately.
    """
    target = sl.Constant(level=0.0, name="target")
    seen: list[float] = []
    original = target.process

    # Constant is a Source, so its process takes the context only.
    def spy(ctx):
        seen.append(target.p["level"])  # what the target sees when it runs
        return original(ctx)

    # Patch the INSTANCE, not the class: `run` calls `self.process`, so an instance
    # attribute takes precedence while `run`'s bookkeeping still happens.
    target.process = spy  # type: ignore[method-assign]

    mod = sl.Constant(level=0.25)
    node = Modulated(target, mod, "level", depth=1.0, base=0.0)
    ctx = Context(sr=SR)
    node.prepare(ctx)
    ctx.index = 0
    out = node.run(0.0, ctx)

    assert seen == [0.25], f"target saw {seen}, expected the modulated value 0.25"
    assert abs(out - 0.25) < 1e-12, f"modulation was not applied: {out}"


def test_envelope_appended_to_a_chain_is_rejected():
    """`Chain(osc, env)` must raise, not silently output a DC ramp.

    An envelope is a Source: it ignores its input, so appending it discards the
    oscillator and makes the envelope's own contour the audio. Hardware blocks DC,
    so the result is a click followed by silence -- with no error anywhere. This is
    the mistake that prompted the `Amp` block, so it is pinned here.
    """
    osc = sl.Oscillator(freq=560.0, wave="sine")
    env = sl.ADSR(attack=0.01, decay=0.8, sustain=0.8, release=0.3, gate=1.0)
    try:
        render(Chain(osc, env), 0.1)
    except TypeError as exc:
        assert "Amp" in str(exc), "the error should point at the fix"
    else:
        raise AssertionError("Chain(osc, env) was accepted; it must be rejected")


def test_amp_applies_an_envelope_to_the_signal():
    """`Chain(osc, Amp(env))` must gate the oscillator, not replace it."""
    env = sl.ADSR(attack=0.01, decay=0.4, sustain=0.5, release=0.3, gate=1.0)
    y = render(Chain(sl.Oscillator(freq=400.0, wave="sine"), Amp(env)), 2.0)

    assert not np.allclose(y[:100], y[0]), "output is not oscillating"
    attack_rms = float(np.sqrt((y[int(0.012 * SR):int(0.02 * SR)] ** 2).mean()))
    sustain_rms = float(np.sqrt((y[int(1.0 * SR):int(1.5 * SR)] ** 2).mean()))
    assert attack_rms > sustain_rms > 0.0, (
        f"envelope not applied: attack={attack_rms:.4f} sustain={sustain_rms:.4f}"
    )
    # 0.5 sustain on a full-scale sine gives 0.5 * 0.7071 RMS.
    assert abs(sustain_rms - 0.5 * 0.7071) < 0.05, f"sustain level was {sustain_rms:.4f}"


def test_amp_does_not_advance_its_control_twice():
    """The envelope must advance exactly once per sample.

    Running the control both in the chain loop and inside `Amp` made envelopes decay
    at double speed -- which looks like a mis-tuned envelope rather than a bug.
    """
    env = sl.ADSR(attack=0.1, decay=0.1, sustain=0.5, release=0.1, gate=1.0)
    y = render(Chain(sl.Oscillator(freq=100.0, wave="sine"), Amp(env)), 0.5)

    window = int(0.005 * SR)
    rms = np.array([
        float(np.sqrt((y[i:i + window] ** 2).mean()))
        for i in range(0, int(0.2 * SR) - window, window)
    ])
    peak_time = int(np.argmax(rms)) * 0.005
    assert 0.08 < peak_time < 0.13, (
        f"envelope peaked at {peak_time:.3f}s; expected ~0.1s "
        f"(double-advancing would put it near 0.05s)"
    )


def test_parameter_named_value_is_rejected():
    """A parameter called `value` is shadowed by `Block.last_output`.

    `Param` is a data descriptor, so it wins over the instance attribute and
    swallows every write: the block then returns 0 forever with no error. That
    silently broke `Constant`, and everything reading its output went quiet.
    """
    class Bad(sl.Source):
        value = sl.Param(1.0)

        def process(self, x=0.0, ctx=None):
            return self.value

    try:
        Bad()
    except TypeError as exc:
        assert "value" in str(exc) and "collides" in str(exc), str(exc)
    else:
        raise AssertionError("a parameter named 'value' was accepted")


def test_parallel_reset_keeps_its_blocks():
    """`Block.__init__` calls `reset()` before subclass attributes exist, and a
    naive `reset` then overwrites `blocks` with an empty list, so the combinator
    silently outputs nothing."""
    p = Parallel(sl.Constant(level=1.0), sl.Constant(level=3.0), op="sum")
    assert len(p.blocks) == 2, f"blocks were lost: {p.blocks}"
    y = render(p, 0.01)
    assert abs(y[0] - 4.0) < 1e-12


def test_control_blocks_record_their_output_in_value():
    """`run` must record the output of any block, including one that overrides
    `process` (every oscillator and envelope does).

    This is the contract `Amp` and `Modulated` rely on to read another block's
    signal. It broke once by going unmaintained, and a downstream `Amp` then read a
    permanent zero -- producing silence with no error anywhere.
    """
    osc = sl.Oscillator(freq=440.0, wave="sine")
    ctx = Context(sr=SR)
    osc.prepare(ctx)

    assert osc.last_output == 0.0

    ctx.index = 0
    out = osc.run(ctx)
    assert osc.last_output == out, "run did not record the oscillator's output"
    assert osc._sampled_index == 0

    ctx.index = 1
    out1 = osc.run(ctx)
    assert osc.last_output == out1 and out1 != out

    # And a plain block driven by a helper gets the same treatment.
    env = sl.ADSR(attack=0.01, decay=0.1, sustain=0.5, release=0.1, gate=1.0)
    env.prepare(ctx)
    ctx.index = 0
    level = env.run(ctx)
    assert env.last_output == level
    assert level > 0.0, "envelope did not start its attack"


def test_smoothed_converges_without_overshoot():
    sm = sl.Smoothed(time=0.01)
    y = render(sm, 0.2, input_signal=np.ones(int(0.2 * SR)))
    assert y[0] == 1.0, "smoothed block should prime to the first input value"
    # Step from 0 to 1 on the second sample and check no overshoot.
    sm2 = sl.Smoothed(time=0.01)
    step = np.zeros(int(0.1 * SR))
    step[0] = 0.0
    step[1:] = 1.0
    y2 = render(sm2, 0.1, input_signal=step)
    assert y2.max() <= 1.0 + 1e-12, f"overshoot: {y2.max()}"
    assert y2[-1] > 0.99, f"did not converge: {y2[-1]}"


def test_ramp_reaches_end():
    ramp = sl.Ramp(gate=1.0, start=0.0, end=2.0, time=0.1)
    y = render(ramp, 0.2)
    assert abs(y[-1] - 2.0) < 1e-6, f"ramp ended at {y[-1]}"


# ---------------------------------------------------------------------------
# Composition and engine behaviour
# ---------------------------------------------------------------------------

def test_chain_order_matters_and_is_respected():
    a = sl.Biquad(cutoff=200.0, q=0.7, mode="lowpass")
    b = sl.Biquad(cutoff=200.0, q=0.7, mode="lowpass")
    # Two identical lowpasses in series = 4th order, so twice the dB rolloff.
    single = render(Chain(a), 0.2, input_signal=np.ones(9600))
    double = render(Chain(b, sl.Biquad(cutoff=200.0, q=0.7, mode="lowpass")), 0.2,
                    input_signal=np.ones(9600))
    # DC gain is 1 for both; use a high-frequency tone instead.
    t = np.arange(9600) / SR
    tone = np.sin(2 * np.pi * 4000.0 * t)
    one = render(Chain(sl.Biquad(cutoff=200.0, q=0.7, mode="lowpass")), 0.2, input_signal=tone)
    two = render(
        Chain(sl.Biquad(cutoff=200.0, q=0.7, mode="lowpass"),
              sl.Biquad(cutoff=200.0, q=0.7, mode="lowpass")),
        0.2, input_signal=tone,
    )
    assert np.abs(two).max() < np.abs(one).max(), "cascading did not attenuate more"


def test_parallel_sum_and_mean():
    one = sl.Constant(level=1.0)
    two = sl.Constant(level=3.0)
    summed = render(Parallel(one, two, op="sum"), 0.01)
    mean = render(Parallel(sl.Constant(level=1.0), sl.Constant(level=3.0), op="mean"), 0.01)
    assert abs(summed[0] - 4.0) < 1e-12
    assert abs(mean[0] - 2.0) < 1e-12


def test_render_is_reproducible():
    def build():
        return Chain(sl.Noise("pink"), sl.Biquad(cutoff=1000.0, q=0.9, mode="lowpass"))

    a = render(build(), 0.1, seed=42)
    b = render(build(), 0.1, seed=42)
    assert np.array_equal(a, b), "renders are not deterministic"


def test_reset_allows_identical_rerender():
    osc = sl.Oscillator(freq=440.0, wave="saw", antialias="polyblep")
    filt = sl.MoogLadder(cutoff=1500.0, resonance=0.6)
    chain = Chain(osc, filt)
    first = render(chain, 0.1)
    second = render(chain, 0.1)
    assert np.allclose(first, second, atol=0.0), "reset did not restore initial state"


def test_block_state_is_isolated_between_instances():
    f1 = sl.Biquad(cutoff=1000.0, mode="lowpass")
    f2 = sl.Biquad(cutoff=1000.0, mode="lowpass")
    render(f1, 0.01, input_signal=np.ones(480))
    assert f1.y1 != f2.y1, "filter state leaked between instances"


def test_unknown_parameter_is_rejected():
    try:
        sl.Oscillator(freq=100.0, nonsense=1.0)
    except TypeError as exc:
        assert "nonsense" in str(exc)
    else:
        raise AssertionError("a typo in a parameter name was silently accepted")


def test_voice_note_on_off_lifecycle():
    voice = sl.patch_subtractive(220.0)
    y = render_note(voice, 220.0, 1.0, hold=0.4)
    assert np.isfinite(y).all()
    assert np.abs(y).max() > 0.1, "voice produced no sound"
    onset = np.argmax(np.abs(y) > 0.01)
    assert onset < int(0.05 * SR), f"note started late at sample {onset}"
    # After the release the voice must be silent.
    assert abs(y[-1]) < 1e-6, f"voice still sounding at the end: {y[-1]}"


def test_polyphony_allocates_distinct_voices():
    poly = sl.Polyphony(voices=4, factory=lambda: sl.patch_subtractive(220.0))
    poly.note_on(60)
    poly.note_on(64)
    assert len(poly.note_voice) == 2, poly.note_voice
    assert poly.note_voice[60] != poly.note_voice[64]
    y = render(poly, 0.2, reset=False)
    assert np.abs(y).max() > 0.1
    poly.note_off(60)
    assert 60 not in poly.note_voice


def test_note_name_to_frequency():
    assert abs(sl.note_to_hz("A4") - 440.0) < 1e-9
    assert abs(sl.note_to_hz("A3") - 220.0) < 1e-9
    assert abs(sl.note_to_hz("C4") - 261.6255653) < 1e-6
    assert abs(sl.note_to_hz("C#4") - 277.182631) < 1e-5
    assert abs(sl.note_to_hz("Bb3") - 233.081881) < 1e-5


# ---------------------------------------------------------------------------
# Standalone runner (no pytest required)
# ---------------------------------------------------------------------------

def _run_standalone() -> int:
    tests = [
        (name, obj)
        for name, obj in sorted(globals().items())
        if name.startswith("test_") and callable(obj)
    ]
    failures = []
    for name, fn in tests:
        try:
            fn()
        except Exception as exc:  # noqa: BLE001 - report and continue
            failures.append((name, exc))
            print(f"FAIL  {name}\n        {type(exc).__name__}: {exc}")
        else:
            print(f"ok    {name}")

    print(f"\n{len(tests) - len(failures)}/{len(tests)} passed")
    if failures:
        print("\nfailures:")
        for name, exc in failures:
            print(f"  {name}: {exc}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(_run_standalone())
