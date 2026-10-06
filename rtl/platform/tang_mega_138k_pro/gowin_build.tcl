# -----------------------------------------------------------------------------
# gowin_build.tcl -- real Gowin project build entry for the board top.
#
# Run with the installed Gowin V1.9.9+ (verified V1.9.12.04) FROM THE REPO ROOT:
#   export LD_LIBRARY_PATH="$HOME/gowin/IDE/lib:$LD_LIBRARY_PATH"
#   cd <repo root>
#   printf 'source rtl/platform/tang_mega_138k_pro/gowin_build.tcl\n' | gw_sh -nocomp
# (gw_sh <file> does not run a script in this release; pipe `source`.)
#
# Device: GW5AST-138B.  The FPG676 B-silicon device DB exposes the part as
# `GW5AST-LV138FPG676AES` (ES); the bare `...FPG676A` is not a known part string.
# Confirm the physical part with the user before programming.
#
# Top is `board_top` (board_top.sv), which overrides the ROM paths to ABSOLUTE
# so $readmemh never silently misses the images (WARN EX3988).
#
# PLL IP (user-generated, present under ip/):
#   Gowin_PLL_core_100M  -> 100 MHz   ip/pll_core_100m/
#   Gowin_PLL_audio_12M5 -> 12.5 MHz  ip/pll_audio_12m5/   (functional bring-up;
#                                     NOT exact 12.288 MHz -- see BOARD_README)
# plus the PLL_ADV support file ip/pll_init.v.
#
# SystemVerilog-2017 MUST be selected: the synthesizer defaults to Verilog-2001
# and rejects logic/always_ff.
# -----------------------------------------------------------------------------

set root [pwd]
set plat "$root/rtl/platform/tang_mega_138k_pro"

create_project -name audio_board -dir "$root/build/gowin" -pn GW5AST-LV138FPG676AES -device_version B -force
set_option -verilog_std sysv2017
set_option -top_module board_top
# NOTE (blocker, core RTL): the 2C lane working cache in rtl/core/poly_modal_lane.sv
# is inferred read-first (mem[addr]<=wdata; rdata<=mem[addr] in one always_ff),
# which the GW5AST SPX9 BSRAM cannot implement (P&R ERROR PA2122 WRITE_MODE=2'b10).
# Synthesis succeeds with the real ROM; place & route is BLOCKED until the core
# array's write mode is fixed by the core owner.  Do NOT paper over this with
# -ram_style distributed_ram: that exceeds the DFF budget (RP0001).

add_file "$plat/ip/pll_init.v"
add_file "$plat/ip/pll_core_100m/gowin_pll_core_100m.v"
add_file "$plat/ip/pll_core_100m/gowin_pll_core_100m_mod.v"
add_file "$plat/ip/pll_audio_12m5/gowin_pll_audio_12m5.v"
add_file "$plat/ip/pll_audio_12m5/gowin_pll_audio_12m5_mod.v"

add_file "$plat/board_top.sv"
add_file "$plat/top.sv"
add_file "$plat/clock_reset.sv"
add_file "$plat/board_audio_core.sv"
add_file "$root/rtl/audio/audio_async_fifo.sv"
add_file "$root/rtl/audio/pt8211_tx.sv"
add_file "$root/rtl/audio/i2s_amp_tx.sv"
add_file "$root/rtl/audio/i2s_mic_rx.sv"
add_file "$root/rtl/audio/audio_transport.sv"
add_file "$root/rtl/audio/song_player.sv"
add_file "$root/rtl/audio/audio_demo_core.sv"
add_file "$root/rtl/core/coeff_loader.sv"
add_file "$root/rtl/core/poly_modal_lane.sv"
add_file "$root/rtl/core/modal_poly_bank.sv"
add_file "$root/rtl/core/modal_engine.sv"
add_file "$root/rtl/core/body_filter.sv"

add_file "$plat/tang_mega_138k_pro.cst"
add_file "$plat/tang_mega_138k_pro.sdc"

puts "FILES_ADDED"
run syn
puts "SYN_DONE"
run pnr
puts "PNR_DONE"
# Dedicated external-I2S pin timing reports (launched from clk_audio) for the
# parent's sim/review_i2s_pin_delays.py.  Emitted to stdout; the runner captures
# and splits them.
puts "I2S_SETUP_BEGIN"
report_timing -setup -from_clock clk_audio -to [get_ports {amp_bclk amp_din amp_lrc}] -max_paths 12 -max_common_paths 1
puts "I2S_SETUP_END"
puts "I2S_HOLD_BEGIN"
report_timing -hold -from_clock clk_audio -to [get_ports {amp_bclk amp_din amp_lrc}] -max_paths 12 -max_common_paths 1
puts "I2S_HOLD_END"
