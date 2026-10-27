#!/usr/bin/env python3
"""Render a short vibrato demo with the real B-class synth.

This is deliberately *not* an FFT re-analysis of a recording.  The modal
parameters already exist in ``FFT_results/params/<inst>_sustain.npz``; using the
parametric synth keeps the A/B clean: excitation, modes, envelope and drive are
identical, only the a1 update law changes.

Variants
--------
off      no vibrato
exact    a1 = -2r cos(rho*theta)       (current Python engine)
linear   a1 = a1_0 + s*(rho-1)*theta   (first-order Taylor)
q20      b_a1_refresh integer model: a1 Q2.20, dtheta Q3.14
q24      proposed integer model:     a1 Q2.24, dtheta Q3.20

The phrase is cello C2 (2.8 s) then C4 (3.0 s), 20 cents, 5.2 Hz.  AM, noise and
roughness are off so the demo isolates pitch modulation.

Run
---
    python python/modal_sim/vibrato_demo.py
"""

from __future__ import annotations

import os
import sys

import numpy as np
import soundfile as sf

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "fft_analysis"))

import core as CORE                                   # noqa: E402
import paths                                          # noqa: E402
import sustain_engine as SE                           # noqa: E402
import vibrato_coeff as VC                            # noqa: E402

SR = CORE.SR
OUT = paths.SIM_VIBRATO
DEPTH = 20.0
RATE = 5.2
INTERVAL = 96
EVENTS = [(0.0, 36, 2.8, 1.0), (3.0, 60, 3.0, 0.9)]   # cello C2 -> C4
SECONDS = 6.4


class CoefVibratoSynth(SE.SustainSynth):
    """SustainSynth with a selectable a1 update law.

    ``coef_mode`` is one of ``exact``, ``linear``, ``q20``, ``q24``.  The default
    exact path is the same formula as the parent, so this subclass is only a demo
    harness -- the verified engine is untouched.
    """

    def __init__(self, *args, coef_mode: str = "exact", **kwargs):
        if coef_mode not in ("off", "exact", "linear", "q20", "q24"):
            raise ValueError(coef_mode)
        self.coef_mode = coef_mode
        super().__init__(*args, **kwargs)
        V, N = self.max_poly, self.Nmax
        self._a1q = np.zeros((V, N), dtype=np.int64)
        self._a2q = np.zeros((V, N), dtype=np.int64)
        self._thetaq = np.zeros((V, N), dtype=np.int64)

    def _start(self, v, midi, vel, dynamic, nid):
        v = super()._start(v, midi, vel, dynamic, nid)
        theta = 2.0 * np.pi * self.base_f[v] * self.dt
        r = np.exp(-self.g[v] * self.dt)
        a1 = -2.0 * r * np.cos(theta)
        a2 = r * r
        used = self.base_f[v] > 0.0
        self._a1q[v, used] = np.round(a1[used] * (1 << 20)).astype(np.int64)
        self._a2q[v, used] = np.round(a2[used] * (1 << 24)).astype(np.int64)
        for k in np.nonzero(used)[0]:
            self._thetaq[v, k] = VC._theta_q_from_a1a2(
                int(self._a1q[v, k]), int(self._a2q[v, k]))
        return v

    def _update_coeffs(self):
        self.cents = (self.drift_cents
                      + self.vibrato_cents * np.sin(2.0 * np.pi * self.lfo_phase))
        ratio = 2.0 ** (self.cents / 1200.0)
        theta = 2.0 * np.pi * self.base_f * self.dt
        r = np.exp(-self.g * self.dt)

        if self.coef_mode == "exact":
            self.a1 = -2.0 * r * np.cos(ratio[:, None] * theta)
            self.a2 = r * r
        elif self.coef_mode == "linear":
            a1_0 = -2.0 * r * np.cos(theta)
            s = 2.0 * r * np.sin(theta)
            dth = (ratio[:, None] - 1.0) * theta
            self.a1 = a1_0 + s * dth
            self.a2 = r * r
        else:
            qa1, qd = (20, 14) if self.coef_mode == "q20" else (24, 20)
            self.a2 = r * r
            for v in np.nonzero(self.active)[0]:
                rq = int(round(ratio[v] * (1 << 15)))
                for k in np.nonzero(self.base_f[v] > 0.0)[0]:
                    a1q = VC._refresh_int(
                        int(self._a1q[v, k]), int(self._a2q[v, k]),
                        int(self._thetaq[v, k]), rq, qa1, qd)
                    self.a1[v, k] = a1q / float(1 << qa1)
                    self.a2[v, k] = self._a2q[v, k] / float(1 << 24)
        self.fdrive_inst = self.base_fdrive * ratio


