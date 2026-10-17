# -----------------------------------------------------------------------------
# tang_mega_138k_pro.sdc -- 时钟 / CDC / 外部输出约束。
#
# 语法遵循 SUG940（Gowin Design Timing Constraints User Guide）；在布局布线阶段
# 由真实 Gowin V1.9.12.04 时序引擎加载。
#
# 本构建中的实际时钟（12.5 MHz 功能上电调试，并非精确的 12.288）：
#   50 MHz 晶振       -> 20.000 ns
#   100 MHz core PLL  -> 10.000 ns
#   12.5 MHz audio PLL-> 80.000 ns  (BCLK 3.125 MHz / 320 ns; LRC 48.828 kHz)
# ROM 是 48 kHz 系数集，因此诊断运行约快 ~1.725%；并非
# 忠实于 48 kHz。
#
# 外部 I2S 输出模型（修订版）：
# 功放引脚并未在输出端口上声明为生成时钟。工具当前策略
# 不创建虚拟时钟（SUG940："Create Clock does
# not support the creation of virtual clocks"），因此我们改用
# *时钟源到输出*（C2O）路径包络模型：将发射（clk_audio）-> 焊盘延迟约束到
# [min,max] = [0, 40] ns。这是一个路径包络，而非逐 corner 的测量；
# 它与 BOARD_DELIVERY_REPORT.md 中针对 MAX 接收端单独的下降沿差分
# 论证结合使用。原始报告 SHA 与 bound_vs_measured
# 记录在那里；父会话会独立重跑 review_i2s_pin_delays。
#   d_max <= 40 ns (constraint)  and  d_min >= 0 ns (constraint)
#   转发沿差分（标称半个 BCLK 160 ns，预算 10 ns）：
#       setup >= 160 + d_min(BCLK) - d_max(Data) - 10 >= 110 ns
#       hold  >= 160 + d_min(Data) - d_max(BCLK) - 10 >= 110 ns
#   这远高于 MAX98357A 的 10 ns 要求，前提是实际 C2O
#   路径处于 [0,40] 之内，且 STA 确认这些端点在
#   Slow(0C)/Fast(85C) corner 上零违例。在每一个音频输出
#   端点都显示非负的 setup 与 hold、且没有缺失时钟/被忽略的
#   约束、并且时钟模型得到独立论证之前，本条保持
#   OPEN。已评审的 core100 基线有零 setup/hold 违例，但存在
#   负的时钟最小脉冲宽度检查；标称延迟覆盖不能
#   作为物理修复被接受。
# -----------------------------------------------------------------------------

create_clock -name clk_50m -period 20.000 [get_ports {clk}]

# 两个 PLL 输出的生成时钟。board_top 将 top 实例化为 u_top，
# 因此引脚路径带有 u_top 前缀（已对照 P&R 网表确认）。
create_generated_clock -name clk_core -source [get_ports {clk}] -master_clock clk_50m -divide_by 1 -multiply_by 2 [get_pins {u_top/u_clock_reset/u_pll_core/u_pll/PLL_inst/CLKOUT0}]
create_generated_clock -name clk_audio -source [get_ports {clk}] -master_clock clk_50m -divide_by 100 -multiply_by 25 [get_pins {u_top/u_clock_reset/u_pll_audio/u_pll/PLL_inst/CLKOUT0}]

# -----------------------------------------------------------------------------
# PLL 源模型：保留器件时序模型，包括其 early/late
# 与 rise/fall 极值。一个候选方案是在两个 PLL 时钟上使用
# set_clock_latency -source 3.765，它使 MPW 转正，但未被接受：SUG940 只记录
# 命令语法，并不允许用中点值替换物理 min/max 延迟。
# 标称 50% 占空比并不能证明两个不同 PLL 没有占空比失真或相关性
# 时序变化。任何修订模型都需要独立的
# 器件/PVT/占空比/抖动证据；不要用标称覆盖来获得通过。
# 被拒绝的候选方案及其原始报告单独保存。
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# clk_core 与 clk_audio 之间的 CDC。
#   * 异步 FIFO 的 Gray 指针用 max_delay 约束（它们需要
#     逐位的约束，因此不设为 false path）；
#   * 2-FF 同步器的*第一级*捕获寄存器跨两个不相关时钟是异步的，
#     因此有作用域的 hold 例外只应施加在这些端点上
#     ——而不是一刀切的时钟组 false path（那会
#     同时抹掉上面的 Gray 约束）。
# 下方max_delay保留跨域最大传播界。2026-10-07已独立核对v4真实网表：
# TX FIFO两向Gray均由源域寄存器驱动第一级，再到目标域第二级；最高位
# Gray与bin最高位合并，但仍为寄存源。只排除第一级D的异步hold相位检查，
# 不排除setup/max_delay，也不排除第二级D的同域setup/hold。
# 这不是改变物理布线或解决MPW；PLL相位、CDC裕量/MTBF仍单独审查。
# -----------------------------------------------------------------------------
set_max_delay -from [get_clocks {clk_core}] 10.000 -to [get_clocks {clk_audio}]
set_max_delay -from [get_clocks {clk_audio}] 10.000 -to [get_clocks {clk_core}]

