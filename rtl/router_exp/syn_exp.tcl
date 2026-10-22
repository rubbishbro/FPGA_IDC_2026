set here "D:/PythonProject/SythSound/rtl/router_exp"
set root "D:/PythonProject/SythSound"
set top $::env(TOP)
set build "$root/build/${top}_exp"
file mkdir $build
create_project -name ${top}_exp -dir $build -pn GW5AST-LV138FPG676AES -device_version B -force
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
add_file "$here/routers/exc_router.sv"
add_file "$here/routers/env_router.sv"
add_file "$here/routers/mod_router.sv"
add_file "$here/loader.sv"
add_file "$here/voice_router.sv"
add_file "$here/fmax_router.sv"
puts "EXP_TOP $top"
run syn
puts "EXP_DONE $top"
