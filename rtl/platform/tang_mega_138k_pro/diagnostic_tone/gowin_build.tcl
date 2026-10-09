# -----------------------------------------------------------------------------
# gowin_build.tcl —— 独立连续诊断音（diagnostic_tone_top）的真实 Gowin 工程构建入口。
#
# 这是与自动演奏歌曲构建分开的独立工程。它不触碰 build/gowin 或任何生产产物，也不
# 替代主工程。它只构建：
#   * 现有的真实 Gowin_PLL_audio_12M5 IP（没有 100 MHz 核心 PLL），
#   * 诊断用的 tone_source.sv / top.sv，
#   * 现有的只读 rtl/audio/i2s_amp_tx.sv，
#   * 诊断用的 tone.cst / tone.sdc。
#
# 在已安装的 Gowin V1.9.9+（已验证 V1.9.12.04）下，从仓库根目录运行：
#   export LD_LIBRARY_PATH="$HOME/gowin/IDE/lib:$LD_LIBRARY_PATH"
#   cd <repo root>
#   printf 'source rtl/platform/tang_mega_138k_pro/diagnostic_tone/gowin_build.tcl\n' | gw_sh -nocomp
# （此发布版中 gw_sh <file> 不会运行脚本；请通过管道 `source`。）
#
# BUILD_DIR：输出目录被强制到专用树，且绝不能位于 build/gowin 内。设置 BUILD_DIR 环境
# 变量可覆盖它；否则默认值为 <repo>/build/diagnostic_tone。任何解析后落入 build/gowin
# 的路径都会在任何工具运行前被拒绝，因此诊断构建无法覆盖生产工程。
#
# 必须选择 SystemVerilog-2017：综合器默认使用 Verilog-2001，会拒绝 logic/always_ff。
#
# 本脚本不烧录或下载任何东西，其本身也不产生任何 bitstream 声明。
# -----------------------------------------------------------------------------

set root [pwd]
set plat "$root/rtl/platform/tang_mega_138k_pro"
set diag "$plat/diagnostic_tone"

# --- 专用的、非生产构建目录 -------------------------------
if {[info exists env(BUILD_DIR)] && [string length $env(BUILD_DIR)] > 0} {
    set build_dir $env(BUILD_DIR)
} else {
    set build_dir "$root/build/diagnostic_tone"
}
if {[string first "/build/gowin" $build_dir] >= 0} {
    error "BUILD_DIR must not be inside build/gowin (got: $build_dir)"
}
file mkdir $build_dir

create_project -name diagnostic_tone -dir $build_dir -pn GW5AST-LV138FPG676AES -device_version B -force
set_option -verilog_std sysv2017
set_option -top_module diagnostic_tone_top

# 真实厂商 PLL IP（仅音频 PLL；此处不使用核心 100 MHz PLL）。
add_file "$plat/ip/pll_init.v"
add_file "$plat/ip/pll_audio_12m5/gowin_pll_audio_12m5.v"
add_file "$plat/ip/pll_audio_12m5/gowin_pll_audio_12m5_mod.v"

# 诊断 RTL + 现有只读 I2S 发送器。
add_file "$diag/tone_source.sv"
add_file "$diag/top.sv"
add_file "$root/rtl/audio/i2s_amp_tx.sv"

# 诊断引脚/时序约束。
add_file "$diag/tone.cst"
add_file "$diag/tone.sdc"

puts "FILES_ADDED"
run syn
puts "SYN_DONE"
run pnr
puts "PNR_DONE"

# 注意：本 Tcl 上下文不输出专用时序报告。
# 在 P&R 之后，gw_sh 不再提供 SDC 报告命令集（没有 get_ports），因此裸调用
# `report_timing ... [get_ports ...]` 会以 `invalid command name "get_ports"` 失败并
# 什么都不产生。完整的 setup/hold 时序报告改为由生效的 SDC 配置生成（tone.sdc 末尾的
# report_timing 命令，max_paths 300，无引脚过滤），并由流程写入实现报告：
#   <BUILD_DIR>/diagnostic_tone/impl/pnr/diagnostic_tone.tr
# 父级从该完整报告的 Slow（setup）和 Fast（hold）部分提取三个 amp_* 输出引脚极值；
# 此处不生成按引脚过滤的报告。
