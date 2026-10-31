# Independent router resource synthesis; no board pins or PnR claim.
set root [pwd]
set out "$root/build/eng1_pitch/full_synth"
file mkdir $out
create_project -name pitch_router -dir $out -pn GW5AST-LV138FPG676AES -device_version B -force
set_option -verilog_std sysv2017
set_option -top_module pitch_sustain_probe
set_option -opt_goal timing
set fh [open "$root/rtl/router/tools/run_all.ps1" r]
set sources [read $fh]
close $fh
foreach {full path} [regexp -all -inline {'(rtl/[^']+\.sv)'} $sources] {
    if {![string match "*/tb/*" $path]} {add_file "$root/$path"}
}
add_file "$root/sim/synth/pitch_sustain_probe.sv"
run syn
puts "PITCH_ROUTER_SYN_DONE"
