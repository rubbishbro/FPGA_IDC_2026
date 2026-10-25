# FFT Spectrum Show

GW5AST-138B + 800×480 LCD 的可视化子系统，当前作为独立 demo 验证。
它不包含主合成引擎，也不直接连接主引擎的 PCM 输出。

当前状态（2026-10-24）：

- 页面：BARS / WAVE / FALL / SETTINGS
- 全部可视化逻辑运行在 **33.333 MHz** 像素时钟域
- 正常 bitstream 使用三音正弦测试源
- 扫频 bitstream 使用 1 kHz → 10 kHz 测试源
- 主引擎 PCM tap、100 MHz→33.3 MHz FIFO、摇杆解析均未实现

---

## 1. 对外接口

### 1.1 板级 top：`board/ui_demo_top.v`

```text
clk          50 MHz 板级晶振
rst_n        低有效复位
key0         短按下一页 / 长按进入设置
key1         短按上一页 / 长按返回 BARS
lcd_clk      33.333 MHz 像素时钟输出
lcd_en       有效显示区
lcd_r[5:0]   R
lcd_g[5:0]   G
lcd_b[5:0]   B
```

约束：

```text
clk    P16
rst_n  G16
key0   F15
key1   G15
lcd_*  见 board/ui_demo.cst
```

### 1.2 可视化核心：`src/audio/real_audio_chain.v`

```text
clk_core       可视化计算时钟
rst_core_n     低有效复位
clk_pix        像素扫描时钟
rst_pix_n      低有效复位

pcm_valid      输入 PCM 有效，单个 33.3M 周期脉冲
pcm_data[23:0] 有符号 24-bit PCM

frame_pulse    每帧一个脉冲，用于切换双 bank

rd_bar_idx[6:0]   当前像素对应柱子 0..127
rd_valid          当前像素在有效柱状图区域
rd_q_y[9:0]       柱高 0..479
rd_q_ov[9:0]      峰值光点目标 0..479

wave_rd_addr[9:0]  → 波形帧缓冲读地址
wave_rd_data[9:0]  ← 波形帧缓冲数据
curve_rd_addr[9:0] → FALL 曲线读地址
curve_rd_data[39:0]← FALL 曲线数据
```

**当前 demo 中 `clk_core` 与 `clk_pix` 都接 33.333 MHz**。
模块本身保留了双时钟端口，但还没有真正的异步 FIFO/CDC。

未来接主引擎时，建议只改 `pcm_valid/pcm_data` 的来源：

```text
主引擎 100M
  → PCM tap
  → 异步 FIFO
  → 33.3M 侧 pcm_valid/pcm_data
  → real_audio_chain
```

不要把主引擎直接接到 `real_audio_chain` 的 100M 时钟上。

### 1.3 UI 控制：`src/ui/ui_ctrl.sv`

```text
ev_valid / ev[2:0]   UI 事件
page[1:0]            当前页面
setting_sel[1:0]     设置页当前行
effects[3:0]         bit0 SMTH, bit1 PEAK, bit2 THEM, bit3 GRID
```

页面编号：

```text
00 = BARS
01 = WAVE
10 = FALL
11 = SETTINGS
```

### 1.4 ROM / 初始化文件

```text
board/sine256.mem          三音正弦 / 扫频正弦表
board/bar2bin.mem          512 bin → 128 bar 映射
board/hann1024.mem         1024 点 Hann 窗
board/twiddle1024.mem      FFT 旋转因子
board/waterfall_zero.mem   历史 RAM 初始化
```

`$readmemh` 使用工程运行目录下的文件名，因此 `board/` 和 `sim/` 各有一份所需表。

---

## 2. 时钟域

