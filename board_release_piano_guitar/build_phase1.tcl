# Run gw_sh build_phase1.tcl from build/main_src. Never programs a device.
set root [file normalize [pwd]]
set board "$root/rtl/platform/tang_mega_138k_pro"
set out "$root/build/phase1_piano_guitar"
file mkdir $out
create_project -name phase1_piano_guitar -dir $out -pn GW5AST-LV138FPG676AES -device_version B -force
set_option -verilog_std sysv2017
set_option -top_module instrument_board_top
set_option -use_sspi_as_gpio 1
set_option -use_cpu_as_gpio 1
set_option -use_mspi_as_gpio 1
set fh [open "$board/sources.f" r]
foreach path [split [read $fh] "\n"] {
    if {[string trim $path] ne ""} {add_file "$root/$path"}
}
close $fh
foreach m [glob -nocomplain "$root/FFT_spectrumshow/board/*.mem"] {
    file copy -force $m "$out/phase1_piano_guitar/[file tail $m]"
}
add_file "$board/instrument_board.cst"
add_file "$board/instrument_board.sdc"
run syn
puts "PHASE1_SYN_DONE"
run pnr
puts "PHASE1_PNR_DONE"
