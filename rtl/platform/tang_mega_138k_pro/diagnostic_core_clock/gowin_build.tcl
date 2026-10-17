# -----------------------------------------------------------------------------
# gowin_build.tcl —— 独立核心时钟观测（clock_probe_top）的真实 Gowin 工程构建入口。
#
# 这是与自动演奏歌曲构建、以及 diagnostic_tone 诊断音构建分开的独立工程。它不触碰
# build/gowin 或任何生产/其它诊断产物，也不替代主工程。它只构建：
#   * 现有的真实 Gowin_PLL_core_100M IP（100 MHz 核心 PLL；不含音频 PLL），
#   * 现有只读的 ip/pll_init.v（PLL_ADV 的 PLL_INIT 支持），
#   * 观测用 top.sv / clock_probe.cst / clock_probe.sdc。
#
# 在已安装的 Gowin V1.9.9+（已验证 V1.9.12.04）下，从仓库根目录运行：
#   export LD_LIBRARY_PATH="$HOME/gowin/IDE/lib:$LD_LIBRARY_PATH"
#   cd <repo root>
#   printf 'source rtl/platform/tang_mega_138k_pro/diagnostic_core_clock/gowin_build.tcl\n' | gw_sh -nocomp
# （此发布版中 gw_sh <file> 不会运行脚本；请通过管道 `source`。）
#
# 源根定位：
#   * 若设置了 SOURCE_ROOT 环境变量（父会话冻结快照根），优先使用它；
#   * 否则从本脚本自身所在目录向上回溯 4 级（diagnostic_core_clock -> tang_mega_138k_pro
#     -> platform -> rtl -> 仓库根）；
#   * 再否则退回当前工作目录。
# 选中的根必须真的含有 diagnostic_core_clock/sources.f，否则报错退出。
#
# 文件清单：唯一来源是同目录 sources.f。每个条目都解析为 SOURCE_ROOT 下的绝对路径，
# 且必须存在；任一缺失或逃出 SOURCE_ROOT 都会 abort。
#
# 输出目录：唯一的专用目录 <root>/build/diagnostic_core_clock，可用 BUILD_DIR 环境变量
# 覆盖为新的专用路径；任何落入 build/gowin 或含 song_synthesis（生产歌曲综合）的路径都会
# 在任何工具运行前被拒绝。解析后使用绝对路径（file normalize）。
#
# 不覆盖用户已建工程：若输出目录下已存在 core_clock_probe.gprj 或 core_clock_probe/impl，
# 直接 error；本脚本调用 create_project 时不使用 -force，绝不覆盖已存在的工程。
#
# 器件：GW5AST-LV138FPG676AES / Device Version B（沿用冻结生产目标）。用户实际硅片
# 型号/速度等级/ES 与否仍未确认，本脚本不据器件字符串推断实物已核实。
#
# 必须选择 SystemVerilog-2017：综合器默认使用 Verilog-2001，会拒绝 logic/always_ff。
#
# 本脚本只 run syn / run pnr；不烧录、不下载，也不声明任何 bitstream 或时序 PASS。
# 完整 setup/hold/recovery/removal 与最小脉宽（MPW）报告由 clock_probe.sdc 尾部的报告
# 命令在实现流程中展开，写入
#   <BUILD_DIR>/core_clock_probe/impl/pnr/core_clock_probe.tr
# 本 Tcl 上下文不做按引脚过滤的报告（P&R 后 gw_sh 没有 SDC reporting 命令集/get_ports）。
# -----------------------------------------------------------------------------

# --- 定位 SOURCE_ROOT ------------------------------------------------------
proc clock_probe_find_root {} {
    set candidates [list]
    if {[info exists ::env(SOURCE_ROOT)] && [string length $::env(SOURCE_ROOT)] > 0} {
        lappend candidates [file normalize $::env(SOURCE_ROOT)]
    }
    if {[info script] ne ""} {
        set here [file dirname [file normalize [info script]]]
        lappend candidates [file normalize [file join $here ../../../..]]
    }
    lappend candidates [file normalize [pwd]]
    foreach candidate $candidates {
        if {[file isfile [file join $candidate rtl/platform/tang_mega_138k_pro/diagnostic_core_clock/sources.f]]} {
            return $candidate
        }
    }
    error "cannot locate SOURCE_ROOT; tried: $candidates"
}

set root [clock_probe_find_root]
set diag_rel "rtl/platform/tang_mega_138k_pro/diagnostic_core_clock"
set sources_file [file normalize [file join $root $diag_rel sources.f]]
if {![file isfile $sources_file]} {
    error "missing sources.f under SOURCE_ROOT (got: $sources_file)"
}

# --- 解析 sources.f（绝对路径，存在性/包含性校验）------------------------
set src_files [list]
set fh [open $sources_file r]
foreach line [split [read $fh] "\n"] {
    set line [string trim $line]
    if {[string length $line] == 0} { continue }
    if {[string first "//" $line] == 0} { continue }
    if {[string first "#" $line] == 0} { continue }
    set resolved [file normalize [file join $root $line]]
    if {[string first "$root/" $resolved] != 0} {
        error "source escapes SOURCE_ROOT: '$line' -> $resolved"
    }
    if {![file isfile $resolved]} {
        error "missing required source: $resolved (from '$line')"
    }
    lappend src_files $resolved
}
close $fh
if {[llength $src_files] == 0} {
    error "sources.f listed no source files: $sources_file"
}

# --- 输出目录（专用、非生产、绝对路径）-------------------------------------
set project_name core_clock_probe
if {[info exists env(BUILD_DIR)] && [string length $env(BUILD_DIR)] > 0} {
    set build_dir [file normalize $env(BUILD_DIR)]
} else {
    set build_dir [file normalize [file join $root build diagnostic_core_clock]]
}
if {[string first "/build/gowin" $build_dir] >= 0} {
    error "BUILD_DIR must not be inside build/gowin (got: $build_dir)"
}
if {[string first "song_synthesis" $build_dir] >= 0} {
    error "BUILD_DIR must not be a production song_synthesis path (got: $build_dir)"
}
file mkdir $build_dir

# --- 拒绝覆盖已有的 core_clock_probe 工程 -----------------------------------
set gprj_path [file join $build_dir "$project_name.gprj"]
set proj_dir  [file join $build_dir $project_name]
if {[file exists $gprj_path] || [file exists $proj_dir]} {
    error "refusing to overwrite existing project '$project_name' under $build_dir (found .gprj/impl); choose an empty BUILD_DIR"
}

# --- 真实 Gowin 工程（不用 -force）-----------------------------------------
create_project -name $project_name -dir $build_dir -pn GW5AST-LV138FPG676AES -device_version B
set_option -verilog_std sysv2017
set_option -top_module clock_probe_top

foreach src $src_files {
    add_file $src
}

puts "FILES_ADDED"
run syn
puts "SYN_DONE"
run pnr
puts "PNR_DONE"