| 时钟/节拍 | 频率 | 来源 | 使用范围 |
|---|---:|---|---|
| `clk50` / `clk` | 50 MHz | 板级晶振 P16 | PLL 输入、按键 |
| `clk_pix` | 33.333 MHz | `Gowin_PLL`，50M × 2 ÷ 3 | LCD 扫描、FFT、曲线、UI |
| `clk_core` | 33.333 MHz | demo 中直接同 `clk_pix` | 可视化计算 |
| `samp_en` | 48.03 kHz | `clk_pix / 694` | demo PCM 采样节拍 |
| `frame_pulse` | ~52.5 Hz | `lcd_timing` | 双 bank 切换 |

说明：

- `samp_en` 是使能脉冲，不是时钟。
- 当前没有 100 MHz 可视化逻辑。
- 当前没有真正的跨时钟 FIFO；`display_frame_buffer`、`curve_store` 等虽然带双时钟端口，但 demo 中两端同频。
- 主引擎目标是 100 MHz，但主引擎不在此目录内，也没有接入。

---

## 3. 内部架构

```text
pcm_valid / pcm_data[23:0]
        │
        ▼
time_pingpong  1024 × 24bit 双 bank
        │
        ├─→ fft_ctrl（Hann 窗）→ fft1024_iter（1024 点 DIF FFT）
        │        → spectrum_map（512 bin → 128 bar，AGC/门限）
        │        → display_frame_buffer（柱高/峰值双 bank）→ BARS
        │        → waterfall_store（64×128 历史）
        │              → trail_calc（取 age 0/3/7/15 + 3 点平滑）
        │              → curve_calc（Catmull-Rom，768 列）
        │              → curve_store（768×40 双 bank）→ FALL
        │
        └─→ wave_capture → wave_frame_buffer → WAVE

lcd_timing / lcd_draw
        ├─ BARS
        ├─ WAVE
        ├─ FALL
        └─ SETTINGS + 顶部 tab
```

### FALL 曲线

```text
current = age 0   黄
recent  = age 3   青
mid     = age 7   紫
old     = age 15  蓝
```

- 0 线固定在 `y=240`
- 高度减半
- 上半屏 4 条曲线
- 下半屏 4 条镜像线，只画线不填充
- 柱中心控制点：`x = bar*6 + 3`
- Catmull-Rom 三次插值
- 横向 2px / 竖向 3px 线宽
- 3 点频率平滑在 `trail_calc` 完成

### SETTINGS

```text
SMTH  柱状图平滑
PEAK  BARS 峰值光点
THEM  单色主题
GRID  背景网格
```

---

## 4. 目录组织

```text
board/
  ui_demo_top.v        正常板级 top（三音正弦）
  sweep_demo_top.v     扫频测试 top，参数覆盖 SWEEP_MODE=1
  ui_demo.gprj         Gowin 工程
  flow.tcl             正常 bitstream
  flow_sweep.tcl       扫频 bitstream
  ui_demo.cst          引脚约束
  timing.sdc           时钟约束
  gowin_pll.v          50M → 33.333M PLL
  *.mem                初始化表

src/
  ui/
    ui_pkg.sv          页面/事件常量
    key_ui_event.sv    按键去抖 + 短按/长按事件
    ui_ctrl.sv         页面、设置项、特效状态机
  audio/
    real_audio_chain.v PCM → 时域窗口 → FFT → 频谱/波形/曲线链
    time_pingpong.v    1024×24 双 bank
    wave_capture.v     时域波形抽取
    sweep_source.sv    1k→10k 扫频相位累加器
  fft/
    fft1024_iter.sv    1024 点基 2 DIF FFT
    fft_ctrl.v         Hann 窗 + FFT 控制
  spectrum/
    spectrum_map.v     512 bin → 128 bar，AGC/门限
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
    waterfall_store.sv 64×128 历史（FALL age 来源）
    wave_frame_buffer.sv 波形双 bank
    lcd_ui.sv          顶部 tab、设置页
  input/
    key_debounce.v     基础按键去抖

sim/
  run_regression.ps1   全部可视化回归入口
  *_tb.sv             自检 testbench

archive/
  3d_spectrum/         已放弃的 3D 频谱
  unused_pages/        lcd_trail_spectrum / lcd_waterfall
  legacy/              旧 FFT、旧板级 demo、旧 testbench
  debug_board/         早期板级工程
```

