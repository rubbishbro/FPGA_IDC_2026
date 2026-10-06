# -----------------------------------------------------------------------------
# tang_mega_138k_pro.sdc -- clock / CDC / external-output constraints.
#
# Syntax follows SUG940 (Gowin Design Timing Constraints User Guide); loaded by the
# real Gowin V1.9.12.04 timing engine during place & route.
#
# ACTUAL clocks in this build (12.5 MHz functional bring-up, NOT exact 12.288):
#   50 MHz crystal       -> 20.000 ns
#   100 MHz core PLL     -> 10.000 ns
#   12.5 MHz audio PLL   -> 80.000 ns  (BCLK 3.125 MHz / 320 ns; LRC 48.828 kHz)
# ROM is the 48 kHz coefficient set, so the diagnostic runs ~1.725% fast; not
# 48 kHz-faithful.
#
# EXTERNAL I2S OUTPUT MODEL (revised):
# The amp pins are NOT declared as a generated clock on the output port.  The
# tool's current policy does not create virtual clocks (SUG940: "Create Clock does
# not support the creation of virtual clocks"), so we use a *clock-source-to-output*
# (C2O) path-envelope model instead: bound the launch (clk_audio) -> pad delay to
# [min,max] = [0, 40] ns.  This is a PATH ENVELOPE, not a per-corner measurement;
# it is combined with a separate falling-edge differential argument for the MAX
# receiver in BOARD_DELIVERY_REPORT.md.  raw report SHA + bound_vs_measured are
# recorded there; the parent re-runs review_i2s_pin_delays independently.
#   d_max <= 40 ns (constraint)  and  d_min >= 0 ns (constraint)
#   forwarded-edge differential (nominal half-BCLK 160 ns, budget 10 ns):
#       setup >= 160 + d_min(BCLK) - d_max(Data) - 10 >= 110 ns
#       hold  >= 160 + d_min(Data) - d_max(BCLK) - 10 >= 110 ns
#   which is far above the MAX98357A 10 ns requirement, PROVIDED the actual C2O
#   paths are inside [0,40] and the STA confirms zero violations on these
#   endpoints at the Slow(0C)/Fast(85C) corners.  Until every audio-output
#   endpoint shows non-negative setup AND hold with no missing-clock/ignored
#   constraint and the clock model is independently justified, this remains
#   OPEN. The reviewed core100 baseline has zero setup/hold violations but a
#   negative clock minimum-pulse-width check; a nominal latency override is not
#   accepted as a physical fix.
# -----------------------------------------------------------------------------

create_clock -name clk_50m -period 20.000 [get_ports {clk}]

# Generated clocks for the two PLL outputs.  board_top instantiates top as u_top,
# so the pin paths carry the u_top prefix (confirmed against the P&R netlist).
create_generated_clock -name clk_core -source [get_ports {clk}] -master_clock clk_50m -divide_by 1 -multiply_by 2 [get_pins {u_top/u_clock_reset/u_pll_core/u_pll/PLL_inst/CLKOUT0}]
create_generated_clock -name clk_audio -source [get_ports {clk}] -master_clock clk_50m -divide_by 100 -multiply_by 25 [get_pins {u_top/u_clock_reset/u_pll_audio/u_pll/PLL_inst/CLKOUT0}]

