# 只跑一个顶层：由环境变量 TOP 指定（fmax_seq / fmax_ram），便于两个进程并行
set here [file dirname [file normalize [info script]]]
set root [pwd]
set top $::env(TOP)

set build "$root/build/${top}_pnr"
file mkdir $build
create_project -name ${top}_pnr -dir $build -pn GW5AST-LV138FPG676AES -device_version B -force
set_option -verilog_std sysv2017
set_option -top_module $top
add_file "$here/../math/pkg/fxp_pkg.sv"
add_file "$here/modal_step_pkg.sv"
add_file "$here/coeff_loader.sv"
add_file "$here/modal_bank_seq.sv"
add_file "$here/modal_bank_ram.sv"
add_file "$here/top_seq.sv"
add_file "$here/top_ram.sv"
add_file "$here/fmax_probe.sv"
add_file "$here/fmax.sdc"
add_file "$here/fmax.cst"
puts "FILES_ADDED $top"
run syn
run pnr
puts "PNR_DONE $top"
