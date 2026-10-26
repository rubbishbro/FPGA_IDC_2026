set here "D:/PythonProject/SythSound/rtl/router"
set root "D:/PythonProject/SythSound"
set top $::env(TOP)
set build "$root/build/${top}_syn"
file mkdir $build
create_project -name ${top}_syn -dir $build -pn GW5AST-LV138FPG676AES -device_version B -force
set_option -verilog_std sysv2017
set_option -top_module $top
add_file "$root/rtl/math/pkg/fxp_pkg.sv"
add_file "$root/rtl/drivers/pkg/clk_rst_pkg.sv"
add_file "$root/rtl/drivers/pkg/pad_driver_pkg.sv"
add_file "$here/pkg/modal_step_pkg.sv"
add_file "$here/pkg/router_pkg.sv"
add_file "$here/engines/eng0.sv"
add_file "$here/engines/eng1.sv"
add_file "$here/parts/envelope.sv"
add_file "$here/parts/excitation.sv"
add_file "$here/parts/modulation.sv"
# 注意：parts/comb_reverb.sv 和 routers/reverb_router.sv 已经写好并单独验证过
#       （tb_reverb），但**还没接进 voice_router**，所以先不加进这条流程；
#       接的时候把这两个文件一起加进来。
add_file "$here/parts/body_biquad.sv"
add_file "$here/parts/comb_reverb.sv"
add_file "$here/routers/exc_router.sv"
add_file "$here/routers/body_router.sv"
add_file "$here/routers/reverb_router.sv"
add_file "$here/routers/env_router.sv"
add_file "$here/routers/mod_router.sv"
add_file "$here/routers/eng_router.sv"
add_file "$here/loader.sv"
add_file "$here/voice_router.sv"
add_file "$here/fmax_router.sv"
puts "SYN_TOP $top"
run syn
puts "SYN_DONE $top"
