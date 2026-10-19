# 只跑一个顶层：由环境变量 TOP 指定（fmax_seq / fmax_ram / fmax_e7），便于多进程并行
# 环境变量 SDC 可换约束文件（默认 fmax.sdc = 100 MHz，fmax200.sdc = 200 MHz 用于探真实 Fmax）
set here [file dirname [file normalize [info script]]]
set root [file normalize "$here/../../.."]
set top $::env(TOP)
if {[info exists ::env(SDC)]} { set sdc $::env(SDC) } else { set sdc "fmax.sdc" }

set build "$root/build/${top}_pnr"
file mkdir $build
create_project -name ${top}_pnr -dir $build -pn GW5AST-LV138FPG676AES -device_version B -force
set_option -verilog_std sysv2017
set_option -top_module $top
add_file "$here/../../math/pkg/fxp_pkg.sv"
add_file "$here/../modal_step_pkg.sv"
add_file "$here/../coeff_loader.sv"
add_file "$here/../modal_bank_seq.sv"
add_file "$here/../modal_bank_ram.sv"
add_file "$here/../modal_engine7.sv"
    add_file "$here/../modal_voice_top.sv"
    add_file "$here/../modal_voice_top_ab.sv"
add_file "$here/../top_seq.sv"
add_file "$here/../top_ram.sv"
add_file "$here/../fmax_probe.sv"
add_file "$here/../constr/$sdc"
add_file "$here/../constr/fmax.cst"
puts "FILES_ADDED $top"
run syn
run pnr
puts "PNR_DONE $top"
