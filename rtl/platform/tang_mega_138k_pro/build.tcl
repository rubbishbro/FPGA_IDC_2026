# From repo root; BOARD_PNR=1 enables physical implementation.
set root [file normalize [pwd]]
set board "$root/rtl/platform/tang_mega_138k_pro"
set resource_python python3
if {[info exists ::env(BOARD_PYTHON)]} {set resource_python $::env(BOARD_PYTHON)}
if {[catch {exec $resource_python "$root/sim/check_performance_resources.py"} resource_check]} {
    error "Flash resource/board contract check failed: $resource_check"
}
puts "FLASH_RESOURCE_CONTRACT $resource_check"
set out "$root/build/instrument_board"
if {[info exists ::env(INSTRUMENT_BUILD_DIR)]} {set out [file normalize $::env(INSTRUMENT_BUILD_DIR)]}
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
set top_source_path "$board/instrument_board_top.sv"
set profile_fh [open "$out/build_profile.json" w]
puts $profile_fh "{\"communication_protocol\": \"unversioned\"}"
close $profile_fh
set fh [open "$board/sources.f" r]
foreach path [split [read $fh] "\n"] {
    if {$path eq "rtl/platform/tang_mega_138k_pro/instrument_board_top.sv"} {
        add_file $top_source_path
    } elseif {[string trim $path] ne ""} {add_file "$root/$path"}
}
close $fh
foreach m [glob -nocomplain "$root/FFT_spectrumshow/board/*.mem"] {
    file copy -force $m "$out/instrument_board/[file tail $m]"
}
set led_tables "$out/instrument_board/rtl/drivers/pad_led_tables"
file mkdir $led_tables
foreach m [glob "$root/rtl/drivers/pad_led_tables/*.mem"] {
    file copy -force $m "$led_tables/[file tail $m]"
}
add_file "$board/instrument_board.cst"
add_file "$board/instrument_board.sdc"
# Optional documented router strategy for isolated implementation retries.
if {[info exists ::env(BOARD_ROUTE_OPTION)]} {
    if {$::env(BOARD_ROUTE_OPTION) ni {1 2}} {error "BOARD_ROUTE_OPTION must be 1 or 2"}
    set_option -route_option $::env(BOARD_ROUTE_OPTION)
}
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
