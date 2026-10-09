#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# flash.sh -- Tang Mega 138K Pro 板级烧录辅助脚本。
#
# 为什么需要它：Gowin Programmer GUI 在第一次扫描时会缓存调试器的 USB
# “location”。插拔线缆后缓存就失效了，之后每次尝试都会失败并报
#     "Error: Cable failed to open via the location."
# 只能重启 GUI 强制重新枚举。
#
# 本脚本改用 programmer_cli，它每次调用都会重新扫描 USB 总线，并按线缆
# 名字（"Gowin USB Cable(FT2CH)"）选择，因此永远不会用到失效的 location。
# 想插拔多少次都可以。
#
# 用法：
#   ./flash.sh <bitstream.fs>          # SRAM 烧录（易失，默认）
#   ./flash.sh <bitstream.fs> 5        # embFlash 擦除+烧录（掉电保存）
#   ./flash.sh <bitstream.fs> 6        # embFlash 擦除+烧录+校验
#   ./flash.sh --read                  # 仅连接线缆并读取器件代码
#   ./flash.sh --scan                  # 列出线缆和检测到的 location
#
# 可用 PROGRAMMER_CLI=/path/to/programmer_cli 覆盖 programmer 安装位置。
# -----------------------------------------------------------------------------
set -euo pipefail

DEVICE="${DEVICE:-GW5AST-138B}"
CABLE="${CABLE:-Gowin USB Cable(FT2CH)}"
CLI="${PROGRAMMER_CLI:-$HOME/gowin/Programmer/bin/programmer_cli}"

if [[ ! -x "$CLI" ]]; then
    echo "error: 在 '$CLI' 未找到 programmer_cli" >&2
    echo "       请设置 PROGRAMMER_CLI=/path/to/programmer_cli" >&2
    exit 1
fi

case "${1:-}" in
    --scan|scan)
        exec "$CLI" --scan-cables
        ;;
    --read|read)
        exec "$CLI" --device "$DEVICE" --operation_index 0 --cable "$CABLE"
        ;;
    ""|-h|--help)
        sed -n '3,24p' "$0"
        exit 0
        ;;
esac

FS="$1"
OP="${2:-2}"   # 2 = SRAM 烧录

echo "device=$DEVICE cable=$CABLE op=$OP"
exec "$CLI" --device "$DEVICE" --operation_index "$OP" \
            --fsFile "$FS" --cable "$CABLE"