def render(mode: str) -> np.ndarray:
    patch = SE.SustainPatch("cello", max_modes=32)
    synth = CoefVibratoSynth(
        patch, max_poly=8, coef_mode=mode,
        vibrato_hz=RATE,
        vibrato_cents=0.0 if mode == "off" else DEPTH,
        vibrato_am=0.0,
        drift_cents=0.0,
        roughness=0.0,
        noise_gain=0.0,
        coef_interval=INTERVAL,
        seed=0,
    )
    y = synth.render(EVENTS, SECONDS)
    y = np.asarray(y, dtype=float)
    # short fade, then normalise each variant to the same peak for A/B listening
    n = int(0.01 * SR)
    y[:n] *= np.linspace(0.0, 1.0, n)
    y[-n:] *= np.linspace(1.0, 0.0, n)
    y *= 0.9 / max(float(np.max(np.abs(y))), 1e-12)
    return y


def render_decay_bank(mode: str, midi: int = 36, seconds: float = 2.5) -> np.ndarray:
    """A-like free decay: excite the extracted cello modes, then let them ring.

    There is no drive here, so the output pitch is set directly by the a1
    trajectory.  This is where Q2.20's low-note staircase becomes an audible
    *pitch* staircase, unlike the B-class driven demo where the NCO carries pitch.
    """
    ms = VC.load_modes("cello", midi)
    cfg = VC.CONFIG_BY_NAME[{"exact": "float_exact", "linear": "float_t1",
                              "q20": "q20_int", "q24": "q24_int"}[mode]]
    a2 = ms.a2
    if mode in ("q20", "q24"):
        a2 = np.round(a2 * (1 << 24)) / float(1 << 24)
    n = int(seconds * SR)
    y1 = ms.weight.copy()
    y2 = np.zeros_like(y1)
    out = np.zeros(n)
    a1 = np.zeros_like(y1)
    for i in range(n):
        if i % INTERVAL == 0:
            c = DEPTH * np.sin(2.0 * np.pi * RATE * i / SR)
            a1 = VC.a1_curve(ms, np.array([c]), cfg, DEPTH)[:, 0]
        y = -a1 * y1 - a2 * y2
        y2, y1 = y1, y
        out[i] = float(y.sum())
    nf = int(0.01 * SR)
    out[:nf] *= np.linspace(0.0, 1.0, nf)
    out[-nf:] *= np.linspace(1.0, 0.0, nf)
    out *= 0.9 / max(float(np.max(np.abs(out))), 1e-12)
    return out


def _mode_cfg(mode: str):
    return VC.CONFIG_BY_NAME[{"exact": "float_exact", "linear": "float_t1",
                              "q20": "q20_int", "q24": "q24_int"}[mode]]


def render_pure_decay(mode: str, midi: int = 36, seconds: float = 4.0,
                      rate: float = 4.0) -> np.ndarray:
    """Single-mode free decay: the cleanest way to hear the a1 pitch law."""
    ms = VC.load_modes("cello", midi)
    y, _ = VC.render_decay(ms, _mode_cfg(mode), seconds=seconds,
                           depth=DEPTH, rate=rate, interval=INTERVAL, mode=0)
    nf = int(0.01 * SR)
    y[:nf] *= np.linspace(0.0, 1.0, nf)
    y[-nf:] *= np.linspace(1.0, 0.0, nf)
    return 0.9 * y / max(float(np.max(np.abs(y))), 1e-12)


def render_pitch_tone(mode: str, midi: int = 36, seconds: float = 4.0,
                      rate: float = 4.0, carrier: float = 220.0) -> np.ndarray:
    """Sonify the *realized* pitch trajectory on a 220 Hz carrier.

    This is not the cello timbre; it is a deliberately simple tone so the
    coefficient quantisation is audible even on small speakers.
    """
    ms = VC.load_modes("cello", midi)
    n = int(seconds * SR)
    ticks = np.arange(0, n, INTERVAL)
    c = DEPTH * np.sin(2.0 * np.pi * rate * ticks / SR)
    a1 = VC.a1_curve(ms, c, _mode_cfg(mode), DEPTH)[0]
    f_mode = np.arccos(np.clip(-a1 / (2.0 * ms.r[0]), -1, 1)) / (2.0 * np.pi) * SR
    cents = 1200.0 * np.log2(f_mode / ms.f[0])
    f_carrier = carrier * 2.0 ** (cents / 1200.0)
    f_s = np.repeat(f_carrier, INTERVAL)[:n]
    y = np.sin(2.0 * np.pi * np.cumsum(f_s) / SR)
    nf = int(0.01 * SR)
    y[:nf] *= np.linspace(0.0, 1.0, nf)
    y[-nf:] *= np.linspace(1.0, 0.0, nf)
    return 0.9 * y / max(float(np.max(np.abs(y))), 1e-12)


