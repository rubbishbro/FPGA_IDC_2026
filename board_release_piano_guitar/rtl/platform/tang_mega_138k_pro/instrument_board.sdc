create_clock -name clk50 -period 20.000 [get_ports {clk}]
create_generated_clock -name clk_core -source [get_ports {clk}] -master_clock clk50 -divide_by 1 [get_pins {u_clocks/u_core/u_pll/PLL_inst/CLKOUT0}]
create_generated_clock -name clk_audio -source [get_ports {clk}] -master_clock clk50 -divide_by 4 [get_pins {u_clocks/u_core/u_pll/PLL_inst/CLKOUT1}]
create_generated_clock -name clk_pix -source [get_ports {clk}] -master_clock clk50 -multiply_by 2 -divide_by 3 [get_pins {u_clocks/u_core/u_pll/PLL_inst/CLKOUT2}]

# Bundled-data/toggle and Gray-pointer CDC: bound only actual first captures.
# Second synchronizer stages keep normal destination-clock timing.
set_max_delay -from [get_clocks {clk_core}] -to [get_pins {u_system/u_sound/g_audio.u_audio/u_fifo/wgray_s1_*/D}] 10.000
set_max_delay -from [get_clocks {clk_audio}] -to [get_pins {u_system/u_sound/g_audio.u_audio/u_fifo/rgray_s1_*/D}] 10.000
set_max_delay -from [get_pins {u_system/u_sound/g_audio.u_audio/frame_toggle*/Q}] -to [get_pins {u_system/u_sound/g_audio.u_audio/frame_s1*/D}] 10.000
set_max_delay -from [get_pins {u_system/u_ui/u_view_cdc/request_toggle*/Q}] -to [get_pins {u_system/u_ui/u_view_cdc/req_meta*/D}] 10.000
set_max_delay -from [get_pins {u_system/u_ui/u_view_cdc/ack_toggle*/Q}] -to [get_pins {u_system/u_ui/u_view_cdc/ack_meta*/D}] 10.000
# Synthesis merges held_data into sent_view (identical held transaction).
# Constrain the capture endpoints from core, independent of that legal alias.
set_max_delay -from [get_clocks {clk_core}] -to [get_pins {u_system/u_ui/pixel_view*/D}] 10.000
# Only the reset synchronizer chains intentionally receive asynchronous release.
# Functional payload/state registers use the locally synchronized reset output.
set_false_path -to [get_pins {u_system/u_sound/u_voice/child_reset*/CLEAR u_system/core_reset*/CLEAR u_system/audio_reset*/CLEAR u_system/pix_reset*/CLEAR u_system/u_ui/ctrl_reset*/CLEAR u_system/u_ui/pix_reset*/CLEAR u_system/u_ui/u_view_cdc/src_reset*/CLEAR u_system/u_ui/u_view_cdc/dst_reset*/CLEAR u_system/u_sound/g_audio.u_audio/arst*/CLEAR u_system/u_sound/g_audio.u_audio/u_fifo/wrst_sync*/CLEAR u_system/u_sound/g_audio.u_audio/u_fifo/rrst_sync*/CLEAR}]

# Asynchronous board inputs terminate in explicit synchronizers.
set_false_path -from [get_ports {key0 key1 uart_rx[0] uart_rx[1] bt_state}]
# I2S C2O envelope for bring-up. Physical setup/hold still requires board validation.
set_output_delay -clock clk_audio -max 40.000 [get_ports {amp_bclk amp_ws amp_din}]
set_output_delay -clock clk_audio -min 0.000 [get_ports {amp_bclk amp_ws amp_din}]
# LCD engineering budget, not a substitute for the actual panel timing specification.
set_output_delay -clock clk_pix -max 10.000 [get_ports {lcd_en lcd_r[*] lcd_g[*] lcd_b[*]}]
set_output_delay -clock clk_pix -min 0.000 [get_ports {lcd_en lcd_r[*] lcd_g[*] lcd_b[*]}]
set_max_delay -from [get_ports {rst_n}] -to [get_ports {amp_sd}] 100.000

# Include per-domain paths even when many core endpoints dominate the global top.
report_timing -setup -max_paths 100 -max_common_paths 1
report_timing -setup -from_clock [get_clocks {clk_pix}] -to_clock [get_clocks {clk_pix}] -max_paths 25 -max_common_paths 1
report_timing -recovery -max_paths 50 -max_common_paths 1

# First synchronizer captures intentionally tolerate arbitrary inter-domain phase.
# Keep their setup routing bounds above; second stages are never excepted.
set_false_path -hold -from [get_clocks {clk_core}] -to [get_pins {u_system/u_sound/g_audio.u_audio/u_fifo/wgray_s1_*/D u_system/u_ui/u_view_cdc/req_meta*/D u_system/u_ui/pixel_view*/D}]
set_false_path -hold -from [get_clocks {clk_audio}] -to [get_pins {u_system/u_sound/g_audio.u_audio/u_fifo/rgray_s1_*/D u_system/u_sound/g_audio.u_audio/frame_s1*/D}]
set_false_path -hold -from [get_clocks {clk_pix}] -to [get_pins {u_system/u_ui/u_view_cdc/ack_meta*/D}]
