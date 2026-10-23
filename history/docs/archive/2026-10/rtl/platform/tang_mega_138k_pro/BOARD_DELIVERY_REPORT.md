# 板级歌曲工程历史交付记录（2026年10月4日）

> 历史归档：保留当轮记录，不代表当前状态；当前只读[工程汇报](../../../../../工程汇报.md)

> **历史归档：2026年10月4日的84MHz阶段报告。**下文资源、时序及当时实板状态不代表当前v5。最新整机数据见[歌曲合成工程资源占用](../../../../../工程汇报.md)，迭代过程见[歌曲修复与时序记录](../../song_control_timing_review.md)。保留本文件作为历史证据。

Date 2026-10-04 (rev 8: 2BC core physical fixes; 100 MHz still not met).
**NOT ACCEPTED. No board programmed (USB disconnected); no audio heard; physical
part unknown (AES/B provisional).** Real STA still fails, so external/complete-part
items stay OPEN. No clock lowered, no coefficient/value changed, II=3 kept.

## 1. Netlist corrections accepted and applied

* `n1423_s` was confirmed as the **loader voice*12 constant-address MULT12X12**
  (`A=sp_load_voice[4:0] B=12 OREG=BYPASS`) driving `state_valid.CE`, not a
  frame-controller issue.
* The 7 negative "hold" entries are the **Removal Paths Table**
  (`pll_init.state -> crst_sync_*/arst_sync_*.CLEAR`), i.e. async-assert reset
  release, not 7 Gray data holds (Hold Paths Table worst is +0.247).

## 2. Changes (platform + authorised 2BC core; body_filter read-only v3)

`rtl/core/body_filter.sv` = `00d8e13d...` (body DS, untouched); ROM `64920ba5...`.

* `poly_modal_lane.sv` (`f0f9f998...`): registered `voice_base` (`vb_r`);
  `sv_run_r`/`ctx_valid` split across the existing phases; **static per-voice
  clear decoder** (`for v ... if (clear && clear_voice==v) state_valid[v*LOCAL_MODES
  +: LOCAL_MODES] <= 0`) so no voice*LOCAL_MODES DSP is generated.
* `modal_engine.sv` (`a7eb66c3...`): registered `nm_vec_r` (captured on the same
  edge as `voice_nm`; comment corrected).
* `modal_poly_bank.sv` (`5a967fe7...`): masked-AND legality scan; **PREP
  frame-init stage** — the sample handshake captures a scratch candidate
  (`act_c/nm_c/x_c`) and only a passing precheck enters PREP, which alone writes
  the operational `act_r/nm_r/x_r` (shallow CE). A reject keeps the same-edge
  `error_valid`/`busy=0` and never touches operational state/history; back-to-back
  reject-then-legal works. This is NOT deferred rejection.
* SDC (`ef14413c...`): amp pins = C2O envelope `[0,40] ns`; `amp_sd` = `set_max_delay
  100 ns`; Gray `max_delay 10 ns`; **scoped `set_false_path -hold -to [get_pins
  {...sync.../CLEAR}]`** removal exception for the reset synchronisers.

## 3. Real result (full body v3, Gowin V1.9.12.04)

| metric | prebody | body v3 start | round 7 | **round 8** |
|---|---|---|---|---|
| clk_core Fmax | 56.05 | 48.73 | 77.32 | **84.08 MHz** |
| setup violated | 4235 | 3991 | 2928 | **571** |
| hold violated | 14 | 10 | 7 | **0** (removal exception scoped) |

Resources: 13286 logic (11985 LUT+1301 ALU), 8436 FF, BSRAM 52 (16 SPX9 + 34 pROM),
DSP 15 (2 MULT12X12 + 7 MULT27X36) — all lanes/ROM/DSP retained. Both clocks hit
(clk_core 10 ns, clk_audio 80 ns). Engine max cycles **1475** (≤1800), II=3.

Worst remaining path: `g_lane[3].u_lane/acc -> ynew-clamp -> ps` (11.8 ns). A
partial-sum split was implemented and **reverted** (it regressed to 78.2 MHz —
placement-sensitive), per the "only keep real improvements" rule.

## 4. Gates (honest)

Report dir `reports/pnr_body_v3_84mhz/` (timing report SHA recorded in-tree):

* `review_gowin_reports.py` → **REJECT** (setup 571; the reviewer also checks
  individual path slacks). Report gate exit 1.
* `review_i2s_pin_delays.py --certified-report` → **REJECT** ("complete Setup STA
  must have zero violations"). C2O envelope + external-edge bound recorded,
  **not certified** while core STA is non-zero. No fabricated evidence.
* Preflight PASS; board sim 6/6; preflight tests 10/10; lane 24/24; bank 9/9;
  engine 7/7; independent bank/engine reviews 3/3 each (SKIP 0/1); chain prebody
  12m5 pass.

## 5. Regression / hashes

* `poly_modal_lane.sv` `f0f9f998...`; `modal_engine.sv` `a7eb66c3...`;
  `modal_poly_bank.sv` `5a967fe7...`; SDC `ef14413c...`;
  body_filter `00d8e13d...` (read-only); body ROM `64920ba5...`.
* Reports kept: `pnr_body_v3_84mhz/` (current), `pnr_body_v3_coreopt_77mhz/`,
  `pnr_body_vbr_sdc_c2o/`, `pnr_body_timing_fail/`, `pnr_timing_fail_prebody/`.

## 6. Open / next decision

Remaining 571 setup paths (~1.9 ns worst) are the **lane `acc -> ynew -> ps`
arithmetic chain** and cross-lane/control enables. Closing them needs a structural
pipeline of that arithmetic (register `ynew` + defer the per-mode commit by a
cycle) — a schedule change requiring fresh golden re-verification, and it was
placement-sensitive in test. The body filter v3 itself is no longer in the
worst-path set. External I2S certificate waits on core STA zero.

Still: **not programmed, part unknown (AES provisional), no measured BCLK/LRC,
external I2S and complete-part items OPEN.** No 77/84 MHz artifact is accepted.