def main() -> int:
    paths.makedirs()
    os.makedirs(OUT, exist_ok=True)
    names = ["off", "exact", "linear", "q20", "q24"]
    peaks = {}
    renders = {}
    for mode in names:
        y = render(mode)
        renders[mode] = y
        path = os.path.join(OUT, f"demo_{mode}.wav")
        sf.write(path, y, SR, subtype="PCM_16")
        peaks[mode] = float(np.max(np.abs(y)))
        print(f"wrote {path}  peak={peaks[mode]:.3f}")

    # easy A/B: same C2 segment, q20 then q24
    seg = slice(int(0.20 * SR), int(2.80 * SR))
    gap = np.zeros(int(0.40 * SR))
    ab = np.concatenate([renders["q20"][seg], gap, renders["q24"][seg]])
    sf.write(os.path.join(OUT, "demo_ab_q20_q24.wav"), ab, SR, subtype="PCM_16")
    ab2 = np.concatenate([renders["exact"][seg], gap, renders["q20"][seg]])
    sf.write(os.path.join(OUT, "demo_ab_exact_q20.wav"), ab2, SR, subtype="PCM_16")

    # A-like free decay: pitch comes directly from a1, so q20's staircase is a
    # pitch staircase here (unlike the driven B demo).
    decays = {}
    for mode in ("exact", "linear", "q20", "q24"):
        y = render_decay_bank(mode)
        decays[mode] = y
        sf.write(os.path.join(OUT, f"demo_decay_{mode}.wav"), y, SR, subtype="PCM_16")
    dec_ab = np.concatenate([decays["q20"], np.zeros(int(0.4 * SR)), decays["q24"]])
    sf.write(os.path.join(OUT, "demo_decay_ab_q20_q24.wav"), dec_ab, SR, subtype="PCM_16")

    # single-mode free decay + 220 Hz pitch sonification: the clearest A/B
    pure = {m: render_pure_decay(m) for m in ("exact", "q20", "q24")}
    for m, y in pure.items():
        sf.write(os.path.join(OUT, f"demo_pure_{m}.wav"), y, SR, subtype="PCM_16")
    sf.write(os.path.join(OUT, "demo_pure_ab_q20_q24.wav"),
             np.concatenate([pure["q20"], np.zeros(int(0.4 * SR)), pure["q24"]]),
             SR, subtype="PCM_16")

    tones = {m: render_pitch_tone(m) for m in ("exact", "q20", "q24")}
    for m, y in tones.items():
        sf.write(os.path.join(OUT, f"demo_pitch_{m}.wav"), y, SR, subtype="PCM_16")
    sf.write(os.path.join(OUT, "demo_pitch_ab_q20_q24.wav"),
             np.concatenate([tones["q20"], np.zeros(int(0.4 * SR)), tones["q24"]]),
             SR, subtype="PCM_16")

    def null(a, b, s, e):
        aa = renders[a][int(s * SR):int(e * SR)]
        bb = renders[b][int(s * SR):int(e * SR)]
        return 10.0 * np.log10(np.sum((aa - bb) ** 2) / max(np.sum(aa ** 2), 1e-30))

    rows = []
    for lo, hi, lab in ((0.5, 2.6, "C2"), (3.5, 5.6, "C4")):
        rows.append(f"| {lab} | {null('exact', 'linear', lo, hi):.1f} dB "
                    f"| {null('exact', 'q20', lo, hi):.1f} dB "
                    f"| {null('exact', 'q24', lo, hi):.1f} dB |")
    ab_rows = "\n".join(rows)

    lines = [
        "# 颤音 A/B 试听",
        "",
        "脚本：`python/modal_sim/vibrato_demo.py`  ",
        "合成器：B 类用 `SustainSynth`；A 类/纯音/音高 sonification 用同一组 cello 模态参数。",
        "**不是**对录音做 FFT 再分析。",
        "",
        "短句：cello C2 2.8 s → C4 3.0 s；深度 20 cents，LFO 5.2 Hz；",
        "AM、噪声、roughness 全关，只保留纯音高颤音。",
        "",
        "| 文件 | a1 更新方式 | 预期 |",
        "|---|---|---|",
        "| `demo_off.wav` | 无颤音 | 平直参考 |",
        "| `demo_exact.wav` | `-2r cos(ρθ)` | 精确参考 |",
        "| `demo_linear.wav` | `a1₀ + s(ρ-1)θ` | 和 exact 几乎一样 |",
        "| `demo_q20.wav` | 当前 Q2.20 + δθ Q3.14 整数 | C2 有粗糙/音色抖动 |",
        "| `demo_q24.wav` | Q2.24 + δθ Q3.20 整数 | C2 顺滑很多 |",
        "| `demo_ab_q20_q24.wav` | q20 → 0.4 s 静音 → q24 | 最快听出差别 |",
        "| `demo_ab_exact_q20.wav` | exact → 0.4 s 静音 → q20 | 对照精确参考 |",
        "",
        "每个文件独立归一化到 -1 dBFS 附近，方便直接 A/B；",
        "听 C2 段（前 2.8 s）最容易分辨，C4 段（后 3 s）差异会小一些。",
        "音高轨迹见 `fig_staircase.png` 左图（C2）。",
        "",
        "## B 类（持续音）残差",
        "",
        "| 片段 | exact-linear | exact-q20 | exact-q24 |",
        "|---|---:|---:|---:|",
        ab_rows,
        "",
        "注意：B 类的音高由驱动 NCO 决定，q20 的差别主要是**共振/音色/幅度抖动**，",
        "不是音高台阶。要听音高台阶，请看下面的 A 类自由衰减。",
        "",
        "## A 类自由衰减（音高直接由 a1 决定）",
        "",
        "用同一组 cello C2 模态，给一个初始状态后自由衰减，没有驱动：",
        "",
        "| 文件 | 听感 |",
        "|---|---|",
        "| `demo_decay_exact.wav` | 平滑的 20 c 颤音 |",
        "| `demo_decay_linear.wav` | 和 exact 几乎一样 |",
        "| `demo_decay_q20.wav` | 几个 10 c 级台阶，明显不连续 |",
        "| `demo_decay_q24.wav` | 接近平滑 |",
        "| `demo_decay_ab_q20_q24.wav` | q20 → 0.4 s 静音 → q24 |",
        "",
        "### 更清楚的单模态 / 音高轨迹试听",
        "",
        "`demo_decay_*` 是多模态混合，音高台阶有时会被高次模态和衰减盖住；",
        "如果还听不明显，用下面两组：",
        "",
        "| 文件 | 内容 |",
        "|---|---|",
        "| `demo_pure_exact.wav` / `demo_pure_q20.wav` / `demo_pure_q24.wav` | 单个 C2 模态自由衰减，4 s，4 Hz，20 c |",
        "| `demo_pure_ab_q20_q24.wav` | q20 → 静音 → q24 |",
        "| `demo_pitch_exact.wav` / `demo_pitch_q20.wav` / `demo_pitch_q24.wav` | 把实际音高轨迹搬到 220 Hz 载波上（不是 cello 音色） |",
        "| `demo_pitch_ab_q20_q24.wav` | q20 → 静音 → q24，台阶最明显 |",
        "",
        "`demo_pitch_*` 是“音高轨迹的 sonification”：它不经过模态合成器，",
        "只把 `a1` 反解出来的 cents 轨迹乘到 220 Hz 上，所以量化台阶不会被音色掩盖。",
        "",
        "### 为什么 q24 不是严格围绕 f0",
        "",
        "`q24` 只加宽了**调制量/影子**，标称 `a1_nom` 仍然来自 Q2.20 ROM。",
        "cello C2 的 Q2.20 标称值对应约 **-1.57 c** 的静态误差；",
        "所以 q24 的轨迹是围绕这个“已量化的标称音高”上下摆，而不是围绕理想 f0。",
        "整数 `term1` 的截断还会再加一点偏置。实测 C2、4 Hz、20 c 下：",
        "",
        "| 版本 | 轨迹中心 | 范围 |",
        "|---|---:|---:|",
        "| exact | 0.00 c | -20.00 .. +20.00 c |",
        "| q20 | -1.86 c | -24.44 .. +20.72 c |",
        "| q24 | -1.45 c | -21.55 .. +18.65 c |",
        "",
        "要让它严格围绕 f0，需要在 note-on 用更高精度重算/存储 `a1_nom`，",
        "或者把标称 a1 也做到 Q2.24。",
        "",
        "B 类里听不出这个中心偏移是正常的：B 的音高由驱动 NCO 决定（NCO 用精确的 `rho`），",
        "a1 只负责模态共振；A 类/`demo_pure_*` 才是音高直接跟着 a1 走。",
        "",
    ]
    with open(os.path.join(OUT, "DEMO.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    print(f"wrote {os.path.join(OUT, 'DEMO.md')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
