# FFT Spectrum Show

GW5AST-138B + 800×480 LCD 的可视化子系统，当前作为独立 demo 验证。
它不包含主合成引擎，也不直接连接主引擎的 PCM 输出。

当前状态（2026-10-27）：

- 页面：BARS / WAVE / FALL / SETTINGS
- FFT/频谱/曲线/UI/显示逻辑仍全部运行在 **33.333 MHz**
- 正常 bitstream 使用三音正弦测试源
- 扫频 bitstream 使用 1 kHz → 10 kHz 测试源
- `time_pingpong` 写侧已支持独立 PCM 时钟域；扫频测试使用 **100 MHz PLL + 100 MHz 域 48 kHz 源**
- FALL 可选 **极坐标曲线**：`POLAR_FALL=1` 时逐像素 CORDIC 求 (r, θ) → 查 768 列曲线 → 半径辉光；圆内是极坐标仪表盘、圆外是双层视差星空 + 流星；不占 framebuffer（polar 工程 BSRAM 223 → 31）
- 主引擎 PCM tap、主引擎接入、指令端口、摇杆解析仍未实现

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
clk_core       可视化计算时钟（33.333 MHz）
rst_core_n     低有效复位
clk_pix        像素扫描时钟（33.333 MHz）
rst_pix_n      低有效复位

clk_wr         PCM 写入时钟域（demo 接 clk_pix；扫频测试接 100 MHz）
rst_wr_n       PCM 写入域低有效复位
pcm_valid      clk_wr 域单拍有效（48 kHz 节拍）
pcm_data[23:0] 有符号 24-bit PCM
pcm_ready      当前 time_pingpong 写 bank 可接收

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

`time_pingpong` 的写侧是唯一的 PCM 跨时钟点：

```text
clk_wr 域（demo: 33.3M / sweep: 100M）
  pcm_valid + pcm_data
        │
        ▼
time_pingpong 写侧
  2 × 1024 × 24 bit
        │  full_exists / full_ptr 2FF
        │  rd_done toggle + 2FF
        ▼
clk_core 33.333M
  FFT / waterfall / curve / wave / display
```

跨域控制信号使用 2FF，`rd_done` 先转 toggle 再跨域；`tbuf_ram` 是双时钟 RAM。可视化处理仍然全部在 33.333 MHz，不要把 FFT/Catmull 逻辑搬到 100 MHz。

接主引擎时只需要在 **100 MHz 侧提供 PCM tap**，接到：

```text
clk_wr      = 主引擎 100 MHz
rst_wr_n    = 主引擎复位
pcm_valid   = 48 kHz valid
pcm_data    = 24-bit PCM
pcm_ready   → 主引擎背压（可忽略，但不能在无效时强行丢样本）
```

指令端口尚未实现。

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
| `clk_src` | 100 MHz | `Gowin_PLL_SRC`，仅扫频/CDC 测试 | `time_pingpong` 写侧、100M 扫频源 |
| `samp_en` | 48.03 kHz | `clk_pix / 694` | 正常 demo PCM 采样节拍 |
| `samp_en_src` | 48 kHz | `clk_src` 频率累加 | 扫频/CDC 测试 PCM 采样节拍 |
| `frame_pulse` | ~52.5 Hz | `lcd_timing` | 双 bank 切换 |

说明：

- `samp_en` / `samp_en_src` 是使能脉冲，不是时钟。
- 所有 FFT/频谱/曲线/UI/显示逻辑仍然只在 33.333 MHz 域。
- 当前唯一的真实 CDC 是 `time_pingpong` 写侧（`clk_src`）到读侧（`clk_pix`）。
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
        │              → curve_store（768×40 双 bank）
        │                    ├─ 线性 FALL：逐像素比较柱高
        │                    └─ 极坐标 FALL：CORDIC 求 (r,θ) → 查 768 列 → 半径比较
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
AGENTS.md            AI 交接：当前状态、命令、约束、目录图（先读这个）
README.md            本文：接口、时钟、页面、构建、目录
docs/
  README.md          文档索引（当前 / 背景 / 历史）
  RTL编码规范.md      编码规范
  系统设计详解.md     原理讲解（部分早于真 FFT 升级）
  FFT升级设计蓝图.md   真 FFT 架构方案
  history/           历史方案（只作参考）
  ref/               异步 FIFO 参考代码（不参与综合）

