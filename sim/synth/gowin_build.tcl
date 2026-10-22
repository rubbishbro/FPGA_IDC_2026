set root [pwd]
cd $root
# $readmemh 由综合器在工程目录解析；生成一份把 sim/unit/core/ 改成绝对路径的探针副本。
set probe_src "$root/sim/synth/router_probe.sv"
set probe_gen "$root/build/router_probe/router_probe_probe.sv"
file mkdir [file dirname $probe_gen]
set fh [open $probe_src r]
set probe_text [read $fh]
close $fh
set probe_text [string map [list "sim/unit/core/" "$root/sim/unit/core/" "rtl/rom/" "$root/rtl/rom/"] $probe_text]
set fh [open $probe_gen w]
puts $fh $probe_text
close $fh
set files [list \
  "$root/rtl/math/pkg/fxp_pkg.sv" \
  "$root/rtl/simsynth/modal_step_pkg.sv" \
  "$root/rtl/simsynth/modal_engine7.sv" \
  "$root/rtl/core/class_format_pkg.sv" \
  "$root/rtl/core/index_loader20.sv" \
  "$root/rtl/core/index_loader64.sv" \
  "$root/rtl/core/router_loader.sv" \
  "$root/rtl/core/modal_record_pkg.sv" \
  "$root/rtl/core/abc_lane_core.sv" \
  "$root/rtl/core/abc_engine.sv" \
      "$root/rtl/core/e2_engine.sv" \
    "$root/rtl/core/shared_modal_ram.sv" \
  "$root/rtl/core/pure_engine_abc.sv" \
  "$root/rtl/core/engine_mux.sv" \
  "$root/rtl/core/shared_engines_top.sv" \
  "$root/rtl/core/shared_engines_system_top.sv" \
  "$root/rtl/core/envelope_mul.sv" \
  "$root/rtl/core/body_biquad.sv" \
  "$root/rtl/core/comb_reverb.sv" \
  "$root/rtl/core/dry_wet_mix.sv" \
  "$root/rtl/core/final_adder.sv" \
  "$root/rtl/core/post_chain.sv" \
  "$root/rtl/core/router_pkg.sv" \
  "$root/rtl/core/router_ctrl.sv" \
  "$root/rtl/core/excitation_convert.sv" \
  "$root/rtl/core/router_frontend.sv" \
  "$root/rtl/core/router_voice_alloc.sv" \
    "$root/rtl/core/router_system_top.sv" \
  "$probe_gen" \
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
