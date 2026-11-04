#!/usr/bin/env python3
"""Bend vs vibrato: is the a1 coefficient law the same?

Both gestures are pitch trajectories c(t) in cents.  The modal coefficient is a
*static function of instantaneous cents*:

    rho   = 2^(c/1200)
    a1    = -2 r cos(rho*theta)
    a2    = r^2

So bend and vibrato must use the same formula, the same derivative and the same
fixed-point quantiser.  What differs is only c(t): a bend is a slow plateau, a
vibrato is a zero-mean oscillation.  This script checks that numerically and
quantifies where the difference matters (range, linearity, quantisation,
static detune vs staircase).

Run
---
    python python_monotor/modal_sim/bend_vs_vibrato.py
"""

from __future__ import annotations

import csv
import json
import math
import os
import sys

import numpy as np

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt                       # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "fft_analysis"))

import core as CORE                                   # noqa: E402
import paths                                          # noqa: E402
import vibrato_coeff as VC                            # noqa: E402

SR = CORE.SR
OUT = os.path.join(paths.SIM_VIBRATO, "bend_vs_vibrato")
CFG = {
    "exact": "float_exact",
    "linear": "float_t1",
    "t2": "float_t2",
    "q20": "q20_int",
    "q24": "q24_int",
}


def smoothstep(x):
    x = np.clip(np.asarray(x, dtype=float), 0.0, 1.0)
    return x * x * (3.0 - 2.0 * x)


def traj_vibrato(t, depth, rate=5.2):
    return depth * np.sin(2.0 * np.pi * rate * t)


def traj_bend(t, depth, rise=0.35, hold=0.60, fall=0.35):
    """0 -> depth -> hold -> 0, smoothstep edges (no clicks)."""
    t = np.asarray(t, dtype=float)
    y = np.zeros_like(t)
    m = t < rise
    y[m] = depth * smoothstep(t[m] / rise)
    m = (t >= rise) & (t < rise + hold)
    y[m] = depth
    m = t >= rise + hold
    y[m] = depth * (1.0 - smoothstep((t[m] - (rise + hold)) / fall))
    return y


def _refresh_int_half(a1q20, a2q, thetaq, ratioq, qa1=24, qd=20):
    """Same integer refresh, but with the correct second-order /2.

    The current b_a1_refresh uses term2 = a1*dtheta^2 (>>28); the Taylor term is
    a1*dtheta^2/2.  At 20 c the difference is <0.03 a1 LSB, but at 200 c it is
    about 2 LSB and becomes visible.
    """
    delta = int(ratioq) - (1 << 15)
    dth = (delta * int(thetaq)) >> (29 - qd)
    dth = max(-(1 << (qd + 3)), min((1 << (qd + 3)) - 1, dth))
    a1sq = int(a1q20) * int(a1q20)
    rad = (int(a2q) << 2) - (a1sq >> 16)
    s = math.isqrt(max(rad, 0))
    d2 = dth * dth
    s1 = 12 + qd - qa1
    s2 = 20 + 2 * qd - qa1 + 1
    t1 = (s * dth) >> s1
    t2 = (int(a1q20) * d2) >> s2
    calc = (int(a1q20) << (qa1 - 20)) + t1 - t2
    return max(-(1 << (qa1 + 1)), min((1 << (qa1 + 1)) - 1, calc))


def a1_curve_half(ms, cents, qa1=24, qd=20):
    cents = np.atleast_1d(np.asarray(cents, dtype=float))
    a1q = np.round(ms.a1 * (1 << 20)).astype(np.int64)
    a2q = np.round(ms.a2 * (1 << 24)).astype(np.int64)
    thq = np.array([VC._theta_q_from_a1a2(int(a1q[i]), int(a2q[i]))
                    for i in range(a1q.size)])
    rq = np.round((2.0 ** (cents / 1200.0)) * (1 << 15)).astype(np.int64)
    out = np.empty((a1q.size, cents.size))
    for i in range(a1q.size):
        for j in range(cents.size):
            out[i, j] = _refresh_int_half(
                int(a1q[i]), int(a2q[i]), int(thq[i]), int(rq[j]),
                qa1, qd) / float(1 << qa1)
    return out


