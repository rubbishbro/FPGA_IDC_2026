create_clock -name clk50 -period 20.000 [get_ports {clk}]

# LED serial frame is a slow 400 ns protocol; idx/gram are not 50 MHz paths.
set_false_path -from [get_regs {u_pad/led_inst/idx_*}] -to [get_regs {u_pad/led_inst/trig_*}]




set_false_path -from [get_regs {u_pad/led_inst/gram_*}] -to [get_regs {u_pad/led_inst/trig_*}]