board/
  ui_demo_top.v        正常板级 top（三音正弦 / SWEEP_MODE=1 时 100M 扫频）
  sweep_demo_top.v     扫频测试 top，参数覆盖 SWEEP_MODE=1
  polar_demo_top.v     极坐标 FALL top（SWEEP_MODE=1 + POLAR_FALL=1）
  ui_demo.gprj         正常 Gowin 工程
  ui_demo_sweep.gprj   扫频/CDC Gowin 工程
  ui_demo_polar.gprj   极坐标 FALL Gowin 工程
  flow.tcl             正常 bitstream
  flow_sweep.tcl       扫频 bitstream
  flow_polar.tcl       极坐标 bitstream
  ui_demo.cst          引脚约束
  timing.sdc           正常时钟约束
  timing_sweep.sdc     扫频/CDC 时钟约束（含 clk_src）
  gowin_pll.v          50M → 33.333M PLL
  gowin_pll_src.v      50M → 100M PLL（仅扫频/CDC 测试）
  *.mem                综合时读取的初始化表（bar2bin/hann/twiddle/waterfall/sine）

src/
  ui/
    ui_pkg.sv          页面/事件常量
    key_ui_event.sv    按键去抖 + 短按/长按事件
    ui_ctrl.sv         页面、设置项、特效状态机
  audio/
    real_audio_chain.v PCM → 时域窗口 → FFT → 频谱/波形/曲线链
    time_pingpong.v    双时钟 1024×24 双 bank（CDC 边界）
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
    lcd_curve_spectrum.sv  FALL 线性曲线和镜像
    cordic_polar.sv        14 级流水线 CORDIC（(x,y)→(r,θ)，BAM 角度）
    lcd_polar_curve.sv     极坐标 FALL（逐像素逆映射 + 仪表盘/星空装饰）
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
  run_regression.ps1   18 项自检回归入口
  *_tb.sv              自检测试（含 tb_lcd_polar_curve）
  curve_calc_ref.sv    旧 curve_calc 参考副本（只给等价性 TB 用）
  *.mem                仿真时读取的初始化表

archive/               历史实验（不参与构建/回归，见 archive/README.md）
  3d_spectrum/         已放弃的 3D 频谱
  unused_pages/        lcd_trail_spectrum / lcd_waterfall
  legacy/              旧 FFT、旧板级 demo、旧 testbench
  debug_board/         早期板级工程
  framebuffer_polar/   极坐标页的旧 framebuffer 版本
  sim_legacy/          旧仿真 testbench 和数据
  data/ logs/ tools/ pll_core_100m/  旧数据、日志、生成脚本、PLL 实验
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

