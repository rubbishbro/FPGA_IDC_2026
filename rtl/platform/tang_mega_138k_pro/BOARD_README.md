# Tang Mega 138K Pro board top: FPGA -> MAX98357A -> speaker

**首次实板无声排查：**用户已手动尝试SRAM下载，报告VIN/SD约3.3V、BCLK/LRC可见而DIN未捕获。另行完成了不依赖按键/核心的[持续测试音诊断版](diagnostic_tone/README.md)，亲跑独立仿真和真实构建/报告筛查通过，文件`build/diagnostic_tone_20261005/diagnostic_tone.fs`。主工程继续冻结、未被诊断版覆盖；诊断音实板结果待用户反馈。

**2026-10-05最新状态：用户已同意先冻结当前核心与时钟配置、准备7针MAX98357A/3W8Ω接线。** 输入快照及PLL/IP/SDC一致性核对见[`../../demo_freeze_20261005.md`](../../demo_freeze_20261005.md)，安全接线以[`MAX98357A_WIRING.md`](MAX98357A_WIRING.md)为准。完整核心100MHz setup/hold已父会话亲跑0/0，MPW及PLL动态uncertainty覆盖仍OPEN。没有烧录、实板播放或完整时序放行。下方旧测试/构建目录保留为版本历史，不将旧provisional或84MHz记录套用到冻结版。

This is the platform wrapper for the automatic-song playback path.  It turns the
verified RTL digital chain (`rtl/audio/`) into a board project bound to the real
Tang Mega 138K Pro pins. **Tools have generated provisional build artifacts, but
none is released for programming; no board has been programmed or heard.**

Intended board/package: Tang Mega 138K Pro Dock / **FPG676**. The tool uses
**GW5AST-LV138FPG676AES**, Device Version **B**, provisionally; the manifest's
non-ES part declaration and the physical marking still need confirmation.
Do not substitute a PG484 / non-Pro part or treat the board name as part proof.

## 1. Files

| file | role |
|---|---|
| `top.sv` | board top: 50 MHz crystal, reset button, 4 amp outputs, auto SONG (32 voices) |
| `clock_reset.sv` | instantiates the two Gowin PLL IP + reset/lock wrapper (real vendor ports) |
| `board_audio_core.sv` | platform wrapper around `audio_demo_core`; exposes `playback_ready` |
| `board_top.sv` | Gowin synthesis top: wraps `top.sv`, absolute ROM paths |
| `gowin_build.tcl` | real Gowin Tcl build entry (`run syn` / `run pnr`) |
| `ip/README.md` | PLL status: core 100 MHz + audio 12.5 MHz (not 12.288) |
| `ip/pll_core_100m/`, `ip/pll_audio_12m5/`, `ip/pll_init.v` | **real vendor-generated** PLL IP + support |
| `reports/attempt2_romfixed_syn_ok_pnr_blocked/` | real synth resources (P&R blocked) |
| `reports/provisional/` | **INVALID** (ROM missing; superseded) |
| `board_build.json` | machine-readable manifest (device, pins, ROM sizes, PLL, sources) |
| `tang_mega_138k_pro.cst` | full pin constraints (clk/reset + PMOD2 amp pins) |
| `tang_mega_138k_pro.sdc` | clock/generated-clock/CDC constraints (validated in Gowin P&R) |
| `sources.f` | Gowin synthesis file list (excludes all test-only models) |
| `preflight.py` | non-zero gate (files / sources / PLL IP / ROM / device / SDC / tool) |
| `build.sh` | build entry: preflight, then the real `gowin_build.tcl` via `gw_sh` |
| `BOARD_README.md` | this document |
| `sim/audio_helpers/board_pll_model.sv` | **test-only** PLL model (never in `sources.f`) |
| `sim/audio_helpers/board_audio_core_model.sv` | **test-only** wrapper model (never in `sources.f`) |
| `sim/test_audio_board.py` | board simulation (wrapper + auto song + ratios + lock) |
| `sim/test_audio_board_preflight.py` | preflight gate tests |

The parent-owned `audio_pmod2.cst` and `BOARD_TASK.md` are unchanged; this CST
reuses the PMOD2 pin facts from `audio_pmod2.cst`.

## 2. Wiring

FPGA side (PMOD2 / J26), to the **MAX98357A**.  **Confirm the PMOD2 Pin-1
marking and connector orientation on the physical board before wiring**; do not
trust a photo left/right guess.

| board top port | PMOD2 | FPGA pin | MAX98357A |
|---|---|---|---|
| `amp_bclk` | IO0 | C21 | BCLK |
| `amp_lrc`  | IO1 | B20 | LRC |
| `amp_din`  | IO2 | B19 | DIN |
| `amp_sd`   | IO3 | A17 | SD |
| 3V3 | 1/2 | | VIN |
| GND | 3/4 | | GND / GAIN reference |

