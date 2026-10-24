# FFT Spectrum Show

面向 GW5AST-138B + 800×480 LCD 的频谱可视化 demo。当前所有逻辑运行在
33.333 MHz 像素时钟域，主引擎 PCM 接入和 100 MHz 跨时钟域尚未开始。

## 当前页面

| page | 页面 | 内容 |
|---|---|---|
| `00` | BARS | 128 根 FFT 柱 + 峰值光点 |
| `01` | WAVE | 时域波形 |
| `10` | FALL | 0 线居中、上下镜像的 4 条时间曲线 |
| `11` | SETTINGS | SMTH / PEAK / THEM / GRID 开关 |

FALL 的时间曲线：

```text
current = age 0   （黄）
recent  = age 3   （青）
mid     = age 7   （紫）
old     = age 15  （蓝）
```

上半屏四条曲线，下半屏四条镜像线；下半屏只画线，不填充。

按键：

```text
key0 短按 = 下一页 / 设置页下一项
key1 短按 = 上一页 / 设置页上一项
key0 长按 = 进入设置 / 切换当前项
key1 长按 = 返回 BARS
```

## 音频源

正常 bitstream 使用 440 / 880 / 1320 Hz 三音正弦测试源。

扫频 bitstream 使用 `sweep_source`：

```text
1 kHz -> 10 kHz，约 10 秒线性扫频
48.03 kHz sample tick
```

用途是检查 FALL 的 0/3/7/15 帧时间关系，不是正式音频输入。

## 目录

```text
board/
  ui_demo_top.v        正常板级 top（三音正弦）
  sweep_demo_top.v     扫频测试 top（参数覆盖）
  ui_demo.gprj         Gowin 工程
  flow.tcl             正常 bitstream
  flow_sweep.tcl       扫频 bitstream
  ui_demo.cst          引脚约束
  timing.sdc           时钟约束
  *.mem                ROM 初始化文件
  gowin_pll.v          33.333 MHz 像素时钟

src/
  ui/
    ui_pkg.sv          页面/事件常量
    key_ui_event.sv    按键去抖 + 短按/长按事件
    ui_ctrl.sv         页面、设置项、特效状态机
  audio/
    real_audio_chain.v PCM -> 时域窗口 -> FFT -> 频谱/波形/曲线链
    time_pingpong.v    1024×24 时域双 bank
    wave_capture.v     时域波形抽取
    sweep_source.sv    1k->10k 扫频相位累加器
  fft/
    fft1024_iter.sv    1024 点基 2 DIF FFT
    fft_ctrl.v         Hann 窗 + FFT 控制
  spectrum/
    spectrum_map.v     512 bin -> 128 bar，AGC/门限
  display/
    lcd_timing.v       800×480 扫描
    lcd_draw.v         页面选择/优先级
    lcd_background.v   网格/边框
    lcd_fft.v          BARS + 峰值/平滑/主题
    lcd_wave.v         WAVE
    lcd_curve_spectrum.sv  FALL 曲线和镜像
    trail_calc.sv      0/3/7/15 帧抽取 + 3 点平滑
    trail_store.sv     128×40 历史数据
    curve_calc.sv      Catmull-Rom 768 列插值
    curve_store.sv     768×40 双 bank 曲线
    display_frame_buffer.sv  BARS 柱高/超调双 bank
    waterfall_store.sv 64×128 历史（FALL 的 age 来源）
    wave_frame_buffer.sv 波形双 bank
    lcd_ui.sv          顶部 tab、设置页
  input/
    key_debounce.v     基础按键去抖

sim/
  run_regression.ps1   全部可视化回归
  *_tb.sv             自检 testbench

archive/
  3d_spectrum/         已放弃的 3D 频谱
  unused_pages/        lcd_trail_spectrum / lcd_waterfall
  legacy/              旧 FFT、旧板级 demo、旧 testbench
  debug_board/         早期板级工程
```

## 构建

正常 bitstream：

```powershell
cd board
& "D:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe" flow.tcl
```

输出：

```text
board/impl/pnr/ui_demo.fs
```

扫频 bitstream：

```powershell
cd board
& "D:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe" flow_sweep.tcl
Copy-Item impl/pnr/ui_demo.fs impl/pnr/sweep_demo.fs -Force

# 恢复正常 bitstream
& "D:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe" flow.tcl
```

烧录：

```text
正常：board/impl/pnr/ui_demo.fs
扫频：board/impl/pnr/sweep_demo.fs
```

## 回归

```powershell
cd sim
powershell -ExecutionPolicy Bypass -File .\run_regression.ps1
```

当前回归结果：

```text
SWEEP SOURCE TEST PASSED
SPECTRUM MAP TEST PASSED
WAVE CAPTURE TEST PASSED
WATERFALL TEST PASSED
TRAIL CALC TEST PASSED
CURVE CALC TEST PASSED
LCD CURVE SPECTRUM TEST PASSED
LCD UI TEST PASSED
LCD EFFECTS TEST PASSED
UI KEY/CTRL TEST PASSED
UI DUAL KEY TEST PASSED
LCD FFT TEST PASSED
LCD FFT ALIGN TEST PASSED
CHAIN TEST PASSED
=== REGRESSION PASSED ===
```

## 当前时序

```text
正常 bitstream : SETUP +2.163 ns, HOLD +0.140 ns
扫频 bitstream : SETUP +5.951 ns, HOLD +0.144 ns
```

两者都在 33.333 MHz 下通过。Catmull-Rom 是当前主要 LUT/时序开销。

## 已知限制

- 还没有接主引擎 `mix_sum[63:0]` PCM tap。
- 还没有 100 MHz 可视化 PnR；主引擎与显示仍是单 33.3 MHz demo。
- 还没有异步 FIFO / 跨时钟域历史 RAM。
- 还没有摇杆输入。
- FALL 的 Catmull-Rom 曲线仍能看出控制点节点。
- `lcd_trail_spectrum`、`lcd_waterfall` 和 3D 代码已归档，不参与当前构建。
