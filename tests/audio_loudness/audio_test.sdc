create_clock -name clk50 -period 20.000 [get_ports {clk}]
# Only asynchronous reset synchronizers and the first key capture are excepted.
set_false_path -from [get_ports {key0 key1}] -to [get_pins {u_core/key_meta*/D}]
set_false_path -to [get_pins {u_core/reset_sync*/CLEAR}]
set_output_delay -clock clk50 -max 10.000 [get_ports {amp_bclk amp_ws amp_din dac_bck dac_ws dac_din amp_sd dac_pa_en}]
set_output_delay -clock clk50 -min 0.000 [get_ports {amp_bclk amp_ws amp_din dac_bck dac_ws dac_din amp_sd dac_pa_en}]
report_timing -setup -max_paths 20
report_timing -hold -max_paths 20
