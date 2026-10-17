# 两个方案各做一次 syn + PnR，拿真实 Fmax（时钟约束 100 MHz = 10 ns）
set root [pwd]
set here [file dirname [file normalize [info script]]]

foreach top {fmax_seq fmax_ram fmax_e7} {
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
    add_file "$here/modal_engine7.sv"
    add_file "$here/modal_voice_top.sv"
    add_file "$here/top_seq.sv"
    add_file "$here/top_ram.sv"
    add_file "$here/fmax_probe.sv"
    add_file "$here/fmax.sdc"
    add_file "$here/fmax.cst"
    puts "FILES_ADDED $top"
    run syn
    run pnr
    puts "PNR_DONE $top"
}
