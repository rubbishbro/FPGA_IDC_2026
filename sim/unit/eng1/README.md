# eng1 router-level model tests

Python regression for [`python/modal_sim/router_eng1.py`](../../../python/modal_sim/router_eng1.py),
the integer sample-level model of the current `voice_router` eng1 path.

```bash
# unit tests (numpy/scipy; the torch312 env has them)
PATH=$HOME/micromamba/envs/torch312/bin:$PATH \
  python -m pytest -q sim/unit/eng1/test_router_eng1.py

# RTL co-simulation: generates cases.txt and runs tb_eng1_cosim
PATH=$HOME/micromamba/envs/torch312/bin:$PATH \
  python python/modal_sim/eng1_cosim.py --mode intended
```

Use `--mode intended` explicitly: the script default still reproduces the old F05
pipeline, while the current RTL uses the current mode's state and clears all modes.
On 2026-10-27, pytest passed 33 tests; intended RTL co-simulation matched 63
nonzero-mode jobs and failed 3 zero-mode jobs (66 total). This is not a passing RTL
regression. See F12 in the current issue list.

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
