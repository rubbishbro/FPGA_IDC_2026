"""
Swapping the algorithm at every layer.

This is the point of synthlab: each experiment below replaces one *algorithmic*
layer rather than turning a knob. Read it as a menu of extension points.

Run:
    python experiments/01_algorithm_swapping.py

Everything prints measurements. The optional plots need matplotlib and are
skipped quietly if `synthlab.plotting` is unavailable.
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import synthlab as sl
from synthlab.core import Block, Chain, Modulated, Parallel, Source, render

SR = 48_000


def banner(text: str) -> None:
    print("\n" + "=" * 72)
    print(text)
    print("=" * 72)


def show(label: str, value) -> None:
    if isinstance(value, float):
        print(f"  {label:<44} {value:>14.6f}")
    else:
        print(f"  {label:<44} {value:>14}")


def try_plot(fn, *args, **kwargs):
    """Plot if the plotting module and matplotlib are available; never fail the run."""
    try:
        from synthlab import plotting
    except Exception:
        print("  (plotting unavailable -- skipping figure)")
        return None
    try:
        return fn(*args, **kwargs)
    except Exception as exc:
        print(f"  (plot failed: {type(exc).__name__}: {exc})")
        return None


# ---------------------------------------------------------------------------
# 1. Replace the waveform function, keep the oscillator
# ---------------------------------------------------------------------------

def experiment_custom_waveform() -> np.ndarray:
    """Inject a `shape` callable. The phase accumulator, tuning, anti-aliasing and
    modulation all stay the library's; only the waveform maths is yours.

    Waveforms are written in terms of phase 0..1 with no knowledge of time or
    frequency, which is what makes them interchangeable.
    """
    banner("1. Custom waveform formulas (phase -> amplitude)")

    def skewed_sine(ph):
        """A sine whose peak is dragged toward the start or end of the cycle.

        This is the basis of 'phase distortion' synthesis: instead of filtering a
        waveform, you reshape the time axis. With `k` near 1 it approaches a saw.
        """
        k = 0.75
        warped = ph ** k
        return math.sin(math.tau * warped)

    def staircase(ph):
        """Quantised phase -- a bit-crushed oscillator, 4 steps per cycle."""
        steps = 4
        return 2.0 * (math.floor(ph * steps) / (steps - 1.0)) - 1.0

    def folded_sine(ph):
        """Clamp a scaled sine. Overflowing is flattened against the rails rather
        than reflected, which keeps the curve continuous and cheap, and adds
        odd harmonics without the broadband click of a true hard clip."""
        return max(-1.0, min(1.0, 2.2 * math.sin(math.tau * ph)))

    freq = 220.0
    for label, fn in (("skewed_sine (phase distortion)", skewed_sine),
                      ("staircase (4 steps)", staircase),
                      ("folded_sine", folded_sine)):
        osc = sl.Oscillator(freq=freq, shape=fn)
        y = render(osc, 0.25)

        # Count the harmonics that differ from a plain sine. Normalise by the
        # LARGEST partial, not by the fundamental: a waveform whose fundamental is
        # weak (a clamped or folded curve can be) would otherwise show ratios in
        # the billions and tell you nothing.
        idx = np.arange(y.size)
        partials = np.array([
            abs(np.sum(y * np.exp(-2j * np.pi * freq * k * idx / SR))) for k in range(1, 8)
        ])
        peak = partials.max() if partials.max() else 1.0
        partials = partials / peak
        strengths = ", ".join(f"{p:.2f}" for p in partials[1:6])
        print(f"  {label:<34} harmonics 2-6: {strengths}")

    # Keep one for the caller to listen to.
    return render(sl.Oscillator(freq=freq, shape=skewed_sine), 1.0)


# ---------------------------------------------------------------------------
# 2. Replace the filter's coefficient maths
# ---------------------------------------------------------------------------

def experiment_custom_filter() -> np.ndarray:
    """Write your own coefficients and hand them to `Biquad`.

    `Biquad` applies the five coefficients and nothing else, so a different filter
    is a different coefficient function -- not a subclass. Design first, then
    construct: the numbers are available to inspect, plot or edit before any audio
    runs.
    """
    banner("2. Custom filter coefficient maths")

    def butterworth3_lowpass(cutoff: float, sr: float):
        """3-pole Butterworth: a first-order section plus a biquad.

        A 3rd-order Butterworth is not a single biquad, so this pair of coefficient
        sets has to be cascaded by hand.
        """
        w0 = math.tau * min(max(cutoff, 1.0), sr * 0.45) / sr
        cw, sw = math.cos(w0), math.sin(w0)
        alpha = sw / 2.0                      # Q = 1 for this section
        b0 = (1.0 - cw) / 2.0
        a0 = 1.0 + alpha
        biquad = (b0 / a0, (1.0 - cw) / a0, b0 / a0, -2.0 * cw / a0, (1.0 - alpha) / a0)
        first_order = (1.0 - math.exp(-math.tau * cutoff / sr),)
        return biquad, first_order

    class Cascade(sl.Biquad):
        """A biquad with one first-order pole in front of it.

        Subclassing is still how you add *state*; the coefficients come from the
        function above rather than from a `design` hook.
        """

        def __init__(self, biquad, first_order_a, **params):
            self.first_order_a = first_order_a
            super().__init__(*biquad, **params)

        def reset(self, ctx) -> None:
            super().reset(ctx)
            self.z = 0.0

        def process(self, x, ctx=None):
            self.z += self.first_order_a * (x - self.z)
            return super().process(self.z, ctx)

    order1 = sl.Biquad(*sl.design_lowpass(1000.0, 0.707, SR))
    biquad, fo = butterworth3_lowpass(1000.0, SR)
    order3 = Cascade(biquad, fo[0])

    print("  magnitude response (dB), 1st-order vs custom 3-pole:")
    for f in (200.0, 1000.0, 2000.0, 4000.0, 8000.0):
        a = 20 * math.log10(max(order1.magnitude_at(f, SR), 1e-12))
        b = 20 * math.log10(max(order3.magnitude_at(f, SR), 1e-12))
        print(f"    {f:>7.0f} Hz    {a:>8.2f} dB    {b:>8.2f} dB")

    print(f"\n  the biquad section's coefficients: "
          f"{tuple(round(c, 6) for c in biquad)}")

    tone = np.sin(math.tau * 440.0 * np.arange(SR // 4) / SR)
    return render(order3, 0.25, input_signal=tone)


# ---------------------------------------------------------------------------
# 3. Replace the phase law
# ---------------------------------------------------------------------------

def experiment_custom_phase_law() -> np.ndarray:
    """Override `tick()` to own the phase accumulator itself.

    This is where hard sync, through-zero FM, and chaotic or non-linear phase maps
    live. The waveform function and table stay whatever you configured.
    """
    banner("3. Custom phase law (hard sync)")

    class HardSyncOsc(sl.Oscillator):
        """A slave oscillator restarted by a master, plus optional phase wrapping.

        Hard sync is impossible with a fixed-frequency oscillator: it requires
        resetting the slave's phase mid-cycle. `tick` owns the phase accumulator,
        so overriding it is enough -- whatever it leaves in `self.ph` is what the
        next sample reads.
        """

        slave_ratio = sl.Param(2.5, doc="slave freq = master freq * ratio")

        def reset(self, ctx) -> None:
            super().reset(ctx)
            self.master_ph = 0.0

        def tick(self, freq, dt):
            self.master_ph += freq * dt
            synced = False
            if self.master_ph >= 1.0:
                self.master_ph -= math.floor(self.master_ph)
                synced = True

            value = self.shape(self.ph)
            self.ph += freq * self.slave_ratio * dt
            if synced:
                # Restart the slave. This mid-cycle discontinuity is the sound of
                # hard sync: it forces the slave to become periodic at the master.
                self.ph = 0.0
            self.ph -= math.floor(self.ph)
            return value

    osc = HardSyncOsc(freq=110.0, wave="sine")
    y = render(osc, 0.5)

    # A synced slave is restarted by the master, so its spectrum is a series of
    # partials at multiples of the MASTER frequency, not the slave frequency.
    def level(sig, f):
        idx = np.arange(sig.size)
        return float(abs(np.sum(sig * np.exp(-2j * np.pi * f * idx / SR))) / sig.size * 2.0)

    print("  frequency content (master = 110 Hz, slave ratio = 2.5):")
    for f in (110.0, 220.0, 330.0, 440.0, 550.0, 660.0):
        print(f"    {f:>7.1f} Hz    {level(y, f):>10.5f}")
    print("  (partials sit on multiples of 110 Hz -- the master's periodicity")

    # The sync ratio changes the *timbre*, which is best seen as a spectral centroid
    # rather than RMS (a saw's RMS is frequency-independent by construction).
    print("\n  sync ratio -> spectral centroid (higher = brighter):")
    for ratio in (1.5, 2.5, 4.03):
        osc = HardSyncOsc(freq=110.0, wave="saw", antialias="polyblep")
        osc.slave_ratio = ratio
        sweep = render(osc, 0.5)
        spec = np.abs(np.fft.rfft(sweep))
        freqs = np.fft.rfftfreq(sweep.size, 1 / SR)
        centroid = float((spec * freqs).sum() / max(spec.sum(), 1e-12))
        show(f"sync ratio {ratio}: centroid (Hz)", centroid)

    return y


# ---------------------------------------------------------------------------
# 4. Compose your own waveshaper chain
# ---------------------------------------------------------------------------

def experiment_custom_shaper() -> np.ndarray:
    """A waveshaper is a Block that applies a memoryless function. Here the
    function is a Chebyshev polynomial, chosen because its harmonic content is
    exactly predictable -- which makes it a good way to *design* a distortion
    rather than just add one.
    """
    banner("4. Chebyshev waveshaping with predictable harmonics")

    class Chebyshev(Block):
        """Applies T_n(x) to the input, where T_n is the nth Chebyshev polynomial.

        This is a `Block`, not a `Source`: it transforms the signal it is handed
        rather than generating one, which is what lets it sit mid-chain.

        A cosine at amplitude 1 through T_n produces exactly the nth harmonic and
        nothing else, because T_n(cos t) = cos(n t). That identity is why Chebyshev
        shapers are used for additive-by-distortion.
        """

        order = sl.Param(2.0, doc="which harmonic to generate")
        gain = sl.Param(1.0)
        mix = sl.Param(1.0)

        def process(self, x, ctx=None):
            n = int(self.order)
            t0, t1 = 1.0, x * self.gain
            if n == 0:
                shaped = t0
            elif n == 1:
                shaped = t1
            else:
                for _ in range(2, n + 1):
                    t0, t1 = t1, 2.0 * x * self.gain * t1 - t0
                shaped = t1
            return x * (1.0 - self.mix) + shaped * self.mix

    carrier = sl.Oscillator(freq=200.0, wave="sine")
    print("  nth-harmonic output, input = 200 Hz sine:")
    for order in (2, 3, 4, 5):
        shaper = Chebyshev(order=order)
        y = render(Chain(sl.Oscillator(freq=200.0, wave="sine"), shaper), 0.5)

        def amp(f):
            idx = np.arange(y.size)
            return float(abs(np.sum(y * np.exp(-2j * np.pi * f * idx / SR))) / y.size * 2.0)

        target = 200.0 * order
        others = max(amp(200.0 * k) for k in range(1, 7) if k != order)
        print(f"    order {order}:  {target:>6.0f} Hz = {amp(target):.5f}"
              f"   strongest other = {others:.5f}")

    return render(Chain(carrier, Chebyshev(order=3)), 1.0)


# ---------------------------------------------------------------------------
# 5. Audio-rate modulation of an algorithm parameter
# ---------------------------------------------------------------------------

def experiment_audio_rate_modulation() -> np.ndarray:
    """Drive a filter's cutoff with an audio-rate oscillator and measure the
    sidebands. This only works because parameters are sampled once per sample --
    a buffer-based engine cannot do it without a block-size artefact.
    """
    banner("5. Audio-rate modulation of filter cutoff")

    carrier = sl.Oscillator(freq=440.0, wave="sine")
    filt = sl.MoogLadder(cutoff=1000.0, resonance=0.6)
    modulator = sl.Oscillator(freq=37.0, wave="sine")  # a low audio rate

    node = Chain(carrier, Modulated(filt, modulator, "cutoff", depth=700.0, base=1200.0))
    y = render(node, 1.0)

    def amp(f):
        idx = np.arange(y.size)
        return float(abs(np.sum(y * np.exp(-2j * np.pi * f * idx / SR))) / y.size * 2.0)

    print("  spectral peaks (Hz : amplitude):")
    peaks = []
    for f in (403.0, 440.0, 477.0, 366.0, 514.0):
        a = amp(f)
        peaks.append((f, a))
        print(f"    {f:>7.1f}   {a:.6f}")
    sideband = max(a for f, a in peaks if f != 440.0)
    show("sideband / carrier ratio", sideband / max(amp(440.0), 1e-12))

    return y


# ---------------------------------------------------------------------------
# 6. Write a block from scratch: a formant (bandpass) bank
# ---------------------------------------------------------------------------

def experiment_custom_block() -> np.ndarray:
    """A Block written from zero: three bandpasses in parallel tuned to vowel
    formants, summed. Nothing here comes from the library except the Block contract
    and the biquad used as a building block.

    Formant frequencies for the vowels below are the standard Peterson-Barney
    measurements for an adult male voice.
    """
    banner("6. A vowel/formant block built from scratch")

    VOWELS = {
        "a": (730.0, 1090.0, 2440.0),
        "e": (530.0, 1840.0, 2480.0),
        "i": (270.0, 2290.0, 3010.0),
        "o": (570.0, 840.0, 2410.0),
        "u": (300.0, 870.0, 2240.0),
    }

    class FormantBank(Block):
        """Parallel bandpass filters at the first three formants.

        A `Block`, not a `Source`: it filters whatever it is given, which is what a
        vowel does to a glottal source.

        Coefficients cannot be modulated, so changing `vowel` or `q` rebuilds the
        bank instead. That is the honest cost of a fixed-coefficient filter: a sweep
        is a designed trajectory, not a per-sample parameter write.
        """

        vowel = sl.Param(0.0, doc="0=a, 1=e, 2=i, 3=o, 4=u")
        q = sl.Param(8.0, doc="formant sharpness")
        wet = sl.Param(1.0)

        def __init__(self, sr: float = SR, name: str | None = None, **params):
            self._sr = float(sr)
            self._key = None
            self.bank = None
            super().__init__(name=name, **params)

        def reset(self, ctx) -> None:
            super().reset(ctx)
            self._sr = float(getattr(ctx, "sr", self._sr) or self._sr)
            self._key = None
            self._rebuild()

        def param_changed(self, name) -> None:
            # Fires during __init__ too, which is why `_rebuild` guards on `bank`.
            if name in ("vowel", "q"):
                self._rebuild()

        def _rebuild(self) -> None:
            idx = int(self.params["vowel"]) % len(VOWELS)
            key = (idx, float(self.params["q"]), self._sr)
            if key == self._key:
                return
            self._key = key
            formants = list(VOWELS.values())[idx]
            self.bank = [
                (sl.Biquad(*sl.design_bandpass(f, key[1], self._sr)), gain)
                for f, gain in zip(formants, (1.0, 0.5, 0.25))
            ]
            for filt, _ in self.bank:
                filt.reset(self.ctx)

        def process(self, x, ctx=None):
            total = 0.0
            for filt, gain in self.bank:
                total += filt.process(x, ctx) * gain
            wet = self.params["wet"]
            return x * (1.0 - wet) + total * wet

    # A glottal-ish source: a pulse wave through a gentle lowpass.
    source = Chain(
        sl.Oscillator(freq=110.0, wave="pulse", pulse_width=0.35, antialias="polyblep"),
        sl.Biquad(*sl.design_lowpass(3000.0, 0.7, SR)),
    )
    voice = Chain(source, FormantBank())
    y = render(voice, 1.0)

    print("  formant energy per vowel (rendered one at a time):")
    for name, formants in VOWELS.items():
        bank = FormantBank(vowel=float(list(VOWELS).index(name)))
        out = render(Chain(Chain(sl.Oscillator(freq=110.0, wave="pulse", pulse_width=0.35),
                                 sl.Biquad(*sl.design_lowpass(3000.0, 0.707, SR))), bank), 0.5)

        def amp(f):
            idx = np.arange(out.size)
            return float(abs(np.sum(out * np.exp(-2j * np.pi * f * idx / SR))) / out.size * 2.0)

        levels = [amp(f) for f in formants]
        print(f"    {name}: " + "  ".join(f"{f:.0f}Hz={v:.5f}" for f, v in zip(formants, levels)))

    return y


def main() -> int:
    results = {
        "custom_waveform": experiment_custom_waveform(),
        "custom_filter": experiment_custom_filter(),
        "custom_phase_law": experiment_custom_phase_law(),
        "custom_shaper": experiment_custom_shaper(),
        "audio_rate_mod": experiment_audio_rate_modulation(),
        "formant_bank": experiment_custom_block(),
    }

    banner("Summary")
    for name, signal in results.items():
        finite = bool(np.isfinite(signal).all())
        print(f"  {name:<20} {signal.size:>8} samples  peak={np.abs(signal).max():.4f}"
              f"  finite={finite}")

    print("\nSaving audio to out/ so you can listen to each experiment...")
    try:
        from synthlab.ext.io import save_wav
        out_dir = Path(__file__).resolve().parent.parent / "out"
        for name, signal in results.items():
            path = save_wav(out_dir / f"exp_{name}.wav", signal, SR)
            print(f"  wrote {path}")
    except Exception as exc:
        print(f"  could not save audio ({type(exc).__name__}: {exc}); "
              f"the numbers above are still valid")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
