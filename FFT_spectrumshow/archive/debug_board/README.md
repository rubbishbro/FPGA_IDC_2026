# 板级调试顶层（已归档）

这里保存原来的 LCD 调试工程：

- `top.v`：板级顶层（50 MHz 输入、PLL、LCD 扫描、按键）
- `800_480_screen.gprj`：Gowin 工程文件
- `800_480_screen.cst` / `timing.sdc`：引脚和时序约束
- `platform/gowin_pll/`：50→33.333 MHz PLL
- `flow.tcl`：构建脚本
- `impl/`：最后一次构建输出（bitstream、报告）

当前 `src/` 只保留可视化核心，不再包含这个顶层。

## 恢复调试工程

把以下文件/目录移回 `lcd_draw_learn/` 对应位置：

```text
top.v              -> src/top.v
800_480_screen.gprj -> 800_480_screen.gprj
flow.tcl           -> flow.tcl
800_480_screen.cst -> src/800_480_screen.cst
timing.sdc         -> src/timing.sdc
platform/gowin_pll -> src/platform/gowin_pll
impl/              -> impl/
```

然后恢复 `real_audio_chain` 的 demo 音频输入：
- 从 `archive/legacy/audio_if.v` 取回 `src/audio/audio_if.v`
- 把 `time_pingpong` 写侧接回 `audio_if`
- 用 `archive/data/ode_to_joy.mem` 或 `gc_6s.mem` 初始化 ROM

恢复后运行：

```powershell
cd lcd_draw_learn
& "D:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe" flow.tcl
```
