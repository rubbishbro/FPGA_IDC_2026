#!/usr/bin/env python
"""dec2wav.py -- 把 tb_music 渲染出来的 y_data 序列转成 WAV。

输入：每行一个 64 位有符号十进制（`voice_router` 的 `y_data`），
      默认 `_analysis/music_dec.txt`（tb_music 写的）。
输出：16-bit 单声道 PCM WAV，默认 `_analysis/music.wav`，按峰值归一到 -1 dBFS。

用法::

    python rtl/router/tools/dec2wav.py                      # 默认输入输出
    python rtl/router/tools/dec2wav.py in.txt out.wav 48000
    python rtl/router/tools/dec2wav.py --gain 0.5            # 不自动归一化，用固定增益

注意：y_data 是腔体+混响之后的 64 位样本，量级大约 1e9~1e12（Q24.40 之类），
      所以这里只做"按峰值缩放"，不改采样率、不做任何滤波。
"""

from __future__ import annotations

import argparse
import math
import struct
import sys
import wave
from pathlib import Path


def read_series(path: Path) -> list[int]:
    vals: list[int] = []
    with path.open("r", encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                vals.append(int(line))
            except ValueError:
                continue            # 表头/日志行直接跳过
    return vals


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("src", nargs="?", default="_analysis/music_dec.txt")
    ap.add_argument("dst", nargs="?", default="_analysis/music.wav")
    ap.add_argument("fs", nargs="?", type=int, default=48000)
    ap.add_argument("--gain", type=float, default=0.0,
                    help="固定增益（0 = 按峰值自动归一到 -1 dBFS）")
    ap.add_argument("--fade", type=float, default=0.01,
                    help="末尾淡出秒数（0 = 不淡出）")
    args = ap.parse_args(argv)

    src = Path(args.src)
    if not src.exists():
        print(f"ERROR: 找不到输入 {src}（先跑 run_all.ps1 或 tb_music）")
        return 1
    vals = read_series(src)
    if not vals:
        print("ERROR: 没有读到数据")
        return 1

    peak = max(abs(v) for v in vals)
    nz = sum(1 for v in vals if v != 0)
    rms = math.sqrt(sum(v * v for v in vals) / len(vals))
    print(f"采样数 = {len(vals)}  ({len(vals)/args.fs:.3f} s @ {args.fs} Hz)")
    print(f"峰值   = {peak}   非零 = {nz} ({100*nz/len(vals):.1f}%)   RMS = {rms:.1f}")
    if peak == 0:
        print("WARN: 全 0（引擎没算？），仍然写一个静音 wav 方便排查")

    # 目标峰值：-1 dBFS
    target = 0.891
    gain = args.gain if args.gain > 0 else (target / peak if peak else 0.0)
    print(f"增益   = {gain:.6g}" + ("（按峰值归一化）" if args.gain == 0 else "（固定）"))

    n_fade = int(args.fade * args.fs) if args.fade > 0 else 0
    frames = bytearray()
    for i, v in enumerate(vals):
        x = v * gain
        if n_fade and i >= len(vals) - n_fade:
            x *= (len(vals) - i) / n_fade
        x = max(-1.0, min(1.0, x))
        frames += struct.pack("<h", int(round(x * 32767)))

    dst = Path(args.dst)
    dst.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(dst), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(args.fs)
        w.writeframes(bytes(frames))
    print(f"写出 {dst}  ({dst.stat().st_size} 字节)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
