# pad_driver → voice_router 端到端适配

## 1. 结论：新引擎不需要“按键事件适配器”

当前新引擎 [`voice_router.sv`](voice_router.sv) 已经直接接收：

```systemverilog
input pad_driver_pkg::mat4x4 fmap
```

内部已经完成：

```text
fmap 4×4
  → 双阈值滞回（NOTE_ON_TH / NOTE_OFF_TH）
  → note_on / note_gate 电平
  → 取沿得到起音事件
  → 每个 slot 一个声部
  → 激励 / 包络 / 引擎 / 腔体 / 混响
```

所以不需要再写一个“key_code / note_on / voice_alloc”软件式适配器。  
`pad_driver` 的 16 个压力单元，正好对应 `voice_router` 的 16 个 slot。

## 2. 真正缺的是板级 top

`pad_driver` 顶层：

```text
cr, led_p → dat, input_p
input_p.fmap : mat4x4
```

`voice_router` 顶层：

```text
fmap, inst, reverb_preset, reload, start,
n_voices, n_modes, n_samples,
ready, busy, done, y_valid, y_data,
qspi_*
```

两者之间缺：

```text
clk_rst 生成（pad_driver 要求 400ns 有效周期）
start 连续节拍
inst / reverb_preset / reload 配置
QSPI flash 引脚
y_valid/y_data 输出
LED 接口
```

新增 [`pad_voice_top.sv`](pad_voice_top.sv) 只做这些连接，不改 `voice_router` / `pad_driver`。

## 3. 数据/控制编排

```text
                 ┌───────────────┐
 clk 100MHz ────►│ clk_en /40    │──► pad_driver (2.5MHz 有效)
                 └───────────────┘
                         │
                         ▼
                  input_p.fmap (4×4×8)
                         │
                         ▼
                 voice_router.fmap
                         │
        ┌────────────────┼─────────────────┐
        ▼                ▼                 ▼
   note_on/gate      force_pre         env_router
        │                │                 │
        └──────────────► 引擎 ◄─────────────┘
                         │
                         ▼
                   body_router
                         │
                         ▼
                   reverb_router
                         │
                         ▼
                    y_valid/y_data
```

`start` 使用电平而不是脉冲：

```text
run = 1
  → voice_router 在 ready 后启动一个 block（n_samples 个采样）
  → done 后回到 IDLE
  → run 仍为 1，自动启动下一个 block
```

`pad_voice_top` 中：

```text
n_voices  = 16
n_modes   = 48
n_samples = X_DEPTH = 64
start     = run
```

## 4. 为什么不是“16 键键盘驱动”

`pad_driver` 给的是：

```text
fmap[0..15] 每个压力单元的原始 8-bit 压力
row_s/ch_s  模拟前端扫描选择
pos         摇杆极坐标
```

它不提供：

```text
keycode / key_pressed[15:0]
note_on / note_off
velocity 事件
debounce
voice 分配
```

但 `voice_router` 恰好已经把这些逻辑做在内部：

```text
每个 slot 对应一个压力单元
fmap[i] > NOTE_ON_TH → note_on[i]
fmap[i] < NOTE_OFF_TH → 松开
压力本身作为激励幅度
```

因此对于 **16 个固定压力键**，`fmap` 直连就是端到端方案。

## 5. 哪些情况还需要转换

### 5.1 用摇杆做表情

`pad_driver` 的 `pos.x/pos.y` 目前没有接进 `voice_router`。  
`voice_router` 的调制器只吃 `mod_par_t` 参数（c0/s0/theta0/g/k12/k21），
没有 joystick 输入口。

如果要做“摇杆揉弦/滑音”，需要：

```text
pos → 归一化 → 调制参数增量 → mod_router
```

或者改 `voice_router` 的调制接口，但不能直接塞进 fmap。

### 5.2 外部 MIDI / 上位机

外部 MIDI 是 note event，不是 16 单元压力矩阵。  
需要：

```text
MIDI note/velocity
  → 分配 slot
  → 写一个“虚拟 fmap”或直接驱动 voice_router 的 note 通路
```

当前 `voice_router` 没有外部 note 口，只有 fmap；要么做 fmap 映射，要么加 note 接口。

### 5.3 16 键以上

`voice_router` 的 `SLOTS` 可以参数化，但 `fmap` 只有 4×4×8。  
更多键需要扩展 `mat4x4` 或换输入接口。

## 6. 时钟与 CDC

`pad_driver` 要求有效周期 400ns，`pad_voice_top` 用 100MHz / 40 生成 `clk_en`：

```text
pad_clk_en 每 40 个 clk 高 1 拍
```

`pad_driver` 和 `voice_router` 仍是同一个 `clk` 域，只是 `pad_driver` 用 `clk_en` 降速，
所以没有 CDC；`fmap` 变化慢，`voice_router` 在 48kHz `smp_tick` 采样它。

## 7. LED

`pad_driver` 顶层强制带 `led8x8`，但 `voice_router` 不产生 LED 数据。  
`pad_voice_top` 当前：

```text
led_p = '0
led_dat 输出（不驱动）
```

要 LED 演奏反馈，需要另加 visualizer，把 `note_on`/包络/频谱映射到 `led_param`。

## 8. 仿真限制

`pad_driver` 内部例化 Gowin `ADCLRC` 原语，纯 Icarus 无法直接仿真。  
`pad_voice_top` 提供参数：

```systemverilog
parameter bit USE_PAD_DRIVER = 1'b1
```

仿真时设 `USE_PAD_DRIVER=0`，用 `fmap_ext` 旁路 pad_driver。  
但 `voice_router` 还需要 W25Q64 行为模型/真实 flash，`tb_loader_flash.sv` 已有该模型可复用。

## 9. 不做的事情

本次没有改：

```text
voice_router.sv
pad_driver.sv
engines/
parts/
routers/
```

`pad_voice_top.sv` 只是新增板级适配层。
