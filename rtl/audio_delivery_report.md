# Audio bring-up delivery report (independent audio chain + song demo)

Date 2026-10-04. **All results below are RTL simulation only. No bitstream, no
Gowin synthesis/timing report, no board was programmed, and no sound has been
heard.** The hardware is not yet accepted: MAX98357A module wiring/power and the
FPGA physical pins are unconfirmed, and no pin/PLL primitive was invented.

## 1. Scope

Primary deliverable (per the top of `rtl/audio_bringup_design.md`): the
**FPGA -> standard I2S -> MAX98357A -> speaker** playback path for the automatic
public-domain Twinkle melody, plus the CDC/transport and the song front-end.

* Default output format is **standard I2S for MAX98357A** (`OUT_FORMAT=1`):
  BCLK 3.072 MHz, LRC/WS 48 kHz, 32-bit slots, one-BCLK I2S MSB delay, 16-bit
  signed example + zero padding, mono duplicated to both channels, no MCLK.
* **PT8211 (Japanese/LSBJ) is an explicit opt-in only** (`OUT_FORMAT=0`) and is
  never mixed with the I2S path.
* The microphone RX (`i2s_mic_rx`) is kept as a **conditional / historical**
  block. The user has confirmed the target is playback, not capture; the MIC
  tests are reported separately and do not gate the playback delivery.

No 2A/2B/2C file, no frozen-list entry, no reference model and no existing
coefficient file was modified.

## 2. Files

Owned / added by this task:

| file | role |
|---|---|
| `rtl/audio/audio_async_fifo.sv` | dual-clock Gray-pointer async FIFO, per-domain sync reset release |
| `rtl/audio/i2s_amp_tx.sv` | **default** standard-I2S TX for MAX98357A |
| `rtl/audio/pt8211_tx.sv` | optional PT8211 Japanese/LSBJ TX |
| `rtl/audio/i2s_mic_rx.sv` | conditional standard-I2S mic RX (optional) |
| `rtl/audio/audio_transport.sv` | CDC transport, format select, diagnostics, 48 kHz tick |
| `rtl/audio/song_player.sv` | melody events -> engine load/sample, 7-sample pulse |
| `rtl/audio/audio_demo_core.sv` | engine + song_player + transport + output adapter |
| `sim/test_audio_transport.py` | FIFO / both serial TX decoders / MIC / transport |
| `sim/test_song_player.py` | song_player vs mock engine |
| `sim/test_audio_demo.py` | end-to-end SONG (mock + **real engine**) and MIC loopback |
| `sim/audio_helpers/mock_modal_engine.sv` | behavioural engine stand-in (test only) |
| `sim/audio_helpers/song_player_harness.sv` | song_player + mock harness (test only) |

`rtl/core/modal_engine.sv` appeared during this task; its external interface
matches the `module2BC_design.md` section 5 contract exactly and is consumed
read-only. `audio_demo_core` adds `COEFF_FILE`/`INDEX_FILE` pass-through
parameters so the real ROM can be selected.

## 3. Interfaces

* `audio_async_fifo #(WIDTH, DEPTH)`: `wclk/rclk/rst_n`, `wvalid/wready/wdata`,
  `rvalid/rready/rdata`, `wfull/rempty`. Shared async reset, per-domain 2-FF
  release; data bus never synchronised.
* `i2s_amp_tx #(CLK_DIV=4)`: pops one 32-bit `{left,right}` pair per frame
  (mono = either half), outputs `amp_bclk/amp_ws/amp_din`, sticky
  `underflow_sticky`, `frame_tick`. Zero frame on empty.
* `pt8211_tx #(CLK_DIV=8)`: same shape, `dac_bck/ws/din`, WS-low=right,
  no I2S delay.
* `audio_transport #(TX_DEPTH, RX_DEPTH, CH_SEL, OUT_FORMAT=1)`:
  core TX/RX handshakes, `mic_sd`, `dac_bck/ws/din`, `mic_bck/ws`,
  `core_sample_tick` + `core_sample_pulse`, sticky `underflow_sticky` /
  `overflow_sticky`. `OUT_FORMAT=1` -> `i2s_amp_tx` (default), `0` -> `pt8211_tx`.
