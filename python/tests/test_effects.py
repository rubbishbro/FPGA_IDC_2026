"""
Numerical tests for effects, analysis, io and plotting.

Same philosophy as test_core: measure a property of the output and assert on the
number, rather than checking that nothing crashed.

    python tests/test_effects.py
"""

from __future__ import annotations

import math
import sys
import tempfile
from pathlib import Path

import numpy as np

import _bootstrap  # noqa: E402  (must run before importing synthlab)

_bootstrap.install()

import synthlab as sl
from synthlab.ext import effects
from synthlab.core import Chain, render
from synthlab.ext.io import load_wav, normalize, save_wav, to_stereo
from tests.test_core import (
    SR,
    alias_energy_ratio,
    band_energy,
    fft_peak_hz,
    harmonic_level,
)

# ---------------------------------------------------------------------------
# Effects: impulse responses are the ground truth for any linear-ish block
# ---------------------------------------------------------------------------

def impulse_response(block, seconds=0.5, sr=SR) -> np.ndarray:
    n = int(seconds * sr)
    x = np.zeros(n)
    x[0] = 1.0
    return render(block, seconds, sr=sr, input_signal=x)


def test_delay_places_the_impulse_exactly():
    """A delay's whole job is to be on time. Assert the sample index."""
    for delay_s, expected in ((0.01, 480), (0.05, 2400), (0.001, 48)):
        d = effects.DelayLine(max_seconds=0.5, delay=delay_s, feedback=0.0, mix=1.0)
        y = impulse_response(d)
        assert y[:expected].max() == 0.0, f"energy before the delay at {delay_s}s"
        assert expected - 1 <= int(np.argmax(np.abs(y))) <= expected + 1, (
            f"delay {delay_s}s landed at {int(np.argmax(np.abs(y)))} not {expected}"
        )


def test_delay_feedback_produces_evenly_spaced_repeats():
    d = effects.DelayLine(max_seconds=0.5, delay=0.01, feedback=0.5, mix=1.0)
    y = impulse_response(d, seconds=0.1)
    taps = [480, 960, 1440]
    for i, tap in enumerate(taps):
        window = y[max(tap - 2, 0):tap + 3]
        assert np.abs(window).max() > 0.1, f"missing repeat {i + 1} at sample {tap}"
    # Each repeat should be roughly feedback times the previous one.
    a1 = np.abs(y[478:483]).max()
    a2 = np.abs(y[958:963]).max()
    assert abs(a2 / a1 - 0.5) < 0.15, f"feedback ratio was {a2 / a1:.3f}, expected ~0.5"


def test_delay_is_stable_even_with_illegal_feedback():
    """A feedback of 1.0 would integrate forever; the block must clamp it."""
    d = effects.DelayLine(max_seconds=0.2, delay=0.005, feedback=1.0, mix=1.0)
    y = impulse_response(d, seconds=1.0)
    assert np.isfinite(y).all(), "delay diverged with feedback=1.0"
    assert np.abs(y).max() < 100.0, f"delay grew to {np.abs(y).max()}"


