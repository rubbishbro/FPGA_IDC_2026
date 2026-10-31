# Current production ENG1 Python/RTL parity

`python/modal_sim/eng1_rtl.py` is the production Q24 model. `RouterEng1` and
`BSynth` now route to it; `LegacyRouterEng1`/`LegacyBSynth` retain Q30 experiments.

```bash
/home/rubbishbro/micromamba/envs/torch312/bin/python -m pytest -q \
  sim/unit/eng1/test_eng1_rtl.py sim/unit/eng1/test_router_eng1.py
/home/rubbishbro/micromamba/envs/torch312/bin/python sim/run_eng1_model.py
```

The runner compares real production RTL traces: four B instruments / 16 slots,
excitation, envelope, zero masks, all voice sums, mixed output and retired idle;
40,000 pitch core clocks including cancellation and metadata rejection; and
37,800 postprocessing samples including reverb truncation, stereo and PCM.
The waveform replay boundary is the accepted performance/pitch snapshot, not
raw MIDI bytes or FIFO timing. See [current model contract](../../../docs/ENG1_PY_MODEL.md).

The older tests below retain historical arithmetic/demo coverage. They are not
the current production waveform acceptance test.

---

# eng1 router-level model tests

Python regression for [`python/modal_sim/router_eng1.py`](../../../python/modal_sim/router_eng1.py),
the integer reference for the eng1 arithmetic. The standalone model uses Q30, while the production router now uses Q24; front-end excitation/envelope parity remains incomplete.

As of 2026-10-30, eng1 and its reference both use signed26 Q2.24 a1 directly.
Runtime first-order pitch uses `pitch_linear.py` and `sim/run_pitch.py`:
`--test unit` checks coefficient/trajectory vectors and atomic cancellation;
`--test phase` checks fractional excitation phase; `--test system` exercises
real P1T1 Flash, both MIDI sources, all 16 slots and I2S at 50 MHz by default.
Use a Python environment with numpy/scipy. `sim/check_pitch_resources.py` audits
the full catalog, and `sim/check_pitch_dynamics.py` checks one-second driven/free
responses at the production Q24 scale. See the [pitch contract](../../../docs/ENG1一阶音高调制.md).

The current regression entry points are `sim/run_audio.py` (272 integer jobs,
including the new low four coefficient bits, sign extension and unused high bits),
`sim/run_sustain.py` (real regenerated Q2.24 Flash resources and all 16 voices),
and the pytest command below. Production B images from the old Q2.20 generation
must be regenerated with `rtl/router/tools/sustain_resources.py`; the 64-byte
record layout remains unchanged. The old serial-core co-simulation described
below is retained for historical use, not the current pipeline acceptance test.

```bash
# unit tests (numpy/scipy; the torch312 env has them)
PATH=$HOME/micromamba/envs/torch312/bin:$PATH \
  python -m pytest -q sim/unit/eng1/test_router_eng1.py

# Historical serial-core co-simulation (TB interface is outdated)
PATH=$HOME/micromamba/envs/torch312/bin:$PATH \
  python python/modal_sim/eng1_cosim.py --mode intended
```

The commands above describe the older co-simulation entry point. For the current pipeline run `python3 sim/run_audio.py --test eng1 --test bridge`; on 2026-10-29 the 256-job integer oracle and PCM/I2S bridge passed. The full integration matrix currently fails to elaborate because performance tops lack AUDIO_ENABLE. See the [current audit](../../../docs/工程评审与验证.md#global-docs-2026-10-29).

For historical reproduction use `--mode intended` explicitly: the script default still reproduces the old F05
pipeline, while the current RTL uses the current mode's state and clears all modes.
On 2026-10-27, pytest passed 33 tests; intended RTL co-simulation matched 63
nonzero-mode jobs and failed 3 zero-mode jobs (66 total). This is not a passing RTL
regression. F12 was subsequently fixed in the pipeline; these are historical results.

On 2026-10-28, Questa 2025.2 ran the current `tb_eng1_cosim.sv` with the same
intended vectors and reproduced those three failures. The recovered `tb_eng1_g`
passed its feedback, clear and full-64-mode checks; a separate current-module
probe measured 321 cycles for 64 modes and one unintended state write for zero
modes. These module runs use unmodified eng1 RTL. Router integration runs require
a temporary declaration-order compatibility copy and have separate limits; see
the [Questa supplement](../../../docs/工程评审与验证.md#questa-2026-10-28).
The CLI above still invokes Icarus; the isolated Questa scripts and logs are in
the supplement's evidence package, not a restored repository regression entry.

The audio demo lives in `python/modal_sim/eng1_demo.py`; its output is under
`FFT_results/sim/eng1/`.  Contract and divergence notes:
[`docs/ENG1_PY_MODEL.md`](../../../docs/ENG1_PY_MODEL.md).
