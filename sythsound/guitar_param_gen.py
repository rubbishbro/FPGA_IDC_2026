#!/usr/bin/env python
"""guitar_param_gen.py -- 吉他调制参数表（与 guitar_coeff_gen 同一硬件域，浮点）.

``guitar_coeff_gen.gen_coeff7`` 输出的不是纯物理域，而是**已经缩放**的硬件域系数：

    a12 = es * w0 / wd        # = k * (es/wd),  k = w0 = 2*pi*n*f0
    a21 = -es * w0 / wd       # = -a12（a21 约定为负）
    a11, a22 不变
    gq  = gq_phys * sq
    wo  = wo_phys / sq        # sq 由 gen_coeff7 里的循环按 |wo/sq|<1、|gq*sq|<1 选
    gv  = 0

所以本文件的静态系数直接取 ``gen_coeff7`` 的输出；调制灵敏度必须在这个
**已缩放域**里推：

    S11  = d*rho*(-theta*s + g*(theta*c - s))
    S22  = d*rho*(-theta*s - g*(theta*c - s))
    S12  = w0 * (d*rho/wd)*(theta*c - s)          # 乘 k = w0
    S21  = -2*a12 - S12                          # 因为 a21 = -alpha^2*a12
    Swo  = -2*wo                                 # sim_guitar: wo = wo0/alpha^2
    Sgq = Sgv = 0

运行时（已缩放域）：``a11 = a11_0 + lambda*S11``，其余同理。
``gq/gv`` 不随调制变化，不输出（它们由系数生成器负责）。

输出格式与旧版一致（``midi`` 头 + ``mode`` 行，逗号分隔浮点）::

    midi40
    mode0:a11,a12,a21,a22,wo,S11,S22,S12,S21,Swo
    mode1:...
    ...
    midi41
    ...

其中 a12/a21、S12/S21、wo/Swo 都是 ``guitar_coeff_gen`` 的缩放域，可直接
和系数表对齐；a11/a22、S11/S22 不受缩放影响。

用法::

    python sythsound/guitar_param_gen.py                  # 40..79，写 guitar_param.txt
    python sythsound/guitar_param_gen.py --midi 45,55,76  # 指定音
    python sythsound/guitar_param_gen.py --verify         # 打印一阶误差
"""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

import numpy as np

# guitar_coeff_gen 与本文件同目录；直接复用它的缩放系数和 sq 选择
sys.path.insert(0, str(Path(__file__).resolve().parent))
from guitar_coeff_gen import gen_coeff7  # noqa: E402

FS = 48000.0
DT = 1.0 / FS
OMEGA_D_FLOOR = 1e-5
MODE_N = 20

# 物理桥力方向：弦张力 T 变 alpha 倍时，桥力 T/L 也变 alpha 倍，
# 而模态权重 wo 里带 (T/L) 的平方根关系 -> wo ~ alpha^2，所以 Swo = +2*wo。
# （sim_guitar 里写的是 wo = wo0/alpha^2，那是他们那版把 alpha 定义反过来用了；
#   按物理桥力这个方向定 +1。）
WO_SIGN = +1

FIELD_ORDER = ("a11", "a12", "a21", "a22", "wo",
               "S11", "S22", "S12", "S21", "Swo")

# sythsound/sim_guitar.py::guitar_generator 的阻尼查找表
DAMP_BIN_HZ = (93.96, 122.52, 159.75, 208.30, 271.60, 354.15,
               461.78, 602.11, 785.10, 1023.70, 1334.82, 1740.49)
DAMP_BIN_LN_GAMMA = (0.2148, -0.6427, -0.0040, 0.5375, 0.2490, -0.1477,
                     0.5102, 0.6994, float("nan"), float("nan"), 0.4489, 1.1248)


