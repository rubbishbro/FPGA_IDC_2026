#!/usr/bin/env python
"""piano_flash.py -- 把（已归一化的）钢琴系数表打成 weight_loader 能读的 flash 镜像。

**一个 slot 一个 MIDI 音**，16 个 slot = 16 个音高。
加 `--notes 32` 可以按 MIDI 顺序存 32 个音，由 loader 用偏移选择一组 16 音装入工作槽。

数据来源：`sythsound/piano_coeff_scaled.txt`（`piano_coeff_gen.py` 的产物）。
那份表**已经在生成器里做过 sq/sv 归一化**了：

    a12 = a21 = es*omega0/omega_d   （= omega0*dt，O(1)）
    gq / gv / wo 按每模态的 sq 缩放过（gq*wo、gv*wo 的乘积不变）

所以这里**只做量化**（float -> Q 整数），不再算缩放 —— 本工具以前有一份
`scale_mode()`，生成器接管归一化之后就重复了，已删。推导见 README §4.5。

字段的 Q（`modal_step_pkg.sv` 的 SH_*，两边必须一致）：

    a11 Q28   a12 Q30   a21 Q23   a22 Q28   gq Q31   gv Q27   wo Q15

用法::

    python rtl/router/tools/piano_flash.py                  # 出 .bin + .mem
    python rtl/router/tools/piano_flash.py --verify         # 只打印量化余量/状态峰值
    python rtl/router/tools/piano_flash.py --midi 40,45,50  # 指定音
    python rtl/router/tools/piano_flash.py --notes 32 --first-midi 40 # 示例连续32音，非正式音域
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import struct
import sys
from pathlib import Path

_HERE = Path(__file__).resolve().parent
_REPO = _HERE.parent.parent.parent          # rtl/router/tools -> 仓根
sys.path.insert(0, str(_HERE))

from flash_image import REC_BYTES, record, image   # noqa: E402
from pack_board_flash import board_layout, check_layout

# ---- 必须和 modal_step_pkg.sv 的 SH_* 一致 ----
SH = dict(a11=28, a12=30, a21=23, a22=28, gq=32, gv=34, wo=29)
FIELDS = ("a11", "a12", "a21", "a22", "gq", "gv", "wo")
# 钢琴不做揉弦（mod_router 里 en=0），参数表整片填 0；8 个字是新的调制布局
PM_FIELDS = ("a11_0", "a12_0", "a22_0", "wo_0", "s11", "s12", "s22", "swo")
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


def simulate_state(co: dict, n_samp: int = 4000) -> tuple[float, float, float]:
    """按递推跑一遍，返回 (peak|q|, peak|v|, peak|y|)，都是"1.0 = 满幅"的物理量。

    激励形状和 excitation_gen 一致：32 拍斜坡到 x=0.977、tau≈48 指数尾巴、
    周期 480、4 个锤击。
    """
    x = []
    acc, tgt, k, cnt, st = 0.0, 0.977, 0, 0, "att"
    for _ in range(n_samp):
        x.append(acc)
        if st == "att":
            acc += tgt / 32.0
            cnt += 1
            if cnt >= 32:
                cnt, st = 0, "dec"
        elif st == "dec":
            acc -= acc * 0.0205
            cnt += 1
            if cnt >= 448:
                cnt = 0
                k += 1
                if k < 4:
                    tgt *= 0.6875
                    acc, st = 0.0, "att"
                else:
                    st = "off"
    q = v = 0.0
    pq = pv = py = 0.0
    for xi in x:
        y = co["wo"] * q
        q, v = (co["a11"] * q + co["a12"] * v + co["gq"] * xi,
                co["a21"] * q + co["a22"] * v + co["gv"] * xi)
        pq = max(pq, abs(q)); pv = max(pv, abs(v)); py = max(py, abs(y))
    return pq, pv, py


def build(table, midi_list, n_modes: int, notes: int = SLOTS):
    if notes not in (SLOTS, 2 * SLOTS) or len(midi_list) != notes:
        raise SystemExit(f"midi 列表要给 {notes} 个音（现在是 {len(midi_list)}）")
    if n_modes < 1 or any(n < 0 or n > 127 for n in midi_list) or len(set(midi_list)) != notes:
        raise SystemExit("模态数/音符编号无效，音符不得重复")
    if notes == 2 * SLOTS and midi_list != list(range(midi_list[0], midi_list[0] + notes)):
        raise SystemExit("32音镜像须按MIDI编号连续递增排列")
    out = bytearray()
    for slot, midi in enumerate(midi_list):
        modes = table.get(midi)
        if modes is None:
            raise SystemExit(f"表里没有 midi{midi}")
        if len(modes) < n_modes:
            raise SystemExit(f"midi{midi} 只有 {len(modes)} 个 mode，要 {n_modes}")
        for m in range(n_modes):
            co = {f: to_int(modes[m][f], SH[f], f) for f in FIELDS}
            pm = {f: 0 for f in PM_FIELDS}
            out += record(co, pm)
    assert len(out) == notes * n_modes * REC_BYTES
    return bytes(out)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--coeff", default=str(_REPO / "sythsound" / "piano_coeff_scaled.txt"),
                    help="已经归一化过的系数表（生成器产物）")
    ap.add_argument("--out", default=str(_HERE / "piano_flash.bin"))
    ap.add_argument("--mem", default=str(_HERE / "piano_flash.mem"))
    ap.add_argument("--inst", type=int, default=INST_DEFAULT)
    ap.add_argument("--modes", type=int, default=MODES_DEFAULT)
    ap.add_argument("--midi", default="", help="逗号分隔的16音，或连续递增32音")
    ap.add_argument("--notes", type=int, choices=(SLOTS, 2 * SLOTS), default=SLOTS,
                    help="资源音高数，计算槽仍为16")
    ap.add_argument("--first-midi", type=int, help="显式指定连续音域起点，不改变默认16音镜像")
    ap.add_argument("--manifest", type=Path, help="可选资源清单，绑定音域、步长、输入及镜像hash")
    ap.add_argument("--verify", action="store_true", help="只检查，不写文件")
    args = ap.parse_args(argv)
    flash_base, flash_bytes = board_layout()

    if args.midi and args.first_midi is not None:
        ap.error("--midi和--first-midi只能选择一种")
    if args.notes == 2 * SLOTS and not args.midi and args.first_midi is None:
        ap.error("32音必须显式指定--first-midi或--midi，不擅自冻结音域")
    midi_list = ([int(x) for x in args.midi.split(",")] if args.midi else
                 list(range(args.first_midi, args.first_midi + args.notes))
                 if args.first_midi is not None else DEFAULT_MIDI)
    table = parse(Path(args.coeff))
    print(f"[piano_flash] 表 {Path(args.coeff).name}：{len(table)} 个音"
          f"（{min(table)}..{max(table)}），每个 {len(next(iter(table.values())))} 个模态")

    tbl = build(table, midi_list, args.modes, args.notes)

    print("[piano_flash] 量化余量（|整数| / 2^31；超了会被饱和）：")
    ok = True
    for f in FIELDS:
        ratio = PEAK[f] / (1 << 31)
        flag = "   <-- 有饱和" if CLAMPED[f] else ""
        ok &= (CLAMPED[f] == 0)
        print(f"    {f:4s} Q{SH[f]:2d}  峰值 float={PEAK_RAW[f]:12.4g}  "
              f"整数={PEAK[f]:11d}  占比={ratio:6.1%}  饱和 {CLAMPED[f]} 次{flag}")

    print("[piano_flash] 状态/输出峰值（按递推 + excitation_gen 的激励形状）：")
    for midi in (midi_list[0], midi_list[len(midi_list) // 2], midi_list[-1]):
        pq, pv, py = simulate_state(table[midi][0])
        print(f"    midi{midi} mode0: |q|={pq:.4f}  |v|={pv:.4f}  |y|={py:.4e}")

    if args.verify:
        print("[piano_flash] --verify：不写文件")
        return 0 if ok else 1

    img = image({args.inst: tbl})
    try:
        check_layout(flash_base, flash_bytes, len(img))
    except ValueError as exc:
        ap.error(str(exc))
    Path(args.out).write_bytes(img)
    if args.manifest:
        args.manifest.write_text(json.dumps({
            "schema": 1, "instrument": args.inst, "format": "ENG0_MATRIX_FIXED_Q",
            "notes": midi_list, "notes_per_instrument": args.notes, "slots_per_bank": SLOTS,
            "modes": args.modes, "record_bytes": REC_BYTES, "note_bytes": args.modes * REC_BYTES,
            "table_bytes": len(tbl), "instrument_base": args.inst * len(tbl),
            "flash_base": flash_base, "flash_bytes": flash_bytes,
            "image_flash_address": flash_base, "instrument_flash_address": flash_base + args.inst * len(tbl), "q_shifts": SH,
            "source_sha256": hashlib.sha256(Path(args.coeff).read_bytes()).hexdigest(),
            "image_sha256": hashlib.sha256(img).hexdigest(),
        }, indent=2) + "\n", encoding="utf-8")
    with open(args.mem, "w", encoding="utf-8", newline="\n") as fh:
        for b in img:
            fh.write(f"{b:02X}\n")

    def check(slot: int):
        midi = midi_list[slot]
        base = args.inst * len(tbl) + (slot * args.modes + 0) * REC_BYTES
        rec = img[base:base + REC_BYTES]
        a11, a12, a21, a22, gq, gv, wo = (struct.unpack(">i", rec[4 * i:4 * i + 4])[0]
                                          for i in range(7))
        print(f"    slot{slot:2d} midi{midi}: a11={a11 / 2**SH['a11']:+.5f} "
              f"a12={a12 / 2**SH['a12']:+.6f} a21={a21 / 2**SH['a21']:+.5f} "
              f"a22={a22 / 2**SH['a22']:+.5f} gq={gq / 2**SH['gq']:+.4e} "
              f"gv={gv / 2**SH['gv']:+.4f} wo={wo / 2**SH['wo']:+.5f}")

    print(f"[piano_flash] 每乐器 {len(tbl)} 字节"
          f"（{args.notes} 音 x {args.modes} mode x {REC_BYTES} B；每组{SLOTS}槽）")
    check(0)
    check(len(midi_list) - 1)
    print(f"[piano_flash] 镜像 {len(img)} 字节 -> {args.out}")
    print(f"[piano_flash] $readmemh 字节文件 -> {args.mem}")
    print(f"[piano_flash] 整个BIN烧写地址：0x{flash_base:06X}；乐器实际地址：0x{flash_base + args.inst * len(tbl):06X}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
