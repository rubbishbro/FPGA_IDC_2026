"""持续性引擎控制率/收尾残留回归（纯 Python，合成 Patch，不依赖 NPZ）。

针对 ``python/modal_sim/sustain_engine.py`` 的三类明确缺陷，只固定以下行为，
不改音准/抢占/包络/噪声公式/参数：

1. ``_update_coeffs`` 只在每 ``coef_interval`` 个采样被调用，却在那里把**每个声部**的
   LFO 相位只推进 ``vibrato_hz*dt``：颤音与 AM 实际慢 ``coef_interval`` 倍；而且
   ``vibrato_cents=drift_cents=0`` 时该函数根本不调用，AM 完全不运转。修复后相位在
   ``step`` 里每采样推进一次，系数仍按控制率（``coef_interval``）采样这个已经正确的
   相位。本文件固定“note_on 之后的首个采样使用初始相位、不预推进一个 interval”的定义，
   并覆盖 ``coef_interval = 1/7/96/257``（非 96 间隔）与纯 AM（cents=drift=0）。
2. ``verify()`` 用 6 个变量解包 ``modes()`` 返回的 7 项，直接 ``ValueError``。
3. 最后一个声部被回收后 ``last_env/last_nz`` 不清零，``render`` 的噪声（乘
   ``envt*nzt``）永远残留。修复在回收最后声部的**同一采样**清零；仍有活动声部时
   保持原 ``max(env) / max(nz*env)`` 规则。

用 ``FakePatch`` 提供最小 ``modes()/noise_fir()/max_modes``，使绝大多数用例不依赖
提取出的 NPZ；真实的 ``verify()`` 入口另有一个在 NPZ 存在时才运行的用例。

第二轮（2026-10-16）在此文件继续固定 7 项已复现缺陷的修复行为：

* **静音回收过零误判**：原判据只看当前采样 ``abs(y)``；两采样 ``max(|y[n]|,|y[n-1]|)``
  在低频过零点仍会低估一个数量级（两拍都小但整体幅度大）。现由两个状态样本与当前极点
  ``(r,theta)`` 恢复**相位独立的模态 quadrature 包络** ``E``（``E^2 = y1^2 +
  ((y1 cos t - r y2)/sin t)^2``），``sum_k E_k`` 低于阈值才回收；``E`` 上界未来全部 ``|y|``，
  任意相位/高低频/gamma 边界/未用模态/调制路径都无除零 NaN，真正静音仍回收，递推不变。
* **软抢占队列卡住**：满池时反复选中同一个已淡出的槽；每个排队音现在**绑定**到 note_on
  返回的那个槽（pending 条目带 bound slot），``step`` 让绑定音在它自己的槽空闲时启动，
  取消别的排队音不会把它挪到别的槽，超池突发仍有界进展、仍淡出不硬清。
* **pending MIDI Note Off 丢失**：裸 ``note_off(midi)`` 现在同时取消 active 与 pending
  的同音事件，精确 ``note_id`` off 仍只关闭该事件。
* **键回退选错录音**：``SustainPatch._pick_key`` 原会跳到全表第一键（无关音高）；
  新顺序：同音高任意合法力度优先，其次最近音高的合理力度。
* **release 提取算法**：``fft_analysis/sustain.py`` 原取 note 尾端后第一个 <10% 采样；
  改为 90%→10% 下降时长，并处理截断/无下降。
* **verify 颤音不匹配**：静态校准明确关闭调制/噪声/roughness，返回可断言的定量指标；
  窗口随 ``seconds`` 校验/适配，过短抛错而非测空段。
* **默认噪声策略**：``SustainSynth`` 默认 ``noise_gain`` 由 1.0 改为 0.0，显式 >0 仍工作。
"""
from __future__ import annotations

import os
from pathlib import Path
import sys
import unittest
from unittest import mock

import numpy as np

ROOT = Path(__file__).resolve()
while not ((ROOT / "rtl").is_dir() and (ROOT / "sim").is_dir()):
    ROOT = ROOT.parent
import sys as _sim_sys  # noqa: E402
_sim_sys.path.insert(0, str(ROOT / "sim" / "support"))
from _sim_paths import bootstrap as _sim_bootstrap  # noqa: E402
ROOT = _sim_bootstrap(__file__)

import sustain_engine as SE  # noqa: E402
import core as CORE          # noqa: E402
import sustain as SUS        # noqa: E402  (python/fft_analysis/sustain.py)


class FakePatch:
    """``SustainSynth`` 需要的最小 Patch：``modes()/noise_fir()/max_modes``，无 NPZ。"""

    def __init__(self, max_modes: int = 6, attack: float = 0.02, release: float = 0.05):
        k = np.arange(1, max_modes + 1, dtype=float)
        self.max_modes = max_modes
        self._modes = (k, np.full(max_modes, 4.0), np.linspace(1.0, 0.2, max_modes),
                       float(attack), float(release), -40.0, 2048.0)

    def modes(self, midi, dynamic="forte"):
        return self._modes

    def noise_fir(self, sr=SE.SR, n=257):
        return None


def make_synth(patch=None, **kw):
    kw.setdefault("max_poly", 2)
    kw.setdefault("noise_gain", 0.0)
    return SE.SustainSynth(patch or FakePatch(), **kw)


def _analytic_a1(s, v, phase):
    """引擎 ``_update_coeffs`` 对给定 LFO 相位应得到的 ``a1`` 行（独立重算）。"""
    cents = s.drift_cents + s.vibrato_cents * np.sin(2.0 * np.pi * phase)
    ratio = 2.0 ** (cents / 1200.0)
    f = s.base_f[v] * ratio
    theta = 2.0 * np.pi * f * s.dt
    r = np.exp(-s.g[v] * s.dt)
    return -2.0 * r * np.cos(theta)


