# FFT Spectrum Show - AI handoff

## Scope

- This directory owns the visualization subsystem only.
- Do not modify `rtl/core`, `rtl/router`, `keyboard_board`, or the main synth engine from this directory.
- Keep FFT / spectrum / waterfall / curve / UI / LCD logic at 33.333 MHz.
- The only permitted separate clock domain is the PCM write side of `time_pingpong`.
- Do not add a second visualization pipeline at 100 MHz.

## Current state (2026-10-27)

Implemented:

- BARS / WAVE / FALL / SETTINGS pages.
- 1024-point FFT + Hann window.
- 512 bins -> 128 bars, AGC/threshold/smoothing.
- BARS peak light dot.
- WAVE real time-domain waveform.
- FALL four real history curves (ages 0/3/7/15) + bottom mirror.
- Catmull-Rom interpolation and line thickening.
- UI tabs, settings, dual-key short/long events.
- Normal three-tone demo bitstream.
- 1 kHz -> 10 kHz sweep test bitstream.
- Dual-clock `time_pingpong` PCM capture:
  - write side can run at 100 MHz;
  - read side is 33.333 MHz;
  - sweep test uses a separate 100 MHz PLL and a 48 kHz average sample tick.

Not implemented:

- Main-engine `pcm_tap` (`y_data[63:0]` -> 24-bit PCM with scale/saturation).
- Main-engine 48 kHz `y_valid` integration.
- Command / remote-control port.
- Joystick parser.
- Polar BARS.
- Polar FALL (planned below; not coded).

## Clock domains

| Signal | Frequency | Notes |
|---|---:|---|
| `clk` / `clk50` | 50 MHz | board oscillator, P16 |
| `clk_pix` | 33.333 MHz | LCD scan, FFT, curves, UI |
| `clk_core` | 33.333 MHz | tied to `clk_pix` |
| `clk_wr` | 33.333 MHz demo / 100 MHz sweep | PCM write side |
| `clk_src` | 100 MHz | sweep-only PLL output |
| `samp_en` | ~48.03 kHz | demo PCM tick, `clk_pix / 694` |
| `samp_en_src` | 48 kHz average | sweep/CDC PCM tick, `clk_src` |

Important:

- 48 kHz is a sample rate, not a clock domain.
- `pcm_valid` is a single-cycle enable in the `clk_wr` domain.
- Do not use the local 48.03 kHz `samp_en` to drain a 48.00 kHz source FIFO.

## Main PCM interface

`src/audio/real_audio_chain.v`:

```text
clk_wr
rst_wr_n
pcm_valid
pcm_data[23:0] signed
pcm_ready
```

Normal demo:

```text
clk_wr   = clk_pix
rst_wr_n = rst_pix_n
```

Sweep/CDC test:

```text
clk_wr   = clk_src (100 MHz)
rst_wr_n = source-domain reset
```

`time_pingpong` is the CDC boundary:

- `2 x 1024 x 24 bit` dual-clock banks.
- `full_exists` / `full_ptr` synchronized to read side with 2FF.
- `rd_done` converted to toggle in read domain and edge-detected in write side.
- Cross-domain registers marked `ASYNC_REG`.
- `wr_ready_o` exported as `pcm_ready`.
- Do not replace this with a 16-deep FIFO; the 1024-sample banks are the FFT window buffer.

Main-engine integration is still open:

- `voice_router` output is `y_valid` + signed `y_data[63:0]`.
- Need a `pcm_tap` to scale/saturate 64-bit samples to 24-bit.
- Need to confirm `y_valid` cadence at 48 kHz and whether block boundaries/gaps exist.
- Need to decide backpressure/drop policy for `pcm_ready`.
- The main engine currently lives on `origin/main`, not in the current `boardtest` worktree.
- Main-engine documentation reports ~85 MHz Fmax under a 100 MHz constraint; 48 kHz throughput only needs ~71.5 MHz. Do not assume it closes at 100 MHz.

## Sweep / CDC test

`SWEEP_MODE=1` in `board/ui_demo_top.v`:

```text
50 MHz -> Gowin_PLL_SRC -> 100 MHz
100 MHz domain -> 48 kHz average tick -> sweep_source
100 MHz pcm_valid/pcm_data -> time_pingpong
33.333 MHz -> FFT / display
```

The sweep source is a 24-bit test source. It validates CDC and display behavior, not the 64-bit main-engine tap.

## Build

Normal:

```powershell
cd FFT_spectrumshow/board
& "D:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe" flow.tcl
```

Output:

```text
board/impl/pnr/ui_demo.fs
```

Sweep / CDC:

```powershell
cd FFT_spectrumshow/board
& "D:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe" flow_sweep.tcl
```

Outputs:

```text
board/impl/pnr/ui_demo_sweep.fs
board/impl/pnr/sweep_demo.fs
```

`flow_sweep.tcl` opens `ui_demo_sweep.gprj` and uses `timing_sweep.sdc`.
Do not use the normal `ui_demo.fs` to test the 100 MHz CDC path; normal mode ties `clk_wr` to `clk_pix`.

## Regression

```powershell
cd FFT_spectrumshow/sim
powershell -ExecutionPolicy Bypass -File .\run_regression.ps1
```

Expected result:

```text
TIME PINGPONG TEST PASSED
...
CHAIN TEST PASSED
=== REGRESSION PASSED ===
```

`time_pingpong_tb.sv` uses small 16-sample banks for a fast direct CDC test with 100 MHz write / 33.333 MHz read. Production uses 1024 samples and is covered by `chain_tb`.

## Current PnR results

```text
normal: SETUP +1.976 ns, HOLD +0.149 ns
sweep : SETUP +2.221 ns, HOLD +0.154 ns
```

Both have positive slack. Sweep includes `clk_src` 100 MHz + `clk_pix` 33.333 MHz.

Known warnings:

- `PR1014`: `clk_d` uses generic routing; present in both builds.
- `lcd_background` is swept in optimization; existing behavior.
- `waterfall_zero.mem` entry width warning; existing behavior.

## Polar FALL plan (not implemented)

Polar BARS was rejected: it requires filled sectors and per-pixel inverse polar mapping (large map or CORDIC).

Polar FALL curves are simpler:

```text
curve_calc -> curve_store (768 x 4 x 10-bit)
  -> lcd_polar_curve (at frame start)
       sin/cos LUT from sine256.mem
       R = Rin + curve_height * scale
       x/y = center + R * sin/cos
       5x5 point brush
       2bpp dual-bank framebuffer
  -> LCD scan reads framebuffer
  -> lcd_draw FALL page mux
```

Constraints for the polar FALL implementation:

- Do not add atan2/sqrt/CORDIC or a 800x480 polar map.
- Prefer one new RTL file `src/display/lcd_polar_curve.sv`.
- Reuse `sine256.mem` with 256 angular points first; 768 points is optional.
- 2bpp double-bank framebuffer is about 86 BSRAM; current design uses about 30/340.
- Draw 4 age curves with 4 palette entries.
- Keep linear FALL available via a `POLAR_FALL` parameter.
- New testbench: `sim/tb_lcd_polar_curve.sv`.
- No new top is required; add a tiny wrapper only if a separate polar bitstream is needed.

## Files added for PCM CDC

```text
board/gowin_pll_src.v      50 MHz -> 100 MHz PLL for sweep/CDC
board/ui_demo_sweep.gprj   sweep project
board/timing_sweep.sdc     clk_src + clk_pix constraints
sim/time_pingpong_tb.sv    direct 100 MHz / 33.333 MHz CDC test
```

## Do not

- Do not move the visualizer or FFT into 100 MHz.
- Do not directly connect `y_data[63:0]` to `pcm_data[23:0]` without saturation.
- Do not sync multi-bit PCM/command buses with plain 2FF logic; use the block buffer/toggle handshake.
- Do not add a command FIFO unless multiple outstanding commands are actually required; a 2FF + mailbox is enough for one low-rate command.
- Do not modify or restore `rtl/drivers/pad_driver.sv` from this directory.
- Do not commit `board/impl/`, `sim/work/`, or generated `.fs` files.