---

## 5. 构建

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

扫频源：

```text
1 kHz → 10 kHz
约 10 秒线性扫频
```

它的用途是检查 FALL 四条曲线的 0/3/7/15 帧时间关系，不是正式音频输入。

---

## 6. 回归

```powershell
cd sim
powershell -ExecutionPolicy Bypass -File .\run_regression.ps1
```

当前结果：

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

PnR：

```text
正常 bitstream : SETUP +2.163 ns, HOLD +0.140 ns
扫频 bitstream : SETUP +5.951 ns, HOLD +0.144 ns
```

两者都在 33.333 MHz 下通过。Catmull-Rom 是当前主要 LUT/时序开销。

---

## 7. 已实现

- 1024 点 FFT + Hann 窗
- 512 bin → 128 bar，AGC、门限、平滑
- BARS 峰值光点
- WAVE 真实时域波形
- FALL 4 条真实历史曲线 + 下半镜像
- FALL Catmull-Rom + 柱中心控制点 + 线条加粗
- 顶部 tab、设置页、参数开关
- 双按键短按/长按
- 三音正弦 demo 源
- 1k→10k 扫频测试源和独立 bitstream
- 全部可视化自检测试

---

## 8. 未实现 / 集成缺口

### 主引擎 PCM

- 还没有 `pcm_tap`：主引擎 `mix_sum[63:0]` → 24-bit PCM 的缩放/饱和。
- 还没有 100M→33.3M 异步 FIFO。
- 还没有主引擎 `48k valid` 到可视化 `pcm_valid` 的连接。
- 当前 `samp_en` 是 33.333M/694 ≈ 48.03k，只用于 demo，不是主引擎采样节拍。
- 主引擎完成后，建议在 **100M 侧只做 PCM 捕获和 FIFO 写**，可视化继续留 33.3M。

### 摇杆

- 还没有摇杆解析器。
- 旧 `rtl/drivers/pad_driver.sv` 不在本目录构建中，且只输出极坐标 `pos`，没有 `pos_valid`、没有中心校准、没有死区/迟滞。
- 当前 `ui_demo.cst` 没有摇杆/ADC 引脚约束。
- 后续应单独做 `joystick_parser`：
  - 原始 `x/y` 输入；
  - 上电自动校准中心；
  - 死区 + 迟滞；
  - 左右切页、上下选设置项；
  - 有按键时再做 OK/Back；
  - 与 key0/key1 的事件合并。
- 不要把旧 `pos.x=r / pos.y=w` 直接当方向使用。

### 其他

- 没有 100 MHz 可视化 PnR；当前 Catmull 链不适合直接搬到 100M。
- 没有真正的双时钟历史 RAM；相关模块端口保留，但 demo 同频。
- FALL Catmull 曲线仍能看出控制点节点。
- 设置没有持久化。
- 3D 频谱和旧瀑布页已归档，不参与构建。
- 主引擎板级音频输出、I2S、Flash 加载等不在本目录范围内。

---

## 9. 给队友 AI 的工作边界

- 本目录只负责可视化，不修改 `rtl/core`、`rtl/router` 或主引擎。
- 不要把主引擎 100M 逻辑直接加进 `ui_demo_top`。
- 不要重新启用 `archive/` 里的模块。
- 不要做 100M 全可视化；如要尝试，先单独开分支并重新设计 Catmull 流水线。
- 修改后至少运行 `sim/run_regression.ps1`，并检查 PnR 的 setup/hold。
- 目录内生成物（`board/impl/`、`sim/work/`）已被 `.gitignore` 忽略。
