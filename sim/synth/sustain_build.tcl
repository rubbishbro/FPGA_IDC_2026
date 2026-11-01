# Run from repository root. Synthesis only, no board pin/timing claim.
set root [pwd]
set out "$root/build/sustain/synth"
file mkdir $out
create_project -name sustain_probe -dir $out -pn GW5AST-LV138FPG676AES -device_version B -force
set_option -verilog_std sysv2017
set_option -top_module sustain_probe
set manifest [open "$root/sim/router_sources.list" r]
set sources [read $manifest]
close $manifest
foreach {full path} [regexp -all -inline {'(rtl/[^']+\.sv)'} $sources] {
    if {![string match "*/tb/*" $path]} { add_file "$root/$path" }
}
add_file "$root/sim/synth/sustain_probe.sv"
run syn
puts "SUSTAIN_SYN_DONE"
