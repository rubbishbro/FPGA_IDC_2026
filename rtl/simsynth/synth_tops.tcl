# 两个顶层各综合一次（同样的设备/选项），用于公平对比
set root [pwd]
set here [file dirname [file normalize [info script]]]

foreach {name files} {
    top_seq_syn {../math/pkg/fxp_pkg.sv modal_step_pkg.sv coeff_loader.sv modal_bank_seq.sv top_seq.sv}
    top_ram_syn {../math/pkg/fxp_pkg.sv modal_step_pkg.sv coeff_loader.sv modal_bank_ram.sv top_ram.sv}
} {
    set build "$root/build/$name"
    file mkdir $build
    create_project -name $name -dir $build -pn GW5AST-LV138FPG676AES -device_version B -force
    set_option -verilog_std sysv2017
    set_option -top_module [string map {_syn {}} $name]
    foreach f $files { add_file "$here/$f" }
    puts "FILES_ADDED $name"
    run syn
}
puts "SYN_DONE"
