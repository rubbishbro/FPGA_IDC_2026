# Run from the repository root: gw_sh sim/synth/comm_build.tcl
set root [pwd]
set out "$root/build/comm_timing"
file mkdir $out
create_project -name comm_probe -dir $out -pn GW5AST-LV138FPG676AES -device_version B -force
set_option -verilog_std sysv2017
set_option -top_module comm_probe
set manifest [open "$root/sim/comm_sources.f" r]
foreach f [split [string trim [read $manifest]] "\n"] {
    add_file "$root/[string trim $f]"
}
close $manifest
add_file "$root/sim/synth/comm_probe.sv"
add_file "$root/sim/synth/comm_probe.cst"
add_file "$root/sim/synth/comm_probe.sdc"
run syn
puts "COMM_SYN_DONE"
run pnr
puts "COMM_PNR_DONE"
# This Gowin release writes setup/hold reports during PnR; report_timing is
# not a callable gw_sh command. check_comm_timing.py checks the emitted .tr.
puts "COMM_REPORT $out/comm_probe/impl/pnr/comm_probe.tr"