* `clk` = P16 (50 MHz crystal), `reset` = U4 (button, active high).  Per the
  official `audio.cst` (fetched by the parent session) both are inputs with
  `PULL_MODE=NONE DRIVE=OFF BANK_VCCIO=3.3`; the CST matches that.  The official
  project header is `GW5AST-LV138FPG676AES` (Device Version B) while the declared
  target here stays `GW5AST-LV138FPG676A`; the user must confirm the physical
  part and the target is not changed unilaterally.
* VIN range of the MAX98357A is 2.5-5.5 V; the chosen supply is 3.3 V, but the
  PMOD2 3.3 V rail current capability under a speaker load is **not measured**.
  Starting volume is intentionally low; verify supply droop on real hardware.
* Speaker: 3 W / 8 ohm, connected **bridged across OUTP/OUTN**.  Neither speaker
  terminal may touch ground or an FPGA GPIO.  At 3.3 V / 8 ohm the real output
  is well below the 3 W rating; do not assume 3 W.
* **GAIN** is a hardware configuration pin, not audio data and not a GPIO in
  this design.  I2S `GAIN_SLOT` gives 3/6/9/12/15 dB depending on the resistor
  at GAIN (TDM's fixed 12 dB does **not** apply).  Confirm the module's actual
  GAIN resistor before listening.
* **SD** is shutdown / channel select: high = left channel, low = shutdown.
  `amp_sd = locked & playback_ready & ~reset`, where `playback_ready` is the
  audio core's sticky flag for the **first real sample handed to the TX FIFO**
  (`core_tx_valid && core_tx_ready`), not a 48 kHz frame count.  A failed voice
  load or a stuck song therefore keeps the amplifier shut down; a button reset or
  loss of lock drops SD in the same cycle.  Left/right carry the same mono
  sample, so a channel-selection mistake is harmless.

## 3. Clock / reset behaviour

* The 50 MHz crystal drives two Gowin PLL IP modules; the board top never wires
  the crystal, a test clock or an integer division directly onto `clk_core` /
  `clk_audio`.
* Frozen `clk_core` = 100.000 MHz, `clk_audio` = **12.500 MHz**, not 12.288 MHz.
  BCLK is 3.125 MHz and WS is 48,828.125 Hz; this is diagnostic playback, not
  48 kHz-faithful output.
* `rst_n` is released only after both PLL locks and drops in the same cycle lock
  is lost; the amplifier is shut down until then.

## 4. PLL IP status (real toolchain)

Tool: Gowin V1.9.12.04, `/home/rubbishbro/gowin/IDE/bin/gw_sh` on PATH.

* **clk_core 100 MHz: generated** (`ip/pll_core_100m/`), real vendor output.
* **clk_audio 12.5 MHz: generated** (`ip/pll_audio_12m5/`, module
  `Gowin_PLL_audio_12M5`).  This is a **functional bring-up** clock, NOT exact
  12.288 MHz: BCLK 3.125 MHz, LRC **48.828 kHz** (+1.725% / +29.6 cents).  Exact
  12.288 MHz is not generatable from 50 MHz on this part (see `ip/README.md`).
  Do not report this as measured 48 kHz.
* Real wrapper ports are `(clkin, init_clk, clkout0, lock)` -- no reset/enclk.
* The part string is the ES `...AES`; the physical chip marking must be confirmed
  before programming.

`preflight.py` inspects the uncommented module header, requires the real ports
and the primitive `_mod.v` companion, and rejects stub/behavioural modules.

`board_top.sv` is the Gowin **synthesis** top: it wraps `top.sv` and overrides
`COEFF_FILE`/`INDEX_FILE` with absolute ROM paths so `$readmemh` always finds the
images (a relative path silently failed with WARN EX3988 and let the engine
constant-fold away).  The board simulation still uses `top.sv` directly.

`board_audio_core.sv` consumes `audio_demo_core`'s public output
`playback_ready` (sticky first `core_tx_valid && core_tx_ready`).

## 5. Commands and actual results

Environment:

```bash
export PATH="$HOME/micromamba/envs/torch312/bin:$PATH"   # iverilog 13.0, cocotb 2.1.0
export PATH="$HOME/gowin/IDE/bin:$PATH"                  # Gowin V1.9.12.04
export LD_LIBRARY_PATH="$HOME/gowin/IDE/lib:$LD_LIBRARY_PATH"
```

Board simulation (test-only PLL/wrapper models; **RTL simulation only**):

```bash
python sim/test_audio_board.py --build-dir /abs/path/audio_board
# 6 tests passed   (exit 0)
```

RTL `-Wall` board sim: 6/6 pass (`sim/build/audio_board/{normal,stuck}/results_*.xml`).
`board_t03` checks the behavioural PLL is 2x the drive, BCLK = audio/4 and
LRC = BCLK/64; `board_t05` forces a lock loss (the vendor IP has no reset port,
so button reset drops `rst_n`/SD instead of clearing lock).

**Real Gowin toolchain closure (provisional, official ES part):**

```bash
printf 'source rtl/platform/tang_mega_138k_pro/gowin_build.tcl\n' | gw_sh -nocomp
# FILES_ADDED / SYN_DONE / PNR_DONE
```

Real results (`reports/provisional/`): synthesis pass, place & route pass,
**bitstream produced**; resources 776 logic (739 LUT + 37 ALU), 621 registers,
0 SSRAM, 6 I/O; clk_core Fmax **144.359 MHz** (constraint 100),
clk_audio 160.856 MHz, clk_50m 299.996 MHz; **setup violated endpoints 0**; 40
hold violations are all the `clk_audio -> clk_bclk` output-buffer SDC artifact.
See `BOARD_DELIVERY_REPORT.md`.
`board_t05_loss_of_lock` (a simulated
lock loss with no button reset drops rst_n/SD immediately and only recovers
after relock + a new `playback_ready`), and `board_t06_stuck_no_sd` (a stuck
song built with `-DBOARD_AUDIO_STUCK` keeps `playback_ready`/SD low).
The behavioural PLL is free-running with rounded periods and models no
PFD/VCO/lock/jitter, so this is wiring/control evidence only.

An independent parent review (`sim/test_audio_board_review.py`, not owned here)
additionally runs the **real** `board_audio_core` + real `modal_engine` + real
ROM (not the mock), V32, 256 golden samples over 16 events, bit-exact at the
board pins, forcing an audio-PLL unlock (SD low immediately) and a voice-load
reject path (even after 12 frames SD stays low).  Log
`/tmp/opencode/audio-board-independent-final.log`, XML
`/tmp/opencode/audio-review/board-independent-final/{real,reject}/results.xml`.
This is still RTL simulation, not a physical PLL lock or Gowin run.

Preflight:

```bash
# on this machine the tool IS installed; the missing audio PLL fails code 3:
python3 rtl/platform/tang_mega_138k_pro/preflight.py
# FAIL[PLL_IP] ... pll_audio_12m288/gowin_pll_audio_12m288.v
# exit 3

# structural-only (isolate the tool check):
python3 rtl/platform/tang_mega_138k_pro/preflight.py --no-tool

# after generating the audio PLL IP: exit 0, and build via gw_sh
```

`preflight.py` checks: required files, every `sources.f` entry resolves (with
`--ip-dir` semantics for generated IP), the PLL wrappers have the real ports plus
a primitive `_mod.v` companion, the ROM images are exactly 72x5483 and 20x1024
valid hex entries, the device/pins agree across manifest/README/CST, and the SDC
has **active** (uncommented) generated clocks, `set_max_delay` CDC constraints,
and source-synchronous output constraints (forwarded `clk_bclk` +
`set_output_delay` max/min on `amp_din`/`amp_lrc`).  Exit codes: 1 tool, 2
file/source/ROM, 3 PLL IP, 4 consistency/SDC.  Passing it is **not** a
synthesis, fit or timing result and does not validate PLL PFD/VCO/filter
legality.

## 6. ROM initialisation

`audio_demo_core` / `modal_engine` load the coefficient and index ROMs with
`$readmemh` from `rtl/rom/modal_coeff.mem` (72 bits x 5483) and
`rtl/rom/modal_index.mem` (20 bits x 1024).  For simulation the path is relative
to the run directory (run from the repository root).  For Gowin synthesis run the
tool from the repository root (as `build.sh` does), or pass absolute
`COEFF_FILE` / `INDEX_FILE` parameters, so the relative ROM paths resolve, and
confirm the synthesizer initialises the inferred ROM from these images.

## 7. What is done / NOT done

**Latest freeze:** production RTL/IP/ROM match the independently reviewed
core100 candidate (apart from TEMP ROM path relocation in its build wrapper).
Parent full-build setup/hold0/0, Fmax100.024MHz; bank/engine1506/1508cycles,
4096 bodyON diagnostic chain and full functional/parameter reviews passed.
Clock MPW remains negative under the unchanged device model; the midpoint source
latency candidate was rejected. See the latest documents linked at the top.
The following 84MHz subsection is historical, not the current core result.

**Done (real Gowin V1.9.12.04):** full body-v3 SYN+PNR, both PLL clocks hit, real
ROM, all lanes/BSRAM/DSP retained, all SDC constraints `Actived`. 2BC core
physical fixes (registered `vb_r`, `sv_run_r`/`ctx_valid` split, static per-voice
clear decoder, registered `nm_vec`, masked-AND legality scan, PREP frame-init,
scoped reset-synchroniser removal exception) lifted clk_core Fmax
**48.7 -> 84.08 MHz**, setup endpoints 3991 -> **571**, hold **0**. Reports in
`reports/pnr_body_v3_84mhz/`.

**NOT ACCEPTED -- open items:**

* **Core 100 MHz timing FAILS**: 84.08 MHz; worst remaining path the lane
  `acc -> ynew -> ps` arithmetic chain (~11.8 ns on 10 ns). Closing it needs a
  structural pipeline of that arithmetic (register `ynew`, defer per-mode commit)
  with fresh golden re-verification. Parent report gate **REJECTS**.
* **External I2S closure OPEN**: `review_i2s_pin_delays.py --certified-report`
  rejects because complete setup STA is non-zero; C2O envelope recorded, not
  certified, no fabricated evidence.
* Physical part unknown (AES provisional); no programming; no measured BCLK/LRC.
