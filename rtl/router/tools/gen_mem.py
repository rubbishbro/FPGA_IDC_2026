#!/usr/bin/env python
"""gen_mem.py -- 把我们的 flash 镜像（byte-per-line 的 .mem）转成 W25Q128JVxIM
模型能吃的 MEM.TXT（稀疏，用 `@地址` 指令，不会生成 51 MB 的大文件）。

模型里是 `$readmemh(MEM_FILENAME, memory)`，`@hhhhhh` 是标准的地址跳转指令。

用法::

    python _analysis/gen_mem.py --src rtl/router/tools/piano_flash.mem --base 0
    python _analysis/gen_mem.py --src rtl/router/tools/guitar_flash.mem --base 20480
"""

from __future__ import annotations

import argparse
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", default="rtl/router/tools/piano_flash.mem")
    ap.add_argument("--base", type=int, default=0, help="镜像在 flash 里的起始字节地址")
    ap.add_argument("--out", default="_analysis/vendor_w25q128/MEM.TXT")
    args = ap.parse_args()

    data = Path(args.src).read_bytes()
    # .mem 是 byte-per-line 的十六进制文本，但文件本身是 "AB\nCD\n..." 这么写的，
    # 所以这里直接把文本行的字节读出来更省事：每行两个 hex 字符。
    txt = Path(args.src).read_text(encoding="utf-8", errors="ignore").split()
    vals = [int(x, 16) for x in txt]
    print(f"[gen_mem] {args.src}: {len(vals)} 字节 -> 放到 flash 地址 0x{args.base:06X}")

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", encoding="utf-8", newline="\n") as fh:
        # 注意：注释里**不能出现 @**，xsim 的 $readmemh 会把注释里的 @ 当地址指令
        fh.write(f"// sparse dump: {args.src} base 0x{args.base:06X}\n")
        fh.write(f"@{args.base:x}\n")   # 别补零
        for i in range(0, len(vals), 16):
            fh.write(" ".join(f"{v:02X}" for v in vals[i:i + 16]) + "\n")
    print(f"[gen_mem] 写出 {out}（{out.stat().st_size} 字节）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
