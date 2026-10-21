# -----------------------------------------------------------------------------
# tone.sdc —— 独立诊断音时序约束。
#
# 独立于生产 SDC（tang_mega_138k_pro.sdc），仅针对 diagnostic_tone_top 层次编写。
# 任何地方都不使用 set_clock_latency。
#
# 时钟模型：
#   50 MHz 晶振     clk        -> 20.000 ns
#   12.5 MHz 音频   clk_audio  -> 由 clk 生成，divide_by 100 multiply_by 25
#                                 （并非精确的 12.288 MHz；见 top.sv 头部）
#
# 这是保守的诊断预算，不是数据手册签字确认的事实：
#   在 clk_audio 上额外加入 0.400 ns 的 setup 不确定度作为余量。父级证书流程明确拒绝
#   不确定度覆盖，因此本 SDC 不是 sim/review_i2s_pin_delays.py --certified-report 的
#   有效输入；它仅用于诊断 bring-up 构建。
#
# 外部 I2S 输出模型（C2O 路径包络），形式复制自生产 SDC：launch（clk_audio）-> pad
# 延迟限定在 [0, 40] ns。这是路径包络（PATH ENVELOPE），不是逐 corner 测量，也不是
# 完整的外部 I2S 证书：它必须与 RTL 边沿关系及独立的板级/抖动预算结合，且每个端点仍
# 必须显示非负的 setup/hold 且没有被忽略的约束。
#
#   d_max <= 40 ns（约束）  且  d_min >= 0 ns（约束）
# -----------------------------------------------------------------------------

create_clock -name clk_50m -period 20.000 [get_ports {clk}]

# 生成的音频时钟。diagnostic_tone_top 直接例化 PLL 为 u_pll_audio，因此引脚路径携带
# 该前缀（已按模式确认；父级会对照 P&R 网表重新核对确切名称）。
create_generated_clock -name clk_audio -source [get_ports {clk}] -master_clock clk_50m -divide_by 100 -multiply_by 25 [get_pins {u_pll_audio/u_pll/PLL_inst/CLKOUT0}]

# 诊断构建的保守额外 setup 余量（见头部）。Gowin TA1030 要求显式 -from/-to 端点；
# 这是一个同域 clk_audio -> clk_audio 保留量，即应用于每个内部音频域 setup 检查的一个
# launch/capture 预算。它刻意不约束任何跨域（lock）传输。
set_clock_uncertainty -setup 0.400 -from [get_clocks {clk_audio}] -to [get_clocks {clk_audio}]

# -----------------------------------------------------------------------------
# 外部 I2S 输出：相对于 clk_audio 的 C2O 路径包络 [0,40] ns。
# （形式与生产 SDC 相同；并非完整的外部 I2S 证书。）
# -----------------------------------------------------------------------------
set_output_delay -clock clk_audio  40.000 -max [get_ports {amp_bclk}]
set_output_delay -clock clk_audio   0.000 -min [get_ports {amp_bclk}]
set_output_delay -clock clk_audio  40.000 -max [get_ports {amp_din}]
set_output_delay -clock clk_audio   0.000 -min [get_ports {amp_din}]
set_output_delay -clock clk_audio  40.000 -max [get_ports {amp_lrc}]
set_output_delay -clock clk_audio   0.000 -min [get_ports {amp_lrc}]

# -----------------------------------------------------------------------------
# amp_sd 是到 MAX98357A 的异步慢速配置/静音输出，不是由时钟采样的数据输出。约束
# 音频域 launch 到 pad 的建立延迟（工程门限 100 ns）。异步 PLL-lock -> SD 路径是一段
# 短组合静音，此处不单独约束。
# -----------------------------------------------------------------------------
set_max_delay -from [get_clocks {clk_audio}] 100.000 -to [get_ports {amp_sd}]

# -----------------------------------------------------------------------------
# 专用的 3FF 异步置位 / 同步释放复位同步器。
# 三个触发器共享同一个异步 CLEAR（原始 audio_locked 撤销）；同步释放来自移位寄存器，
# 因此仅在这条专用链每一级的 CLEAR 引脚上放置一个限定范围的 hold 例外。
# 普通逻辑看到的复位释放只有 rst_sync[2]（top.sv：
# assign rst_n = rst_sync[2]）。原始锁定信号不组合进入正常状态 CLEAR 树，因此每个普通
# 状态寄存器都正常地对照 clk_audio 发起的最后一级输出进行检查。普通 state/D 寄存器、
# 最后一级的正常时序，以及这些正常 CLEAR 上的 recovery/removal 均不受影响。
# （amp_sd 单独保留原始 audio_locked 以实现立即静音。）
#
# 确切的寄存器名（`_s0` 后缀）以及任何层次前缀都必须对照真实 P&R 网表确认；如果 Gowin
# 命名不同，请更新这三个引脚。如果名称不匹配，该例外即为空操作，普通
# hold/recovery/removal 检查仍然有效。
# -----------------------------------------------------------------------------
set_false_path -hold -to [get_pins {rst_sync_0_s0/CLEAR}]
set_false_path -hold -to [get_pins {rst_sync_1_s0/CLEAR}]
set_false_path -hold -to [get_pins {rst_sync_2_s0/CLEAR}]

# -----------------------------------------------------------------------------
# 完整时序报告捕获（SDC 报告上下文）。
# 在 P&R 之后 gw_sh 没有 SDC 报告命令集（没有 get_ports），因此无法从构建 Tcl 生成
# 按引脚过滤的报告。这些 SDC 报告命令在没有引脚过滤的情况下展开完整的 setup/hold 报告
# （-max_paths 300 覆盖全部约 291 条被报告路径）；流程将其写入
#   <BUILD_DIR>/diagnostic_tone/impl/pnr/diagnostic_tone.tr
# 父级从该完整报告中提取 Slow（setup）/ Fast（hold）的 amp_bclk / amp_din / amp_lrc
# 输出引脚极值。此处不改变任何时序。
# -----------------------------------------------------------------------------
report_timing -setup -max_paths 300 -max_common_paths 1
report_timing -hold  -max_paths 300 -max_common_paths 1
