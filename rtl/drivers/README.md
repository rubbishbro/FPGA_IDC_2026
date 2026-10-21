# rtl/drivers

从 `history/rtl/drivers` 迁入的驱动依赖，供后续 16 按键键盘/矩阵扫描复用。

```text
pkg/clk_rst_pkg.sv      clk / clk_en / rst_n 约定
pkg/pad_driver_pkg.sv   pixel / mat4x4 / vec2 / input_param 类型
pad_driver.sv           led8x8 + sense4x4_joystick + shift_timer
gowin_adc/gowin_adc.v   Gowin ADC IP 包装（4x4 力敏/摇杆路径使用）
```

注意：

- `pad_driver.sv` 是旧的 4x4 力敏 + 摇杆 + 8x8 LED 驱动，不是 16 按键键盘驱动。
- 16 按键键盘可以复用其中的 `shift_timer` 和行列扫描时序，但键码映射/消抖要新写。
- `gowin_adc.v` 例化 Gowin 原语 `ADCLRC`，只能在 Gowin 综合/仿真库中使用；纯 Icarus 需要 blackbox 或改用键盘扫描路径。
