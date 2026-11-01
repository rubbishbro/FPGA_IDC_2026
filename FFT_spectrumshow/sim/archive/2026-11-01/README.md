# 2026-11-01 仿真审计归档

这些文件保留作历史资料，不参与当前回归。

| 原路径（相对 FFT_spectrumshow/sim） | 原因 |
|---|---|
| `gen_ode.py` | 旧 Ode to Joy ROM 生成工具，并非测试；写死 `D:\FPGA_IDC_2026\lcd_draw_learn` 两个输出路径，当前工程已无该目录。现有 `chain_tb.v` 仍使用有效的 `sim/ode_to_joy.mem`，该数据保留。 |
| `fft1024_check_tb.sv` | 适配现有 FFT 接口的历史脉冲诊断工具，但仅打印 count/maxbin，没有期望值断言、PASS/FAIL 或 watchdog。旧 PowerShell 入口仅搜 TEST FAILED，可能把未产生有效结果视为成功；不应计入自检回归。 |
| `fft1024_in.mem` | 上述诊断台专用输入；当前源码没有其他引用，随诊断台归档。 |

已从 `run_regression.ps1` 移除诊断调用，保留 14 个有效自检。若要人工重放诊断台，需将本目录 `fft1024_in.mem` 与 `sim/twiddle1024.mem` 放入运行目录，并使用当前 `src/fft/fft1024_iter.sv` 编译；输出仅供观察，不是通过证据。归档脚本保持原内容，不建议直接执行。
