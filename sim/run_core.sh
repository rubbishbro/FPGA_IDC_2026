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
rtl/core/index_loader20.sv rtl/core/index_loader64.sv \
rtl/core/router_loader.sv \
rtl/core/shared_modal_ram.sv rtl/core/abc_lane_core.sv \
rtl/core/abc_engine.sv rtl/core/pure_engine_abc.sv \
rtl/core/e2_engine.sv rtl/core/engine_mux.sv rtl/core/shared_engines_top.sv \
rtl/core/shared_engines_system_top.sv rtl/core/router_pkg.sv rtl/core/router_ctrl.sv rtl/core/excitation_convert.sv rtl/core/router_frontend.sv rtl/core/router_voice_alloc.sv rtl/core/router_system_top.sv \
rtl/core/envelope_mul.sv rtl/core/body_biquad.sv rtl/core/comb_reverb.sv rtl/core/dry_wet_mix.sv rtl/core/final_adder.sv rtl/core/post_chain.sv"

run() {
  local tb="$1"; shift
  "$IVERILOG" -g2012 -s "$tb" -o "$OUT/$tb" "$@" >"$OUT/$tb.log" 2>&1
  printf '%-28s ' "$tb"
  timeout 25s "$VVP" "$OUT/$tb" 2>/dev/null | grep -E "PASS|FAIL" | head -1
}

run tb_shared_modal_ram rtl/core/modal_record_pkg.sv rtl/core/shared_modal_ram.sv sim/unit/core/tb_shared_modal_ram.sv
run tb_router_loader rtl/core/class_format_pkg.sv rtl/core/index_loader20.sv rtl/core/index_loader64.sv rtl/core/modal_record_pkg.sv rtl/core/router_loader.sv sim/unit/core/tb_router_loader.sv
run tb_engine_mux $(echo "$COMMON") sim/unit/core/tb_engine_mux.sv
run tb_abc_signed $(echo "$COMMON") sim/unit/core/tb_abc_signed.sv
run tb_e2_load_mux $(echo "$COMMON") sim/unit/core/tb_e2_load_mux.sv
run tb_env_signed rtl/core/envelope_mul.sv sim/unit/core/tb_env_signed.sv
run tb_shared_engines_top $(echo "$COMMON") sim/unit/core/tb_shared_engines_top.sv
run tb_router_system_top $(echo "$COMMON") sim/unit/core/tb_router_system_top.sv
run tb_router_voice_alloc rtl/core/router_voice_alloc.sv sim/unit/core/tb_router_voice_alloc.sv
run tb_post_chain rtl/core/envelope_mul.sv rtl/core/dry_wet_mix.sv rtl/core/final_adder.sv rtl/core/body_biquad.sv sim/unit/core/tb_post_chain.sv
run tb_comb_reverb rtl/core/comb_reverb.sv sim/unit/core/tb_comb_reverb.sv
run tb_router_ctrl rtl/core/router_pkg.sv rtl/core/router_ctrl.sv sim/unit/core/tb_router_ctrl.sv
run tb_excitation_convert rtl/core/excitation_convert.sv sim/unit/core/tb_excitation_convert.sv
run tb_linear_modulation rtl/core/linear_modulation.sv sim/unit/core/tb_linear_modulation.sv
run tb_router_frontend rtl/core/router_pkg.sv rtl/core/router_ctrl.sv rtl/core/excitation_convert.sv rtl/core/router_frontend.sv sim/unit/core/tb_router_frontend.sv
run tb_post_chain_top rtl/core/envelope_mul.sv rtl/core/body_biquad.sv rtl/core/comb_reverb.sv rtl/core/dry_wet_mix.sv rtl/core/final_adder.sv rtl/core/post_chain.sv sim/unit/core/tb_post_chain_top.sv
run tb_post_handshake rtl/core/envelope_mul.sv rtl/core/body_biquad.sv rtl/core/comb_reverb.sv rtl/core/dry_wet_mix.sv rtl/core/final_adder.sv rtl/core/post_chain.sv sim/unit/core/tb_post_handshake.sv
run tb_post_data_order rtl/core/envelope_mul.sv rtl/core/body_biquad.sv rtl/core/comb_reverb.sv rtl/core/dry_wet_mix.sv rtl/core/final_adder.sv rtl/core/post_chain.sv sim/unit/core/tb_post_data_order.sv
run tb_engine_post_chain $(echo "$COMMON") sim/unit/core/tb_engine_post_chain.sv
run tb_shared_engines_post rtl/math/pkg/fxp_pkg.sv rtl/simsynth/modal_step_pkg.sv rtl/simsynth/modal_engine7.sv rtl/core/modal_record_pkg.sv rtl/core/shared_modal_ram.sv rtl/core/abc_lane_core.sv rtl/core/abc_engine.sv rtl/core/pure_engine_abc.sv rtl/core/e2_engine.sv rtl/core/engine_mux.sv rtl/core/envelope_mul.sv rtl/core/body_biquad.sv rtl/core/comb_reverb.sv rtl/core/dry_wet_mix.sv rtl/core/final_adder.sv rtl/core/post_chain.sv rtl/core/shared_engines_top.sv sim/unit/core/tb_shared_engines_post.sv
run tb_router_frontend_a_path_top rtl/math/pkg/fxp_pkg.sv rtl/simsynth/modal_step_pkg.sv rtl/simsynth/modal_engine7.sv rtl/core/modal_record_pkg.sv rtl/core/shared_modal_ram.sv rtl/core/abc_lane_core.sv rtl/core/abc_engine.sv rtl/core/pure_engine_abc.sv rtl/core/e2_engine.sv rtl/core/engine_mux.sv rtl/core/router_pkg.sv rtl/core/router_ctrl.sv rtl/core/excitation_convert.sv rtl/core/router_frontend.sv rtl/core/router_frontend_a_path_top.sv sim/unit/core/tb_router_frontend_a_path_top.sv
