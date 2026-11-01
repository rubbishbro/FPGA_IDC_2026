# rtl/drivers

通信实现已按职责分层：

| 目录 | 已实现内容 |
|---|---|
| [uart/](uart/README.md) | 通用 UART RX／TX、唯一 RX 字节 FIFO、物理错误检测 |
| [bluetooth_hc05/](bluetooth_hc05/README.md) | 独立 HC-05 设备包装，内部复用 UART，附可选 STATE 状态 |
| [common/](common/comm_fifo.sv) | 驱动、传输和事件队列共用的同步 FIFO |
| [万向摇杆适配](JOYSTICK_ADAPTER.md) | 原始 ADC 成对出口、中心校准、连续双轴偏移、八方向与带握手的导航连发；已接 sidebar_system；独立 LCD demo 无 ADC 输入 |
| [analyzer/](analyzer/README.md) | TYPE 分发、MIDI／Config 业务解析、接口和验证汇报 |
| [../comm/](../comm/README.md) | 每路 transport、帧仲裁、回复路由、会话协调与通信集成顶层 |

当前验证覆盖独立通信 RTL 与 mock 端点，尚无真实音频整机／HC-05 实物验收。历史方案保留在各模块文档的归档入口。

压力/摇杆驱动已经接入 pad_voice_top；原始 X/Y 出口用于 sidebar_system，真实板级矩阵映射仍需验证。机械按键如需复用扫描，应另行处理消抖和键码。

```text
pkg/clk_rst_pkg.sv      clk / clk_en / rst_n 约定
pkg/pad_driver_pkg.sv   pixel / mat4x4 / vec2 / input_param 类型
pad_driver.sv           led8x8 + sense4x4_joystick + shift_timer
pad_led_effects.sv      明暗行波、左上灯相位锁色、16 条 sinc 波纹、全查表渲染
pad_led_tables/        9 张同步 ROM（119808 bit），附生成参数及校验摘要
tools/gen_pad_led_tables.py  离线生成查找表，--check 检查是否可复现
gowin_adc/gowin_adc.v   Gowin ADC IP 包装（4x4 力敏/摇杆路径使用）
```

当前 sense4x4_joystick 已采用泄放→建立→请求→完成锁存→存储 FSM、超时重试及可选 dummy；旧 row_scan 连续轮转的缺陷描述仅适用于历史版本。

高级 LED 灯效的取色、渲染和 ROM 部署说明见 [PAD_LED_EFFECTS.md](PAD_LED_EFFECTS.md)。

注意：

- `pad_driver.sv` 是旧的 4x4 力敏 + 摇杆 + 8x8 LED 驱动，不是 16 按键键盘驱动。
- 16 按键键盘可以复用其中的 `shift_timer` 和行列扫描时序，但键码映射/消抖要新写。
- `gowin_adc.v` 例化 Gowin 原语 `ADCLRC`，只能在 Gowin 综合/仿真库中使用；纯 Icarus 需要 blackbox 或改用键盘扫描路径。
