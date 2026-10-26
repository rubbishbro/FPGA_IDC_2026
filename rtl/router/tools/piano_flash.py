#!/usr/bin/env python
"""piano_flash.py -- 把 sythsound/piano_coeff.txt 打成 weight_loader 能读的 flash 镜像。

**一个 slot 一个 MIDI 音**（loader 现在是"每个声部一张表"，见 README §4.1），
这样 16 个声部就是 16 个音高，按哪个键就响哪个 slot。

系数格式（`modal_step_pkg.sv` 的冻结值，见那个文件的 SH_*）：

    字段   Q 小数位      整数 = round(float * 2**Q)
    a11    28
    a12    30
    a21    23
    a22    28
    gq     31
    gv     27
    wo     15

`sythsound/piano_coeff.txt` 是 `piano_coeff_gen.py` 打印的，格式：

    midi40
    mode0:<a11>,<a12>,<a21>,<a22>,<gq>,<gv>,<wo>
    mode1:...
    ...
    (空行)
    midi41
    ...

每个 midi 有 2*32=64 条 mode（每对是微失谐的一对），正好对上 N_MODES=64。

钢琴没有揉弦（mod_router 对钢琴 en=0），所以调制参数表（pm）整片填 0。

用法::

    python rtl/router/tools/piano_flash.py                     # 默认 16 个音，写 .bin + .mem
    python rtl/router/tools/piano_flash.py --midi 40,45,50     # 指定音
    python rtl/router/tools/piano_flash.py --out x.bin --mem x.mem
"""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

_HERE = Path(__file__).resolve().parent
_REPO = _HERE.parent.parent.parent          # rtl/router/tools -> 仓根
sys.path.insert(0, str(_HERE))

from flash_image import REC_BYTES, record, image   # noqa: E402

# modal_step_pkg.sv 的 SH_*
SH = dict(a11=28, a12=30, a21=23, a22=28, gq=31, gv=27, wo=15)
FIELDS = ("a11", "a12", "a21", "a22", "gq", "gv", "wo")
INT32 = (-(1 << 31), (1 << 31) - 1)

SLOTS_DEFAULT = 16
MODES_DEFAULT = 64
INST_DEFAULT = 2
# 默认挑 16 个音：40..79 里均匀取
DEFAULT_MIDI = [40, 42, 44, 46, 48, 50, 52, 54, 56, 58, 60, 62, 64, 67, 71, 76]


def parse(path: Path) -> dict[int, list[dict]]:
    """{midi: [ {field: float}, ... ]}；mode 顺序按文件里的 mode 编号。"""
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


CLAMPED: dict[str, int] = {k: 0 for k in FIELDS}
PEAK: dict[str, int] = {k: 0 for k in FIELDS}
PEAK_RAW: dict[str, float] = {k: 0.0 for k in FIELDS}


def to_int(v: float, sh: int, field: str = "") -> int:
    """float -> Q(sh) 整数。超出 int32 就饱和并记账（见 main 里的"量化余量"）。"""
    i = int(round(v * (1 << sh)))
    lo, hi = INT32
    if i < lo:
        i = lo
        CLAMPED[field] += 1
    elif i > hi:
        i = hi
        CLAMPED[field] += 1
    if field:
        PEAK[field] = max(PEAK[field], abs(i))
        PEAK_RAW[field] = max(PEAK_RAW[field], abs(v))
    return i


def build(table: dict[int, list[dict]], midi_list, n_modes: int) -> bytes:
    """16 个 slot、每 slot n_modes 条记录，slot-major。返回一个乐器的表字节。"""
    if len(midi_list) != SLOTS_DEFAULT:
        raise SystemExit(f"midi 列表要给 {SLOTS_DEFAULT} 个音（现在是 {len(midi_list)}）")
    out = bytearray()
    for slot, midi in enumerate(midi_list):
        modes = table.get(midi)
        if modes is None:
            raise SystemExit(f"表里没有 midi{midi}")
        if len(modes) < n_modes:
            raise SystemExit(f"midi{midi} 只有 {len(modes)} 个 mode，要 {n_modes}")
        for m in range(n_modes):
            co = {k: to_int(modes[m][k], SH[k], k) for k in FIELDS}
            pm = {k: 0 for k in ("c0", "s0", "gam", "theta0", "g", "k12", "k21")}
            out += record(co, pm)
    assert len(out) == SLOTS_DEFAULT * n_modes * REC_BYTES
    return bytes(out)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--coeff", default=str(_REPO / "sythsound" / "piano_coeff.txt"))
    ap.add_argument("--out", default=str(_HERE / "piano_flash.bin"))
    ap.add_argument("--mem", default=str(_HERE / "piano_flash.mem"))
    ap.add_argument("--inst", type=int, default=INST_DEFAULT)
    ap.add_argument("--modes", type=int, default=MODES_DEFAULT)
    ap.add_argument("--midi", default="", help="逗号分隔的 16 个 MIDI 音")
    args = ap.parse_args(argv)

    midi_list = ([int(x) for x in args.midi.split(",")] if args.midi else DEFAULT_MIDI)
    table = parse(Path(args.coeff))
    print(f"[piano_flash] 读到 {len(table)} 个音（{min(table)}..{max(table)}），"
          f"每个 {len(next(iter(table.values())))} 个 mode")

    tbl = build(table, midi_list, args.modes)
    img = image({args.inst: tbl})
    Path(args.out).write_bytes(img)

    # $readmemh 用的字节文件（tb 里 $readmemh 到这个行为模型的 mem[]）
    with open(args.mem, "w", encoding="utf-8", newline="\n") as fh:
        for b in img:
            fh.write(f"{b:02X}\n")

    # 自检：把首尾两个槽按 loader 的规则读回来，看量级是否合理
    def check(slot: int):
        midi = midi_list[slot]
        base = args.inst * len(tbl) + (slot * args.modes + 0) * REC_BYTES
        rec = img[base:base + REC_BYTES]
        import struct
        a11, a12, a21, a22, gq, gv, wo = (struct.unpack(">i", rec[4 * i:4 * i + 4])[0]
                                          for i in range(7))
        print(f"    slot{slot:2d} midi{midi}: a11={a11} ({a11 / 2**28:+.6f})  "
              f"a21={a21} ({a21 / 2**23:+.4f})  wo={wo} ({wo / 2**15:+.5f})")

    print(f"[piano_flash] 每乐器 {len(tbl)} 字节（{SLOTS_DEFAULT} slot x {args.modes} mode x {REC_BYTES} B）")
    check(0)
    check(len(midi_list) - 1)
    # 量化余量：整数峰值占 int32 的比例；>1 说明这个字段的 Q 太激进（被饱和了）
    print("[piano_flash] 量化余量（|整数|峰值 / 2^31，超了会被饱和）：")
    for k in FIELDS:
        ratio = PEAK[k] / (1 << 31)
        flag = "   <-- 有饱和" if CLAMPED[k] else ""
        print(f"    {k:4s} Q{SH[k]:2d}  峰值 float={PEAK_RAW[k]:12.4g}  "
              f"整数={PEAK[k]:11d}  占比={ratio:6.1%}  饱和 {CLAMPED[k]} 次{flag}")
    print(f"[piano_flash] 镜像 {len(img)} 字节 -> {args.out}")
    print(f"[piano_flash] $readmemh 字节文件 -> {args.mem}")
    print(f"[piano_flash] 烧写地址：0x{args.inst * len(tbl):06X}（= inst x TABLE_BYTES）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
