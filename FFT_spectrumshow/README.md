# 可视化核心（PCM → FFT → 频谱/瀑布）

当前目录只保留核心逻辑，不再包含 demo 音频 ROM 和板级调试 top。
板级 top、Gowin 工程、约束、bitstream 已归档到 `archive/debug_board/`。

## 核心接口

```text
主引擎 PCM 输入（33.3 MHz 侧）
  pcm_valid      ：当前 PCM 样本有效
  pcm_data[23:0] ：24-bit 有符号 PCM

显示读接口（33.3 MHz）
  rd_bar_idx     ：当前像素对应柱子编号 0..127
  rd_valid       ：当前像素在有效柱状图区域
  rd_q_y         ：柱高 0..479
  rd_q_ov        ：光点超调目标 0..479

瀑布读接口（33.3 MHz）
  wf_base_row    ：最新历史行号
  wf_rd_row      ：显示要读的历史行
  wf_rd_col      ：显示要读的柱子编号
  wf_rd_data     ：历史柱高 0..1023
```

## 数据流

```text
pcm_valid/pcm_data
  → time_pingpong（1024 × 24 bit，双 bank）
  → fft_ctrl（Hann 1024）
  → fft1024_iter（1024 点 DIF）
  → spectrum_map（512 正 bin → 128 bar）
  → display_frame_buffer + waterfall_store（64 帧）
  → lcd_draw / lcd_fft / lcd_waterfall（33.3 MHz）
```

当前所有核心/显示逻辑都在 **33.333 MHz**。
接入主引擎时，只需在 100 MHz 侧加：

```text
pcm_tap：mix_sum[63:0] → pcm_data[23:0]
async FIFO：100 MHz 写 / 33.3 MHz 读
```

FIFO 满时丢弃显示样本，不能反压主引擎。

## 当前源码

```text
src/
├─ audio/
│  ├─ real_audio_chain.v    PCM → 时域窗口 → FFT → 频谱/瀑布
│  └─ time_pingpong.v       1024×24 双 bank 时域窗口
├─ fft/
│  ├─ fft1024_iter.sv       1024 点基 2 DIF、单蝶形
│  └─ fft_ctrl.v            Hann + FFT 控制
├─ spectrum/
│  └─ spectrum_map.v        bin→bar、峰值、平滑、flush
├─ display/
│  ├─ display_frame_buffer.sv  当前柱高/超调双 bank
│  ├─ waterfall_store.sv       64 帧频谱历史
│  ├─ lcd_timing.v             800×480 扫描
│  ├─ lcd_draw.v               页面选择/优先级
│  ├─ lcd_fft.v                柱状图/光点/颜色
│  ├─ lcd_waterfall.v          瀑布图
│  ├─ lcd_wave.v               旧波形占位
│  └─ lcd_background.v         网格/边框
└─ input/key_debounce.v
```

## 数据文件和表

```text
bin2bar.mem        512 个正 bin → 128 根柱子
hann1024.mem       1024 点 Hann 窗
twiddle1024.mem    1024 点 FFT 旋转因子
waterfall_zero.mem 瀑布历史初始化
```

## 仿真

`bin2bar.mem`、`hann1024.mem`、`twiddle1024.mem`、`waterfall_zero.mem`、
`ode_to_joy.mem` 已复制到 `sim/`。

```powershell
cd sim
vlib work
vlog -sv ..\src\fft\fft1024_iter.sv `
    ..\src\display\display_frame_buffer.sv `
    ..\src\display\waterfall_store.sv `
    ..\src\fft\fft_ctrl.v `
    ..\src\audio\time_pingpong.v `
    ..\src\spectrum\spectrum_map.v `
    ..\src\audio\real_audio_chain.v `
    .\chain_tb.v
vsim -c -do "run -all; quit" chain_tb
```

当前链级结果：

```text
=== CHAIN TEST PASSED ===
max bar height = 280
```

`chain_tb.v` 里的 `ode_to_joy.mem` 只是仿真激励，不参与综合。

## 已知问题

- `spectrum_map` 的 ACCUM 流水线 bin/bar 延迟不一致，
  会把 bin n 写到 bar n-1，并和 bar n-3 的旧值比较；
  表现为频谱左移、空洞和斜边。
- `bin2bar` 在低频有空 bar，需要改成最近 bin 分配或提高 FFT 点数。
- 没有峰值归一化，安静输入的柱高偏低。
- 时域波形尚未实现，`lcd_wave.v` 仍是旧占位。

## 归档

- `archive/debug_board/`：原 `top.v`、`.gprj`、`.cst`、`.sdc`、PLL、`flow.tcl`、`impl/`
- `archive/legacy/`：原 Gowin FFT IP、旧 512 点 FFT、旧 testbench、`audio_if.v`
- `archive/data/`：旧 `gc_6s.mem`、`twiddle512.mem`、`ode_to_joy.mem`
- `archive/tools/`：旧生成脚本
- `archive/logs/`：旧构建日志
