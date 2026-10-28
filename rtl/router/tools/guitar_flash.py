#!/usr/bin/env python
"""guitar_flash.py -- 把吉他的**系数表 + 调制参数表**打成 weight_loader 能读的 flash 镜像。

一个 slot 一个 MIDI 音（和 `piano_flash.py` 同一套布局，记录 64 字节）：

    +0  a11   +4  a12   +8  a21   +12 a22      <- 系数表（guitar_coeff_scaled.txt）
    +16 gq    +20 gv    +24 wo    +28 保留(0)
    +32 a11_0 +36 a12_0 +40 a22_0 +44 wo_0     <- 参数表（guitar_param.txt 的 base 列）
    +48 s11   +52 s12   +56 s22   +60 swo      <- 参数表（同一份文件的 S 列）

参数表只存 4 个基值 + 4 个斜率：`a21 = -a12`、`S21 = -2*a12 - S12` 都由 RTL/生成器
现算（见 `router_pkg::mod_par_t`）。

Q（必须和 `modal_step_pkg` 的 SH_* 一致）：
    系数表：a11 Q28 / a12 Q30 / a21 Q23 / a22 Q28 / gq Q35 / gv Q34 / wo Q29
    参数表：a11_0 Q28 / a12_0 Q30 / a22_0 Q28 / wo_0 Q29
            s11/s12/s22/swo 一律 **Q29**（整表 |S| ≤ 1.7，±4 还留 2× 余量）

用法::

    python rtl/router/tools/guitar_flash.py                     # 出 .bin + .mem
    python rtl/router/tools/guitar_flash.py --verify            # 只检查量化余量
    python rtl/router/tools/guitar_flash.py --midi 40,45,50     # 指定音
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

_HERE = Path(__file__).resolve().parent
_REPO = _HERE.parent.parent.parent
sys.path.insert(0, str(_HERE))

from flash_image import FIELDS_CO, FIELDS_PM, REC_BYTES, image, record   # noqa: E402

# 系数表字段的 Q（和 piano_flash.py 同一套）
SH_CO = dict(a11=28, a12=30, a21=23, a22=28, gq=32, gv=34, wo=29)
# 参数表的 Q
SH_PM = dict(a11_0=28, a12_0=30, a22_0=28, wo_0=29,
             s11=29, s12=29, s22=29, swo=29)

SLOTS = 16
MODES_DEFAULT = 64          # flash 布局固定 64 条/slot（loader 按 N_MODES 读），吉他实际只用前 20
INST_DEFAULT = 1            # = router_pkg::INST_GUITAR
DEFAULT_MIDI = [40, 42, 44, 46, 48, 50, 52, 54, 56, 58, 60, 62, 64, 67, 71, 76]

CO_FIELDS = ("a11", "a12", "a21", "a22", "gq", "gv", "wo")
PARAM_FIELDS = ("a11", "a12", "a21", "a22", "wo", "S11", "S22", "S12", "S21", "Swo")


def parse_table(path: Path, fields) -> dict[int, list[dict]]:
    out: dict[int, list[dict]] = {}
    cur = None
    for line in path.open("r", encoding="utf-8", errors="ignore"):
        line = line.strip()
        if not line:
            continue
        if line.startswith("midi"):
            cur = int(line[4:])
            out[cur] = []
        elif line.startswith("mode"):
            _, rest = line.split(":", 1)
            vals = [float(x) for x in rest.split(",")]
            if len(vals) != len(fields):
                raise SystemExit(f"{path.name}: 字段数 {len(vals)} != {len(fields)}: {line[:50]}")
            out[cur].append(dict(zip(fields, vals)))
    return out


CLAMPED = {k: 0 for k in list(SH_CO) + list(SH_PM)}
PEAK = {k: 0 for k in list(SH_CO) + list(SH_PM)}
INT32 = (-(1 << 31), (1 << 31) - 1)


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
    return i


def build(co_tbl, pm_tbl, midi_list, n_modes: int) -> bytes:
    if len(midi_list) != SLOTS:
        raise SystemExit(f"midi 列表要给 {SLOTS} 个音")
    out = bytearray()
    for midi in midi_list:
        co = co_tbl.get(midi)
        pm = pm_tbl.get(midi)
        if co is None or pm is None:
            raise SystemExit(f"表里没有 midi{midi}")
        for m in range(n_modes):
            if m >= len(co):
                # 表里只有 20 个模态：其余补 0（引擎按 n_modes_of 只读前 20 条）
                out += record({f: 0 for f in CO_FIELDS},
                              {f: 0 for f in FIELDS_PM})
                continue
            c = {f: to_int(co[m][f], SH_CO[f], f) for f in CO_FIELDS}
            p = {
                "a11_0": to_int(pm[m]["a11"], SH_PM["a11_0"], "a11_0"),
                "a12_0": to_int(pm[m]["a12"], SH_PM["a12_0"], "a12_0"),
                "a22_0": to_int(pm[m]["a22"], SH_PM["a22_0"], "a22_0"),
                "wo_0":  to_int(pm[m]["wo"],  SH_PM["wo_0"],  "wo_0"),
                "s11":   to_int(pm[m]["S11"], SH_PM["s11"],   "s11"),
                "s12":   to_int(pm[m]["S12"], SH_PM["s12"],   "s12"),
                "s22":   to_int(pm[m]["S22"], SH_PM["s22"],   "s22"),
                "swo":   to_int(pm[m]["Swo"], SH_PM["swo"],   "swo"),
            }
            out += record(c, p)
    assert len(out) == SLOTS * n_modes * REC_BYTES
    return bytes(out)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--coeff", default=str(_REPO / "sythsound" / "guitar_coeff_scaled.txt"))
    ap.add_argument("--param", default=str(_REPO / "sythsound" / "guitar_param.txt"))
    ap.add_argument("--out", default=str(_HERE / "guitar_flash.bin"))
    ap.add_argument("--mem", default=str(_HERE / "guitar_flash.mem"))
    ap.add_argument("--inst", type=int, default=INST_DEFAULT)
    ap.add_argument("--modes", type=int, default=MODES_DEFAULT)
    ap.add_argument("--midi", default="", help="逗号分隔的 16 个 MIDI 音")
    ap.add_argument("--verify", action="store_true")
    args = ap.parse_args(argv)

    midi_list = ([int(x) for x in args.midi.split(",")] if args.midi else DEFAULT_MIDI)
    co_tbl = parse_table(Path(args.coeff), CO_FIELDS)
    pm_tbl = parse_table(Path(args.param), PARAM_FIELDS)
    print(f"[guitar_flash] 系数表 {Path(args.coeff).name}: {len(co_tbl)} 音 x "
          f"{len(next(iter(co_tbl.values())))} 模态；参数表 {Path(args.param).name}: "
          f"{len(pm_tbl)} 音 x {len(next(iter(pm_tbl.values())))} 模态")

    tbl = build(co_tbl, pm_tbl, midi_list, args.modes)

    print("[guitar_flash] 量化余量（|整数| / 2^31）：")
    ok = True
    for f in list(SH_CO) + list(SH_PM):
        q = SH_CO.get(f, SH_PM.get(f))
        flag = "   <-- 有饱和" if CLAMPED[f] else ""
        ok &= (CLAMPED[f] == 0)
        print(f"    {f:6s} Q{q:2d}  峰值={PEAK[f]:11d}  占比={PEAK[f] / (1 << 31):6.1%}"
              f"  饱和 {CLAMPED[f]} 次{flag}")
    if args.verify:
        print("[guitar_flash] --verify：不写文件")
        return 0 if ok else 1

    img = image({args.inst: tbl})
    Path(args.out).write_bytes(img)
    with open(args.mem, "w", encoding="utf-8", newline="\n") as fh:
        for b in img:
            fh.write(f"{b:02X}\n")

    # 回读自检：slot0 的第一条记录
    base = args.inst * len(tbl)
    rec = img[base:base + REC_BYTES]
    vals = [struct.unpack(">i", rec[4 * i:4 * i + 4])[0] for i in range(16)]
    print(f"[guitar_flash] slot0 mode0 回读：")
    for name, v in zip(FIELDS_CO, vals[:7]):
        print(f"      {name:5s} = {v / 2**SH_CO[name]:+.6g}")
    for name, v in zip(FIELDS_PM, vals[8:16]):
        print(f"      {name:5s} = {v / 2**SH_PM[name]:+.6g}")
    print(f"[guitar_flash] 每乐器 {len(tbl)} 字节（{SLOTS} slot x {args.modes} mode x {REC_BYTES} B）")
    print(f"[guitar_flash] 镜像 {len(img)} 字节 -> {args.out}")
    print(f"[guitar_flash] 烧写地址：0x{args.inst * len(tbl):06X}（= inst x TABLE_BYTES）")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
