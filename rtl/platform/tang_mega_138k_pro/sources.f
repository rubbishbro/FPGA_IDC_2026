// Gowin 综合文件列表，用于 Tang Mega 138K Pro 音箱板级顶层。
// 请将此列表连同 tang_mega_138k_pro.cst 和 .sdc 导入 Gowin
// 工程，目标为 GW5AST-LV138FPG676AES（Device Version B, FPG676）。
//
// 综合 TOP 是 board_top（board_top.sv），它包装 top.sv 并用绝对 ROM 路径覆盖
// COEFF_FILE/INDEX_FILE，使 $readmemh 无论工具工作目录如何
// 总能找到镜像（相对路径曾静默
// 失败并触发 WARN EX3988，还让引擎被常量折叠掉）。
//
// 两个 PLL IP 文件由用户用 Gowin IP Core
// Generator 生成。此处有意不列出它们：若缺失，综合
// 必须失败，而不是静默使用行为模型。sim/audio_helpers/ 下
// 仅供测试的模型绝不列在此处。
//
// 路径相对于仓库根目录；请从仓库根目录运行 Gowin
// （build.sh / gowin_build.tcl 即是如此）。

// 板级包装
rtl/platform/tang_mega_138k_pro/board_top.sv
rtl/platform/tang_mega_138k_pro/top.sv
rtl/platform/tang_mega_138k_pro/clock_reset.sv
rtl/platform/tang_mega_138k_pro/board_audio_core.sv

// 生成的 Gowin PLL IP（综合前必须存在）
rtl/platform/tang_mega_138k_pro/ip/pll_init.v
rtl/platform/tang_mega_138k_pro/ip/pll_core_100m/gowin_pll_core_100m.v
rtl/platform/tang_mega_138k_pro/ip/pll_core_100m/gowin_pll_core_100m_mod.v
rtl/platform/tang_mega_138k_pro/ip/pll_audio_12m5/gowin_pll_audio_12m5.v
rtl/platform/tang_mega_138k_pro/ip/pll_audio_12m5/gowin_pll_audio_12m5_mod.v

// 音频数据通路
rtl/audio/audio_async_fifo.sv
rtl/audio/pt8211_tx.sv
rtl/audio/i2s_amp_tx.sv
rtl/audio/i2s_mic_rx.sv
rtl/audio/audio_transport.sv
rtl/audio/song_player.sv
rtl/audio/audio_demo_core.sv

// 模态引擎（2B/2C）+ 琴体滤波器
rtl/core/coeff_loader.sv
rtl/core/poly_modal_lane.sv
rtl/core/modal_poly_bank.sv
rtl/core/modal_engine.sv
rtl/core/body_filter.sv
