# 万向摇杆适配接口

2026-10-27：独立 RTL、原始 X/Y 出口及 26 组回归已完成，默认参数有独立综合记录；适配器已在 sidebar_system 中接入交互。独立 LCD demo 无 ADC 引脚，HAS_JOYSTICK=0；真实板级方向/漂移/模拟前端仍待验收。采集 FSM 当前已有泄放、建立、完成锁存与超时，不再是早期盲读扫描。

## 接线与职责

```text
sense4x4_joystick（ADC 采集）
    → pad_driver / pad_voice_top 的 joy_sample_valid、joy_raw_x、joy_raw_y
    → joystick_adapter（同一个主时钟域）
    → 连续偏移 / 八方向 / 带握手的导航事件
    → sidebar_ctrl 侧栏 UI（已实现接线）
    → 用户选定配置值后，UI 才产生配置请求交给 control_loop
```

适配层不解释菜单、频谱样式或乐器配置，不把上/下方向定义成确认/返回，也不限制万向摇杆只能用于四方向菜单。摇杆按压开关没有出现在当前采集接口中，本模块不虚构 OK/Back 输入。

`pad_voice_top` 已引出原始采样端口，但不内置适配器；由整机顶层例化适配器并选择输出接法。新增端口追加在 `pad_voice_top` 端口末尾，已有命名连线可保留。

## 输入

| 信号 | 合同 |
|---|---|
| `clk / rst_n` | 主时钟、异步低有效复位；复位释放由集成方同步 |
| `sample_valid` | 一对全新的 X/Y 有效，一个 `clk` 周期；没有 ready |
| `raw_x / raw_y[13:0]` | 无符号 ADC，0..16383，在有效采样边沿稳定 |
| `recalibrate` | 高一拍，重新采集中心；同拍的样本忽略 |
| `nav_ready` | UI 能接收一个方向事件；不使用导航事件时可绑 1 |

对应采集输出是 `joy_sample_valid / joy_raw_x / joy_raw_y`。在 Y 通道的有效转换存储时，一次发布前面得到的 X 与当前 Y，坐标保持到下一对。两轴物理采样先后发生；成对发布表示原子快照，不代表 ADC 同时采两轴。dummy 转换和超时重试不发布样本。`joy_sample_valid` 在主时钟域仅高一拍，不会随 400ns 的 `clk_en` 拉长。

不要把旧极坐标 `pad_pos` 接到原始坐标口。当前旧坐标转换没有去除摇杆中心，新的适配路径直接使用原始 ADC。

## 输出

| 信号 | 含义 |
|---|---|
| `calibrated` | 中心采集完成；首次完成前不产生运动 |
| `stale` | 无新样本超时或等待首次采样；连续状态回中，停止产生重复事件 |
| `center_x / center_y[13:0]` | 校准得到的原始轴中心，便于调试 |
| `position_update` | 校准后每收到一对样本，高一个时钟周期 |
| `dx / dy` | 15 bit 有符号偏移，单位为 ADC count；已经减中心并执行换轴/反向，+X 向右、+Y 向上 |
| `direction` | 持续状态：回中、四个正方向、四个斜方向，类型为 `joystick_pkg::joy_dir_t` |
| `nav_valid / nav_ready` | 高电平握手，握手边沿取走一条事件；反压期间 valid 和载荷保持 |
| `nav_dir / nav_repeat` | 方向及是否为持续推动产生的重复事件；回中也有方向变化事件 |

`dx/dy` 保留中心附近的小偏移，没有做速度映射或全行程归一化。死区与迟滞作用于 `direction` 和导航事件；用连续偏移控制光标时，UI 应根据死区状态/阈值抑制漂移。连续输出只有在 `calibrated && !stale` 时有效。失联回中不产生 `position_update`，消费者还需观察 `stale`。

导航是状态通知，允许合并：一个事件已经进入槽后，等待期间不得改载荷。期间发生的多个方向变化只保留最终状态；槽可用后补发该状态，不需要等待新的 ADC 样本。重复触发在忙时跳过，不累计成一串补发。因此 UI 长时间停顿后可能先收到一条已暂存的旧方向，再收到最新方向。需要实时光标状态时直接读连续输出，不把事件通道当无损轨迹记录。

`nav_repeat=0` 表示方向变化，`=1` 表示同向连发；松手回中、转向重新计时。重校准保持已暂存事件的握手合同，并通过后续回中状态通知释放；复位则取消所有在途事件。

