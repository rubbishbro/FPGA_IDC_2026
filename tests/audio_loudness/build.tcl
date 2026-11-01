# Run from repository root: AUDIO_TEST=1 (independent) or 2 (project serializers).
set root [file normalize [pwd]]
set src "$root/tests/audio_loudness"
set which 1
if {[info exists ::env(AUDIO_TEST)]} {set which $::env(AUDIO_TEST)}
if {$which ni {1 2}} {error "AUDIO_TEST must be 1 or 2"}
set top [expr {$which==1 ? "test1_reference_top" : "test2_project_top"}]
set out "$root/build/audio_loudness/test$which"
create_project -name $top -dir $out -pn GW5AST-LV138FPG676AES -device_version B -force
set_option -verilog_std sysv2017
set_option -top_module $top
set_option -opt_goal timing
set_option -oreg_in_iob 1
add_file "$src/tone_test_core.sv"
add_file "$src/$top.sv"
if {$which==1} {
    add_file "$src/reference_audio_tx.sv"
} else {
    add_file "$root/rtl/audio/i2s_amp_tx.sv"
    add_file "$root/rtl/audio/pt8211_tx.sv"
}
add_file "$src/audio_test.cst"
add_file "$src/audio_test.sdc"
run syn
run pnr
puts "AUDIO_TEST_${which}_BUILD_DONE"
set pnr "$out/$top/impl/pnr"
if {[catch {exec python3 "$src/check_build.py" $which} result]} {
    foreach fs [glob -nocomplain "$pnr/*.fs"] {file rename -force $fs "${fs}.UNVALIDATED"}
    error "Audio test acceptance failed: $result"
}
puts $result
