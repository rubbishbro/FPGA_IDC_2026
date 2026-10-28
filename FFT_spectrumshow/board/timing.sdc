create_clock -name clk50 -period 20.000 [get_ports {clk}]

create_generated_clock -name clk_pix -source [get_ports {clk}] -master_clock clk50 -divide_by 3 -multiply_by 2 [get_pins {*Gowin_PLL_inst/PLL_inst/CLKOUT0}]

# Compute (50 MHz board clock) and pixel (33.333 MHz) are treated as
# asynchronous; the frame buffer / 2FF handshake is the CDC boundary.
set_clock_groups -asynchronous -group {clk50} -group {clk_pix}

# Board key is asynchronous; first synchronizer stage is intentional.
set_false_path -from [get_ports {key0}]
set_false_path -from [get_ports {key1}]
