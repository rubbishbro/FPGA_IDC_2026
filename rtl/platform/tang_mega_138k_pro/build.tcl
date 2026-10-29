# From repo root; BOARD_PNR=1 enables physical implementation.
set root [file normalize [pwd]]
set board "$root/rtl/platform/tang_mega_138k_pro"
set out "$root/build/instrument_board"
file mkdir $out
create_project -name instrument_board -dir $out -pn GW5AST-LV138FPG676AES -device_version B -force
set_option -verilog_std sysv2017
set_option -top_module instrument_board_top
set_option -opt_goal timing
set_option -map_option 1
set_option -replicate_resources 1
set_option -oreg_in_iob 1
# PMOD0 and DBG_UART.RX share SSPI/CPU-function pins. No AE350/SSPI boot consumer.
set_option -use_sspi_as_gpio 1
set_option -use_cpu_as_gpio 1
# On-board 128Mbit config NOR is read by the loader: free its MSPI pins as GPIO.
set_option -use_mspi_as_gpio 1
set fh [open "$board/sources.f" r]
foreach path [split [read $fh] "\n"] {
    if {[string trim $path] ne ""} {add_file "$root/$path"}
}
close $fh
file copy -force "$root/FFT_spectrumshow/board/sidebar_font.mem" "$out/instrument_board/sidebar_font.mem"
add_file "$board/instrument_board.cst"
add_file "$board/instrument_board.sdc"
run syn
puts "INSTRUMENT_BOARD_SYN_DONE"
if {[info exists ::env(BOARD_PNR)] && $::env(BOARD_PNR)=="1"} {
    run pnr
    puts "INSTRUMENT_BOARD_PNR_DONE"
    set py python3
    if {[info exists ::env(BOARD_PYTHON)]} {set py $::env(BOARD_PYTHON)}
    set pnr "$out/instrument_board/impl/pnr"
    if {[catch {exec $py "$board/check_board.py" --timing "$pnr/instrument_board.tr" --out "$out/acceptance.json"} result]} {
        foreach fs [glob -nocomplain "$pnr/*.fs"] {
            file rename -force $fs "${fs}.UNVALIDATED"
        }
        error "Board timing acceptance failed: $result"
    }
    puts $result
    puts "INSTRUMENT_BOARD_TIMING_ACCEPTED"
}
