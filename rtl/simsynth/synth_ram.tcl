set root [pwd]
set here [file dirname [file normalize [info script]]]
set build "$root/build/modal_bank_ram_syn"
file mkdir $build
create_project -name modal_bank_ram_syn -dir $build -pn GW5AST-LV138FPG676AES -device_version B -force
set_option -verilog_std sysv2017
set_option -top_module modal_bank_ram
add_file "$here/modal_step_pkg.sv"
add_file "$here/modal_bank_ram.sv"
puts "FILES_ADDED"
run syn
puts "SYN_DONE"
