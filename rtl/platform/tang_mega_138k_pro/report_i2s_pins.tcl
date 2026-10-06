# -----------------------------------------------------------------------------
# report_i2s_pins.tcl -- emit DEDICATED setup/hold timing reports for the three
# external I2S output pins, launched from clk_audio, for the parent's
# sim/review_i2s_pin_delays.py checker.
#
# Usage (after a completed P&R):
#   printf 'source rtl/platform/tang_mega_138k_pro/report_i2s_pins.tcl\n' | gw_sh -nocomp
# Writes i2s_setup.rpt / i2s_hold.rpt into the P&R impl directory.
#
# The reports carry complete "Path Summary:" blocks with the launching edge row,
# so the checker can subtract the nominal edge offset and keep the real
# clock-insertion/C2Q/route/pad delay.
# -----------------------------------------------------------------------------
set root [pwd]
set impl "$root/build/gowin/audio_board/impl/pnr"
open_project "$root/build/gowin/audio_board/audio_board.gprj"

set pins {amp_bclk amp_din amp_lrc}
report_timing -setup -from_clock clk_audio -to [get_ports $pins] -max_paths 12 -max_common_paths 1 > "$impl/i2s_setup.rpt"
report_timing -hold  -from_clock clk_audio -to [get_ports $pins] -max_paths 12 -max_common_paths 1 > "$impl/i2s_hold.rpt"
puts "I2S_PIN_REPORTS_DONE"