# 生产mode下RX FIFO/诊断同步器已被优化移除，不给不存在的端点加例外。
# 端点集合必须随生产综合网表复核；禁止使用宽泛clock-group false path。
set_false_path -hold -to [get_pins {u_top/u_audio/u_core/u_transport/u_tx_fifo/wgray_s1_0_s0/D}]
set_false_path -hold -to [get_pins {u_top/u_audio/u_core/u_transport/u_tx_fifo/wgray_s1_1_s0/D}]
set_false_path -hold -to [get_pins {u_top/u_audio/u_core/u_transport/u_tx_fifo/wgray_s1_2_s0/D}]
set_false_path -hold -to [get_pins {u_top/u_audio/u_core/u_transport/u_tx_fifo/wgray_s1_3_s0/D}]
set_false_path -hold -to [get_pins {u_top/u_audio/u_core/u_transport/u_tx_fifo/wgray_s1_4_s0/D}]
set_false_path -hold -to [get_pins {u_top/u_audio/u_core/u_transport/u_tx_fifo/rgray_s1_0_s0/D}]
set_false_path -hold -to [get_pins {u_top/u_audio/u_core/u_transport/u_tx_fifo/rgray_s1_1_s0/D}]
set_false_path -hold -to [get_pins {u_top/u_audio/u_core/u_transport/u_tx_fifo/rgray_s1_2_s0/D}]
set_false_path -hold -to [get_pins {u_top/u_audio/u_core/u_transport/u_tx_fifo/rgray_s1_3_s0/D}]
set_false_path -hold -to [get_pins {u_top/u_audio/u_core/u_transport/u_tx_fifo/rgray_s1_4_s0/D}]
set_false_path -hold -to [get_pins {u_top/u_audio/u_core/u_transport/tgl_s1_s0/D}]

# -----------------------------------------------------------------------------
# 外部 I2S 输出：相对 clk_audio 的 C2O 路径包络 [0,40] ns。
# -----------------------------------------------------------------------------
set_output_delay -clock clk_audio  40.000 -max [get_ports {amp_bclk}]
set_output_delay -clock clk_audio   0.000 -min [get_ports {amp_bclk}]
set_output_delay -clock clk_audio  40.000 -max [get_ports {amp_din}]
set_output_delay -clock clk_audio   0.000 -min [get_ports {amp_din}]
set_output_delay -clock clk_audio  40.000 -max [get_ports {amp_lrc}]
set_output_delay -clock clk_audio   0.000 -min [get_ports {amp_lrc}]

# -----------------------------------------------------------------------------
# 异步置位 / 同步释放的复位同步器。
# 每条专用复位同步链都是普通的 2FF/3FF 移位寄存器，其触发器
# 共享同一个异步 CLEAR（置位）；同步释放由
# clock_reset 的 PLL 锁定状态机驱动，因此各级 CLEAR 引脚看到的是复位
# *撤销*穿越，而不是同步数据保持。hold 例外仅限定在
# 这些专用链每一级的 CLEAR 引脚上：
#   * clock_reset 3FF crst_sync
#   * audio_demo_core 2FF crst_sync
#   * audio_transport 2FF arst_sync
# 正常的状态/D 寄存器以及驱动普通逻辑的同步器输出
# 不受影响。输出上的 recovery/removal 得到保留，Gray CDC
# max_delay 与下游 setup/hold 也不受影响。
# -----------------------------------------------------------------------------
set_false_path -hold -to [get_pins {u_top/u_clock_reset/crst_sync_0_s0/CLEAR}]
set_false_path -hold -to [get_pins {u_top/u_clock_reset/crst_sync_1_s0/CLEAR}]
set_false_path -hold -to [get_pins {u_top/u_clock_reset/crst_sync_2_s0/CLEAR}]
set_false_path -hold -to [get_pins {u_top/u_audio/u_core/crst_sync_0_s0/CLEAR}]
set_false_path -hold -to [get_pins {u_top/u_audio/u_core/crst_sync_1_s0/CLEAR}]
set_false_path -hold -to [get_pins {u_top/u_audio/u_core/u_transport/arst_sync_0_s0/CLEAR}]
set_false_path -hold -to [get_pins {u_top/u_audio/u_core/u_transport/arst_sync_1_s0/CLEAR}]

# -----------------------------------------------------------------------------
# amp_sd 是输出到 MAX98357A 的异步慢速配置/静音信号，而不是
# 同步时钟采样的输出。真正的需求是从 core/reset/lock 域到焊盘的
# 建立/静音延迟约束，因此使用 max_delay
# （工程门限 100 ns），而不是按核心时钟的输出捕获。以
# 时钟组（可解析）表达，而不是未确认的内部引脚名。
# -----------------------------------------------------------------------------
set_max_delay -from [get_clocks {clk_core}] 100.000 -to [get_ports {amp_sd}]
set_max_delay -from [get_ports {reset}] 100.000 -to [get_ports {amp_sd}]