class LfoPerSampleTest(unittest.TestCase):
    """LFO 必须按真实采样时间推进，系数控制率不变，AM-only 也要运转。"""

    def test_phase_advances_one_sample_per_step_all_intervals(self):
        n = 5000
        for ci in (1, 7, 96, 257):
            with self.subTest(coef_interval=ci):
                s = make_synth(vibrato_hz=5.2, vibrato_cents=22.0, vibrato_am=0.0,
                               coef_interval=ci, seed=ci)
                v = s.note_on(60)
                p0 = float(s.lfo_phase[v])
                for _ in range(n):
                    s.step()
                got = (float(s.lfo_phase[v]) - p0) % 1.0
                exp = (n * s.vibrato_hz * s.dt) % 1.0
                self.assertAlmostEqual(got, exp, places=9)

    def test_first_sample_uses_note_initial_phase(self):
        s = make_synth(vibrato_hz=5.2, vibrato_cents=22.0, vibrato_am=0.0,
                       coef_interval=96, seed=0)
        v = s.note_on(60)
        p0 = float(s.lfo_phase[v])
        s.step()  # n == 0, 触发一次控制率更新
        a1 = s.a1[v].copy()
        err_same = float(np.max(np.abs(a1 - _analytic_a1(s, v, p0))))
        err_jump = float(np.max(np.abs(
            a1 - _analytic_a1(s, v, (p0 + s.vibrato_hz * s.dt) % 1.0))))
        # 首采样用的是初始相位，而不是提前推进一个采样（更不是一个 interval）后的相位
        self.assertLess(err_same, 1e-12)
        self.assertLess(err_same, err_jump)

    def test_am_only_runs_at_correct_rate_without_pitch_change(self):
        s = make_synth(vibrato_hz=6.0, vibrato_cents=0.0, drift_cents=0.0,
                       vibrato_am=0.3, coef_interval=96, seed=2)
        v = s.note_on(60, vel=1.0)
        a1_before = s.a1[v].copy()
        a2_before = s.a2[v].copy()
        fd_before = float(s.fdrive_inst[v])
        p0 = float(s.lfo_phase[v])
        steps = int(s.sr / s.vibrato_hz) + 4
        amps = []
        for _ in range(steps):
            amps.append(1.0 + float(s.am[v]) * np.sin(
                2.0 * np.pi * float(s.lfo_phase[v])))
            s.step()
        amps = np.asarray(amps)
        # AM 深度确实覆盖 (1-vibrato_am, 1+vibrato_am)
        self.assertGreater(amps.max(), 1.0 + 0.8 * s.vibrato_am)
        self.assertLess(amps.min(), 1.0 - 0.8 * s.vibrato_am)
        # 纯 AM 不得改动音高系数或驱动频率
        np.testing.assert_array_equal(s.a1[v], a1_before)
        np.testing.assert_array_equal(s.a2[v], a2_before)
        self.assertEqual(float(s.fdrive_inst[v]), fd_before)
        # 相位仍按真实 Hz 推进
        got = (float(s.lfo_phase[v]) - p0) % 1.0
        self.assertAlmostEqual(got, (steps * s.vibrato_hz * s.dt) % 1.0, places=9)


class VerifyEntryTest(unittest.TestCase):
    """``verify()`` 必须能处理 ``modes()`` 的 7 项返回。"""

    def test_verify_runs_with_synthetic_patch(self):
        fake = FakePatch(max_modes=5)
        with mock.patch.object(SE, "SustainPatch", lambda inst, **kw: fake):
            SE.verify("synthetic", midi=60, seconds=3.0)

    @unittest.skipUnless(os.path.exists(SE.paths.param("flute", "sustain")),
                         "extracted flute params not present")
    def test_verify_real_instrument_entry(self):
        SE.verify("flute", midi=69, seconds=3.0)


class TailResidualTest(unittest.TestCase):
    """最后声部回收即清 ``last_env/last_nz``；有活动声部时保持原规则。"""

    def test_zero_active_has_no_residual(self):
        s = make_synth()
        for _ in range(8):
            self.assertEqual(s.step(), 0.0)
        self.assertEqual(s.last_env, 0.0)
        self.assertEqual(s.last_nz, 0.0)

    def test_last_voice_free_clears_env_and_noise_same_sample(self):
        s = make_synth(vibrato_cents=0.0, drift_cents=0.0, vibrato_am=0.0)
        v = s.note_on(60)
        s.nz[v] = 1.0
        for _ in range(500):
            s.step()
        self.assertGreater(s.last_nz, 0.0)
        s.gate[v] = False
        freed = None
        for i in range(400000):
            s.step()
            if not s.active[v]:
                freed = i
                break
        self.assertIsNotNone(freed, "voice was never recycled")
        self.assertEqual(s.last_env, 0.0)
        self.assertEqual(s.last_nz, 0.0)

    def test_render_has_no_noise_after_last_voice(self):
        s = make_synth(vibrato_cents=0.0, drift_cents=0.0, vibrato_am=0.0,
                       noise_gain=1.0, seed=3)
        y = s.render([(0.0, 60, 0.2, 1.0)], 3.0)
        self.assertEqual(int(s.active.sum()), 0)
        np.testing.assert_array_equal(y[-2000:], np.zeros(2000))

    def test_reset_clears_last_env_and_nz(self):
        s = make_synth(vibrato_cents=0.0, drift_cents=0.0, vibrato_am=0.0)
        s.note_on(60)
        for _ in range(50):
            s.step()
        self.assertGreater(s.last_nz, 0.0)
        s.reset()
        self.assertEqual(s.last_env, 0.0)
        self.assertEqual(s.last_nz, 0.0)
        self.assertEqual(s.n, 0)
        np.testing.assert_array_equal(s.lfo_phase, np.zeros(s.max_poly))

    def test_rule_preserved_while_a_voice_remains(self):
        s = make_synth(max_poly=3, vibrato_cents=0.0, drift_cents=0.0,
                       vibrato_am=0.0, noise_gain=0.0)
        v1 = s.note_on(60)
        v2 = s.note_on(64)
        s.nz[v1] = 0.5
        s.nz[v2] = 1.0
        for _ in range(100):
            s.step()
        s.gate[v1] = False
        for _ in range(400000):
            s.step()
            if not s.active[v1]:
                break
        self.assertTrue(s.active[v2])
        active = s.active
        self.assertAlmostEqual(s.last_env, float(s.env[active].max()), places=12)
        self.assertAlmostEqual(s.last_nz, float((s.nz * s.env)[active].max()),
                               places=12)


