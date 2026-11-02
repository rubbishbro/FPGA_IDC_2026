# Independent resource/timing probe for the shared 16-slot trumpet datapath.
set root [pwd]
set out "$root/build/trumpet_tdm_20261102/standalone"
if {[info exists ::env(TRUMPET_BUILD_DIR)]} {set out [file normalize $::env(TRUMPET_BUILD_DIR)]}
create_project -name trumpet -dir $out -pn GW5AST-LV138FPG676AES -device_version B -force
set_option -verilog_std sysv2017
set_option -top_module trumpet_excitation
set_option -opt_goal timing
add_file "$root/rtl/router/pkg/trumpet_excitation_pkg.sv"
add_file "$root/rtl/router/parts/trumpet_excitation.sv"
add_file "$root/sim/synth/trumpet.sdc"
run syn
puts "TRUMPET_SYN_DONE"