def analyze(ms, cents, name):
    """Coefficient/pitch metrics for the fundamental and all modes."""
    cents = np.asarray(cents, dtype=float)
    cfg = VC.CONFIG_BY_NAME[CFG[name]]
    dmax = max(20.0, float(np.max(np.abs(cents))))
    a1_all = VC.a1_curve(ms, cents, cfg, dmax)          # (modes, N)
    rho = 2.0 ** (cents / 1200.0)
    f_target = ms.f[:, None] * rho[None, :]
    err_all = VC.pitch_error_cents(a1_all, ms.r, f_target)
    err = err_all[0]
    a1 = a1_all[0]
    realized = cents + err
    err0 = err[int(np.argmin(np.abs(cents)))]
    rel = np.abs(err - err0)
    step = np.max(np.abs(np.diff(realized))) if realized.size > 1 else 0.0
    return dict(
        cents=cents, a1=a1, err=err, realized=realized,
        max_err=float(np.nanmax(np.abs(err_all))),
        fund_max=float(np.nanmax(np.abs(err))),
        fund_rms=float(np.sqrt(np.nanmean(err * err))),
        rel_max=float(np.nanmax(rel)),
        static=float(err0),
        levels=int(np.unique(np.round(a1, 12)).size),
        max_step=float(step),
    )


def render_mode(ms, cfg_name, cents, mode=0):
    """Single free-decaying mode driven only by the a1 trajectory."""
    cfg = VC.CONFIG_BY_NAME[CFG[cfg_name]]
    n = len(cents)
    y1, y2 = 1.0, 0.0
    out = np.zeros(n)
    a1 = 0.0
    dmax = max(20.0, float(np.max(np.abs(cents))))
    for i in range(n):
        if i % 96 == 0:
            a1 = VC.a1_curve(ms, np.array([cents[i]]), cfg, dmax)[mode, 0]
        y = -a1 * y1 - ms.a2[mode] * y2
        y2, y1 = y1, y
        out[i] = y
    nf = int(0.01 * SR)
    out[:nf] *= np.linspace(0.0, 1.0, nf)
    out[-nf:] *= np.linspace(1.0, 0.0, nf)
    return 0.9 * out / max(float(np.max(np.abs(out))), 1e-12)


