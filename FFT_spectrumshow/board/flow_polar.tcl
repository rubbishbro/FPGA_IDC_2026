open_project "ui_demo_polar.gprj"
set_option -verilog_std sysv2017
set_option -top_module polar_demo_top
run all
file copy -force "impl/pnr/ui_demo_polar.fs" "impl/pnr/polar_demo.fs"
exit