# 恢复正常 bitstream
& "D:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe" flow.tcl
```

扫频工程会生成：

```text
board/impl/pnr/ui_demo_sweep.fs
board/impl/pnr/sweep_demo.fs   （flow_sweep.tcl 自动复制）
```

极坐标 FALL：

```powershell
cd board
& "D:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe" flow_polar.tcl
```

输出：

```text
board/impl/pnr/ui_demo_polar.fs
board/impl/pnr/polar_demo.fs   （flow_polar.tcl 自动复制）
```

烧录：

```text
正常：board/impl/pnr/ui_demo.fs
扫频：board/impl/pnr/sweep_demo.fs
极坐标 FALL：board/impl/pnr/polar_demo.fs
```

扫频源：

```text
1 kHz → 10 kHz
约 10 秒线性扫频
100 MHz PLL 域产生 48 kHz 平均采样节拍
```

它的用途是检查 `time_pingpong` 的 100M→33.3M CDC 和 FALL 四条曲线的 0/3/7/15 帧时间关系，不是正式音频输入。

极坐标 FALL：

```text
POLAR_FALL=1
  逐像素：14 级流水线 CORDIC → (r, θ)
  θ × 3 / 256 → curve_store 的 768 列地址
  四列高度 → 四条半径，|r - R| 三级辉光（100% / 50% / 25%）
  装饰背景（全部是 (r, θ) 的函数，不占存储）：
    径向渐变底色（二次衰减）
    47.5 / 95 / 142.5 px 三个距离圈
    16 根方位辐条、182 px 以外的 64 个外圈刻度
    中心光晕（<5 px / <12 px）
    190 px 外圈亮边 + 柔光
  圆外（r > 191.2 px）：
    远景层：4×4 哈希格，1 px，暗（8~15），不闪
    近景层：8×8 哈希格，2×2 px，亮（14~29），各自相位闪烁
    流星：每 170 帧（约 3.2 s）一颗，45° 斜线，64 px 渐隐拖尾
    从外圈向外 66 px 的蓝色光晕
    210 / 232 px 两段断环（每个象限 33° 窗口）
  无 framebuffer、无双 bank、无画线光栅化
```

CORDIC 输入用 `(dy, dx)`，所以 θ=0 在 12 点方向、顺时针增大。流水线 17 拍延迟，`pix_x` 预先加 17，颜色正好对应当前扫描像素；每行最左 17 个像素用延迟后的 valid 屏蔽。

极坐标页现在覆盖**整屏**（圆内是仪表盘、圆外是星空），`lcd_draw` 在 page 10 上屏蔽全局矩形网格。极坐标版本单独出 `polar_demo.fs`，线性 FALL 仍保留。

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
TIME PINGPONG TEST PASSED
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
LCD POLAR CURVE TEST PASSED
CHAIN TEST PASSED
=== REGRESSION PASSED ===
```

PnR：

```text
正常 bitstream : SETUP +6.877 ns, HOLD 无违例
扫频 bitstream : SETUP +2.961 ns, HOLD 无违例
极坐标 FALL   : SETUP +3.139 ns, HOLD 0 violations, BSRAM 31/340
```

正常 bitstream 是 33.333 MHz；扫频和极坐标 bitstream 同时包含 100 MHz `clk_src` 和 33.333 MHz `clk_pix`。三者 setup/hold 都为正。`curve_calc` 改为按需读 `trail_store` 后，128 深寄存器堆和 128:1 选择器全部消失：normal 现在只有 6.4k 逻辑，最差路径也从 `curve_calc` 移到 `spectrum_map`，polar 从 17.4k 逻辑 / 9.4k FF 降到 6.6k / 4.3k。极坐标页本身不占 BSRAM，polar 工程的 31 块 BSRAM 全部来自 FFT/瀑布/曲线/波形缓存；整套极坐标装饰（仪表盘 + 双层星空 + 流星）只增加约 770 逻辑 / 87 FF / 4.5 DSP。

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
- `time_pingpong` 100M 写 / 33.3M 读 CDC 及 48 kHz 顺序测试
- 极坐标 FALL：逐像素 14 级流水线 CORDIC、768 列查表、四条年龄曲线三级辉光、极坐标网格、中心/外圈光晕、圆外双层视差星空（闪烁 + 流星）与断环，无 framebuffer（BSRAM 223 → 31）
- 全部可视化自检测试

---

## 8. 未实现 / 集成缺口

### 主引擎 PCM

- 还没有 `pcm_tap`：主引擎 `mix_sum[63:0]` → 24-bit PCM 的缩放/饱和。
- `time_pingpong` 已支持 100M 写 / 33.3M 读，但还没有接主引擎的 48k valid。
- 当前 `samp_en` 是 33.333M/694 ≈ 48.03k，只用于正常 demo；扫频测试在 100M 域产生 48k 平均节拍。
- 主引擎完成后，建议在 **100M 侧只做 PCM 捕获和 `time_pingpong` 写**，可视化继续留 33.3M。
- 指令端口尚未实现；后续用 2FF + mailbox，不需要 FIFO。

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