* `song_player #(NUM_VOICES=8, N_MODES=48, NOTE_GAP=12000, PULSE_LEN=7)`:
  engine load/sample ports, `sample_tick`, produced `out_valid/out_sum`,
  `deadline_error`. Event k -> voice k%NUM_VOICES; 7-sample raised-cosine pulse
  (amp 0.2 Q30); timeline advances only on accepted samples; missed ticks are
  counted and flagged, never silently skipped.
* `audio_demo_core #(..., MODE_SONG=1, OUT_FORMAT=1)`: two exact clocks, output
  adapter sum Q30 `>>3, (+2^14)>>15, sat16` and mic Q23 `>>2, (+2^7)>>8, sat16`.
  Mode is fixed before reset. Exposes `playback_ready` (sticky after the first
  real `core_tx_valid && core_tx_ready` write into the TX FIFO, 0 in reset): it
  means "the audio producer has actually started", **not** that sound has been
  verified; a board layer may use it (with clock lock / frame priming) to avoid
  enabling the amplifier on a silent or stuck datapath.

## 3a. Review fixes (parent-review risks)

* **FIFO reset handshake**: `wready`/`rvalid` are now gated by the local
  synchronised reset release (`wready = wrst_n & ~wfull`, `rvalid = rrst_n &
  ~rempty`), so a write is never advertised as accepted while its domain is
  still reset and the pointer cannot advance. Test `fifo_t04_reset_handshake`.
* **diag_clear CDC**: a core-domain `diag_clear` is converted to a toggle,
  2-FF synchronised, and re-detected as one audio-domain clock event, so a
  single core-cycle pulse is always delivered to the slower audio domain
  (previously a level 2-FF could miss it). Contract: `diag_clear` is an event;
  two events closer than the synchroniser latency would merge. The core-visible
  sticky flags are the synchronised audio sticky levels, so an event clear really
  clears them. Test `transport_t06_diag_clear`.
* **TX underflow vs clear priority**: in `i2s_amp_tx`/`pt8211_tx` an underflow at
  a frame boundary now wins over a simultaneous clear (clear wins on a normal
  frame). Tests `pt8211_t03_clear`, `i2samp_t03_clear`.
* Testbench note: the clear pulses in the cocotb tests are driven on a falling
  edge, held across the sampled rising edge, and deasserted on the next falling
  edge. Driving on a fast clock with only `RisingEdge + Timer` is a driver race
  (it reads back 0 at the edge); the RTL is unaffected.

## 4. Actual commands and XML results

Environment: `export PATH=$HOME/micromamba/envs/torch312/bin:$PATH`; Icarus 13.0,
cocotb 2.1.0. Builds use absolute build dirs, `-g2012 -Wall`, `always=True`, and
an explicit results-XML gate (missing / empty / failed XML is a non-zero exit).
No run writes `sim/results.xml`.

```
python sim/test_song_player.py
python sim/test_audio_transport.py
python sim/test_audio_demo.py
```

| suite | tests | XML build dir | result |
|---|---|---|---|
| `test_song_player.py` | 5 | `sim/build/song_player*/` | 5/5 pass |
| `test_audio_transport.py` | 16 core + 4 optional MIC = 20 | `sim/build/audio_transport/*` | 20/20 pass |
| `test_audio_demo.py` | 4 (mock SONG, `playback_ready`, mock MIC, real engine) | `sim/build/audio_demo/*` | 4/4 pass |

Final re-run after the review fixes: song 5/5, transport 20/20, demo 4/4, all
exit 0. (The earlier 16/16 transport figure predates the added tests.)

Independent parent review (not my file, reported here for cross-reference):
`sim/test_audio_chain_review.py` with NUM_VOICES=32, gap 16, 1352 samples,
85 events (two song passes), real ROM coefficients and 100 MHz / 81.380 ns
clocks: exit 0, 1353 decoded frames, **1 startup underflow, 0 stable-state
underflow**.

