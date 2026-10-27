# 从仓库根目录 source；仅综合适配层，不替代整机 PnR/CDC/ADC 验收。
set root [pwd]
set out "$root/build/joystick_synth"
file mkdir $out
create_project -name joystick_adapter -dir $out -pn GW5AST-LV138FPG676AES -device_version B -force
set_option -verilog_std sysv2017
set_option -top_module joystick_adapter
add_file "$root/rtl/drivers/pkg/joystick_pkg.sv"
add_file "$root/rtl/drivers/joystick_adapter.sv"
run syn
puts "JOYSTICK_SYN_DONE"
