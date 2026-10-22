#!/usr/bin/env bash
# New architecture regression: pure ABC/E2 + shared RAM + router top.
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
rtl/core/router_loader.sv \
rtl/core/shared_modal_ram.sv rtl/core/eng1_lane_core.sv \
rtl/core/eng1_engine_top_ext.sv rtl/core/pure_engine_abc.sv \
rtl/core/eng2_engine_top_ext.sv rtl/core/engine_mux.sv rtl/core/shared_engines_top.sv \
rtl/core/shared_engines_system_top.sv rtl/core/voice_router.sv rtl/core/router_system_top.sv \
rtl/core/envelope_mul.sv rtl/core/body_filter.sv rtl/core/reverb_filter.sv rtl/core/dry_wet_mix.sv rtl/core/final_adder.sv rtl/core/post_chain.sv"

run() {
  local tb="$1"; shift
  "$IVERILOG" -g2012 -s "$tb" -o "$OUT/$tb" "$@" >"$OUT/$tb.log" 2>&1
  printf '%-28s ' "$tb"
  timeout 25s "$VVP" "$OUT/$tb" 2>/dev/null | grep -E "PASS|FAIL" | head -1
}

run tb_shared_modal_ram rtl/core/modal_record_pkg.sv rtl/core/shared_modal_ram.sv sim/unit/core/tb_shared_modal_ram.sv
run tb_router_loader rtl/core/class_format_pkg.sv rtl/core/class_loader.sv rtl/core/class_loader64.sv rtl/core/modal_record_pkg.sv rtl/core/router_loader.sv sim/unit/core/tb_router_loader.sv
run tb_engine_mux $(echo "$COMMON") sim/unit/core/tb_engine_mux.sv
run tb_shared_engines_top $(echo "$COMMON") sim/unit/core/tb_shared_engines_top.sv
run tb_router_system_top $(echo "$COMMON") sim/unit/core/tb_router_system_top.sv
run tb_voice_router rtl/core/voice_router.sv sim/unit/core/tb_voice_router.sv
run tb_post_chain rtl/core/envelope_mul.sv rtl/core/dry_wet_mix.sv rtl/core/final_adder.sv rtl/core/body_filter.sv sim/unit/core/tb_post_chain.sv
run tb_reverb_filter rtl/core/reverb_filter.sv sim/unit/core/tb_reverb_filter.sv
run tb_router_ctrl rtl/core/router_pkg.sv rtl/core/router_ctrl.sv sim/unit/core/tb_router_ctrl.sv
run tb_excitation_convert rtl/core/excitation_convert.sv sim/unit/core/tb_excitation_convert.sv
run tb_linear_modulation rtl/core/linear_modulation.sv sim/unit/core/tb_linear_modulation.sv
run tb_router_frontend rtl/core/router_pkg.sv rtl/core/router_ctrl.sv rtl/core/excitation_convert.sv rtl/core/router_frontend.sv sim/unit/core/tb_router_frontend.sv
run tb_post_chain_top rtl/core/envelope_mul.sv rtl/core/body_filter.sv rtl/core/reverb_filter.sv rtl/core/dry_wet_mix.sv rtl/core/final_adder.sv rtl/core/post_chain.sv sim/unit/core/tb_post_chain_top.sv
run tb_engine_post_chain $(echo "$COMMON") sim/unit/core/tb_engine_post_chain.sv
run tb_shared_engines_post rtl/math/pkg/fxp_pkg.sv rtl/simsynth/modal_step_pkg.sv rtl/simsynth/modal_engine7.sv rtl/core/modal_record_pkg.sv rtl/core/shared_modal_ram.sv rtl/core/eng1_lane_core.sv rtl/core/eng1_engine_top_ext.sv rtl/core/pure_engine_abc.sv rtl/core/eng2_engine_top_ext.sv rtl/core/engine_mux.sv rtl/core/envelope_mul.sv rtl/core/body_filter.sv rtl/core/reverb_filter.sv rtl/core/dry_wet_mix.sv rtl/core/final_adder.sv rtl/core/post_chain.sv rtl/core/shared_engines_top.sv sim/unit/core/tb_shared_engines_post.sv
run tb_router_frontend_top rtl/math/pkg/fxp_pkg.sv rtl/simsynth/modal_step_pkg.sv rtl/simsynth/modal_engine7.sv rtl/core/modal_record_pkg.sv rtl/core/shared_modal_ram.sv rtl/core/eng1_lane_core.sv rtl/core/eng1_engine_top_ext.sv rtl/core/pure_engine_abc.sv rtl/core/eng2_engine_top_ext.sv rtl/core/engine_mux.sv rtl/core/router_pkg.sv rtl/core/router_ctrl.sv rtl/core/excitation_convert.sv rtl/core/router_frontend.sv rtl/core/router_frontend_top.sv sim/unit/core/tb_router_frontend_top.sv
