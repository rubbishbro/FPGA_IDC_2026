create_clock -name clk -period 10.000 -waveform {0.000 5.000} [get_ports {clk}]
# Only asynchronous physical inputs/reset are excepted, NOT internal UART/CDC
# synchronizer-to-synchronizer, parser, FIFO, CRC, or register paths.
set_false_path -from [get_ports {rst_n rx_i[0] rx_i[1] state_async}]
