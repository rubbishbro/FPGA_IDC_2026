# 从仓库根目录执行；BOARD_PNR=1 时继续 PnR，产物与旧 demo 分开。
set root [file normalize [pwd]]
set out "$root/build/sidebar_board"
set board "$root/FFT_spectrumshow/board"
file mkdir $out
create_project -name sidebar_board -dir $out -pn GW5AST-LV138FPG676AES -device_version B -force
set_option -verilog_std sysv2017
set_option -top_module ui_demo_top
set manifest [open "$board/ui_demo.gprj" r]
set project [read $manifest]
close $manifest
foreach {whole path} [regexp -all -inline {<File path="([^"]+)" type="file.verilog"} $project] {
    add_file [file normalize "$board/$path"]
}
foreach mem [glob "$board/*.mem"] {file copy -force $mem "$out/sidebar_board/[file tail $mem]"}
add_file "$board/ui_demo.cst"
add_file "$board/timing.sdc"
run syn
puts "SIDEBAR_SYN_DONE"
if {[info exists ::env(BOARD_PNR)] && $::env(BOARD_PNR) == "1"} {
    run pnr
    puts "SIDEBAR_PNR_DONE"
}
