# Gowin PLL IP for the Tang Mega 138K Pro board top

Real toolchain run: Gowin V1.9.12.04, `/home/rubbishbro/gowin`, `gw_sh` on PATH.

## 1. clk_core -- 100.000 MHz (GENERATED)

`pll_core_100m/gowin_pll_core_100m.v` + `_mod.v`, module `Gowin_PLL_core_100M`
(PLL_ADV `clock_plladv`, part `GW5AST-LV138FPG676AES`, Version B). Primitive
`IDIV_SEL=1 FBDIV_SEL=1 MDIV_SEL=14 ODIV0_SEL=7` -> VCO 700 MHz / 7 = 100 MHz.

## 2. clk_audio -- 12.500 MHz (GENERATED, functional bring-up)

`pll_audio_12m5/gowin_pll_audio_12m5.v` + `_mod.v`, module
**`Gowin_PLL_audio_12M5`**.  Primitive `IDIV_SEL=1 FBDIV_SEL=1 MDIV_SEL=13
ODIV0_SEL=52` -> VCO 650 MHz / 52 = **12.500 MHz**.

This is a **functional bring-up clock**, not a 48 kHz-faithful reference:
BCLK = 3.125 MHz, LRC/WS = **48.828125 kHz** (+1.725% / +29.6 cents).  The ROM is
the 48 kHz coefficient set, so the diagnostic output runs fast by that ratio.
The module name, manifest and SDC all state 12.5, never "12M288".

**Why not exact 12.288 MHz:** from 50 MHz the PLL PFD must be 19-81.25 MHz, so
IDIV in {1,2}; an exhaustive search finds no exact 12.288 MHz (or 24.576) divider
set, and the VCO-960 exact solution (IDIV=5, PFD 10 MHz) is rejected by P&R
(`PA2078`).  Evidence in `pll_audio_12m288_blocked_proof/` (NOT in `sources.f`).

## 3. Shared support and real ports

Real wrapper interface: **(clkin, init_clk, clkout0, lock)** -- no
`reset`/`enclk0..2`.  Each wrapper needs its `_mod.v` companion (the `PLL`
primitive) and `ip/pll_init.v` (PLL_ADV `PLL_INIT` support), all in `sources.f`.
