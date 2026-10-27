# eng1 router-level model tests

Python regression for [`python/modal_sim/router_eng1.py`](../../../python/modal_sim/router_eng1.py),
the integer sample-level model of the current `voice_router` eng1 path.

```bash
# unit tests (numpy/scipy; the torch312 env has them)
PATH=$HOME/micromamba/envs/torch312/bin:$PATH \
  python -m pytest -q sim/unit/eng1/test_router_eng1.py

# RTL co-simulation: generates cases.txt and runs tb_eng1_cosim
PATH=$HOME/micromamba/envs/torch312/bin:$PATH \
  python python/modal_sim/eng1_cosim.py
```

The co-simulation runs the model's `rtl_compat=True` mode because the current
`eng1.sv` still has F05.  After F05 is fixed, use
`python python/modal_sim/eng1_cosim.py --mode intended`.

The audio demo lives in `python/modal_sim/eng1_demo.py`; its output is under
`FFT_results/sim/eng1/`.  Contract and divergence notes:
[`docs/ENG1_PY_MODEL.md`](../../../docs/ENG1_PY_MODEL.md).