class RecursionUnchangedTest(unittest.TestCase):
    """全部调制关闭时模态递推必须与解析参考逐采样一致。"""

    def test_no_modulation_matches_analytic_recursion(self):
        patch = FakePatch(max_modes=6)
        s = make_synth(patch, max_poly=1, vibrato_cents=0.0, drift_cents=0.0,
                       vibrato_am=0.0, coef_interval=96, seed=7)
        v = s.note_on(60, vel=0.8)
        kk, g, w = patch._modes[0], patch._modes[1], patch._modes[2]
        sr = s.sr
        f0 = float(CORE.midi_to_hz(60))
        period = max(2, int(round(sr / f0)))
        fdrive = sr / period
        f = kk * fdrive
        theta = 2.0 * np.pi * f * s.dt
        r = np.exp(-g * s.dt)
        a1 = -2.0 * r * np.cos(theta)
        a2 = r * r
        gain = w / np.array([SE.steady_amp_unit(gi, fi, fdrive, sr)
                             for gi, fi in zip(g, f)])
        rise = np.exp(-s.dt / 0.02)
        env = 0.0
        phase = 0.0
        y1 = np.zeros(kk.size)
        y2 = np.zeros(kk.size)
        ref = []
        n = 4000
        for _ in range(n):
            env = 1.0 + (env - 1.0) * rise          # gated attack approach to 1
            phase += fdrive * s.dt
            imp = 1.0 if phase >= 1.0 else 0.0
            if imp:
                phase -= 1.0
            y = gain * (imp * env * 0.8) - a1 * y1 - a2 * y2
            y2 = y1
            y1 = y
            ref.append(float(y.sum()))
        got = np.array([s.step() for _ in range(n)])
        np.testing.assert_allclose(got, ref, rtol=1e-10, atol=1e-14)

    def test_modulation_disabled_is_inert(self):
        # 关全部调制时，LFO/系数状态不应被改动（避免顺势改动递推）
        s = make_synth(vibrato_cents=0.0, drift_cents=0.0, vibrato_am=0.0, seed=5)
        v = s.note_on(60)
        phase0 = s.lfo_phase.copy()
        a1_0 = s.a1.copy()
        for _ in range(777):
            s.step()
        np.testing.assert_array_equal(s.lfo_phase, phase0)
        np.testing.assert_array_equal(s.a1, a1_0)


class SemanticsPreservedTest(unittest.TestCase):
    """不得顺手改动的其它语义保持原样。"""

    def test_integer_period_and_harmonic_partials(self):
        patch = FakePatch(max_modes=6)
        s = make_synth(patch, max_poly=1)
        v = s.note_on(60)
        f0 = float(CORE.midi_to_hz(60))
        period = max(2, int(round(s.sr / f0)))
        fdrive = s.sr / period
        np.testing.assert_allclose(s.base_f[v, :6], patch._modes[0] * fdrive)
        self.assertEqual(float(s.base_fdrive[v]), fdrive)
        self.assertEqual(float(s.fdrive_inst[v]), fdrive)

    def test_note_off_gates_only_matching_key(self):
        s = make_synth(max_poly=3)
        v1 = s.note_on(60)
        v2 = s.note_on(64)
        s.note_off(60)
        self.assertFalse(bool(s.gate[v1]))
        self.assertTrue(bool(s.gate[v2]))

    def test_preemption_steals_and_counts(self):
        s = make_synth(max_poly=2)
        s.note_on(60)
        s.note_on(64)
        s.note_on(67)                       # 无空闲 lane
        self.assertEqual(int(s.active.sum()), 2)
        self.assertEqual(s.hard_count, 1)

    def test_modes_returns_seven_fields(self):
        self.assertEqual(len(FakePatch().modes(60)), 7)
        if os.path.exists(SE.paths.param("flute", "sustain")):
            self.assertEqual(len(SE.SustainPatch("flute").modes(69)), 7)


class _ModePatch:
    """Minimal patch with configurable gammas (multi/single mode), no NPZ."""

    def __init__(self, gammas, weights=None, attack=0.02, release=0.05):
        self.max_modes = len(gammas)
        k = np.arange(1, self.max_modes + 1, dtype=float)
        w = (np.linspace(1.0, 0.2, self.max_modes) if weights is None
             else np.asarray(weights, float))
        self._modes = (k, np.asarray(gammas, float), w,
                       float(attack), float(release), -40.0, 2048.0)

    def modes(self, midi, dynamic="forte"):
        return self._modes

    def noise_fir(self, sr=SE.SR, n=257):
        return None


