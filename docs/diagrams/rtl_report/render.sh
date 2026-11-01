#!/usr/bin/env bash
# 重新生成全部 SVG/PNG。需要 graphviz(dot) 与 librsvg(rsvg-convert)。
# 用法：./render.sh [PNG 宽度像素，默认 2200]
set -euo pipefail
cd "$(dirname "$0")"
W="${1:-2200}"
shopt -s nullglob
for f in *.dot; do
  base="${f%.dot}"
  dot -Tsvg "$f" -o "$base.svg"
  rsvg-convert -w "$W" "$base.svg" -o "$base.png"
  printf '%-26s -> %s.svg / %s.png\n' "$base" "$base" "$base"
done
