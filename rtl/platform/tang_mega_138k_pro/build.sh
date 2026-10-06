#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# build.sh -- board build entry for the Tang Mega 138K Pro speaker top.
#
# Modes:
#   ./build.sh --check-only [--no-tool]   run the preflight gate only
#   ./build.sh                            preflight, then require a real Gowin
#                                         build command
#
# There is no Gowin IDE/license on the authoring machine, so this script does not
# contain an unverified gw_sh invocation.  To let it drive a real synthesis, set
# GOWIN_BUILD_CMD to the exact command confirmed in your Gowin install, e.g.
#   GOWIN_BUILD_CMD='gw_sh board.tcl' ./build.sh
# If GOWIN_BUILD_CMD is unset the script prints the import steps and exits 1: it
# never pretends a bitstream was produced.
# -----------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
PY="${PYTHON:-python3}"

CHECK_ONLY=0
PRE_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --check-only) CHECK_ONLY=1 ;;
        *) PRE_ARGS+=("$arg") ;;
    esac
done

echo "[board] preflight ($ROOT)"
"$PY" "$HERE/preflight.py" --root "$ROOT" "${PRE_ARGS[@]}"

if [ "$CHECK_ONLY" -eq 1 ]; then
    echo "[board] check-only: preflight passed; no synthesis attempted"
    exit 0
fi

if [ -n "${GOWIN_BUILD_CMD:-}" ]; then
    echo "[board] running GOWIN_BUILD_CMD: $GOWIN_BUILD_CMD"
    ( cd "$ROOT" && eval "$GOWIN_BUILD_CMD" )
    echo "[board] Gowin command finished (verify the reports yourself)"
    exit 0
fi

if command -v gw_sh >/dev/null 2>&1; then
    echo "[board] running the real Gowin flow via gowin_build.tcl"
    ( cd "$ROOT" && printf 'source %s/gowin_build.tcl\n' "$HERE" | gw_sh -nocomp )
    exit $?
fi

cat >&2 <<'EOF'
[board] ERROR: gw_sh not on PATH and GOWIN_BUILD_CMD unset.

Install Gowin V1.9.9+ (commercial licence) and put IDE/bin on PATH, or set
  GOWIN_BUILD_CMD='<your confirmed gw_sh/tcl command>' ./build.sh
The real flow is rtl/platform/tang_mega_138k_pro/gowin_build.tcl and needs the
generated PLL IP under ip/ (preflight above reports what is missing).

This script refuses to claim a bitstream.
EOF
exit 1