def _free_peak(a1, a2, y1, y2, n):
    """Peak |y| of the free modal recursion started from a captured state.

    Reference future output used to assert that a recycled voice really has a low
    remaining envelope (not just a small current sample).
    """
    a1 = np.atleast_1d(np.asarray(a1, float))
    a2 = np.atleast_1d(np.asarray(a2, float))
    y1 = np.atleast_1d(np.asarray(y1, float)).copy()
    y2 = np.atleast_1d(np.asarray(y2, float)).copy()
    peak = 0.0
    for _ in range(n):
        yn = -a1 * y1 - a2 * y2
        peak = max(peak, float(np.abs(yn).sum()))
        y2 = y1
        y1 = yn
    return peak


class QuietRecycleStateTest(unittest.TestCase):
    """静音回收必须用相位独立的模态包络：过零/低频时两拍都小仍可能很响。"""

    def _quad_state(self, s, v, A, phase=0.0):
        """Set a released voice's two state samples to a pure mode of amplitude A.

        The engine convention is self.y1 = y[n-1], self.y2 = y[n-2]; for
        y[m] = A r^m sin(theta m + phi) with envelope A at y[n-1].
        """
        theta = 2.0 * np.pi * s.base_f[v, 0] / s.sr
        r = float(np.sqrt(s.a2[v, 0]))
        s.y1[v, 0] = A * np.sin(phase)
        s.y2[v, 0] = (A / r) * np.sin(phase - theta)
        return theta, r

    def test_low_frequency_quadrature_envelope_blocks_recycle(self):
        # Reported counterexample: both 2-sample values are ~1e-4 while the mode's
        # amplitude is 0.05, so a max(|y1|,|y2|) test recycled a voice that would ring
        # at peak ~0.048 for the next 1800 samples.
        s = make_synth(_ModePatch([4.0], weights=[1.0], attack=0.02, release=0.02),
                       max_poly=1, vibrato_cents=0.0, vibrato_am=0.0, drift_cents=0.0)
        v = s.note_on(21)
        s.gate[v] = False
        s.env[v] = 0.0
        theta = 2.0 * np.pi * s.base_f[v, 0] / s.sr
        r = float(np.sqrt(s.a2[v, 0]))
        A = 0.05
        s.y1[v, 0] = -A * np.sin(theta / 2) / r
        s.y2[v, 0] = -A * np.sin(3 * theta / 2) / r ** 2
        ref_peak = _free_peak(s.a1[v].copy(), s.a2[v].copy(),
                              s.y1[v].copy(), s.y2[v].copy(), 1800)
        self.assertGreater(ref_peak, 1e-3)          # the voice really will sound
        s.step()
        self.assertTrue(bool(s.active[v]),
                        "recycled though the mode envelope is ~0.05")

    def test_quadrature_envelope_phase_independent(self):
        # Any phase: an amplitude-0.05 mode must survive the release test; a genuinely
        # tiny amplitude (1e-5) must still be recycled.
        for phase in np.linspace(0.0, 2.0 * np.pi, 17):
            with self.subTest(phase=round(float(phase), 4)):
                s = make_synth(_ModePatch([4.0], weights=[1.0], attack=0.02,
                                          release=0.02),
                               max_poly=1, vibrato_cents=0.0, vibrato_am=0.0,
                               drift_cents=0.0)
                v = s.note_on(21)
                s.gate[v] = False
                s.env[v] = 0.0
                self._quad_state(s, v, 0.05, phase)
                s.step()
                self.assertTrue(bool(s.active[v]))

    def test_quadrature_envelope_gamma_boundaries(self):
        # gamma is clipped to [0.3, 400]; the pole must be recovered without NaN and the
        # amplitude-0.05 mode must not be recycled at either extreme.
        for gamma in (0.3, 4.0, 400.0):
            with self.subTest(gamma=gamma):
                s = make_synth(_ModePatch([gamma], weights=[1.0], attack=0.02,
                                          release=0.02),
                               max_poly=1, vibrato_cents=0.0, vibrato_am=0.0,
                               drift_cents=0.0)
                v = s.note_on(21)
                s.gate[v] = False
                s.env[v] = 0.0
                self._quad_state(s, v, 0.05, 1.1)
                s.step()
                self.assertTrue(np.all(np.isfinite(s.y1)))
                self.assertTrue(bool(s.active[v]))

    def test_genuinely_tiny_state_recycled(self):
        s = make_synth(_ModePatch([4.0], weights=[1.0], attack=0.02, release=0.02),
                       max_poly=1, vibrato_cents=0.0, vibrato_am=0.0, drift_cents=0.0)
        v = s.note_on(21)
        s.gate[v] = False
        s.env[v] = 0.0
        self._quad_state(s, v, 1e-6, 0.3)
        s.step()
        self.assertFalse(bool(s.active[v]))

    def test_recycled_voice_future_envelope_is_low(self):
        # The recycle decision must be validated against the *future* free response,
        # not a single sample.  Run several gammas and assert the reference 2000-sample
        # peak at the recycle step is genuinely low.
        for gamma in (4.0, 20.0):
            with self.subTest(gamma=gamma):
                s = make_synth(_ModePatch([gamma], weights=[1.0], attack=0.02,
                                          release=0.02),
                               max_poly=1, vibrato_cents=0.0, vibrato_am=0.0,
                               drift_cents=0.0)
                v = s.note_on(60)
                for _ in range(4000):
                    s.step()
                s.gate[v] = False
                for _ in range(400000):
                    a1 = s.a1[v].copy()
                    a2 = s.a2[v].copy()
                    y1o = s.y1[v].copy()
                    y2o = s.y2[v].copy()
                    s.step()
                    if not s.active[v]:
                        # state used by the quiet test after this step
                        y_new = -a1 * y1o - a2 * y2o
                        peak = _free_peak(a1, a2, y_new, y1o, 2000)
                        self.assertLess(peak, 5e-4,
                                        "recycled with a still-audible future tail")
                        break
                else:
                    self.fail(f"gamma {gamma}: voice never recycled")

    def test_quiet_envelope_no_nan_with_unused_modes_and_modulation(self):
        # Fewer modes than the pool width leaves a1=a2=0 padding rows; vibrato updates
        # the coefficients.  The envelope computation must stay finite and recycle a
        # truly silent voice in every case.
        class ShortPatch(_ModePatch):
            def __init__(self):
                super().__init__([2.0, 1.0], weights=[1.0, 0.5])
                self.max_modes = 6                     # 2 modes used, 4 padding rows

        for kw in (dict(vibrato_cents=0.0, vibrato_am=0.0),
                   dict(vibrato_cents=22.0, vibrato_am=0.14),
                   dict(vibrato_cents=0.0, vibrato_am=0.0, drift_cents=100.0)):
            with self.subTest(**kw):
                s = make_synth(ShortPatch(), max_poly=2, **kw)
                v = s.note_on(60)
                for _ in range(2000):
                    s.step()
                self.assertTrue(np.all(np.isfinite(s.y1)))
                self.assertTrue(np.all(np.isfinite(s.y2)))
                s.gate[v] = False
                s.env[v] = 0.0
                s.y1[v] = 0.0
                s.y2[v] = 0.0
                s.step()
                self.assertFalse(bool(s.active[v]))

    def test_truly_silent_released_voice_recycles(self):
        s = make_synth(_ModePatch([4.0]), max_poly=1, vibrato_cents=0.0,
                       vibrato_am=0.0, drift_cents=0.0)
        v = s.note_on(60)
        s.gate[v] = False
        s.env[v] = 0.0
        s.y1[v] = 0.0
        s.y2[v] = 0.0
        s.step()
        self.assertFalse(bool(s.active[v]))

    @unittest.skipUnless(os.path.exists(SE.paths.param("flute", "sustain")),
                         "extracted flute params not present")
    def test_real_patches_not_recycled_150ms_after_note_off(self):
        # Reproduced bug: flute/trumpet/cello were all recycled ~139.9 ms after
        # note-off at a modal zero crossing.  With the quadrature envelope they ring on.
        for inst, midi in (("flute", 69), ("trumpet", 69), ("cello", 57)):
            if not os.path.exists(SE.paths.param(inst, "sustain")):
                continue
            with self.subTest(inst=inst):
                s = make_synth(SE.SustainPatch(inst), max_poly=1, vibrato_cents=0.0,
                               vibrato_am=0.0, drift_cents=0.0)
                v = s.note_on(midi, 1.0)
                for _ in range(48000):
                    s.step()
                s.gate[v] = False
                for _ in range(7200):       # 150 ms after note-off
                    s.step()
                self.assertTrue(bool(s.active[v]),
                                f"{inst} recycled 150 ms after note-off")


