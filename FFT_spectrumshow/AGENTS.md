# FFT Spectrum Show - AI handoff

## Start here (new session)

Read in this order; do not infer the architecture from the source tree alone:

1. `AGENTS.md` (this file) - current state, build/regression commands,
   constraints, directory map.
2. `README.md` - interfaces, clock domains, page behaviour, pinout, outputs.
3. `docs/RTL编码规范.md` - coding standard (ports, always blocks, naming).
4. `docs/系统设计详解.md` - data-path principles (background; parts predate
   the real-FFT upgrade).
5. `sim/run_regression.ps1` - the gate: 18 self-checking tests.

`archive/` and `docs/history/` are historical. Never treat them as the
current design.

## Directory map

| path | contents |
|---|---|
| `src/audio/` | PCM input, dual-clock ping-pong, wave capture, sweep source |
| `src/fft/` | 1024-point FFT + Hann window control |
| `src/spectrum/` | 512 bins -> 128 bars (AGC, threshold, release) |
| `src/display/` | timing, page mux, BARS/WAVE/FALL/polar, curve/waterfall/wave stores |
| `src/input/` | key debounce |
| `src/ui/` | page/settings FSM, event constants |
| `board/` | three Gowin projects, tops, constraints, tcl, init `.mem` |
| `sim/` | self-checking testbenches, `run_regression.ps1`, sim `.mem` |
| `docs/` | coding standard, design docs, reference code |
| `archive/` | historical experiments (not built, not simulated) |

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
- Polar FALL renderer (inverse mapping, no framebuffer):
  - `POLAR_FALL=1`;
  - per-pixel pipelined CORDIC -> (r, theta), 14 stages, 1 pixel/clock;
  - theta -> 768-column curve address -> four radii + outer base ring;
  - `|r - R| <= 1 px` draws the curve, no fill;
  - zero framebuffer BSRAM (polar build BSRAM 223 -> 31);
  - separate `polar_demo.fs` test bitstream.

Not implemented:

- Main-engine `pcm_tap` (`y_data[63:0]` -> 24-bit PCM with scale/saturation).
- Main-engine 48 kHz `y_valid` integration.
- Command / remote-control port.
- Joystick parser.
- Polar BARS.

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

Polar FALL:

```powershell
cd FFT_spectrumshow/board
& "D:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe" flow_polar.tcl
```

Outputs:

```text
board/impl/pnr/ui_demo_polar.fs
board/impl/pnr/polar_demo.fs
```

`flow_sweep.tcl` opens `ui_demo_sweep.gprj` and uses `timing_sweep.sdc`.
`flow_polar.tcl` opens `ui_demo_polar.gprj`, uses `polar_demo_top`, and uses `timing_sweep.sdc`.
Do not use the normal `ui_demo.fs` to test the 100 MHz CDC path; normal mode ties `clk_wr` to `clk_pix`.

## Regression

```powershell
cd FFT_spectrumshow/sim
powershell -ExecutionPolicy Bypass -File .\run_regression.ps1
```

Expected result:

```text
TIME PINGPONG TEST PASSED
LCD POLAR CURVE TEST PASSED
...
CHAIN TEST PASSED
=== REGRESSION PASSED ===
```

`time_pingpong_tb.sv` uses small 16-sample banks for a fast direct CDC test with 100 MHz write / 33.333 MHz read. Production uses 1024 samples and is covered by `chain_tb`.

## Current PnR results

```text
normal: SETUP +6.877 ns, HOLD no violations
sweep : SETUP +2.961 ns, HOLD no violations
polar : SETUP +3.139 ns, HOLD 0 violations
```

All have positive slack. Sweep and polar include `clk_src` 100 MHz + `clk_pix` 33.333 MHz.
Polar FALL uses BSRAM 31/340 (9%); the 800x480 framebuffer is gone.

Known warnings:

- `PR1014`: `clk_d` uses generic routing; present in both builds.
- `lcd_background` is swept in optimization; existing behavior.
- `waterfall_zero.mem` entry width warning; existing behavior.

## Polar FALL (inverse mapping, no framebuffer)

