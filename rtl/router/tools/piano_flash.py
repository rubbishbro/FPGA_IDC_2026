#!/usr/bin/env python
"""piano_flash.py -- 把 sythsound/piano_coeff.txt 打成 weight_loader 能读的 flash 镜像。

**一个 slot 一个 MIDI 音**（loader 是"每个声部一张表"，见 README §4.1），
这样 16 个声部就是 16 个音高。

系数要过两道转换：

1. **sq/sv 归一化**（`piano_coeff_gen.py` 没做，README §4.5 有推导）：
   设 q_s = sq*q、v_s = sv*v、k = sq/sv，则

       a11' = a11        a22' = a22
       a12' = a12 * k    a21' = a21 / k        （a12'*a21' 不变）
       gq'  = gq  * sq   gv'  = gv * sq / k    （= gv*sv）
       wo'  = wo  / sq

   挑 k = sqrt(a21/a12) = omega0（rad/s）-> a12'、a21' 都变成 sqrt(a12*a21) =
   omega0*dt（归一化角频率，O(1)）；再挑一个 2 的幂的 sq 让 gq/gv/wo 都落在
   各自的 Q 范围里。

2. **量化到 Q 整数**（`modal_step_pkg.sv` 的 SH_*）：

       a11 Q28   a12 Q30   a21 Q23   a22 Q28   gq Q31   gv Q27   wo Q15

`sythsound/piano_coeff.txt` 的格式（`piano_coeff_gen.py` 打印的）：

    midi40
    mode0:<a11>,<a12>,<a21>,<a22>,<gq>,<gv>,<wo>
    mode1:...
    (空行)
    midi41
    ...

每个音 2*32 = 64 条 mode（每对是微失谐的一对），正好对上 N_MODES=64。
钢琴没有揉弦（`mod_router` 对钢琴 en=0），调制参数表（pm）整片填 0。

用法::

    python rtl/router/tools/piano_flash.py                 # 默认 16 个音，写 .bin + .mem
    python rtl/router/tools/piano_flash.py --midi 40,45,50 # 指定音
    python rtl/router/tools/piano_flash.py --sq 512        # 手动指定 sq（默认自动挑 2 的幂）
    python rtl/router/tools/piano_flash.py --raw           # 不做归一化（对比用）
"""

from __future__ import annotations

import argparse
import math
import struct
import sys
from pathlib import Path

_HERE = Path(__file__).resolve().parent
_REPO = _HERE.parent.parent.parent          # rtl/router/tools -> 仓根
sys.path.insert(0, str(_HERE))

from flash_image import REC_BYTES, record, image   # noqa: E402

SH = dict(a11=28, a12=30, a21=23, a22=28, gq=31, gv=27, wo=15)
FIELDS = ("a11", "a12", "a21", "a22", "gq", "gv", "wo")
PM_FIELDS = ("c0", "s0", "gam", "theta0", "g", "k12", "k21")
INT32 = (-(1 << 31), (1 << 31) - 1)

SLOTS = 16
MODES_DEFAULT = 64
INST_DEFAULT = 0          # = router_pkg::INST_PIANO（枚举改了就跟这里改）
DEFAULT_MIDI = [40, 42, 44, 46, 48, 50, 52, 54, 56, 58, 60, 62, 64, 67, 71, 76]

CLAMPED = {k: 0 for k in FIELDS}
PEAK = {k: 0 for k in FIELDS}
PEAK_RAW = {k: 0.0 for k in FIELDS}


