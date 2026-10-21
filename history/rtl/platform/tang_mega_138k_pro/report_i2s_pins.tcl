# -----------------------------------------------------------------------------
# report_i2s_pins.tcl -- 为三个外部 I2S 输出引脚发射专用的 setup/hold 时序报告，
# 从 clk_audio 发射，供父会话的
# sim/review_i2s_pin_delays.py 检查器使用。
#
# 用法（在 P&R 完成之后）：
#   printf 'source rtl/platform/tang_mega_138k_pro/report_i2s_pins.tcl\n' | gw_sh -nocomp
# 将 i2s_setup.rpt / i2s_hold.rpt 写入 P&R impl 目录。
#
# 报告带有完整的 "Path Summary:" 块以及发射边沿行，
# 因此检查器可以减去标称边沿偏移，并保留真实的
# clock-insertion/C2Q/route/pad 延迟。
# -----------------------------------------------------------------------------
set root [pwd]
set impl "$root/build/gowin/audio_board/impl/pnr"
open_project "$root/build/gowin/audio_board/audio_board.gprj"

set pins {amp_bclk amp_din amp_lrc}
report_timing -setup -from_clock clk_audio -to [get_ports $pins] -max_paths 12 -max_common_paths 1 > "$impl/i2s_setup.rpt"
report_timing -hold  -from_clock clk_audio -to [get_ports $pins] -max_paths 12 -max_common_paths 1 > "$impl/i2s_hold.rpt"
puts "I2S_PIN_REPORTS_DONE"