Polar BARS is still not implemented. The old objection ("needs filled sectors
and a large polar map or CORDIC") no longer holds: this page already runs a
pipelined CORDIC per pixel, so filled sectors would be the same compare with a
range instead of a band.

`src/display/lcd_polar_curve.sv` + `src/display/cordic_polar.sv`:

```text
curve_calc -> curve_store (768 x 4 x 10-bit)
  -> lcd_polar_curve
       (pix - centre) -> cordic_polar -> (r, theta)
       theta*3/256 -> curve column 0..767
       four radii from the four heights
       |r - R| -> 3-level glow (1.0 / 0.5 / 0.25)
       + decorative background from (r, theta)
  -> lcd_draw FALL page mux (page 10 suppresses the rectangular grid)
```

Implementation facts:

- `POLAR_FALL=1` in `ui_demo_top` / `lcd_draw`.
- 14-stage pipelined CORDIC, one pixel per clock, 17-clock latency.
  `pix_x` is advanced by 17 so the colour belongs to the pixel being scanned;
  the first 17 pixels of each line are blank (the delayed valid is low).
- Angle is BAM (2*pi = 65536); CORDIC inputs are `(dy,dx)` so theta=0 is at
  12 o'clock and increases clockwise.
- No atan2/sqrt library call, no framebuffer, no line rasterizer, no double
  bank. `frame_pulse` only advances the sky animation (twinkle / meteor),
  not the curve path.
- `R_BASE=190`; higher magnitude moves inward. h is 0..479, so the inner
  radius is ~49.7 (the old `R_MIN=40` was never reachable).
- Curve thickness is a glow band: core `|r-R| <= 0.95 px`, then 50% at
  2.2 px and 25% at 4.5 px; the brightest curve wins, ties go to the newest.
- Decorative background (all pure functions of r/theta, no storage):
  quadratic radial gradient, rings at 47.5/95/142.5 px, 16 bearing spokes,
  64 rim ticks above 182 px, centre bloom (<5 / <12 px), rim line + halo at
  190 px.
- Outside the circle (r > 191.2 px): two parallax layers plus a meteor.
  Far layer: 4x4 hash cells, 1 px, dim (8..15), steady.
  Near layer: 8x8 hash cells, 2x2 px, bright (14..29), each star twinkles on
  a 128-frame triangle with its own phase. A meteor crosses every 170 frames
  (~3.2 s), 45 deg, 64 px fading trail, drawn over the whole page. Plus a
  66 px halo from the rim and two broken arcs at 210/232 px. All from
  (x, y, frame), no storage, so the page covers the whole screen and
  `lcd_draw` hides the grid on page 10.
- The sky hash is `seed = x*a + y*b` -> xor-shift -> `*0x2C9D` -> xor-shift.
  The avalanche multiply matters: the plain linear seed produced visible
  diagonal stripes at the old density (FFT peak/mean 1177 vs 28 now).
  The sky value is registered one stage before the RGB mux so the hash
  multipliers stay off the path that ends at the RGB register.
- `flow_polar.tcl` builds `polar_demo_top` with `SWEEP_MODE=1`.
- Separate testbench `sim/tb_lcd_polar_curve.sv` (curve cores, glow level,
  gradient, bloom, rim, stream latency, orientation).
- Polar build: BSRAM 31/340 (9%), FF 4,300, logic 6,564, setup +3.139 ns.
  BSRAM is unchanged; the decoration pass (dashboard + sky) is still about
  +770 logic / +87 FF / +4.5 DSP on top of the plain inverse-mapping page.
- `curve_calc` reads the four neighbours from `trail_store` on demand instead
  of copying the 128 bars into a register array.  11 clocks per bar
  (4 reads + 6 columns), ~1.4 k clocks per frame = 42 us, so the data is
  stable (trail_calc writes once per 21 ms frame).  Removed 5,120 FF and the
  128:1 mux tree: polar 17,386 -> 6,564 logic, 9,405 -> 4,300 FF,
  normal 16.5k -> 6.4k logic and setup +2.649 -> +6.877 ns.
  `sim/curve_calc_equiv_tb.sv` compares the old and new modules word for
  word over four random frames (`sim/curve_calc_ref.sv` keeps the old copy).
- The framebuffer version is archived under `archive/framebuffer_polar/`.

## Files added for PCM CDC

```text
board/gowin_pll_src.v      50 MHz -> 100 MHz PLL for sweep/CDC
board/ui_demo_sweep.gprj   sweep project
board/timing_sweep.sdc     clk_src + clk_pix constraints
sim/time_pingpong_tb.sv    direct 100 MHz / 33.333 MHz CDC test

board/ui_demo_polar.gprj   polar FALL project
board/flow_polar.tcl       polar FALL bitstream
board/polar_demo_top.v     sweep + polar FALL wrapper
src/display/cordic_polar.sv    14-stage pipelined vectoring CORDIC
src/display/lcd_polar_curve.sv polar inverse-mapping renderer (no framebuffer)
sim/tb_lcd_polar_curve.sv  polar geometry/latency/orientation test
sim/sine256.mem            demo sine table (also used by the polar TB model)
archive/framebuffer_polar/ old framebuffer renderer + its TB
```

Curve_calc refactor (2026-10-27):

```text
sim/curve_calc_ref.sv      reference copy of the old register-array version
sim/curve_calc_equiv_tb.sv word-for-word comparison, 4 random frames
```

## Do not

- Do not move the visualizer or FFT into 100 MHz.
- Do not directly connect `y_data[63:0]` to `pcm_data[23:0]` without saturation.
- Do not sync multi-bit PCM/command buses with plain 2FF logic; use the block buffer/toggle handshake.
- Do not add a command FIFO unless multiple outstanding commands are actually required; a 2FF + mailbox is enough for one low-rate command.
- Do not modify or restore `rtl/drivers/pad_driver.sv` from this directory.
- Do not commit `board/impl/`, `sim/work/`, or generated `.fs` files.
