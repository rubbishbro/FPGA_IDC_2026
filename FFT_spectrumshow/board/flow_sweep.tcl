open_project "ui_demo_sweep.gprj"
set_option -verilog_std sysv2017
set_option -top_module sweep_demo_top
run all
file copy -force "impl/pnr/ui_demo_sweep.fs" "impl/pnr/sweep_demo.fs"
exit
