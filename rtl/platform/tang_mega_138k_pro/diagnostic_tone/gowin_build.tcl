# -----------------------------------------------------------------------------
# gowin_build.tcl -- real Gowin project build entry for the STANDALONE
# continuous diagnostic tone (diagnostic_tone_top).
#
# This is a SEPARATE project from the automatic-song build.  It does NOT touch
# build/gowin or any production artifact, and it does NOT replace the main
# project.  It builds only:
#   * the existing real Gowin_PLL_audio_12M5 IP (no 100 MHz core PLL),
#   * the diagnostic tone_source.sv / top.sv,
#   * the existing, read-only rtl/audio/i2s_amp_tx.sv,
#   * the diagnostic tone.cst / tone.sdc.
#
# Run with the installed Gowin V1.9.9+ (verified V1.9.12.04) FROM THE REPO ROOT:
#   export LD_LIBRARY_PATH="$HOME/gowin/IDE/lib:$LD_LIBRARY_PATH"
#   cd <repo root>
#   printf 'source rtl/platform/tang_mega_138k_pro/diagnostic_tone/gowin_build.tcl\n' | gw_sh -nocomp
# (gw_sh <file> does not run a script in this release; pipe `source`.)
#
# BUILD_DIR: the output directory is forced to a dedicated tree and must never be
# inside build/gowin.  Set the BUILD_DIR environment variable to override it;
# otherwise it defaults to <repo>/build/diagnostic_tone.  A path that resolves
# into build/gowin is rejected before any tool runs, so a diagnostic build cannot
# overwrite the production project.
#
# SystemVerilog-2017 MUST be selected: the synthesizer defaults to Verilog-2001
# and rejects logic/always_ff.
#
# This script does not program or download anything, and produces no bitstream
# claim on its own.
# -----------------------------------------------------------------------------

set root [pwd]
set plat "$root/rtl/platform/tang_mega_138k_pro"
set diag "$plat/diagnostic_tone"

# --- dedicated, non-production build directory -------------------------------
if {[info exists env(BUILD_DIR)] && [string length $env(BUILD_DIR)] > 0} {
    set build_dir $env(BUILD_DIR)
} else {
    set build_dir "$root/build/diagnostic_tone"
}
if {[string first "/build/gowin" $build_dir] >= 0} {
    error "BUILD_DIR must not be inside build/gowin (got: $build_dir)"
}
file mkdir $build_dir

create_project -name diagnostic_tone -dir $build_dir -pn GW5AST-LV138FPG676AES -device_version B -force
set_option -verilog_std sysv2017
set_option -top_module diagnostic_tone_top

# Real vendor PLL IP (audio PLL only; the core 100 MHz PLL is NOT used here).
add_file "$plat/ip/pll_init.v"
add_file "$plat/ip/pll_audio_12m5/gowin_pll_audio_12m5.v"
add_file "$plat/ip/pll_audio_12m5/gowin_pll_audio_12m5_mod.v"

# Diagnostic RTL + existing read-only I2S transmitter.
add_file "$diag/tone_source.sv"
add_file "$diag/top.sv"
add_file "$root/rtl/audio/i2s_amp_tx.sv"

# Diagnostic pin/timing constraints.
add_file "$diag/tone.cst"
add_file "$diag/tone.sdc"

puts "FILES_ADDED"
run syn
puts "SYN_DONE"
run pnr
puts "PNR_DONE"

# NOTE: dedicated timing reports are NOT emitted from this Tcl context.
# After P&R, gw_sh no longer provides the SDC reporting command set (there is no
# get_ports), so raw `report_timing ... [get_ports ...]` calls fail with
# `invalid command name "get_ports"` and produce nothing.  The complete setup/hold
# timing report is instead produced from the active SDC configuration (the
# trailing report_timing commands in tone.sdc, max_paths 300, no pin filter) and
# is written by the flow to the implementation report:
#   <BUILD_DIR>/diagnostic_tone/impl/pnr/diagnostic_tone.tr
# The parent extracts the three amp_* output-pin extrema from that full report's
# Slow (setup) and Fast (hold) sections; no pin-filtered report is generated here.
