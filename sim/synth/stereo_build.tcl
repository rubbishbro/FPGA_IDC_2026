# Independent standalone synthesis: dynamic pan, enable and audio data remain ports.
set root [pwd]
set out "$root/build/stereo_synth"
file mkdir $out
create_project -name stereo_spatializer -dir $out -pn GW5AST-LV138FPG676AES -device_version B -force
set_option -verilog_std sysv2017
set_option -top_module stereo_spatializer
set_option -opt_goal timing
add_file "$root/rtl/audio/stereo_spatializer.sv"
add_file "$root/sim/synth/stereo.sdc"
run syn
set fh [open "$out/stereo_spatializer/impl/gwsynthesis/stereo_spatializer.vg" r]
set netlist [read $fh]
close $fh
if {[regexp -line {^[ \t]*(MULT[A-Z0-9_]*|DSP[A-Z0-9_]*|PADD[A-Z0-9_]*)[ \t]} $netlist]} {
    error "Unexpected multiplier/DSP primitive in stereo spatializer"
}
puts "STEREO_DSP_FREE_CONFIRMED"
puts "STEREO_SYN_DONE"