def parse(path: Path) -> dict[int, list[dict]]:
    out: dict[int, list[dict]] = {}
    cur = None
    with path.open("r", encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            if line.startswith("midi"):
                cur = int(line[4:])
                out[cur] = []
            elif line.startswith("mode"):
                _, rest = line.split(":", 1)
                vals = [float(x) for x in rest.split(",")]
                if len(vals) != len(FIELDS):
                    raise SystemExit(f"字段数不对: {line[:60]}")
                if cur is None:
                    raise SystemExit("mode 行出现在 midi 行之前")
                out[cur].append(dict(zip(FIELDS, vals)))
    return out


def pick_sq(co: dict, k: float) -> float:
    """状态定标 sq 取 ~k（等价于 sv = sq/k ≈ 1），再夹进 Q 范围。

    为什么是 sv≈1：状态是 s8.24（|state| < 128）。一次击弦注入的速度约
        v ≈ gv * N_pulse * x_max      （x_max = 250<<20/2^28 ≈ 0.98）
    若 sv 取大（比如 sq=2048 时 sv≈4），v 会到 286 -> **超出 s8.24 饱和**，
    状态就变成单调爬升（直流）而不是振荡。sv≈1 时 v≈72、q≈v/ω0≈0.14，都在
    范围里还有余量，所以 sq = k 是这套 Q 格式下的自然选择。

    然后仍要过一遍 Q 范围：
        |gq*sq| < 1 (Q31)  |gv*sq/k| < 16 (Q27)  |wo/sq| < 65536 (Q15)
    """
    sq = max(1.0, 2.0 ** round(math.log2(max(k, 1e-9))))       # ≈ k -> sv ≈ 1
    lim_gq = 1.0 / abs(co["gq"]) if co["gq"] else float("inf")
    lim_gv = 16.0 * k / abs(co["gv"]) if co["gv"] else float("inf")
    # 只用到 Q 范围的一半，留余量（正好压边界会四舍五入到饱和）
    return max(1.0, min(sq, math.floor(0.5 * min(lim_gq, lim_gv))))


def scale_mode(co: dict, sq_user: float) -> tuple[dict, float, float]:
    """物理域 -> 硬件域；返回 (scaled, k, sq)。"""
    a12, a21 = co["a12"], co["a21"]
    if a12 == 0.0 or a21 == 0.0:
        k = 1.0
    else:
        # 注意 a21 是负的（回复力项），k 只用幅值；a21' = a21/k 仍然带负号
        k = math.sqrt(abs(a21) / abs(a12))
    sq = float(sq_user) if sq_user else pick_sq(co, k)
    out = dict(co)
    out["a12"] = a12 * k
    out["a21"] = a21 / k
    out["gq"] = co["gq"] * sq
    out["gv"] = co["gv"] * sq / k
    out["wo"] = co["wo"] / sq
    return out, k, sq


def check_state(co: dict, sq: float, k: float, n_pulse: int = 5, x_max: float = 0.976,
                n_samp: int = 4000) -> tuple[float, float]:
    """按递推 `q' = a11 q + a12 v + gq x`、`v' = a21 q + a22 v + gv x` 跑一遍，
    返回 (peak|q_s|, peak|v_s|)，单位是 Q24 的"1.0"（>128 就饱和了）。"""
    a11, a12, a21, a22 = co["a11"], co["a12"] * k, co["a21"] / k, co["a22"]
    sv = sq / k
    gq, gv = co["gq"] * sq, co["gv"] * sv
    q = v = 0.0
    pq = pv = 0.0
    for i in range(n_samp):
        x = x_max if i < n_pulse else 0.0
        q, v = (a11 * q + a12 * v + gq * x,
                a21 * q + a22 * v + gv * x)
        pq = max(pq, abs(q)); pv = max(pv, abs(v))
    return pq, pv


def to_int(v: float, sh: int, field: str) -> int:
    i = int(round(v * (1 << sh)))
    lo, hi = INT32
    if i < lo:
        i = lo
        CLAMPED[field] += 1
    elif i > hi:
        i = hi
        CLAMPED[field] += 1
    PEAK[field] = max(PEAK[field], abs(i))
    PEAK_RAW[field] = max(PEAK_RAW[field], abs(v))
    return i


def build(table, midi_list, n_modes: int, sq_user: float, raw: bool):
    if len(midi_list) != SLOTS:
        raise SystemExit(f"midi 列表要给 {SLOTS} 个音（现在是 {len(midi_list)}）")
    out = bytearray()
    k_first = float("nan")
    sq_first = float("nan")
    for slot, midi in enumerate(midi_list):
        modes = table.get(midi)
        if modes is None:
            raise SystemExit(f"表里没有 midi{midi}")
        if len(modes) < n_modes:
            raise SystemExit(f"midi{midi} 只有 {len(modes)} 个 mode，要 {n_modes}")
        for m in range(n_modes):
            if raw:
                sm, k, sq = modes[m], 1.0, 1.0
            else:
                sm, k, sq = scale_mode(modes[m], sq_user)
            if slot == 0 and m == 0:
                k_first, sq_first = k, sq
            co = {f: to_int(sm[f], SH[f], f) for f in FIELDS}
            pm = {f: 0 for f in PM_FIELDS}
            out += record(co, pm)
    assert len(out) == SLOTS * n_modes * REC_BYTES
    return bytes(out), k_first, sq_first


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--coeff", default=str(_REPO / "sythsound" / "piano_coeff.txt"))
    ap.add_argument("--out", default=str(_HERE / "piano_flash.bin"))
    ap.add_argument("--mem", default=str(_HERE / "piano_flash.mem"))
    ap.add_argument("--inst", type=int, default=INST_DEFAULT)
    ap.add_argument("--modes", type=int, default=MODES_DEFAULT)
    ap.add_argument("--midi", default="", help="逗号分隔的 16 个 MIDI 音")
    ap.add_argument("--sq", type=float, default=0.0, help="状态定标 sq（0 = 自动挑 2 的幂）")
    ap.add_argument("--raw", action="store_true", help="不做 sq/sv 归一化（只用来对比）")
    args = ap.parse_args(argv)

    midi_list = ([int(x) for x in args.midi.split(",")] if args.midi else DEFAULT_MIDI)
    table = parse(Path(args.coeff))
    print(f"[piano_flash] 读到 {len(table)} 个音（{min(table)}..{max(table)}），"
          f"每个 {len(next(iter(table.values())))} 个 mode")

    tbl, k0, sq0 = build(table, midi_list, args.modes, args.sq, args.raw)
    img = image({args.inst: tbl})
    Path(args.out).write_bytes(img)
    with open(args.mem, "w", encoding="utf-8", newline="\n") as fh:
        for b in img:
            fh.write(f"{b:02X}\n")

    print(f"[piano_flash] {'未归一化(--raw)' if args.raw else 'sq/sv 归一化'}: "
          f"第一个模态 k=sqrt(a21/a12)={k0:.6g}（= omega0 rad/s），sq={sq0:.6g}")

    def check(slot: int):
        midi = midi_list[slot]
        base = args.inst * len(tbl) + (slot * args.modes + 0) * REC_BYTES
        rec = img[base:base + REC_BYTES]
        a11, a12, a21, a22, gq, gv, wo = (struct.unpack(">i", rec[4 * i:4 * i + 4])[0]
                                          for i in range(7))
        print(f"    slot{slot:2d} midi{midi}: a11={a11 / 2**28:+.5f} a12={a12 / 2**30:+.6f} "
              f"a21={a21 / 2**23:+.5f} a22={a22 / 2**28:+.5f} "
              f"gq={gq / 2**31:+.4e} gv={gv / 2**27:+.4f} wo={wo / 2**15:+.5f}")

    print("[piano_flash] 量化余量（|整数|峰值 / 2^31，超了会被饱和）：")
    for f in FIELDS:
        flag = "   <-- 有饱和" if CLAMPED[f] else ""
        print(f"    {f:4s} Q{SH[f]:2d}  峰值 float={PEAK_RAW[f]:12.4g}  "
              f"整数={PEAK[f]:11d}  占比={PEAK[f] / (1 << 31):6.1%}  饱和 {CLAMPED[f]} 次{flag}")
    print(f"[piano_flash] 每乐器 {len(tbl)} 字节（{SLOTS} slot x {args.modes} mode x {REC_BYTES} B）")
    check(0)
    check(len(midi_list) - 1)
    print(f"[piano_flash] 镜像 {len(img)} 字节 -> {args.out}")
    print(f"[piano_flash] $readmemh 字节文件 -> {args.mem}")
    print(f"[piano_flash] 烧写地址：0x{args.inst * len(tbl):06X}（= inst x TABLE_BYTES）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
