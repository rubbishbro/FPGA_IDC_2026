# archive - 历史材料（不参与构建，不参与回归）

这里的任何文件都**不会**被三个 Gowin 工程（`ui_demo` / `ui_demo_sweep` /
`ui_demo_polar`）编译，也不会被 `sim/run_regression.ps1` 执行。只作参考。

| 目录 | 内容 | 说明 |
|---|---|---|
| `3d_spectrum/` | 早期 3D 频谱页面 | 已放弃 |
| `data/` | 旧音频数据 `.mem`（gc / synth / spectrum） | 演示已改用 `sine256.mem` |
| `debug_board/` | 早期 800×480 点屏工程 | 独立工程，仅参考 |
| `framebuffer_polar/` | 极坐标页的旧 framebuffer 版本 + TB | 已被逐像素逆映射替代 |
| `legacy/` | 旧 FFT、旧 `data_source`、旧 `fft512` 等 | 已被 `src/fft/fft1024_iter.sv` 替代 |
| `logs/` | 旧构建日志 | 无参考价值，保留只为追溯 |
| `pll_core_100m/` | 早期 100 MHz PLL 实验 | 已被 `board/gowin_pll_src.v` 替代 |
| `sim_legacy/` | 旧 testbench、旧仿真数据、旧 transcript | 已被 `sim/*_tb.sv` 替代 |
| `tools/` | 生成 `.mem` 的脚本和 wav 源 | 需要重新生成数据时才看 |
| `unused_pages/` | `lcd_trail_spectrum` / `lcd_waterfall` | 未接入当前页面 |

规则：**不要把 archive 里的模块直接接回 `src/`**。如果确实需要，先读
`AGENTS.md` 的约束，重新验证并跑回归。