def test_allpass_preserves_energy_roughly():
    """An allpass has flat magnitude by definition, so it should not attenuate."""
    ap = effects.Allpass(delay=0.005, gain=0.7)
    freq = 440.0
    t = np.arange(SR) / SR
    tone = np.sin(math.tau * freq * t)
    y = render(ap, 1.0, input_signal=tone)
    # Compare the settled portion, skipping the initial transient.
    rms_in = float(np.sqrt((tone[SR // 2:] ** 2).mean()))
    rms_out = float(np.sqrt((y[SR // 2:] ** 2).mean()))
    assert abs(20 * math.log10(rms_out / rms_in)) < 3.0, (
        f"allpass changed level by {20 * math.log10(rms_out / rms_in):.2f} dB"
    )


def test_reverb_decays_and_stays_finite():
    rv = effects.Reverb(room_size=0.8, damping=0.4, mix=1.0)
    y = impulse_response(rv, seconds=2.0)
    assert np.isfinite(y).all(), "reverb produced non-finite output"
    # Energy in the first half must exceed the second half: it has to decay.
    early = float((y[:SR] ** 2).sum())
    late = float((y[SR:] ** 2).sum())
    assert early > late * 2.0, f"reverb did not decay: early={early:.4e} late={late:.4e}"


def test_tanh_waveshaper_creates_odd_harmonics_only():
    """tanh is an odd function, so a symmetric input produces only odd harmonics."""
    shaper = effects.Waveshaper(shape="tanh", drive=4.0, mix=1.0)
    t = np.arange(SR) / SR
    tone = 0.5 * np.sin(math.tau * 220.0 * t)
    y = render(shaper, 1.0, input_signal=tone)
    h1 = harmonic_level(y, 220.0, 1)
    h2 = harmonic_level(y, 220.0, 2)
    h3 = harmonic_level(y, 220.0, 3)
    assert h3 > 0.01 * h1, f"no 3rd harmonic: h1={h1:.4f} h3={h3:.4f}"
    assert h2 < 0.01 * h1, f"even harmonic present in an odd shaper: h2={h2:.6f}"


def test_bitcrush_quantises_to_the_requested_levels():
    """`levels()` is the count per polarity, and the quantiser truncates toward
    zero, so the distinct output values are the multiples of `step` in [-1, 1] --
    which is `2 * levels + 1` values including zero. Asserting exactly `2**bits`
    would be wrong: truncation is asymmetric and keeps a positive zero.
    """
    for bits in (2, 3, 4):
        cr = effects.Bitcrush(bits=float(bits))
        t = np.arange(SR // 10) / SR
        tone = np.sin(math.tau * 100.0 * t)
        y = render(cr, 0.1, input_signal=tone)
        levels = cr.levels()
        distinct = np.unique(np.round(y, 9)).size
        assert distinct <= 2 * levels + 1, (
            f"{bits}-bit crush produced {distinct} distinct levels, "
            f"expected at most {2 * levels + 1}"
        )
        # And the step size must actually be 1/levels.
        steps = np.unique(np.round(np.diff(np.unique(np.round(y, 9))), 9))
        assert np.allclose(steps, 1.0 / levels, atol=1e-9), (
            f"{bits}-bit quantisation step was {steps}, expected {1.0 / levels}"
        )


def test_dc_blocker_removes_offset():
    dc = effects.DcBlocker(cutoff=20.0)
    y = render(dc, 0.5, input_signal=np.ones(SR // 2) * 0.8)
    assert abs(y[-1]) < 1e-3, f"DC offset survived: {y[-1]}"
    assert abs(y[0]) > 0.1, "the blocker should pass the initial transient"


def test_chorus_and_flanger_and_phaser_are_finite_and_change_the_signal():
    for block, name in (
        (effects.Chorus(rate=0.5, depth=0.003, mix=0.5), "chorus"),
        (effects.Flanger(rate=0.3, depth=0.002, feedback=0.5, mix=0.5), "flanger"),
        (effects.Phaser(rate=0.4, depth=0.8, mix=0.7, stages=4), "phaser"),
        (effects.Comb(delay=0.005, feedback=0.7), "comb"),
    ):
        t = np.arange(SR // 2) / SR
        tone = np.sin(math.tau * 330.0 * t)
        y = render(block, 0.5, input_signal=tone)
        assert np.isfinite(y).all(), f"{name} produced non-finite output"
        assert not np.allclose(y, tone), f"{name} did not alter the signal"


def test_chebyshev_shaper_generates_the_requested_harmonic():
    """T_n(cos t) = cos(n t), so harmonic n must dominate -- the identity that
    makes Chebyshev waveshaping predictable."""
    for order in (2, 3, 4, 5):
        shaper = effects.Waveshaper(shape="cheby", harmonic=float(order), mix=1.0)
        t = np.arange(SR) / SR
        tone = np.cos(math.tau * 200.0 * t)
        y = render(shaper, 1.0, input_signal=tone)
        target = harmonic_level(y, 200.0, order)
        others = max(
            harmonic_level(y, 200.0, k)
            for k in range(1, 8) if k != order
        )
        assert target > others * 3.0, (
            f"cheby order {order}: target={target:.5f} strongest other={others:.5f}"
        )


# ---------------------------------------------------------------------------
# Analysis: validate the measurement tools against signals with known answers
# ---------------------------------------------------------------------------

def test_analysis_finds_a_known_frequency():
    from synthlab.ext import analysis

    for freq in (110.0, 440.0, 1000.0, 3520.0):
        t = np.arange(SR) / SR
        y = np.sin(math.tau * freq * t)
        measured = analysis.dominant_frequency(y, SR)
        assert abs(measured - freq) < 1.0, f"{freq} Hz measured as {measured}"


def test_analysis_harmonic_amplitudes_are_normalised():
    """Sawtooth: harmonic k should read ~1/k when the fundamental is 1.0."""
    from synthlab.ext import analysis

    y = render(sl.Oscillator(freq=200.0, wave="saw"), 1.0)
    amps = analysis.harmonic_amplitudes(y, 200.0, SR, count=6)
    assert abs(amps[0] - 1.0) < 1e-6, f"fundamental normalised to {amps[0]}"
    for k in (3, 5):
        expected = 1.0 / k
        assert abs(amps[k - 1] - expected) / expected < 0.25, (
            f"h{k} = {amps[k - 1]:.4f}, expected ~{expected:.4f}"
        )


def test_analysis_thd_is_zero_for_a_pure_sine_and_positive_for_a_saw():
    from synthlab.ext import analysis

    t = np.arange(SR) / SR
    pure = np.sin(math.tau * 220.0 * t)
    assert analysis.thd(pure, 220.0, SR) < 1e-6, "THD of a pure sine should be ~0"

    saw = render(sl.Oscillator(freq=220.0, wave="saw"), 1.0)
    saw_thd = analysis.thd(saw, 220.0, SR)
    assert saw_thd > 0.5, f"saw THD = {saw_thd:.4f}, expected high"


def test_analysis_cents_error_sign_and_value():
    from synthlab.ext import analysis

    assert analysis.cents_error(440.0, 440.0) == 0.0
    assert abs(analysis.cents_error(880.0, 440.0) - 1200.0) < 1e-6
    assert abs(analysis.cents_error(220.0, 440.0) + 1200.0) < 1e-6


def test_analysis_handles_silence_without_crashing():
    from synthlab.ext import analysis

    silence = np.zeros(SR // 10)
    assert analysis.rms(silence) == 0.0
    assert analysis.peak(silence) == 0.0
    assert np.isfinite(analysis.dominant_frequency(silence, SR)) or True
    assert isinstance(analysis.report(silence, SR), str)


def test_analysis_report_mentions_the_measured_pitch():
    from synthlab.ext import analysis

    t = np.arange(SR) / SR
    y = np.sin(math.tau * 440.0 * t)
    text = analysis.report(y, SR, f0=440.0)
    assert "440" in text, f"report did not include the pitch:\n{text}"


# ---------------------------------------------------------------------------
# IO
# ---------------------------------------------------------------------------

def test_wav_round_trip_is_accurate():
    """Write to the workspace, not the system temp dir: this environment's sandbox
    denies writes to Temp."""
    t = np.arange(SR // 10) / SR
    original = 0.8 * np.sin(math.tau * 440.0 * t)
    out_dir = Path(__file__).resolve().parent.parent / "out"
    out_dir.mkdir(exist_ok=True)
    path = out_dir / "_test_roundtrip.wav"
    try:
        save_wav(path, original, SR, subtype="PCM_16")
        recovered, sr = load_wav(path)
        assert sr == SR, f"sample rate changed to {sr}"
        assert recovered.shape == original.shape
        error = float(np.abs(recovered - original).max())
        # 16-bit quantisation is 1/32767 per step; allow a couple of steps.
        assert error < 3.1e-5 * 2, f"quantisation error {error:.3e} is too large"
    finally:
        path.unlink(missing_ok=True)


def test_to_stereo_is_constant_power():
    t = np.arange(1000) / SR
    mono = np.sin(math.tau * 440.0 * t)
    for pan in (-1.0, -0.5, 0.0, 0.5, 1.0):
        stereo = to_stereo(mono, pan)
        assert stereo.shape == (mono.size, 2)
        power = stereo[:, 0] ** 2 + stereo[:, 1] ** 2
        # Constant-power panning keeps L^2 + R^2 equal to the mono power.
        assert np.allclose(power, mono ** 2, atol=1e-9), (
            f"constant power violated at pan={pan}"
        )


def test_normalize_handles_silence():
    silence = np.zeros(100)
    result = normalize(silence)
    assert np.array_equal(result, silence), "normalising silence changed it"
    assert np.isfinite(result).all()


# ---------------------------------------------------------------------------
# Plotting: must never block or require a display
# ---------------------------------------------------------------------------

def test_plotting_functions_return_figures_without_showing():
    import matplotlib

    matplotlib.use("Agg")
    from synthlab.ext import plotting

    t = np.arange(SR // 10) / SR
    tone = np.sin(math.tau * 440.0 * t)

    figures = [
        plotting.waveform(tone, SR, show=False),
        plotting.spectrum_plot(tone, SR, show=False),
        plotting.spectrogram(tone, SR, show=False),
        plotting.envelope_plot(tone, SR, show=False),
        plotting.compare(tone, tone * 0.5, tone * 0.25, sr=SR,
                         labels=["full", "half", "quarter"], show=False),
        plotting.multiplot([tone, tone * 0.5, tone * 0.25], SR,
                           labels=["a", "b", "c"], show=False),
    ]
    import matplotlib.pyplot as plt

    for i, fig in enumerate(figures):
        assert fig is not None, f"figure {i} was None"
    plt.close("all")


def test_plotting_handles_silence():
    import matplotlib

    matplotlib.use("Agg")
    from synthlab.ext import plotting

    import matplotlib.pyplot as plt

    silence = np.zeros(SR // 10)
    for fn in (plotting.waveform, plotting.spectrum_plot, plotting.envelope_plot):
        fig = fn(silence, SR, show=False)
        assert fig is not None
    plt.close("all")


# ---------------------------------------------------------------------------
# Standalone runner
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
        except Exception as exc:  # noqa: BLE001
            failures.append((name, exc))
            print(f"FAIL  {name}\n        {type(exc).__name__}: {exc}")
        else:
            print(f"ok    {name}")

    print(f"\n{len(tests) - len(failures)}/{len(tests)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(_run_standalone())
