#!/usr/bin/env bash
# New shared-RAM core regression. Old parallel top is archived in history/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
IVERILOG="${IVERILOG:-iverilog}"
VVP="${VVP:-vvp}"
OUT="${OUT:-/tmp/dsh_core_tests}"
mkdir -p "$OUT"

COMMON="rtl/math/pkg/fxp_pkg.sv rtl/simsynth/modal_step_pkg.sv rtl/simsynth/modal_engine7.sv \
rtl/core/modal_record_pkg.sv rtl/core/class_format_pkg.sv \
rtl/core/class_loader.sv rtl/core/class_loader64.sv \
rtl/core/a_router_loader.sv rtl/core/bc_router_loader.sv rtl/core/e2_router_loader.sv \
rtl/core/shared_modal_ram.sv rtl/core/eng1_lane_core.sv \
rtl/core/eng1_engine_top_ext.sv rtl/core/voice_env.sv rtl/core/voice_env_bank.sv \
rtl/core/eng1_engine_env_top_ext.sv \
rtl/core/b_voice_ctrl.sv rtl/core/b_x_pool.sv rtl/core/b_front.sv \
rtl/core/b_a1_refresh.sv rtl/core/b_a1_engine.sv rtl/core/b_a1_ram_engine.sv rtl/core/b_engine_top_ext.sv \
rtl/core/c_voice_timer.sv rtl/core/seed_rom.sv rtl/core/c_seed_loader.sv rtl/core/c_engine_top_ext.sv \
rtl/core/eng2_engine_top_ext.sv rtl/core/pure_engine_abc.sv rtl/core/engine_mux.sv rtl/core/shared_engine_mvp.sv rtl/core/shared_engines_top.sv \
rtl/core/shared_engines_system_top.sv rtl/core/voice_router.sv rtl/core/router_system_top.sv"

run() {
  local tb="$1"; shift
  "$IVERILOG" -g2012 -s "$tb" -o "$OUT/$tb" "$@" >"$OUT/$tb.log" 2>&1
  printf '%-28s ' "$tb"
  timeout 25s "$VVP" "$OUT/$tb" 2>/dev/null | grep -E "PASS|FAIL" | head -1
}

run tb_modal_ram rtl/core/modal_record_pkg.sv rtl/core/modal_ram.sv sim/unit/core/tb_modal_ram.sv
run tb_modal_ram_aux rtl/core/modal_record_pkg.sv rtl/core/modal_ram.sv sim/unit/core/tb_modal_ram_aux.sv
run tb_eng1_lane_core rtl/core/modal_record_pkg.sv rtl/core/modal_ram.sv rtl/core/eng1_lane_core.sv sim/unit/core/tb_eng1_lane_core.sv
run tb_voice_env rtl/core/voice_env.sv sim/unit/core/tb_voice_env.sv
run tb_b_front rtl/core/b_voice_ctrl.sv rtl/core/b_x_pool.sv rtl/core/b_front.sv sim/unit/core/tb_b_front.sv
run tb_b_a1_ram rtl/core/modal_record_pkg.sv rtl/core/modal_ram.sv rtl/core/b_a1_refresh.sv rtl/core/b_a1_engine.sv rtl/core/b_a1_ram_engine.sv sim/unit/core/tb_b_a1_ram.sv
run tb_seed_rom rtl/core/seed_rom.sv sim/unit/core/tb_seed_rom.sv
run tb_c_seed_loader rtl/core/seed_rom.sv rtl/core/c_seed_loader.sv sim/unit/core/tb_c_seed_loader.sv
run tb_a_router_loader rtl/core/class_loader.sv rtl/core/a_router_loader.sv rtl/core/modal_record_pkg.sv sim/unit/core/tb_a_router_loader.sv
run tb_bc_router_loader rtl/core/class_format_pkg.sv rtl/core/class_loader64.sv rtl/core/bc_router_loader.sv rtl/core/modal_record_pkg.sv sim/unit/core/tb_bc_router_loader.sv
run tb_e2_router_loader rtl/core/class_format_pkg.sv rtl/core/class_loader64.sv rtl/core/e2_router_loader.sv rtl/core/modal_record_pkg.sv sim/unit/core/tb_e2_router_loader.sv
run tb_router_system_top $(echo "$COMMON") sim/unit/core/tb_router_system_top.sv
run tb_shared_modal_ram rtl/core/modal_record_pkg.sv rtl/core/shared_modal_ram.sv sim/unit/core/tb_shared_modal_ram.sv
run tb_shared_engine_mvp $(echo "$COMMON") sim/unit/core/tb_shared_engine_mvp.sv
run tb_b_engine_top_ext $(echo "$COMMON") sim/unit/core/tb_b_engine_top_ext.sv
run tb_c_engine_top_ext $(echo "$COMMON") sim/unit/core/tb_c_engine_top_ext.sv
run tb_shared_engines_top $(echo "$COMMON") sim/unit/core/tb_shared_engines_top.sv
run tb_engine_mux $(echo "$COMMON") sim/unit/core/tb_engine_mux.sv
