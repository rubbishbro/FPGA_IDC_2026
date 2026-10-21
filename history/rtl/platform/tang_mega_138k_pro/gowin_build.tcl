# -----------------------------------------------------------------------------
# gowin_build.tcl -- 板级顶层的真实 Gowin 工程构建入口。
#
# 使用已安装的 Gowin V1.9.9+（已验证 V1.9.12.04），从仓库根目录运行：
#   export LD_LIBRARY_PATH="$HOME/gowin/IDE/lib:$LD_LIBRARY_PATH"
#   cd <repo root>
#   printf 'source rtl/platform/tang_mega_138k_pro/gowin_build.tcl\n' | gw_sh -nocomp
# （此版本中 gw_sh <file> 不会运行脚本；需通过管道 `source`。）
#
# 器件：GW5AST-138B。FPG676 B 硅片器件库将型号暴露为
# `GW5AST-LV138FPG676AES`（ES）；裸 `...FPG676A` 不是已知的型号字符串。
# 烧录前请与用户确认物理器件型号。
#
# 顶层是 `board_top`（board_top.sv），它将 ROM 路径覆盖为绝对
# 路径，因此 $readmemh 绝不会静默漏掉镜像（WARN EX3988）。
#
# PLL IP（用户生成，位于 ip/ 下）：
#   Gowin_PLL_core_100M  -> 100 MHz   ip/pll_core_100m/
#   Gowin_PLL_audio_12M5 -> 12.5 MHz  ip/pll_audio_12m5/   （功能上电调试；
#                                     并非精确的 12.288 MHz -- 见 BOARD_README）
# 外加 PLL_ADV 支持文件 ip/pll_init.v。
#
# 必须选择 SystemVerilog-2017：综合器默认使用 Verilog-2001，
# 会拒绝 logic/always_ff。
# -----------------------------------------------------------------------------

set root [pwd]
set plat "$root/rtl/platform/tang_mega_138k_pro"

create_project -name audio_board -dir "$root/build/gowin" -pn GW5AST-LV138FPG676AES -device_version B -force
set_option -verilog_std sysv2017
set_option -top_module board_top
# 注意（阻塞项，核心 RTL）：rtl/core/poly_modal_lane.sv 中的 2C lane 工作缓存
# 被推断为 read-first（在同一个 always_ff 中 mem[addr]<=wdata; rdata<=mem[addr]），
# 而 GW5AST SPX9 BSRAM 无法实现该模式（P&R ERROR PA2122 WRITE_MODE=2'b10）。
# 使用真实 ROM 时综合可以通过；在核心所有者修复该核心
# 阵列的写模式之前，布局布线被阻塞。请勿用
# -ram_style distributed_ram 掩盖：那会超出 DFF 预算（RP0001）。

add_file "$plat/ip/pll_init.v"
add_file "$plat/ip/pll_core_100m/gowin_pll_core_100m.v"
add_file "$plat/ip/pll_core_100m/gowin_pll_core_100m_mod.v"
add_file "$plat/ip/pll_audio_12m5/gowin_pll_audio_12m5.v"
add_file "$plat/ip/pll_audio_12m5/gowin_pll_audio_12m5_mod.v"

add_file "$plat/board_top.sv"
add_file "$plat/top.sv"
add_file "$plat/clock_reset.sv"
add_file "$plat/board_audio_core.sv"
add_file "$root/rtl/audio/audio_async_fifo.sv"
add_file "$root/rtl/audio/pt8211_tx.sv"
add_file "$root/rtl/audio/i2s_amp_tx.sv"
add_file "$root/rtl/audio/i2s_mic_rx.sv"
add_file "$root/rtl/audio/audio_transport.sv"
add_file "$root/rtl/audio/song_player.sv"
add_file "$root/rtl/audio/audio_demo_core.sv"
add_file "$root/rtl/core/coeff_loader.sv"
add_file "$root/rtl/core/poly_modal_lane.sv"
add_file "$root/rtl/core/modal_poly_bank.sv"
add_file "$root/rtl/core/modal_engine.sv"
add_file "$root/rtl/core/body_filter.sv"

add_file "$plat/tang_mega_138k_pro.cst"
add_file "$plat/tang_mega_138k_pro.sdc"

puts "FILES_ADDED"
run syn
puts "SYN_DONE"
run pnr
puts "PNR_DONE"
# 专用外部 I2S 引脚时序报告（从 clk_audio 发射），供
# 父会话的 sim/review_i2s_pin_delays.py 使用。输出到 stdout；运行器会捕获
# 并拆分它们。
puts "I2S_SETUP_BEGIN"
report_timing -setup -from_clock clk_audio -to [get_ports {amp_bclk amp_din amp_lrc}] -max_paths 12 -max_common_paths 1
puts "I2S_SETUP_END"
puts "I2S_HOLD_BEGIN"
report_timing -hold -from_clock clk_audio -to [get_ports {amp_bclk amp_din amp_lrc}] -max_paths 12 -max_common_paths 1
puts "I2S_HOLD_END"