def string_params(midi: int):
    """返回 (f0, L, TLr, pos, gamma[0..MODE_N-1])，与 sim_guitar 一致。"""
    assert 40 <= midi <= 80
    if midi < 45:
        midi0, t, damp_scale = 40, 115.7, 0.7904
    elif midi < 50:
        midi0, t, damp_scale = 45, 133.4, 0.8145
    elif midi < 55:
        midi0, t, damp_scale = 50, 133.4, 0.8793
    elif midi < 59:
        midi0, t, damp_scale = 55, 133.4, 1.1734
    elif midi < 64:
        midi0, t, damp_scale = 59, 102.3, 1.3362
    else:
        midi0, t, damp_scale = 64, 102.3, 1.3023

    L = 0.6477 * 2.0 ** ((midi0 - midi) / 12.0)
    f0 = 440.0 * 2.0 ** ((midi - 69) / 12.0)

    mode = np.arange(1, MODE_N + 1, 1.0)
    ln_hz = np.log(np.asarray(DAMP_BIN_HZ))
    ln_g = np.asarray(DAMP_BIN_LN_GAMMA)
    ok = np.isfinite(ln_g)
    gamma = 1.3 * damp_scale * np.exp(
        np.interp(np.log(mode * f0), ln_hz[ok], ln_g[ok])
    )
    return f0, L, t / L, 0.14 / L, gamma


def coeffs(f0: float, TLr: float, pos: float, gamma: float, n: int, alpha: float):
    """纯物理域系数（只用于 --verify 的精确参照）。"""
    w0 = alpha * 2.0 * math.pi * n * f0
    wd = math.sqrt(max(w0 * w0 - gamma * gamma, OMEGA_D_FLOOR))
    d = math.exp(-gamma * DT)
    c = math.cos(wd * DT)
    s = math.sin(wd * DT)

    a11 = d * (c + gamma * s / wd)
    a12 = d * s / wd
    a21 = -(w0 * w0) * a12
    a22 = d * (c - gamma * s / wd)
    # 物理桥力方向：桥力 T/L 随张力线性变，而 wo 里带 (T/L) 的关系 -> wo ~ alpha^2
    # （注意 sythsound/sim_guitar.py 里写的是 /alpha^2，那是另一套 alpha 定义；
    #   这里和 WO_SIGN=+1 保持一致，否则 --verify 永远差 2%）
    wo = n * ((-1.0) ** n) * TLr * (alpha * alpha)
    return dict(w0=w0, a11=a11, a12=a12, a21=a21, a22=a22, wo=wo)


def sensitivities(f0: float, gamma: float, n: int):
    """物理域的一阶灵敏度（a12 在缩放域里再乘 k）。"""
    w0 = 2.0 * math.pi * n * f0
    wd = math.sqrt(max(w0 * w0 - gamma * gamma, OMEGA_D_FLOOR))
    d = math.exp(-gamma * DT)
    theta = wd * DT
    c = math.cos(theta)
    s = math.sin(theta)
    g = gamma / wd
    rho = (w0 * w0) / (wd * wd)

    S11 = d * rho * (-theta * s + g * (theta * c - s))
    S22 = d * rho * (-theta * s - g * (theta * c - s))
    S12 = (d * rho / wd) * (theta * c - s)
    return S11, S22, S12


def _check_first_order(f0, TLr, pos, gamma, n, k, sq, base, lam):
    """用 alpha=1+lam 的精确缩放域系数检查一阶公式。"""
    q = coeffs(f0, TLr, pos, gamma, n, 1.0 + lam)
    exact = dict(a11=q["a11"], a12=q["a12"] * k, a21=q["a21"] / k,
                 a22=q["a22"], wo=q["wo"] / sq)
    pred = dict(
        a11=base["a11"] + lam * base["S11"],
        a12=base["a12"] + lam * base["S12"],
        a21=base["a21"] + lam * base["S21"],
        a22=base["a22"] + lam * base["S22"],
        wo=base["wo"] + lam * base["Swo"],
    )
    err = 0.0
    for name in ("a11", "a12", "a21", "a22", "wo"):
        den = max(abs(exact[name]), 1e-12)
        err = max(err, abs(pred[name] - exact[name]) / den)
    return err


