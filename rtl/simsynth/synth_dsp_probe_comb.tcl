set root [pwd]
set here [file dirname [file normalize [info script]]]
set build "$root/build/dsp_probe_comb_syn"
file mkdir $build
create_project -name dsp_probe_comb_syn -dir $build -pn GW5AST-LV138FPG676AES -device_version B -force
set_option -verilog_std sysv2017
set_option -top_module dsp_probe_comb
add_file "$here/../math/pkg/fxp_pkg.sv"
add_file "$here/modal_step_pkg.sv"
add_file "$here/dsp_probe_comb.sv"
puts "FILES_ADDED"
run syn
puts "SYN_DONE"