Highlights:

* `fifo_t01_sequence`: 320 words across 10 ns / 14 ns clocks, random
  backpressure, 40 wraps, order preserved, no X on valid data.
* `fifo_t02_full_empty`: full does not overwrite; oldest data drained.
* `pt8211_t01/t02`: independent BCK-edge decoder, WS-low=right, MSB-first, no
  I2S delay (a one-bit slip would change the value), zero underflow frame,
  `underflow_sticky` + clear.
* `i2samp_t01/t02`: independent standard-I2S decoder, 16-bit mono duplicated,
  zero padding and the I2S one-bit delay verified, zero underflow frame.
* `transport_t01` (PT8211, `OUT_FORMAT=0`) and `transport_t05`
  (I2S, `OUT_FORMAT=1`): full core->FIFO->serial CDC, both formats.
* `transport_t02/t03`: RX CDC with backpressure / overflow sticky, oldest
  samples preserved. `transport_t04`: 48 kHz tick pulse + underflow sticky.
  `transport_t06`: a one-core-cycle `diag_clear` event is delivered across the
  CDC and clears both sticky flags.
* `mic_t01/t02`: conditional 24-bit ramp (both channels) and high-Z detection
  (optional).
* **`demo_song_real_engine`**: real `modal_engine` + `song_player` + transport +
  standard-I2S, **4096 samples bit-exact** against a plain-Python integer model
  of the 2C per-mode recurrence and the output adapter; 8 voices, accelerated
  `NOTE_GAP=512` (8 events). Measured engine `busy` max **254 core cycles**;
  frame budget in that run is 2048 core cycles (the real 100 MHz / 48 kHz budget
  is 2083). `deadline_error=0`, `tx_overflow_sticky=0`, engine errors 0.
  **Startup vs steady state**: the initial 2 frames are unavoidable FIFO
  underflow silence (`startup underflow=1`); after a race-free one-event
  `diag_clear` the rest of the run shows **steady-state underflow=0**.
* `demo_playback_ready`: `playback_ready` is low while `rst_n` is held, goes
  high only after the first real TX-FIFO write, and is low again after a reset;
  it is a producer-started flag, not an acoustic/pin verification.

## 5. Differences: standard I2S (MAX98357A) vs PT8211

| | default I2S (`i2s_amp_tx`) | optional PT8211 (`pt8211_tx`) |
|---|---|---|
| BCLK | audio_clk/4 = 3.072 MHz | audio_clk/8 = 1.536 MHz |
| WS | low = left, high = right | low = right, high = left |
| delay | standard I2S one-BCLK MSB delay | no I2S delay (MSB at WS edge) |
| frame | 64 BCLK, 32-bit slots | 32 BCLK, 16-bit slots |
| use | external MAX98357A -> speaker | onboard PT8211 only, explicit opt-in |

The two are selected by the static `OUT_FORMAT` parameter and are never mixed;
each has its own independent decoder test.

## 6. Risks / not verified

* **No board acceptance.** No Gowin synthesis/place-route, no timing/Fmax, no
  CDC report, no pin constraints, no bitstream, no measured BCLK/WS.
* `audio_clk` must be an exact 12.288 MHz external reference/PLL; no PLL
  primitive or pin was invented. The design is not 100 MHz integer divided.
* `playback_ready` only reports that the audio producer has handed a sample to
  the TX FIFO. It is not clock-lock, not an acoustic test and not a pin-level
  check; the board layer must still combine it with lock/frame priming before
  enabling `amp_sd`.
* MAX98357A module power/VIN/last pin and the FPGA physical output pins are
  unconfirmed; do not wire from this report.
* MIC capture is conditional and has no real device; its tests prove the digital
  protocol/CDC only.
* The SONG integration used an accelerated note gap in simulation; the real
  `NOTE_GAP=12000` timeline is not simulation-quantified here.
* Ceiling: **RTL digital chain passes in simulation; physical link pending.**
