#!/usr/bin/env python
"""flash_image.py -- 把模态系数/调制参数打成 weight_loader 能读的 flash 镜像。

布局必须和 ``rtl/router/loader.sv`` 里写的一致（那边是唯一的对外契约）：

    一个乐器 = SLOTS 张表（**每个声部一张，音高可以不同**），loader 原样搬进 RAM，
    不再复制。记录顺序 = RAM 地址顺序（slot-major）：
    base = inst * TABLE_BYTES          TABLE_BYTES = SLOTS * N_MODES * 64
    第 (slot, mode) 条记录占 64 字节（先 slot 后 mode）：
        +0  a11   +4  a12   +8  a21   +12 a22
        +16 gq    +20 gv    +24 wo    +28 保留(0)
        +32 c0    +36 s0    +40 gam   +44 theta0
        +48 g     +52 k12   +56 k21   +60 保留(0)

每个字段是 **大端** 的 signed 32-bit（高字节在前）。W25Q 先发低地址字节、
每字节高位先出，所以 RTL 里直接移位拼出来就是字段值，不用倒字节。

用法::

    python rtl/router/tools/flash_image.py --selftest          # 只跑自检
    python rtl/router/tools/flash_image.py --demo out.bin      # 打个示例镜像

    # 代码里：
    from flash_image import record, table, image, parse
"""

from __future__ import annotations

import argparse
import os
import struct
import sys

REC_BYTES = 64
N_MODES_DEFAULT = 64     # 和 voice_router / loader 的 N_MODES 默认值一致
SLOTS_DEFAULT = 16       # 和 voice_router 的 SLOTS 默认值一致

FIELDS_CO = ("a11", "a12", "a21", "a22", "gq", "gv", "wo")
FIELDS_PM = ("c0", "s0", "gam", "theta0", "g", "k12", "k21")
CO_OFF = (0, 4, 8, 12, 16, 20, 24)          # 与 RTL 的 word_i 0..6 对应
PM_OFF = (32, 36, 40, 44, 48, 52, 56)       # word_i 8..14


class FlashImageError(Exception):
    pass


def _q(v) -> int:
    """收一个整数（或 float 的小数部分已由调用方量化好），检查 int32 范围。"""
    i = int(v)
    if not -(1 << 31) <= i < (1 << 31):
        raise FlashImageError(f"value {i} outside signed 32-bit")
    return i


def record(co, pm) -> bytes:
    """一个模态的 64 字节记录。``co``/``pm`` 可以是 dict 或 7 元组。"""
    if isinstance(co, dict):
        co = [co[k] for k in FIELDS_CO]
    if isinstance(pm, dict):
        pm = [pm[k] for k in FIELDS_PM]
    if len(co) != len(FIELDS_CO) or len(pm) != len(FIELDS_PM):
        raise FlashImageError("co 需要 7 个字段，pm 需要 7 个字段")
    buf = bytearray(REC_BYTES)
    for off, v in zip(CO_OFF, co):
        buf[off:off + 4] = struct.pack(">i", _q(v))
    for off, v in zip(PM_OFF, pm):
        buf[off:off + 4] = struct.pack(">i", _q(v))
    return bytes(buf)


def table(modes) -> bytes:
    """一个乐器的表：按 slot-major 顺序排列的 SLOTS*N_MODES 条记录。"""
    return b"".join(record(co, pm) for co, pm in modes)


def image(tables: dict, n_modes: int | None = None, size: int | None = None) -> bytes:
    """按 ``{inst: table_bytes}`` 拼镜像；``inst`` 决定基地址。"""
    if not tables:
        raise FlashImageError("empty image")
    need = 0
    for inst, tbl in tables.items():
        if not 0 <= inst <= 15:
            raise FlashImageError(f"instrument {inst} outside 0..15")
        if n_modes is not None and len(tbl) != n_modes * REC_BYTES:
            raise FlashImageError(
                f"inst {inst}: table {len(tbl)} bytes != {n_modes * REC_BYTES}")
        need = max(need, (inst + 1) * len(tbl))
    total = max(need, size or 0)
    buf = bytearray(b"\xff" * total)          # 没写的区域保持擦除态 FF
    for inst, tbl in tables.items():
        base = inst * len(tbl)
        buf[base:base + len(tbl)] = tbl
    return bytes(buf)