class PreemptionQueueTest(unittest.TestCase):
    """满池软抢占：真实历史下抢占、槽位绑定、突发不饥饿、返回 slot 约定。"""

    _MOD = dict(vibrato_cents=0.0, vibrato_am=0.0, drift_cents=0.0)

    def _sounding(self, s, notes):
        """Start notes and let them build real, audible state before any preemption."""
        for m in notes:
            s.note_on(m)
        for _ in range(4800):
            s.step()

    def test_repeated_steal_targets_distinct_slots(self):
        s = make_synth(max_poly=2, **self._MOD)
        self._sounding(s, (60, 64))
        slot_a = s.note_on(67)
        ida = s.last_note_id
        for _ in range(100):                                # < steal_fade: still fading
            s.step()
        slot_b = s.note_on(71)
        self.assertEqual(slot_a, 0)
        self.assertEqual(slot_b, 1)                         # old code: also 0
        self.assertNotEqual(slot_a, slot_b)
        self.assertEqual([p[0] for p in s.pending], [67, 71])
        self.assertEqual([p[4] for p in s.pending], [0, 1])  # each bound to its slot

    def test_burst_beyond_polyphony_all_start(self):
        s = make_synth(max_poly=2, **self._MOD)
        self._sounding(s, (60, 64))
        for m in (67, 71):
            s.note_on(m)
        for _ in range(2000):
            s.step()
        self.assertEqual([p[0] for p in s.pending], [])
        self.assertEqual(set(int(k) for k in s.key[s.active]), {67, 71})
        self.assertTrue(bool(s.gate[s.key == 67][0]))
        self.assertTrue(bool(s.gate[s.key == 71][0]))

    def test_oversized_burst_no_permanent_starvation(self):
        s = make_synth(max_poly=2, **self._MOD)
        self._sounding(s, (60, 64))
        for m in (67, 71, 74):
            s.note_on(m)
        seen = set()
        for _ in range(8000):
            s.step()
            seen |= set(int(k) for k in s.key[s.active])
        self.assertIn(74, seen)                             # old code: 74 starved forever
        self.assertEqual([p[0] for p in s.pending], [])

    def test_cancelled_reserved_note_does_not_move_later_bound_note(self):
        # Reported scenario: cancelling the still-queued 67 must not make the later,
        # already-bound 71 start in 67's slot.  The promise is the returned slot.
        s = make_synth(max_poly=2, **self._MOD)
        self._sounding(s, (60, 64))
        slot_a = s.note_on(67)
        ida = s.last_note_id
        for _ in range(100):
            s.step()
        slot_b = s.note_on(71)
        idb = s.last_note_id
        self.assertEqual((slot_a, slot_b), (0, 1))
        s.note_off(note_id=ida)                             # cancel queued 67
        for _ in range(600):
            s.step()
        self.assertEqual(s.voice_of(idb), slot_b)           # old code: moved to 0
        self.assertEqual(int(s.key[slot_b]), 71)
        self.assertFalse(bool(s.active[0]))                 # 67's old slot stays free

    def test_cancel_queue_head_and_middle(self):
        s = make_synth(max_poly=2, **self._MOD)
        self._sounding(s, (60, 64))
        slot_a = s.note_on(67)
        ida = s.last_note_id
        slot_b = s.note_on(71)
        idb = s.last_note_id
        slot_c = s.note_on(74)
        idc = s.last_note_id
        self.assertEqual((slot_a, slot_b, slot_c), (0, 1, None))
        self.assertEqual([p[4] for p in s.pending], [0, 1, None])
        s.note_off(note_id=ida)                             # cancel queue head
        for _ in range(1500):
            s.step()
        self.assertEqual(s.voice_of(idb), slot_b)
        self.assertIsNotNone(s.voice_of(idc))               # 74 still makes progress
        self.assertEqual([p[0] for p in s.pending], [])
        # cancelling a middle queued note keeps the others bound
        s2 = make_synth(max_poly=2, **self._MOD)
        self._sounding(s2, (60, 64))
        s2.note_on(67)
        s2.note_on(71)
        idmid = s2.last_note_id
        s2.note_on(74)
        self.assertEqual([p[4] for p in s2.pending], [0, 1, None])
        s2.note_off(note_id=idmid)
        self.assertEqual([p[0] for p in s2.pending], [67, 74])
        self.assertEqual([p[4] for p in s2.pending][0], 0)  # 67 keeps its reservation

    def test_late_note_on_does_not_take_reserved_slot(self):
        s = make_synth(max_poly=2, **self._MOD)
        self._sounding(s, (60, 64))
        slot_a = s.note_on(67)                              # binds slot 0
        slot_b = s.note_on(71)                              # only slot 1 left
        self.assertEqual((slot_a, slot_b), (0, 1))
        self.assertEqual([p[4] for p in s.pending], [0, 1])

    def test_cancel_does_not_hardclear_other_reserved_state(self):
        s = make_synth(max_poly=2, **self._MOD)
        self._sounding(s, (60, 64))
        s.note_on(67)
        for _ in range(100):
            s.step()
        s.note_on(71)
        for _ in range(100):
            s.step()
        self.assertLess(float(s.fade[1]), 1.0)              # slot 1 reserved, fading
        self.assertTrue(bool(s.active[1]))
        self.assertGreater(float(np.abs(s.y1[1]).sum() + np.abs(s.y2[1]).sum()), 0.0)
        ida = [p[3] for p in s.pending if p[0] == 67][0]
        s.note_off(note_id=ida)
        # slot 1's voice/state is untouched by cancelling 67
        self.assertLess(float(s.fade[1]), 1.0)
        self.assertTrue(bool(s.active[1]))

    def test_steal_keeps_state_and_fades_not_hard_reset(self):
        s = make_synth(max_poly=2, **self._MOD)
        self._sounding(s, (60, 64))
        state_before = float(np.abs(s.y1[0]).sum() + np.abs(s.y2[0]).sum())
        self.assertGreater(state_before, 0.0)
        s.note_on(67)
        self.assertLess(float(s.fade[0]), 1.0)              # fading
        self.assertTrue(bool(s.active[0]))                  # not hard-cleared
        self.assertFalse(bool(s.gate[0]))
        self.assertGreater(float(np.abs(s.y1[0]).sum() + np.abs(s.y2[0]).sum()), 0.0)

    def test_note_on_return_contract_for_queued_note(self):
        s = make_synth(max_poly=2, **self._MOD)
        self._sounding(s, (60, 64))
        slot = s.note_on(67)
        nid = s.last_note_id
        self.assertEqual(slot, 0)
        self.assertEqual(int(s.note_id[slot]), 1)           # still the stolen voice
        self.assertIsNone(s.voice_of(nid))                  # queued: not active under id
        for _ in range(1000):
            s.step()
        self.assertEqual(s.voice_of(nid), slot)             # starts in the bound slot
        self.assertEqual(int(s.note_id[slot]), nid)

    def test_all_slots_reserved_returns_none_and_queues(self):
        s = make_synth(max_poly=2, **self._MOD)
        self._sounding(s, (60, 64))
        s.note_on(67)
        s.note_on(71)
        slot = s.note_on(74)
        self.assertIsNone(slot)
        self.assertEqual([p[0] for p in s.pending], [67, 71, 74])
        self.assertEqual([p[4] for p in s.pending], [0, 1, None])

    def test_interleaved_arrival_and_cancel_still_starts(self):
        s = make_synth(max_poly=2, **self._MOD)
        self._sounding(s, (60, 64))
        s.note_on(67)
        nid = s.last_note_id
        for _ in range(100):
            s.step()
        s.note_off(note_id=nid)                             # cancel the queued note
        self.assertEqual([p[0] for p in s.pending], [])
        s.note_on(71)
        for _ in range(2000):
            s.step()
        self.assertIn(71, set(int(k) for k in s.key[s.active]))
        self.assertEqual([p[0] for p in s.pending], [])


