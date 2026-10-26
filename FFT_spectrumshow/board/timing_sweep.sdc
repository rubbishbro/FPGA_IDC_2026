create_clock -name clk50 -period 20.000 [get_ports {clk}]

create_generated_clock -name clk_pix -source [get_ports {clk}] -master_clock clk50 -divide_by 3 -multiply_by 2 [get_pins {*Gowin_PLL_inst/PLL_inst/CLKOUT0}]

# Sweep/CDC test: separate 100 MHz PLL for the PCM source domain.
# time_pingpong is the CDC boundary between clk_src and clk_pix.
create_generated_clock -name clk_src -source [get_ports {clk}] -master_clock clk50 -divide_by 1 -multiply_by 2 [get_pins {*Gowin_PLL_SRC_inst/PLL_inst/CLKOUT0}]

set_clock_groups -asynchronous -group {clk_src} -group {clk_pix}
set_clock_groups -asynchronous -group {clk50} -group {clk_pix}

# Board key is asynchronous; first synchronizer stage is intentional.
set_false_path -from [get_ports {key0}]