def parse(img: bytes, inst: int, n_modes: int, slots: int = 16) -> list[list[dict]]:
    """按 loader 的规则把镜像读回来（独立于 pack 的实现，用来交叉验证）。

    返回 ``[[slot0 的 n_modes 条], [slot1 ...], ...]``。
    """
    tbl_bytes = slots * n_modes * REC_BYTES
    base = inst * tbl_bytes
    if base + tbl_bytes > len(img):
        raise FlashImageError(f"image too short for inst {inst} x {n_modes} modes")
    out = []
    for sl in range(slots):
        slot_recs = []
        for m in range(n_modes):
            k = sl * n_modes + m
            rec = img[base + k * REC_BYTES: base + (k + 1) * REC_BYTES]
            d = {}
            for name, off in zip(FIELDS_CO, CO_OFF):
                d[name] = struct.unpack(">i", rec[off:off + 4])[0]
            for name, off in zip(FIELDS_PM, PM_OFF):
                d[name] = struct.unpack(">i", rec[off:off + 4])[0]
            # 保留字段必须是 0，否则说明打包/布局两边不一致
            for off in (28, 60):
                if rec[off:off + 4] != b"\x00\x00\x00\x00":
                    raise FlashImageError(f"slot {sl} mode {m}: reserved @{off} not zero")
            slot_recs.append(d)
        out.append(slot_recs)
    return out


# ---------------------------------------------------------------------------
def _pattern(slot: int, m: int, w: int) -> int:
    """自检/示例用的确定性图样（和 tb_loader_flash.sv 里的 pat() 一致）。"""
    v = 0x1000_0000 | (slot << 16) | (m << 8) | (w << 4) | 0x5
    return v - (1 << 32) if v >= (1 << 31) else v


def _pattern_modes(n: int, slots: int = 4):
    """按 slot-major 顺序吐记录：先 slot 0 的 n 个模态，再 slot 1 ..."""
    for sl in range(slots):
        for m in range(n):
            co = [_pattern(sl, m, w) for w in range(7)]
            pm = [_pattern(sl, m, w + 8) for w in range(7)]
            yield co, pm


def selftest() -> int:
    n_modes, slots = 4, 4
    tbl = table(list(_pattern_modes(n_modes, slots)))
    insts = {2: tbl}
    img = image(insts, n_modes=None)
    back = parse(img, 2, n_modes, slots)
    for sl in range(slots):
        for m in range(n_modes):
            for w, name in enumerate(FIELDS_CO):
                if back[sl][m][name] != _pattern(sl, m, w):
                    print(f"[flash_image] FAIL co sl={sl} m={m} {name}")
                    return 1
            for w, name in enumerate(FIELDS_PM):
                if back[sl][m][name] != _pattern(sl, m, w + 8):
                    print(f"[flash_image] FAIL pm sl={sl} m={m} {name}")
                    return 1
    # 基地址必须是 inst * TABLE_BYTES：1 号乐器的表要落在 256 字节处，前面是擦除态
    img2 = image({1: tbl})
    tb = slots * n_modes * REC_BYTES
    if img2[0:tb] != b"\xff" * tb:
        print("[flash_image] FAIL inst 1 前面应该是擦除态 FF")
        return 1
    if img2[tb:2 * tb] != tbl:
        print("[flash_image] FAIL inst 1 base offset")
        return 1
    # 没写到的区域应该是 FF（擦除态）
    img3 = image({1: tbl}, size=2 * tb + 16)
    if img3[(2 * tb):] != b"\xff" * 16:
        print("[flash_image] FAIL padding is not 0xFF")
        return 1
    print(f"[flash_image] selftest OK（{slots} 声部 x {n_modes} 模态 x {REC_BYTES} 字节，"
          f"TABLE_BYTES={tb}，基地址 = inst x TABLE_BYTES）")
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--selftest", action="store_true", help="只跑打包/解析自检")
    ap.add_argument("--demo", metavar="OUT.bin", help="写一个示例镜像")
    ap.add_argument("--modes", type=int, default=N_MODES_DEFAULT)
    ap.add_argument("--slots", type=int, default=SLOTS_DEFAULT, help="每乐器几个声部的表")
    ap.add_argument("--inst", type=int, default=2)
    ap.add_argument("--mem-out", metavar="OUT.mem",
                    help="同一份镜像再写一份 $readmemh 用的字节文件（给 tb 用）")
    args = ap.parse_args(argv)

    if args.selftest or not args.demo:
        rc = selftest()
        if not args.demo:
            return rc

    n = args.modes
    slots = args.slots
    tbl = table(list(_pattern_modes(n, slots)))
    img = image({args.inst: tbl})
    with open(args.demo, "wb") as fh:
        fh.write(img)
    print(f"[flash_image] inst {args.inst}: {slots} 声部 x {n} 模态 x {REC_BYTES} B "
          f"= {len(tbl)} B，镜像 {len(img)} B -> {args.demo}")
    if args.mem_out:
        with open(args.mem_out, "w", encoding="utf-8", newline="\n") as fh:
            for b in img:
                fh.write(f"{b:02X}\n")
        print(f"[flash_image] tb 用字节文件 -> {args.mem_out}（{len(img)} 行）")
    print(f"[flash_image] 烧写地址：0x{args.inst * len(tbl):06X}（基地址 = inst × TABLE_BYTES）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