class PendingNoteOffTest(unittest.TestCase):
    """裸 midi Note Off 取消 pending；精确 note_id 只关该事件。"""

    def test_bare_midi_cancels_pending(self):
        s = make_synth(max_poly=2)
        s.note_on(60)
        s.note_on(64)
        s.note_on(67)
        self.assertEqual([p[0] for p in s.pending], [67])
        s.note_off(67)
        self.assertEqual([p[0] for p in s.pending], [])     # old code kept it
        for _ in range(1000):
            s.step()
        self.assertNotIn(67, set(int(k) for k in s.key[s.active]))

    def test_bare_midi_releases_all_active_same_pitch(self):
        s = make_synth(max_poly=3)
        v1 = s.note_on(60)
        v2 = s.note_on(60)
        v3 = s.note_on(64)
        s.note_off(60)
        self.assertFalse(bool(s.gate[v1]))
        self.assertFalse(bool(s.gate[v2]))
        self.assertTrue(bool(s.gate[v3]))

    def test_note_id_off_only_that_event(self):
        s = make_synth(max_poly=3)
        v1 = s.note_on(60)
        id1 = s.last_note_id
        v2 = s.note_on(60)
        s.note_off(note_id=id1)
        self.assertFalse(bool(s.gate[v1]))
        self.assertTrue(bool(s.gate[v2]))