def gen_slot(midi: int, verify: bool = False):
    f0, L, TLr, pos, gamma_all = string_params(midi)

    # 直接复用 guitar_coeff_gen 的缩放域静态系数（含 sq 选择）
    a11, a12, a21, a22, gq, gv, wo = gen_coeff7(
        f0, TLr, gamma_all, MODE_N, pos)

    rows = []
    max_rel = 0.0
    for i in range(MODE_N):
        n = i + 1
        gamma = float(gamma_all[i])

        a11h = float(a11[i])
        a12h = float(a12[i])
        a21h = float(a21[i])
        a22h = float(a22[i])
        woh = float(wo[i])

        if a21h >= 0.0:
            raise SystemExit(f"midi{midi} mode{i}: a21 不是负数")
        if abs(a21h + a12h) > 1e-12 * max(1.0, abs(a12h)):
            raise SystemExit(
                f"midi{midi} mode{i}: a21({a21h:.9g}) != -a12({-a12h:.9g})")

        k = 2.0 * math.pi * n * f0
        S11, S22, S12_phys = sensitivities(f0, gamma, n)
        # a12 的缩放域系数是 k*a12_phys，而 **k = omega0 本身随 alpha 变**（k' = k）。
        #   原来只写了 S12h = k*S12_phys，漏了 +a12 这一项；而 a12_phys = es*sin(theta)/wd
        #   的 alpha 依赖几乎完全抵消（theta*cos - sin ≈ -theta^3/3），于是
        #   S12/a12 只有 1e-5 量级 -> 揉弦只有音量起伏（颤音 tremolo），没有音高起伏。
        #   补上 (k*a12_phys)' = a12 + k*S12_phys 之后，a12' ≈ sin(theta*alpha)，
        #   才是真正的揉弦（mode0 在 lambda=0.0156 时约 +27 音分）。
        S12h = a12h + k * S12_phys
        S21h = -S12h                       # a21 = -a12，导数直接取负
        Swoh = WO_SIGN * 2.0 * woh

        base = dict(a11=a11h, a12=a12h, a21=a21h, a22=a22h, wo=woh,
                    S11=S11, S22=S22, S12=S12h, S21=S21h, Swo=Swoh)

        if verify:
            wo_phys = n * ((-1.0) ** n) * TLr
            sq = wo_phys / woh if abs(woh) > 1e-30 else 1.0
            max_rel = max(max_rel, _check_first_order(
                f0, TLr, pos, gamma, n, k, sq, base, lam=0.005))

        rows.append(dict(midi=midi, mode=i, n=n, base=base))

    return f0, rows, max_rel


def parse_midi(s: str) -> list[int]:
    out: list[int] = []
    for part in s.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-", 1)
            out.extend(range(int(a), int(b) + 1))
        else:
            out.append(int(part))
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--midi", default="40-79", help="40-79 或 45,55,76")
    ap.add_argument("--out", default=str(Path(__file__).resolve().parent / "guitar_param.txt"))
    ap.add_argument("--verify", action="store_true", help="打印一阶公式 vs 精确系数的误差")
    args = ap.parse_args(argv)

    midi_list = parse_midi(args.midi)
    out = Path(args.out)

    lines: list[str] = []
    overall = 0.0
    for midi in midi_list:
        f0, rows, max_rel = gen_slot(midi, verify=args.verify)
        overall = max(overall, max_rel)
        lines.append(f"midi{midi}")
        for r in rows:
            vals = [r["base"][name] for name in FIELD_ORDER]
            lines.append(f"mode{r['mode']}:" + ",".join(f"{v:.12g}" for v in vals))
        lines.append("")

    with open(out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines).rstrip("\n") + "\n")
    print(f"wrote {out} ({len(midi_list)} midi x {MODE_N} modes)")
    if args.verify:
        print(f"first-order max relative error (lambda=0.005): {overall:.3e}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
