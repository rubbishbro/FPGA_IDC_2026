"""Regression tests for the router-level eng1 model.

Run from the repository root::

    ~/micromamba/envs/torch312/bin/python -m pytest -q \
        sim/unit/eng1/test_router_eng1.py

The thresholds are deliberately behavioural (no audio-quality judgement): the
arithmetic tests are exact, the table tests check format/stability, and the
render smoke test only checks determinism/non-silence.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "python" / "modal_sim"))
sys.path.insert(0, str(ROOT / "python"))
sys.path.insert(0, str(ROOT / "python" / "fft_analysis"))

import router_eng1 as R  # noqa: E402


# ---------------------------------------------------------------------------
# eng1 core
# ---------------------------------------------------------------------------
def _core(g, a1, a2, x, y1, y2, *, zero=False, rtl_compat=False):
    n = len(g)
    core = R.Eng1Core(slots=1, n_modes=n, rtl_compat=rtl_compat)
    core.load_slot(0, R.Eng1Coeffs(G=g, a1=a1, a2=a2, n_modes=n))
    core.y1[0] = np.asarray(y1, dtype=np.int64)
    core.y2[0] = np.asarray(y2, dtype=np.int64)
    y, yn = core.step([x], [zero])
    return core, int(y[0]), yn[0]


def test_eng1_golden_g_only():
    """The same golden as rtl/router/tb_eng1_g.sv: y = 3 * -2**28."""
    _, y, _ = _core([1 << 24] * 3, [0] * 3, [0] * 3, -(1 << 28), [0] * 3, [0] * 3)
    assert y == -805306368


def test_eng1_feedback_matches_integer_formula():
    rng = np.random.default_rng(7)
    n = 5
    g = rng.integers(-(1 << 20), 1 << 20, n, dtype=np.int64)
    a1 = rng.integers(-(1 << 25), 1 << 25, n, dtype=np.int64)
    a2 = rng.integers(0, 1 << 20, n, dtype=np.int64)
    x = int(rng.integers(-(1 << 28), 1 << 28))
    y1 = rng.integers(-(1 << 24), 1 << 24, n, dtype=np.int64)
    y2 = rng.integers(-(1 << 24), 1 << 24, n, dtype=np.int64)

    core, got, _ = _core(g, a1, a2, x, y1, y2)
    acc = g * x - (a1 << R.A1_SHIFT) * y1 - a2 * y2
    want = np.clip((acc + R.ENG1_ROUND) >> R.C_FRAC, R.Y_MIN, R.Y_MAX)
    assert got == int(want.sum())
    np.testing.assert_array_equal(core.y1[0], want)
    np.testing.assert_array_equal(core.y2[0], y1)


@pytest.mark.parametrize("a1", [-(1 << 25), -(1 << 24) + 1, -1,
                                1, (1 << 24) + 15, (1 << 25) - 1])
def test_eng1_q24_feedback_preserves_fractional_bits_and_sign(a1):
    # y1=1.0: the output is exactly -a1. This catches both the old 22-bit
    # interpretation and a Q24 table silently rounded down to Q20 precision.
    _, y, _ = _core([0], [a1], [0], 0, [1 << 24], [0])
    assert y == -a1


def test_eng1_saturates_both_ends():
    n = 2
    _, y, yn = _core([(1 << 25) - 1] * n, [0] * n, [0] * n, (1 << 31) - 1,
                     [0] * n, [0] * n)
    assert y == n * R.Y_MAX
    assert np.all(yn == R.Y_MAX)

    _, y, yn = _core([-(1 << 25)] * n, [0] * n, [0] * n, (1 << 31) - 1,
                     [0] * n, [0] * n)
    assert y == n * R.Y_MIN
    assert np.all(yn == R.Y_MIN)


def test_eng1_st_zero_clears_every_mode():
    n = 3
    _, y, yn = _core([0] * n, [1 << 24] * n, [0] * n, 0,
                     [10, 20, 30], [1, 2, 3], zero=True)
    assert y == 0
    assert np.all(yn == 0)


def test_f05_intended_vs_rtl_compat():
    """Historical F05 mode preserves the old serial core for reproduction."""
    n = 3
    _, y_int, yn_int = _core([0] * n, [1 << 24] * n, [0] * n, 0,
                             [10, 20, 30], [0, 0, 0])
    assert y_int == -60
    np.testing.assert_array_equal(yn_int, [-10, -20, -30])

    core, y_rtl, yn_rtl = _core([0] * n, [1 << 24] * n, [0] * n, 0,
                                [10, 20, 30], [0, 0, 0], rtl_compat=True)
    assert y_rtl == -30
    np.testing.assert_array_equal(yn_rtl, [0, -10, -20])
    # the writeback still stores the *captured* q in qdot
    np.testing.assert_array_equal(core.y2[0], [10, 20, 30])


def test_rtl_compat_nmodes_full_count_truncates():
    """The IW-bit ``nmod_lat`` truncation documented under '其它接口与参数错误'.

    A truncated zero still runs mode 0: S_IDLE -> S_RD -> S_MUL happens before
    the ``mi_q+1 >= nmod_lat`` end test in S_WB.
    """
    core = R.Eng1Core(slots=1, n_modes=64, rtl_compat=True)
    core.nm[0] = 64
    assert core._rtl_nmodes(0) == 1
    core.nm[0] = 0
    assert core._rtl_nmodes(0) == 1
    core.nm[0] = 48
    assert core._rtl_nmodes(0) == 48


def test_unpack_core_word_roundtrip():
    for g, a1, a2 in ((1 << 24, -(1 << 20), 1 << 23),
                      (-(1 << 25), (1 << 21) - 1, 0),
                      (0, 0, (1 << 24) - 1)):
        word = ((g & ((1 << 26) - 1)) << 46) | (a2 << 22) | (a1 & ((1 << 22) - 1))
        assert R.unpack_core_word(word) == (g, a1, a2)


# ---------------------------------------------------------------------------
# excitation
# ---------------------------------------------------------------------------
def test_excitation_single_guitar_pulse():
    ex = R.ExcitationGen(slots=1, config=R.ExcitationConfig.guitar())
    xs = [int(ex.step([255], [True])[0]) for _ in range(4)]
    level = 255 << 18
    assert xs == [level, level, 0, 0]


def test_excitation_sustained_impulse_train():
    ex = R.ExcitationGen(slots=1, config=R.ExcitationConfig.sustained(4))
    xs = [int(ex.step([255], [True])[0]) for _ in range(10)]
    level = 255 << 22
    assert xs == [level, 0, 0, 0, level, 0, 0, 0, level, 0]


def test_excitation_release_stops_train_and_clear_resets():
    ex = R.ExcitationGen(slots=1, config=R.ExcitationConfig.sustained(3))
    ex.step([255], [True])
    ex.step([255], [True])
    assert int(ex.step([0], [False])[0]) == 0
    assert int(ex.step([0], [False])[0]) == 0
    # a held note with clear=1 is forced back to idle
    ex.step([255], [True])
    assert int(ex.step([255], [True], clear=True)[0]) == 0
    assert ex.state[0] == ex.X_IDLE


# ---------------------------------------------------------------------------
# envelopes
# ---------------------------------------------------------------------------
def test_adsr_attack_never_goes_negative():
    env = R.AdsrEnvelope(slots=1, a_step=0x01000000, d_step=1,
                         s_level=0, r_step=1)
    vals = []
    for _ in range(200):
        vals.append(int(env.step([True])[0]))
    vals = np.asarray(vals)
    assert vals.min() >= 0
    assert vals.max() == R.ENV_ONE
    assert int(env.state[0]) in (R.AdsrEnvelope.E_DEC, R.AdsrEnvelope.E_SUS)


def test_adsr_release_reaches_zero():
    env = R.AdsrEnvelope(slots=1, a_step=R.ENV_ONE, d_step=1,
                         s_level=R.ENV_ONE, r_step=R.ENV_ONE // 10)
    env.step([True])
    env.step([True])
    for _ in range(20):
        v = int(env.step([False])[0])
    assert v == 0
    assert int(env.state[0]) == R.AdsrEnvelope.E_IDLE


def test_dyn_and_const_envelopes():
    dyn = R.Envelope("dyn", slots=1)
    assert int(dyn.step([255], [True])[0]) == 255 << 23
    assert int(dyn.step([255], [False])[0]) == 0
    const = R.Envelope("const", slots=1)
    assert int(const.step([0], [False])[0]) == R.ENV_ONE


# ---------------------------------------------------------------------------
# body / reverb
# ---------------------------------------------------------------------------
def test_body_passthrough_is_exact():
    f = R.BodyFilter(coeffs=[[1 << 27, 0, 0, 0, 0]] * 5)
    values = [0, 1, -1, 2 ** 40, -(2 ** 40), 1234567890123, -987654321]
    got = [f.step(v)[0] for v in values]
    assert got == values


def test_body_guitar_coefficients_are_parsed():
    rows = R.body_coeffs("guitar")
    assert len(rows) == 5 and all(len(r) == 5 for r in rows)
    assert rows[0] == [-1384742, 2643546, -1276654, -52919616, 5278273]
    # instruments without a real body are explicit passthroughs
    assert R.body_coeffs("none")[0] == [1 << 27, 0, 0, 0, 0]


def test_reverb_none_is_exact():
    rev = R.ReverbRouter("NONE")
    values = [0, 1, -1, 123456789, -123456789, 2 ** 50, -(2 ** 50)]
    assert [rev.step(v) for v in values] == values


def test_reverb_hall_clears_then_produces_wet():
    rev = R.ReverbRouter("HALL")
    # during the first 2048 inputs the delay lines read as zero (RTL clr_run)
    for _ in range(100):
        rev.step(0)
    assert rev.step(0) == 0
    for _ in range(2100):
        rev.step(0)
    # an impulse after the clear window must produce a tail
    rev.step(1 << 30)
    tail = [rev.step(0) for _ in range(3000)]
    assert max(abs(v) for v in tail) > 0
    assert rev.comb.clr_run is False


# ---------------------------------------------------------------------------
# tables
# ---------------------------------------------------------------------------
def test_a_table_load_and_formats():
    t = R.load_a_table("guitar", 57, "forte")
    assert t.n_modes == 20
    assert t.G.min() >= -(1 << 25) and t.G.max() <= (1 << 25) - 1
    assert t.a1.min() >= -(1 << 25) and t.a1.max() <= (1 << 25) - 1
    assert np.all((t.a1 & 15) == 0)  # explicit conversion from legacy Q2.20
    assert t.a2.min() >= 0 and t.a2.max() <= (1 << 24) - 1
    assert t.drive_period is None


def test_b_table_is_stable_and_calibrated():
    t = R.build_b_table("flute", 69, "forte")
    assert t.n_modes > 0 and t.drive_period == 109
    r = np.sqrt(t.a2.astype(float) / float(1 << 24))
    assert np.all(r < 1.0)
    # every mode must be a complex pair (|a1| < 2r), otherwise the "harmonic
    # partial" premise is broken
    assert np.all(np.abs(t.a1.astype(float) / float(1 << R.A1_FRAC)) <= 2.0 * r + 1e-9)
    assert t.G.min() >= -(1 << 25) and t.G.max() <= (1 << 25) - 1


@pytest.mark.parametrize("name", ["flute", "trumpet", "cello", "violin"])
def test_q24_resource_exports_match_production_model(name):
    import struct
    import gen_sustain_q24 as Q24
    import pitch_linear as P
    sys.path.insert(0, str(ROOT / "rtl/router/tools"))
    import sustain_resources as FLASH
    table = R.build_b_table(name, 48)
    row, data, gg, aa, bb = Q24._build_entry(name, 48, True)
    production = FLASH.make_note(name, 48, True)
    assert data == production["data"]
    assert row["coeff_sha256"] == production["coeff_sha256"]
    assert row["period"] == production["period"] == table.drive_period
    for m in range(64):
        words = struct.unpack_from(">16i", data, m * 64)
        expected = (int(table.G[m]), int(table.a1[m]), int(table.a2[m])) if m < table.n_modes else (0, 0, 0)
        assert words[:3] == expected
        assert words[3:8] == (0,) * 5
        assert words[8:] == tuple(P.modulation_words(table)[m])
    np.testing.assert_array_equal(aa, table.a1)
    assert np.any((aa & 15) != 0)
    assert row["max_static_q24_c"] < row["max_static_q20_c"]


# ---------------------------------------------------------------------------
# full chain
# ---------------------------------------------------------------------------
def test_score_render_is_deterministic_and_non_silent():
    notes = [R.NoteEvent(0.0, 57, 0.30, 0.8),
             R.NoteEvent(0.10, 62, 0.30, 0.7),
             R.NoteEvent(0.20, 65, 0.30, 0.7)]
    r = R.ScoreRenderer(R.ATable("guitar"), body="guitar", reverb="NONE",
                        envelope="dyn", tail_s=0.2)
    a, ma = r.render(notes)
    r2 = R.ScoreRenderer(R.ATable("guitar"), body="guitar", reverb="NONE",
                         envelope="dyn", tail_s=0.2)
    b, mb = r2.render(notes)
    np.testing.assert_array_equal(a, b)
    assert ma.raw_peak == mb.raw_peak and ma.raw_peak > 0
    assert ma.body_sat == 0


def test_flute_render_smoke():
    notes = [R.NoteEvent(0.0, 60, 0.15, 0.8),
             R.NoteEvent(0.20, 62, 0.15, 0.8)]
    r = R.ScoreRenderer(R.BTable("flute"), body="none", reverb="NONE",
                        envelope="adsr", tail_s=0.1)
    y, meta = r.render(notes)
    assert y.size > 0 and meta.raw_peak > 0
    assert meta.warnings == []
    assert np.all(np.isfinite(y.astype(float)))


def test_router_note_hysteresis():
    r = R.LegacyRouterEng1(slots=1, body="none", reverb="NONE", envelope="dyn",
                     excitation=R.ExcitationConfig.guitar())
    r.set_slot(0, R.Eng1Coeffs(G=[1 << 24], a1=[0], a2=[0], n_modes=1))
    assert int(r.gate_r[0]) == 0
    r.gate_on(0, 1)                     # below NOTE_ON_TH
    f = r.step()
    assert not f.note_on[0]
    r.gate_on(0, 3)                     # above NOTE_ON_TH
    f = r.step()
    assert f.note_on[0]
    r.gate_on(0, 1)                     # still above NOTE_OFF_TH -> held
    f = r.step()
    assert f.note_on[0]
    r.gate_on(0, 0)
    f = r.step()
    assert not f.note_on[0]


def test_b_render_relative_partials_match_table():
    """The integer B table calibration must reproduce the extracted a_k ratios.

    A single 69 note is driven by a unit impulse every ``drive_period`` samples
    with a constant envelope; the steady spectrum is compared to the extracted
    ``w`` after normalising both to the fundamental.  The bound is deliberately
    loose (20%) because the FFT peak is quantised to a bin and the table itself
    is a quantised fit; the point is to catch a wrong gain law, not to claim
    audio fidelity.
    """
    from sustain_engine import SustainPatch

    table = R.build_b_table("flute", 69, "forte")
    r = R.LegacyRouterEng1(slots=1, n_modes=48, body="none", reverb="NONE",
                     envelope="const",
                     excitation=R.ExcitationConfig.sustained(table.drive_period))
    r.set_slot(0, table)
    r.gate_on(0, 255)
    n = int(0.8 * R.SR)
    y = np.empty(n, dtype=np.int64)
    for i in range(n):
        y[i] = r.step().out

    x = y[int(0.4 * n):].astype(float) / R.Y_ONE
    mag = np.abs(np.fft.rfft(x * np.hanning(x.size)))
    freqs = np.fft.rfftfreq(x.size, 1.0 / R.SR)
    f_drive = R.SR / table.drive_period
    kk, _g, w, *_ = SustainPatch("flute").modes(69, "forte")

    peaks = []
    for k in kk[:8]:
        idx = int(np.argmin(np.abs(freqs - k * f_drive)))
        peaks.append(float(mag[max(0, idx - 3):idx + 4].max()))
    peaks = np.asarray(peaks)
    want = np.asarray(w[:8], dtype=float)
    got_rel = peaks / peaks[0]
    want_rel = want / want[0]
    assert np.all(np.abs(got_rel - want_rel) < 0.20), (got_rel, want_rel)


def test_load_slot_zero_pads_unused_modes():
    core = R.Eng1Core(slots=1, n_modes=8)
    table = R.Eng1Coeffs(G=[1 << 24] * 3, a1=[0] * 3, a2=[0] * 3, n_modes=3)
    core.load_slot(0, table)
    assert core.nm[0] == 3
    assert np.all(core.G[0, 3:] == 0)
    assert np.all(core.y1[0, 3:] == 0)
    y, _ = core.step([-(1 << 28)])
    assert int(y[0]) == -3 * (1 << 28)


def test_eng1_pieces_smoke():
    """The new guitar/piano pieces must at least render and stay finite."""
    import eng1_pieces as P

    class Args:
        seconds = 0.25

    for fn in (P.render_guitar, P.render_piano):
        y, meta = fn(Args())
        assert y.size > 0
        assert meta.raw_peak > 0
        assert meta.warnings == []
        assert np.all(np.isfinite(y.astype(float)))


def test_piano_table_falls_back_to_available_dynamic():
    import eng1_pieces as P

    # B2 only has a forte row in the extracted piano index.
    t = P.PianoTable()(47, "piano")
    assert t.n_modes > 0
    assert t.G.max() <= (1 << 25) - 1


# ---------------------------------------------------------------------------
# B/C on the shared ABC engine
# ---------------------------------------------------------------------------
def test_bc_use_the_same_eng1_core():
    import eng1_bc as BC

    b = BC.BSynth("flute", body="none", reverb="NONE")
    c = BC.CSynth(body="none", reverb="NONE")
    assert isinstance(b.core, R.Eng1Core)
    assert isinstance(c.core, R.Eng1Core)
    assert b.core is not c.core       # same engine class, per-synth state


def test_b_table_carries_envelope_hints():
    t = R.build_b_table("flute", 69, "forte")
    assert t.attack_s is not None and t.attack_s > 0
    assert t.release_s is not None and t.release_s > 0


def test_b_synth_renders_through_core():
    import eng1_bc as BC

    b = BC.BSynth("flute", body="none", reverb="NONE")
    y = b.render([(0.0, 69, 0.25, 0.8, "forte")], 0.5)
    assert y.size == int(0.5 * R.SR)
    assert np.max(np.abs(y)) > 0
    assert np.all(np.isfinite(y.astype(float)))


def test_c_seed_scaling_matches_rtl():
    import eng1_bc as BC

    assert BC.scale_seed(1000, 0.5) == 500
    assert BC.scale_seed(-1000, 0.5) == -500
    assert BC.scale_seed(123, 1.0) == 123


def test_c_table_is_zero_drive_and_seeded():
    import eng1_bc as BC

    t = BC.build_c_table("kick")
    assert t.coeffs.G.max() == 0
    assert t.coeffs.n_modes > 0
    assert t.seed_y1.size == t.coeffs.n_modes
    assert t.length > 0


def test_c_timer_and_choke():
    import eng1_bc as BC

    c = BC.CSynth(body="none", reverb="NONE")
    old = c.hit("hat", 1.0)
    c.step()
    new = c.hit("hat", 0.8)
    assert c.slot[old].timer == 0          # choked by the new hat
    assert c.slot[new].active
    assert c.slot[new].timer > 0


def test_c_render_is_non_silent():
    import eng1_bc as BC

    c = BC.CSynth(body="none", reverb="NONE")
    y = c.render([(0.0, "kick", 1.0), (0.0, "hat", 0.5)], 0.5)
    assert np.max(np.abs(y)) > 0
    assert np.all(np.isfinite(y.astype(float)))
