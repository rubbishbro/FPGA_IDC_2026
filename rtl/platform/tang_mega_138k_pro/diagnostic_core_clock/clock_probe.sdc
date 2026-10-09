# -----------------------------------------------------------------------------
# clock_probe.sdc —— 独立核心时钟观测（clock_probe_top）的时序约束。
#
# 独立于生产 SDC（tang_mega_138k_pro.sdc），只针对 clock_probe_top 这一最小层次编写。
# 刻意不写以下任何一类约束（避免用假数"通过"）：
#   * 不写 set_clock_latency（没有经过审查的物理依据去替换器件 source 极值）；
#   * 不写 set_false_path / set_clock_groups（本设计没有跨域数据，也没有需要切断的路径）；
#   * 不写 set_clock_uncertainty（没有经验证的不确定度预算）；
#   * 不写 set_output_delay（clk_probe 是观察时钟口，没有外部同步接收端的
#     setup/hold 截止时间；本实验不冒充已签核的 I/O 约束）。
#
# 时钟模型（仿生产命名与形式）：
#   50 MHz 晶振    clk       -> 20.000 ns，-waveform {0 10}（名义 50% 占空比）
#   100 MHz 核心   clk_core  -> 由 clk 生成，-divide_by 1 -multiply_by 2 -duty_cycle 50
#                              即 10.000 ns 周期、名义 50% 占空比（高/低各约 5 ns）
#
# 生成时钟的 pin 路径携带顶层实例前缀：clock_probe_top 例化 IP 为 u_pll_core，
# IP 包装内部为 u_pll，其 PLL 原语实例为 PLL_inst，故 CLKOUT0 的完整路径为
#   u_pll_core/u_pll/PLL_inst/CLKOUT0
# （与现有生产 SDC/诊断 SDC 相同的路径形状；父会话会在 P&R 网表上复核确切名称。）
# -----------------------------------------------------------------------------

create_clock -name clk_50m -period 20.000 -waveform {0 10} [get_ports {clk}]

create_generated_clock -name clk_core -source [get_ports {clk}] -master_clock clk_50m -divide_by 1 -multiply_by 2 -duty_cycle 50 [get_pins {u_pll_core/u_pll/PLL_inst/CLKOUT0}]

# -----------------------------------------------------------------------------
# 完整时序报告捕获（SDC 报告上下文）。
# 在 P&R 之后 gw_sh 不再提供 SDC 报告命令集（没有 get_ports），因此不在构建 Tcl 里
# 做按引脚过滤的报告：改为在此 SDC 尾部展开完整的 setup/hold/recovery/removal 以及
# 最小脉宽（MPW）报告，由流程写入实现报告
#   <BUILD_DIR>/core_clock_probe/impl/pnr/core_clock_probe.tr
# 这里不改变任何时序（只输出报告）。未命中的 objects（"Nothing to report!"）或
# Ignored/Inactive 约束必须由父会话在真实报告上核对。
# -----------------------------------------------------------------------------
report_timing -setup   -max_paths 300 -max_common_paths 1
report_timing -hold    -max_paths 300 -max_common_paths 1
report_timing -recovery -max_paths 300 -max_common_paths 1
report_timing -removal  -max_paths 300 -max_common_paths 1
report_min_pulse_width -nworst 300