def _patch_from_keys(keys):
    """A SustainPatch-shaped object with only the key tables _pick_key needs."""
    p = SE.SustainPatch.__new__(SE.SustainPatch)
    p.by_key = {k: [dict(dummy=True)] for k in keys}
    p.keys = sorted(p.by_key)
    p.midis = sorted({k[0] for k in p.keys})
    return p


class KeyFallbackTest(unittest.TestCase):
    """_pick_key：同音高优先，其次最近音高；绝不跳到无关第一键。"""

    def test_exact_dynamic_wins(self):
        p = _patch_from_keys([(60, "forte"), (60, "piano")])
        self.assertEqual(p._pick_key(60, "piano"), (60, "piano"))

    def test_other_dynamic_same_pitch_before_nearest(self):
        p = _patch_from_keys([(57, "forte"), (60, "mezzo-forte")])
        self.assertEqual(p._pick_key(60, "forte"), (60, "mezzo-forte"))
        self.assertEqual(p._pick_key(60, "piano"), (60, "mezzo-forte"))

    def test_nearest_pitch_when_current_absent(self):
        p = _patch_from_keys([(57, "forte"), (60, "mezzo-forte")])
        self.assertEqual(p._pick_key(61, "forte"), (60, "mezzo-forte"))
        self.assertEqual(p._pick_key(58, "forte"), (57, "forte"))

    def test_never_jumps_to_unrelated_first_pitch(self):
        # Old code returned (57,'forte') for every request that missed forte.
        p = _patch_from_keys([(57, "forte"), (60, "mezzo-forte"), (90, "forte")])
        self.assertEqual(p._pick_key(60, "forte")[0], 60)
        self.assertEqual(p._pick_key(89, "forte")[0], 90)
        self.assertEqual(p._pick_key(61, "forte")[0], 60)

    def test_nearest_pitch_prefers_requested_then_forte(self):
        p = _patch_from_keys([(57, "piano"), (64, "forte")])
        self.assertEqual(p._pick_key(63, "piano"), (64, "forte"))

    @unittest.skipUnless(os.path.exists(SE.paths.param("violin", "sustain")),
                         "extracted violin params not present")
    def test_real_violin_stays_on_requested_pitch(self):
        p = SE.SustainPatch("violin")
        for m in (67, 87, 90):
            key = p._pick_key(m, "forte")
            self.assertEqual(key[0], m, f"violin key fell off pitch {m} to {key}")


def _synthetic_release_audio(sr=48000, seconds=5.0, t_on=0.3, t_off=3.0,
                             atk_tau=0.05, rel_tau=0.2, am=0.0, noise=0.0, seed=0):
    t = np.arange(0, seconds, 1.0 / sr)
    env = np.zeros_like(t)
    att = (t >= t_on) & (t < t_off)
    env[att] = 1.0 - np.exp(-(t[att] - t_on) / atk_tau)
    v_at = 1.0 - np.exp(-(t_off - t_on) / atk_tau)
    rel = t >= t_off
    env[rel] = v_at * np.exp(-(t[rel] - t_off) / rel_tau)
    env = env * (1.0 + am * np.sin(2 * np.pi * 6.0 * t))     # 6 Hz AM fluctuation
    audio = env * (np.sin(2 * np.pi * 440 * t) + 0.5 * np.sin(2 * np.pi * 880 * t)
                   + 0.2 * np.sin(2 * np.pi * 1320 * t))
    if noise:
        audio = audio + noise * np.random.default_rng(seed).standard_normal(t.size)
    return audio