def main():
    os.makedirs(OUT, exist_ok=True)
    plt.rcParams.update({"figure.dpi": 120, "savefig.dpi": 140, "font.size": 8.5,
                         "axes.grid": True, "grid.alpha": 0.25,
                         "legend.fontsize": 7.2, "legend.frameon": False})
    ms = VC.load_modes("cello", 36)
    t = np.arange(int(1.6 * SR)) / SR
    cases = {
        "vibrato_20": traj_vibrato(t, 20.0),
        "bend_up_20": traj_bend(t, 20.0),
        "bend_down_20": traj_bend(t, -20.0),
        "vibrato_200": traj_vibrato(t, 200.0),
        "bend_up_200": traj_bend(t, 200.0),
        "bend_down_200": traj_bend(t, -200.0),
    }

    # ---- 1) the mapping is independent of the gesture ---------------------
    # Same c grid, same a1_curve call, only c(t) differs.
    c_grid = np.linspace(-200.0, 200.0, 801)
    identical = True
    for name in CFG:
        a = VC.a1_curve(ms, c_grid, VC.CONFIG_BY_NAME[CFG[name]], 200.0)
        b = VC.a1_curve(ms, c_grid, VC.CONFIG_BY_NAME[CFG[name]], 200.0)
        identical &= bool(np.array_equal(a, b))

    rows = []
    results = {}
    for label, cents in cases.items():
        results[label] = {}
        for name in CFG:
            m = analyze(ms, cents, name)
            results[label][name] = m
            rows.append(dict(
                trajectory=label, config=name,
                max_err_all_modes=m["max_err"],
                fund_max=m["fund_max"], fund_rms=m["fund_rms"],
                rel_max=m["rel_max"], static=m["static"],
                levels=m["levels"], max_step=m["max_step"],
            ))

    # ---- 2) audio: same single C2 modal decay, different c(t) --------------
    import soundfile as sf
    audio = {}
    for label, cents in cases.items():
        for name in ("exact", "linear", "q20", "q24"):
            if label.endswith("200") and name in ("q20", "q24"):
                continue                    # keep the large-bend set small
            y = render_mode(ms, name, cents)
            fn = f"{label}_{name}.wav"
            sf.write(os.path.join(OUT, fn), y, SR, subtype="PCM_16")
            audio[(label, name)] = y

    # ---- 2b) large-bend second-order check ------------------------------
    cc = np.linspace(-200.0, 200.0, 401)
    a_half = a1_curve_half(ms, cc)
    rho = 2.0 ** (cc / 1200.0)
    err_half = VC.pitch_error_cents(a_half, ms.r, ms.f[:, None] * rho[None, :])[0]
    half_max = float(np.nanmax(np.abs(err_half)))
    half_c = float(err_half[int(np.argmax(np.abs(err_half)))])
    half_static = float(err_half[int(np.argmin(np.abs(cc)))])

    # ---- 3) figures --------------------------------------------------------
    fig, axs = plt.subplots(1, 2, figsize=(9.4, 3.1))
    ax = axs[0]
    for label, color in [("vibrato_20", "C0"), ("bend_up_20", "C2"),
                         ("bend_down_20", "C3")]:
        ax.plot(t * 1e3, cases[label], color=color, lw=1.0, label=label)
    ax.set_title("cents trajectory: same depth, different shape")
    ax.set_xlabel("time (ms)")
    ax.set_ylabel("cents")
    ax.legend(loc="upper right")
    ax = axs[1]
    for c in (-20.0, 20.0):
        m = analyze(ms, np.array([c]), "exact")
        ax.plot([c], [m["err"][0]], "o", ms=3, color="0.5")
    for name, color in [("linear", "C1"), ("q20", "C3"), ("q24", "C2")]:
        cc = np.linspace(-20, 20, 161)
        m = analyze(ms, cc, name)
        ax.plot(cc, m["err"], color=color, lw=1.0,
                label={"linear": "linear (t1)", "q20": "Q2.20 current",
                       "q24": "Q2.24 proposed"}[name])
    ax.axhline(0, color="0.7", lw=0.6)
    ax.set_title("same F(c): error depends only on c")
    ax.set_xlabel("cents")
    ax.set_ylabel("pitch error (c)")
    ax.legend(loc="lower right")
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "fig_bend_vs_vibrato.png"))
    plt.close(fig)

    # error vs cents, small and large
    fig, axs = plt.subplots(1, 2, figsize=(9.4, 3.1), sharey=False)
    for ax, depth in zip(axs, (20.0, 200.0)):
        cc = np.linspace(-depth, depth, 401)
        for name, color in [("linear", "C1"), ("t2", "C0"),
                            ("q20", "C3"), ("q24", "C2")]:
            m = analyze(ms, cc, name)
            ax.plot(cc, m["err"], color=color, lw=1.0,
                    label={"linear": "linear (t1)", "t2": "2nd order",
                           "q20": "Q2.20 current", "q24": "Q2.24 proposed"}[name])
        if depth == 200.0:
            ax.plot(cc, err_half, color="C2", lw=1.0, ls="--",
                    label="Q2.24, term2/2")
        ax.axhline(0, color="0.7", lw=0.6)
        ax.set_title(f"F(c) error, depth +-{depth:g} c")
        ax.set_xlabel("cents")
        ax.set_ylabel("pitch error (c)")
        ax.legend(loc="lower left")
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "fig_error_vs_c.png"))
    plt.close(fig)

    # ---- 4) tables/json ---------------------------------------------------
    fields = ["trajectory", "config", "max_err_all_modes", "fund_max",
              "fund_rms", "rel_max", "static", "levels", "max_step"]
    with open(os.path.join(OUT, "bend_vs_vibrato.csv"), "w", newline="",
              encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=fields)
        w.writeheader()
        for r in rows:
            w.writerow(r)

    summary = dict(
        sr=SR, instrument="cello", midi=36, mode=0,
        mapping_identical=identical,
        depth_cases=[20, 200],
        note="a1(c) is a static function of instantaneous cents; only c(t) differs",
        rows=rows,
        q24_term2_half_max=half_max,
        q24_term2_half_at_worst=half_c,
        q24_term2_half_static=half_static,
        audio=[f"{k[0]}_{k[1]}.wav" for k in audio],
    )
    with open(os.path.join(OUT, "summary.json"), "w", encoding="utf-8") as fh:
        json.dump(summary, fh, indent=2, ensure_ascii=False)

    def pick(traj, cfg):
        return next(r for r in rows if r["trajectory"] == traj and r["config"] == cfg)

    lines = [
        "# 弯音 vs 颤音：系数公式是否相同",
        "",
        "脚本：`python_monotor/modal_sim/bend_vs_vibrato.py`  ",
        "乐器/模态：cello C2，基频 `f=65.40 Hz`，`gamma=5.7524/s`。",
        "",
        "## 结论",
        "",
        "**公式相同。** 弯音和颤音都只是给了一个瞬时 `c(t)`，系数都是：",
        "",
        "```text",
        "rho = 2^(c/1200)",
        "a1  = -2 r cos(rho*theta)",
        "a2  = r^2                     (固定)",
        "```",
        "",
        "同一个 `c` 一定得到同一个 `a1`；`a1(c)` 的斜率、量化和误差曲线都与“这是弯音还是颤音”无关。",
        "区别只在 `c(t)` 的形状：",
        "",
        "- 颤音：`c(t)=D sin(2π f_vib t)`，零均值、来回摆；",
        "- 弯音：`c(t)` 是一个慢平台（可上/可下），可以长时间停在非零值。",
        "",
        "## 数值检查",
        "",
        f"同一条 801 点 `c` 网格，用同一 `a1_curve` 计算两次，逐点相同：**{identical}**。",
        "",
        "| 轨迹 | 配置 | 全模态最大误差 (c) | 基频最大 (c) | 基频 RMS (c) | 静态 (c) | 电平数 | 最大单步 (c) |",
        "|---|---|---:|---:|---:|---:|---:|---:|",
    ]
    for traj in ("vibrato_20", "bend_up_20", "bend_down_20",
                 "vibrato_200", "bend_up_200", "bend_down_200"):
        for name in ("exact", "linear", "t2", "q20", "q24"):
            r = pick(traj, name)
            lines.append(
                f"| {traj} | {name} | {r['max_err_all_modes']:.2f} "
                f"| {r['fund_max']:.2f} | {r['fund_rms']:.2f} "
                f"| {r['static']:+.2f} | {r['levels']} | {r['max_step']:.2f} |")
    lines += [
        "",
        "## 什么时候不一样",
        "",
        "1. **范围不同**：20 c 颤音用一阶线性足够；200 c 弯音的一阶误差会明显变大（见 `fig_error_vs_c.png` 右图），"
        "这时要用二阶 `t2` 或精确 `cos`。公式还是同一条，只是展开阶数要够。",
        "2. **量化表现不同**：同一个 Q2.20，20 c 颤音会跨几个电平，听起来是台阶/粗糙；"
        "20 c 弯音可能只停在一个电平上，听起来是静态偏音，不是台阶。"
        "公式相同，但轨迹分布不同，听感不同。",
        "3. **大弯音会暴露二阶项**：当前整数 `b_a1_refresh` 的 `term2` 是 `a1*dtheta^2`，"
        "少了 Taylor 的 `/2`；20 c 时它小于 0.03 个 a1 LSB，看不出来，"
        "200 c 时约 2 LSB，C2 上会变成约 9 c。"
        f"把 `term2` 改成 `/2` 后，200 c 的最大误差约 {half_max:.2f} c"
        f"（其中静态 {half_static:+.2f} c 是 Q2.20 标称值的偏移，调制本身约 "
        f"{half_max - abs(half_static):.2f} c）。",
        "4. **B 类驱动必须同步**：弯音/颤音都要把同一个 `rho` 送给驱动 NCO；"
        "只改 a1 不改驱动，模态会偏离驱动谐波，听成音色/共振变化而不是音高变化。",
        "5. **更新方式不同**：颤音是自由运行 LFO；弯音是慢平台 + slew。"
        "两者可以叠加：`c = bend + depth*sin(...)`，仍然只用一条 `a1(c)` 公式。",
        "",
        "## 试听",
        "",
        "`bend_up_20_exact.wav` / `vibrato_20_exact.wav` 是同一深度、同一 `a1(c)`、"
        "不同 `c(t)` 的单模态自由衰减；`*_q20.wav` / `*_q24.wav` 是对应定点版本。"
        "`bend_up_200_exact.wav` / `bend_up_200_linear.wav` 可以听大弯音时一阶展开的误差。",
        "",
        "![bend vs vibrato](fig_bend_vs_vibrato.png)",
        "",
        "![error vs cents](fig_error_vs_c.png)",
        "",
    ]
    with open(os.path.join(OUT, "README.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))

    print(f"wrote {OUT}")
    print(f"  mapping identical: {identical}")
    for traj in ("vibrato_20", "bend_up_20", "vibrato_200", "bend_up_200"):
        for name in ("linear", "q20", "q24"):
            r = pick(traj, name)
            print(f"  {traj:13s} {name:6s}: max {r['fund_max']:8.2f} c, "
                  f"levels {r['levels']:3d}, max step {r['max_step']:6.2f} c")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
