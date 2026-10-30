# build50.tcl - 50 MHz trial build (Windows gw_sh compatible subset)
set root [file normalize [pwd]]
set board "$root/rtl/platform/tang_mega_138k_pro"
set out "$root/build/instrument_board"
file mkdir $out
create_project -name instrument_board -dir $out -pn GW5AST-LV138FPG676AES -device_version B -force
set_option -verilog_std sysv2017
set_option -top_module instrument_board_top
set_option -use_mspi_as_gpio 1
set fh [open "$board/sources.f" r]
foreach path [split [read $fh] "\n"] {
    if {[string trim $path] ne ""} {add_file "$root/$path"}
}
close $fh
foreach m [glob -nocomplain "$root/FFT_spectrumshow/board/*.mem"] {
    file copy -force $m "$out/instrument_board/[file tail $m]"
}
add_file "$board/instrument_board.cst"
add_file "$board/instrument_board.sdc"
run syn
puts "BOARD50_SYN_DONE"