class ReleaseExtractionTest(unittest.TestCase):
    """release 提取应是 90%→10% 下降时长，而非 note 尾端后第一个 <10% 采样。"""

    def _analyze(self, audio, sr=48000, max_modes=3):
        with mock.patch.object(CORE, "load_audio",
                               lambda path, sr=CORE.SR, channel=None: audio):
            return SUS.analyze_sustain("synthetic_A4_long_forte_normal.mp3",
                                       midi=69, dynamic="forte", max_modes=max_modes,
                                       sr=sr)

    def test_synthetic_release_90_10(self):
        rlx_true = 0.2 * np.log(9.0)                        # 439.445 ms
        r = self._analyze(_synthetic_release_audio())
        got = float(r["release_s"])
        self.assertGreater(got, 0.35)                       # old code: 0.000542 s
        self.assertLess(got, 0.52)
        self.assertLess(abs(got - rlx_true) / rlx_true, 0.10)

    def test_attack_extraction_unchanged_and_sane(self):
        r = self._analyze(_synthetic_release_audio())
        atk_true = 0.05 * np.log(9.0)                       # 10->90 = 109.86 ms
        self.assertTrue(np.isfinite(r["attack_s"]))
        self.assertGreater(float(r["attack_s"]), 0.5 * atk_true)
        self.assertLess(float(r["attack_s"]), 2.0 * atk_true)

    def test_no_decay_returns_zero(self):
        t = np.arange(0, 3.0, 1.0 / 48000)
        audio = (np.sin(2 * np.pi * 440 * t) + 0.5 * np.sin(2 * np.pi * 880 * t)
                 + 0.2 * np.sin(2 * np.pi * 1320 * t))
        r = self._analyze(audio, max_modes=3)
        self.assertEqual(float(r["release_s"]), 0.0)

    def test_truncated_tail_returns_zero(self):
        # Slow release that never reaches 10 % inside the 5 s file.
        audio = _synthetic_release_audio(t_on=0.3, t_off=3.0, rel_tau=5.0)
        r = self._analyze(audio, max_modes=3)
        self.assertEqual(float(r["release_s"]), 0.0)

    def test_noise_and_am_fluctuation_still_extract_release(self):
        # A ±10 % 6 Hz amplitude fluctuation and a small noise floor make the RMS
        # envelope track the AM, so the 90->10 estimate shifts by ~10 %.  It must stay
        # a sane positive duration (the buggy version collapsed to ~0.5 ms), not an
        # absurd or zero value.  This does not change the gamma/attack model.
        for am, noise in ((0.1, 0.0), (0.0, 0.02), (0.1, 0.02)):
            with self.subTest(am=am, noise=noise):
                r = self._analyze(_synthetic_release_audio(am=am, noise=noise))
                got = float(r["release_s"])
                self.assertGreater(got, 0.30)
                self.assertLess(got, 0.55)


class VerifyStaticCalibrationTest(unittest.TestCase):
    """verify() 静态校准：关调制/噪声，返回定量且非空的谱误差。"""

    def test_verify_synthetic_returns_quantitative_metrics(self):
        fake = FakePatch(max_modes=5)
        with mock.patch.object(SE, "SustainPatch", lambda inst, **kw: fake):
            stats = SE.verify("synthetic", midi=60, seconds=3.0)
        self.assertIsInstance(stats, dict)
        self.assertGreater(stats["samples"], 1000)
        self.assertTrue(np.isfinite(stats["median_db"]))
        self.assertLess(stats["median_db"], 1.5)
        self.assertLess(stats["max_db"], 3.0)

    @unittest.skipUnless(os.path.exists(SE.paths.param("flute", "sustain")),
                         "extracted flute params not present")
    def test_verify_real_flute_static_bound(self):
        # Modulated verify read median ~15 dB; static calibration must be < 1 dB.
        stats = SE.verify("flute", midi=69, seconds=3.0)
        self.assertGreater(stats["samples"], 1000)
        self.assertTrue(np.isfinite(stats["median_db"]))
        self.assertLess(stats["median_db"], 1.0)
        self.assertLess(stats["max_db"], 3.0)

    def test_verify_too_short_seconds_raises(self):
        fake = FakePatch(max_modes=5)
        with mock.patch.object(SE, "SustainPatch", lambda inst, **kw: fake):
            with self.assertRaises(ValueError):
                SE.verify("synthetic", midi=60, seconds=0.5)

    def test_verify_adapts_short_window(self):
        fake = FakePatch(max_modes=5)
        with mock.patch.object(SE, "SustainPatch", lambda inst, **kw: fake):
            stats = SE.verify("synthetic", midi=60, seconds=1.5)
        self.assertGreater(stats["samples"], 1000)
        self.assertTrue(np.isfinite(stats["median_db"]))


class NoiseDefaultTest(unittest.TestCase):
    """噪声默认关闭；显式 noise_gain>0 仍工作。"""

    def test_default_noise_off(self):
        s = SE.SustainSynth(FakePatch(), max_poly=2)
        self.assertEqual(float(s.noise_gain), 0.0)

    def test_explicit_noise_on_still_changes_render(self):
        ev = [(0.0, 60, 0.5, 1.0)]
        a = SE.SustainSynth(FakePatch(), max_poly=2, noise_gain=0.0, seed=4)
        b = SE.SustainSynth(FakePatch(), max_poly=2, noise_gain=1.0, seed=4)
        ya = a.render(ev, 1.0)
        yb = b.render(ev, 1.0)
        self.assertFalse(np.allclose(ya, yb))
        # default render equals an explicit noise_gain=0 render
        c = SE.SustainSynth(FakePatch(), max_poly=2, seed=4)
        np.testing.assert_array_equal(c.render(ev, 1.0), ya)


if __name__ == "__main__":
    unittest.main()
