"""Single source of truth for which instruments exist and how they are modelled.

Both the FFT extraction (``fft_analysis/run.py``) and the simulation
(``modal_sim/run.py``) read this, so adding an instrument is a data change rather
than edits in two places that drift apart.

``model`` names the excitation/decay class:

* ``plucked`` / ``struck`` -- Class A: one finite pulse into a *decaying* modal
  bank, then a fixed body filter. Plucked and struck instruments share the maths;
  the difference is only the pulse shape/noise transient.
* ``sustained``           -- Class B: periodic drive into the same modal bank, so
  the modes reach a steady state and ``gamma`` is a resonator *linewidth*, not a
  note decay. (Engine support not wired yet.)
* ``percussion``          -- Class C: a few modes + noise burst + fast envelope.
  (Engine support not wired yet.)

Fields:

* ``source``    -- which scanner/library: ``phil`` (Philharmonia mp3) or ``piano``.
* ``band_hz``   -- analysis band (mp3 content above ~16 kHz is unreliable).
* ``max_modes`` -- mode cap for the analysis.
* ``variations``-- articulation filter for Philharmonia (e.g. exclude ``tremolo``).
* ``noise_*`` / ``release_factor`` / ``tau_*`` -- synthesis parameters.
"""

from __future__ import annotations

REGISTRY = {
    # --- Class A: plucked / struck (implemented) -------------------------
    "guitar": dict(
        source="phil", model="plucked", band_hz=16_000.0, max_modes=48,
        variations=("normal",),
        noise_amp=0.18, noise_lp_hz=3500.0, release_factor=1.0,
    ),
    "piano": dict(
        source="piano", model="struck", band_hz=20_000.0, max_modes=64,
        variations=None,
        noise_amp=0.08, noise_lp_hz=4500.0, release_factor=9.0,
    ),
    "banjo": dict(
        source="phil", model="plucked", band_hz=16_000.0, max_modes=64,
        variations=("normal",),
        noise_amp=0.16, noise_lp_hz=4000.0, release_factor=1.0,
    ),
    "mandolin": dict(
        source="phil", model="plucked", band_hz=16_000.0, max_modes=64,
        variations=("normal",),
        noise_amp=0.16, noise_lp_hz=4000.0, release_factor=1.0,
    ),
}


def get(name: str) -> dict:
    return REGISTRY[name]


def names() -> list[str]:
    return list(REGISTRY)


def by_model(model: str) -> list[str]:
    return [n for n, c in REGISTRY.items() if c["model"] == model]