## 参数与默认值

| 参数 | 默认 | 说明 |
|---|---:|---|
| `CLK_HZ` | 100000000 | 必须与输入采样时钟域一致；当前要求为 1000 的正整数倍 |
| `CALIB_LOG2` | 4 | 上电或重新校准平均 16 对新样本，范围 0..16；0 为一对样本 |
| `DEADZONE_ON / OFF` | 1400 / 900 | 每轴进入/退出方向阈值；满足 `0 <= OFF < ON <= 16383` |
| `REPEAT_DELAY_MS` | 400 | 首次推动立即通知，持续推动约 400ms 后连发 |
| `REPEAT_PERIOD_MS` | 100 | 后续连发周期 |
| `SAMPLE_TIMEOUT_MS` | 100 | 采样中断后约 100ms 回中；应大于真实扫描周期 |
| `SWAP_XY` | 0 | 先交换原始去中心后的两轴 |
| `INVERT_X / Y` | 0 / 0 | 然后按 UI 轴反向，实物安装方向上板确定 |

方向死区为每轴矩形区域，独立判定两轴并保留斜向；进入用 `>= ON`，回到 `<= OFF` 退出。毫秒计时与 ADC 采样次数无关，误差小于约一个毫秒节拍加少量时钟。失联保留已校准中心；未完成校准就失联则清空部分累计。上电及重新校准期间必须松手居中，本版本不检测“启动时一直推住”的误校准。

## 最小例化

先编译 `pkg/joystick_pkg.sv`，再编译 `joystick_adapter.sv`。下面信号均属于 `clk_100m`，不允许直接跨到 LCD 像素时钟域。

```systemverilog
joystick_pkg::joy_dir_t joy_direction, joy_nav_dir;

joystick_adapter #(.CLK_HZ(100_000_000)) u_joystick (
    .clk(clk_100m), .rst_n(rst_100m_n), .recalibrate(1'b0),
    .sample_valid(joy_sample_valid), .raw_x(joy_raw_x), .raw_y(joy_raw_y),
    .calibrated(joy_calibrated), .stale(joy_stale),
    .center_x(), .center_y(),
    .position_update(joy_position_update), .dx(joy_dx), .dy(joy_dy),
    .direction(joy_direction),
    .nav_valid(joy_nav_valid), .nav_ready(joy_nav_ready),
    .nav_dir(joy_nav_dir), .nav_repeat(joy_nav_repeat)
);
```

当前 sidebar_system 在 ctrl_clk 域内实例化适配器和菜单，LCD demo 控制时钟为 50MHz；坐标不直接送入 pix_clk。显示快照走整包 CDC。独立例化到其它控制域时，CLK_HZ 必须匹配；方向枚举与旧 ui_pkg 按键事件仍需显式映射。

## 验证

```bash
python3 sim/run_joystick.py
```

26 组功能仿真：3 种校准长度（1/4/16 对）×8 种换轴/反向组合，以及 dummy 开/关的 2 组采集→适配接线测试。覆盖非默认中心平均、八方向、死区等号/迟滞、中心抖动、ADC 全量程符号、随机位置、连发时间、反压稳定与最新方向合并、采样超时恢复、重校准、部分校准中断和复位。

采集接线测试使用真实 `sense4x4_joystick` 和 `cart2polar`，仅 ADC 使用行为模型，包含一次不返回 ready 的超时重试，并检查成对坐标、dummy 丢弃、单主时钟 valid 和适配层校准计数。没有例化无关的 LED：旧 `led8x8` 对 packed union 的变量索引会阻塞 Icarus 展开，未为本任务改写它。日志在 `build/joystick/`。这 26 组结果不覆盖真实 ADC、LCD UI/CDC；侧栏另有集成回归，也不代表整机已验收。

独立综合脚本为 `sim/synth/joystick_build.tcl`，在仓库根目录启动 Gowin Tcl 控制台后执行 `source sim/synth/joystick_build.tcl`。2026-10-27 默认参数综合成功，无 RTL 综合警告，网表位于 `build/joystick_synth/joystick_adapter/impl/gwsynthesis/`，控制台日志为 `build/joystick/synthesis.log`。该检查只包含 `joystick_pkg` 与适配器，不是采集整链综合，也不表示 100MHz 时序已经签核。
