set root [pwd]
cd $root
set files [list \
  "$root/rtl/math/pkg/fxp_pkg.sv" \
  "$root/rtl/simsynth/modal_step_pkg.sv" \
  "$root/rtl/simsynth/modal_engine7.sv" \
  "$root/rtl/core/class_format_pkg.sv" \
  "$root/rtl/core/class_loader.sv" \
  "$root/rtl/core/class_loader64.sv" \
  "$root/rtl/core/a_router_loader.sv" \
  "$root/rtl/core/bc_router_loader.sv" \
  "$root/rtl/core/e2_router_loader.sv" \
  "$root/rtl/core/modal_record_pkg.sv" \
  "$root/rtl/core/modal_ram.sv" \
  "$root/rtl/core/eng1_lane_core.sv" \
  "$root/rtl/core/eng1_engine_top.sv" \
  "$root/rtl/core/voice_env.sv" \
  "$root/rtl/core/voice_env_bank.sv" \
  "$root/rtl/core/eng1_engine_env_top.sv" \
  "$root/rtl/core/b_voice_ctrl.sv" \
  "$root/rtl/core/b_x_pool.sv" \
  "$root/rtl/core/b_front.sv" \
  "$root/rtl/core/b_a1_refresh.sv" \
  "$root/rtl/core/b_a1_engine.sv" \
  "$root/rtl/core/b_a1_ram_engine.sv" \
  "$root/rtl/core/b_engine_top.sv" \
  "$root/rtl/core/c_voice_timer.sv" \
  "$root/rtl/core/seed_rom.sv" \
  "$root/rtl/core/c_seed_loader.sv" \
  "$root/rtl/core/c_engine_top.sv" \
  "$root/rtl/core/engine_mix_sum.sv" \
  "$root/rtl/core/abc_engines_top.sv" \
  "$root/rtl/core/eng2_engine_top.sv" \
  "$root/rtl/core/four_engines_top.sv" \
  "$root/rtl/core/voice_router.sv" \
  "$root/rtl/core/engines_system_top.sv" \
  "$root/rtl/core/router_system_top.sv" \
  "$root/sim/synth/router_probe.sv" \
]

create_project -name router_probe -dir "$root/build/router_probe" -pn GW5AST-LV138FPG676AES -device_version B -force
set_option -verilog_std sysv2017
set_option -top_module router_probe
foreach f $files { add_file $f }
add_file "$root/sim/synth/router_probe.cst"
add_file "$root/sim/synth/router_probe.sdc"
puts "FILES_ADDED"
run syn
puts "SYN_DONE"
run pnr
puts "PNR_DONE"
puts "TIMING_BEGIN"
report_timing -setup -max_paths 10 -max_common_paths 1
puts "TIMING_END"
