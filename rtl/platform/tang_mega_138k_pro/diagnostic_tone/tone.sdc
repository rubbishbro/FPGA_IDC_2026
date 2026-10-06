# -----------------------------------------------------------------------------
# tone.sdc -- standalone diagnostic-tone timing constraints.
#
# Independent of the production SDC (tang_mega_138k_pro.sdc) and written for the
# diagnostic_tone_top hierarchy only.  No set_clock_latency is used anywhere.
#
# Clock model:
#   50 MHz crystal   clk        -> 20.000 ns
#   12.5 MHz audio   clk_audio  -> generated from clk, divide_by 100 multiply_by 25
#                                 (NOT exact 12.288 MHz; see top.sv header)
#
# This is a CONSERVATIVE DIAGNOSTIC budget, not a datasheet-signed-off fact:
#   0.400 ns setup uncertainty is added on clk_audio as extra margin.  The parent
#   certificate flow explicitly rejects uncertainty overrides, so this SDC is NOT
#   valid input to sim/review_i2s_pin_delays.py --certified-report; it is only for
#   the diagnostic bring-up build.
#
# External I2S output model (C2O path envelope), copied in form from the
# production SDC:  launch (clk_audio) -> pad delay bounded to [0, 40] ns.  This is
# a PATH ENVELOPE, NOT a per-corner measurement, and is NOT a complete external
# I2S certificate: it must be combined with the RTL edge relation and an
# independent board/jitter budget, and every endpoint must still show non-negative
# setup/hold with no ignored constraint.
#
#   d_max <= 40 ns (constraint)  and  d_min >= 0 ns (constraint)
# -----------------------------------------------------------------------------

create_clock -name clk_50m -period 20.000 [get_ports {clk}]

# Generated audio clock.  diagnostic_tone_top instantiates the PLL directly as
# u_pll_audio, so the pin path carries that prefix (confirmed by pattern; the
# exact name is re-checked against the P&R netlist by the parent).
create_generated_clock -name clk_audio -source [get_ports {clk}] -master_clock clk_50m -divide_by 100 -multiply_by 25 [get_pins {u_pll_audio/u_pll/PLL_inst/CLKOUT0}]

# Conservative extra setup margin for the diagnostic build (see header).
# Gowin TA1030 requires explicit -from/-to endpoints; this is a SAME-DOMAIN
# clk_audio -> clk_audio reserve, i.e. one launch/capture budget applied to every
# internal audio-domain setup check.  It deliberately does not bound any
# cross-domain (lock) transfer.
set_clock_uncertainty -setup 0.400 -from [get_clocks {clk_audio}] -to [get_clocks {clk_audio}]

# -----------------------------------------------------------------------------
# External I2S outputs: C2O path envelope [0,40] ns relative to clk_audio.
# (Same form as the production SDC; NOT a full external-I2S certificate.)
# -----------------------------------------------------------------------------
set_output_delay -clock clk_audio  40.000 -max [get_ports {amp_bclk}]
set_output_delay -clock clk_audio   0.000 -min [get_ports {amp_bclk}]
set_output_delay -clock clk_audio  40.000 -max [get_ports {amp_din}]
set_output_delay -clock clk_audio   0.000 -min [get_ports {amp_din}]
set_output_delay -clock clk_audio  40.000 -max [get_ports {amp_lrc}]
set_output_delay -clock clk_audio   0.000 -min [get_ports {amp_lrc}]

# -----------------------------------------------------------------------------
# amp_sd is an ASYNCHRONOUS slow configuration/mute output to the MAX98357A, not
# a clock-sampled data output.  Bound the audio-domain launch-to-pad settle
# latency (engineering gate 100 ns).  The async PLL-lock -> SD path is a short
# combinational mute and is not separately constrained here.
# -----------------------------------------------------------------------------
set_max_delay -from [get_clocks {clk_audio}] 100.000 -to [get_ports {amp_sd}]

# -----------------------------------------------------------------------------
# Dedicated 3FF async-assert / sync-release reset synchronizer.
# The three flops share the SAME asynchronous CLEAR (raw audio_locked deassert);
# the synchronous release comes from the shift register, so a scoped hold
# exception is placed on the CLEAR pins of EVERY stage of this dedicated chain
# ONLY.
# The reset RELEASE seen by normal logic is rst_sync[2] alone (top.sv:
# assign rst_n = rst_sync[2]).  The raw lock is NOT combinational into the normal
# state CLEAR tree, so every ordinary state register is checked normally against
# the clk_audio-launched last-stage output.  Ordinary state/D registers, the
# final stage's normal timing, and recovery/removal on those normal CLEARs are
# NOT touched.  (amp_sd separately keeps raw audio_locked for an immediate mute.)
#
# EXACT register names (the `_s0` suffix) and any hierarchy prefix must be
# confirmed against the real P&R netlist; update these three pins if Gowin names
# them differently.  If the name does not match, the exception is a no-op and the
# ordinary hold/recovery/removal checks remain in force.
# -----------------------------------------------------------------------------
set_false_path -hold -to [get_pins {rst_sync_0_s0/CLEAR}]
set_false_path -hold -to [get_pins {rst_sync_1_s0/CLEAR}]
set_false_path -hold -to [get_pins {rst_sync_2_s0/CLEAR}]

# -----------------------------------------------------------------------------
# Full timing-report capture (SDC reporting context).
# gw_sh after P&R has no SDC reporting command set (no get_ports), so a
# pin-filtered report cannot be produced from the build Tcl.  These SDC reporting
# commands expand the complete setup/hold report WITHOUT a pin filter
# (-max_paths 300 covers all ~291 reported paths); the flow writes it to
#   <BUILD_DIR>/diagnostic_tone/impl/pnr/diagnostic_tone.tr
# The parent extracts the Slow (setup) / Fast (hold) amp_bclk / amp_din / amp_lrc
# output-pin extrema from that full report.  No timings are changed here.
# -----------------------------------------------------------------------------
report_timing -setup -max_paths 300 -max_common_paths 1
report_timing -hold  -max_paths 300 -max_common_paths 1
