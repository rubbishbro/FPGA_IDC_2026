# -----------------------------------------------------------------------------
# synth_dsp_probe.tcl -- Gowin 综合检查：寄存器化的乘法拍（回答 DSP 问题）
#
# 与 synth_bank.tcl 的差别只在顶层模块，用来对比"组合乘法"与"寄存器化乘法"的资源。
# 输出：<repo>/build/dsp_probe_syn
# -----------------------------------------------------------------------------

set root [pwd]
set here [file dirname [file normalize [info script]]]
set build "$root/build/dsp_probe_syn"

file mkdir $build

create_project -name dsp_probe_syn -dir $build -pn GW5AST-LV138FPG676AES -device_version B -force
set_option -verilog_std sysv2017
set_option -top_module dsp_probe

add_file "$here/../math/pkg/fxp_pkg.sv"
add_file "$here/modal_step_pkg.sv"
add_file "$here/dsp_probe.sv"

puts "FILES_ADDED"
run syn
puts "SYN_DONE"