# -----------------------------------------------------------------------------
# PLL source model: preserve the device timing model, including its early/late
# and rise/fall extremes. A candidate set_clock_latency -source 3.765 on both
# PLL clocks made MPW positive, but was NOT accepted: SUG940 documents the
# command syntax, not permission to replace physical min/max latency with a
# midpoint. Nominal 50% duty does not prove zero duty distortion or correlated
# timing variation for two different PLLs. Any revised model needs independent
# device/PVT/duty/jitter evidence; do not use a nominal override to obtain a pass.
# The rejected candidate and its original reports are preserved separately.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# CDC between clk_core and clk_audio.
#   * the async-FIFO Gray pointers are bounded by a max_delay (they need the
#     bit-to-bit bound, so they are NOT false-pathed);
#   * the 2-FF synchroniser *first-stage* capture registers are asynchronous
#     across the two unrelated clocks, so a scoped hold exception belongs on
#     those endpoints only -- NOT a blanket clock-group false path (which would
#     also erase the Gray bound above).
# The Gray bounds below are applied by clock pair.  The scoped stage-1 hold
# exception must be applied by net/pin name from the post-synthesis netlist
# (set_false_path -through [get_pins {<sync_stage1>/D}] -hold) once the exact
# synchroniser register names are confirmed; it is intentionally NOT expressed as
# a broad clock group here.  This item is OPEN until those names are fixed.
# -----------------------------------------------------------------------------
set_max_delay -from [get_clocks {clk_core}] 10.000 -to [get_clocks {clk_audio}]
set_max_delay -from [get_clocks {clk_audio}] 10.000 -to [get_clocks {clk_core}]

# -----------------------------------------------------------------------------
# External I2S outputs: C2O path envelope [0,40] ns relative to clk_audio.
# -----------------------------------------------------------------------------
set_output_delay -clock clk_audio  40.000 -max [get_ports {amp_bclk}]
set_output_delay -clock clk_audio   0.000 -min [get_ports {amp_bclk}]
set_output_delay -clock clk_audio  40.000 -max [get_ports {amp_din}]
set_output_delay -clock clk_audio   0.000 -min [get_ports {amp_din}]
set_output_delay -clock clk_audio  40.000 -max [get_ports {amp_lrc}]
set_output_delay -clock clk_audio   0.000 -min [get_ports {amp_lrc}]

# -----------------------------------------------------------------------------
# Asynchronous-assert / synchronous-release reset synchronisers.
# Each dedicated reset-sync chain is a plain 2FF/3FF shift register whose flops
# share the SAME asynchronous CLEAR (assert); the synchronous release is driven
# from the clock_reset PLL-lock FSM, so the per-stage CLEAR pins see the reset
# *deassert* crossing, not a synchronous data hold.  Scope the hold exception to
# the CLEAR pins of EVERY stage of these dedicated chains only:
#   * clock_reset 3FF crst_sync
#   * audio_demo_core 2FF crst_sync
#   * audio_transport 2FF arst_sync
# Normal state/D registers and the synchroniser outputs driving normal logic are
# NOT touched.  Recovery/removal on the outputs is preserved, and the Gray CDC
# max_delay and downstream setup/hold are untouched.
# -----------------------------------------------------------------------------
set_false_path -hold -to [get_pins {u_top/u_clock_reset/crst_sync_0_s0/CLEAR}]
set_false_path -hold -to [get_pins {u_top/u_clock_reset/crst_sync_1_s0/CLEAR}]
set_false_path -hold -to [get_pins {u_top/u_clock_reset/crst_sync_2_s0/CLEAR}]
set_false_path -hold -to [get_pins {u_top/u_audio/u_core/crst_sync_0_s0/CLEAR}]
set_false_path -hold -to [get_pins {u_top/u_audio/u_core/crst_sync_1_s0/CLEAR}]
set_false_path -hold -to [get_pins {u_top/u_audio/u_core/u_transport/arst_sync_0_s0/CLEAR}]
set_false_path -hold -to [get_pins {u_top/u_audio/u_core/u_transport/arst_sync_1_s0/CLEAR}]

# -----------------------------------------------------------------------------
# amp_sd is an ASYNCHRONOUS slow configuration/mute output to the MAX98357A, not
# a synchronous clock-sampled output.  The real requirement is a settle/mute
# latency bound from the core/reset/lock domain to the pad, so use max_delay
# (engineering gate 100 ns), not a per-core-clock output capture.  Expressed by
# clock groups (resolvable) rather than unconfirmed internal pin names.
# -----------------------------------------------------------------------------
set_max_delay -from [get_clocks {clk_core}] 100.000 -to [get_ports {amp_sd}]
set_max_delay -from [get_ports {reset}] 100.000 -to [get_ports {amp_sd}]
