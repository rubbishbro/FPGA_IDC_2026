"""modal_engine USE_BC=1：class=1 走 class_loader64，载入 4 带中的 band 3。"""

from __future__ import annotations

import os
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = _HERE
while not (os.path.isdir(os.path.join(_ROOT, "rtl"))
           and os.path.isdir(os.path.join(_ROOT, "sim"))):
    _ROOT = os.path.dirname(_ROOT)
sys.path.insert(0, os.path.join(_ROOT, "python", "modal_sim"))
sys.path.insert(0, os.path.join(_ROOT, "sim", "support"))
from class_format import pack_core, pack_ctrl_common, pack_index  # noqa: E402
from _test_runner import build_and_run  # noqa: E402


def _i(sig):
    try:
        return int(sig.value)
    except ValueError:
        return 0


def _roms(d):
    os.makedirs(d, exist_ok=True)
    idx = [0] * 8192
    idx[(1 << 11) | 60] = pack_index(present=1, n_modes=4, n_vel=4,
                                     mode_offset=0, ctrl_index=0, version=0,
                                     has_control=1, has_seed=0, class_=1)
    with open(os.path.join(d, "b_index.mem"), "w") as f:
        for w in idx:
            f.write(f"{w:016x}\n")
    ctrl = [0] * 1024
    ctrl[0] = pack_ctrl_common(class_=1, instrument=0, ctrl_format=1,
                               key_gain=32768)
    with open(os.path.join(d, "b_ctrl.mem"), "w") as f:
        for w in ctrl:
            f.write(f"{w:064x}\n")
    coeff = [0] * 16
    for k in range(4):
        coeff[12 + k] = pack_core(G=100 + k, a2=0x800000 + k, a1=-(10 + k))
    with open(os.path.join(d, "b_coeff.mem"), "w") as f:
        for w in coeff:
            f.write(f"{w:018x}\n")
    with open(os.path.join(d, "c_seed.mem"), "w") as f:
        f.write("0" * 16 + "\n")
    # A-side files（A loader 不启用，但 readmemh 需要存在）
    with open(os.path.join(d, "a_index.mem"), "w") as f:
        for _ in range(1024):
            f.write("00000\n")
    with open(os.path.join(d, "a_coeff.mem"), "w") as f:
        for _ in range(16):
            f.write("0" * 18 + "\n")


@cocotb.test(timeout_time=120, timeout_unit="sec")
async def t01_b_class_load(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    for name, value in (("load_valid", 0), ("load_voice", 0),
                        ("load_instrument", 0), ("load_midi", 60),
                        ("load_dyn", 0), ("load_vel", 200), ("load_class", 1),
                        ("load_note_id", 0), ("ctrl_rd_voice", 0), ("sample_valid", 0),
                        ("active_mask", 0), ("x_vec", 0)):
        getattr(dut, name).value = value
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")

    dut.load_valid.value = 1
    done = 0
    for _ in range(3000):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        if _i(dut.load_done):
            done = 1
            break
    dut.load_valid.value = 0
    assert done, "load_done not raised"
    assert _i(dut.loaded_n_modes) == 4, _i(dut.loaded_n_modes)
    assert _i(dut.error_valid) == 0, _i(dut.error_code)
    exp_ctrl = pack_ctrl_common(class_=1, instrument=0, ctrl_format=1,
                                key_gain=32768)
    assert _i(dut.commit_ctrl) == exp_ctrl
    for _ in range(2):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
    assert _i(dut.ctrl_rd_data) == exp_ctrl


def _sources():
    C = os.path.join(_ROOT, "rtl", "core")
    return [os.path.join(C, "class_format_pkg.sv"),
            os.path.join(C, "class_loader.sv"),
            os.path.join(C, "class_loader64.sv"),
            os.path.join(C, "class_loader_mux.sv"),
            os.path.join(C, "b_a1_refresh.sv"),
            os.path.join(C, "b_a1_engine.sv"),
            os.path.join(C, "poly_modal_lane.sv"),
            os.path.join(C, "modal_poly_bank.sv"),
            os.path.join(C, "modal_engine.sv")]


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--build-dir",
                    default=os.path.join(_ROOT, "sim", "build", "engine_bc"))
    a = ap.parse_args()
    rom = os.path.join(a.build_dir, "rom")
    _roms(rom)
    q = lambda n: '"' + os.path.join(rom, n) + '"'
    params = {
        "USE_BC": 1, "N_MODES": 4,
        "COEFF_DEPTH": 16, "INDEX_DEPTH": 1024,
        "BC_COEFF_DEPTH": 16, "BC_INDEX_DEPTH": 8192,
        "BC_CTRL_DEPTH": 1024, "BC_SEED_DEPTH": 1,
        "COEFF_FILE": q("a_coeff.mem"), "INDEX_FILE": q("a_index.mem"),
        "BC_COEFF_FILE": q("b_coeff.mem"), "BC_INDEX_FILE": q("b_index.mem"),
        "BC_CTRL_FILE": q("b_ctrl.mem"), "BC_SEED_FILE": q("c_seed.mem"),
    }
    summary = build_and_run(_sources(), "modal_engine", "test_engine_bc",
                            _HERE, a.build_dir, params, {})
    print(f"[engine_bc] {summary['n']} tests PASS")
