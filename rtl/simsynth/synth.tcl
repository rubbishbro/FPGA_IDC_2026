# -----------------------------------------------------------------------------
# synth.tcl -- 用 Gowin gw_sh 综合 string_mode_step（只综合，不做 PnR）
#
# 为什么只做 syn：本模块是纯组合逻辑子模块，顶层接入方式还没定，也就没有引脚约束；
# 这里要证明的是"Gowin 综合器接受这份 SystemVerilog"，不是产出 bitstream。
#
# 调用方式（Gowin V1.9.12 这个版本的 gw_sh <file> 不会执行脚本，必须从标准输入 source）：
#   pwsh -File _analysis/rtl_modal/run_gwsh.ps1
# 或手工：
#   cd <repo root>
#   'source _analysis/rtl_modal/synth.tcl' | & $env:GOWIN/gw_sh.exe -nocomp
#
# 输出目录在 <repo>/build/modal_step_syn（build/ 已被 .gitignore 忽略）。
# -----------------------------------------------------------------------------

set root [pwd]
set here [file dirname [file normalize [info script]]]
set build "$root/build/modal_step_syn"

file mkdir $build

create_project -name modal_step_syn -dir $build -pn GW5AST-LV138FPG676AES -device_version B -force
set_option -verilog_std sysv2017
set_option -top_module string_mode_step

add_file "$here/modal_step_pkg.sv"
add_file "$here/string_mode_step.sv"

puts "FILES_ADDED"
run syn
puts "SYN_DONE"
