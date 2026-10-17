# -----------------------------------------------------------------------------
# synth_bank.tcl -- Gowin 综合检查：TDM bank（modal_bank_seq）
#
# 调用：pwsh -File _analysis/rtl_modal/run_gwsh.ps1
# 输出：<repo>/build/modal_bank_syn（build/ 已 gitignore）
# -----------------------------------------------------------------------------

set root [pwd]
set here [file dirname [file normalize [info script]]]
set build "$root/build/modal_bank_syn"

file mkdir $build

create_project -name modal_bank_syn -dir $build -pn GW5AST-LV138FPG676AES -device_version B -force
set_option -verilog_std sysv2017
set_option -top_module modal_bank_seq

add_file "$here/../math/pkg/fxp_pkg.sv"
add_file "$here/modal_step_pkg.sv"
add_file "$here/modal_bank_seq.sv"

puts "FILES_ADDED"
run syn
puts "SYN_DONE"
