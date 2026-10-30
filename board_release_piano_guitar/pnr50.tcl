open_project "build/instrument_board/instrument_board/instrument_board.gprj"
set_option -top_module instrument_board_top
set_option -use_sspi_as_gpio 1
set_option -use_cpu_as_gpio 1
set_option -use_mspi_as_gpio 1
run pnr
puts "BOARD50_PNR_DONE"
