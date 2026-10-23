"""Parent-reviewer tests, independent of the implementer's cocotb helpers.

Run after implementation: python sim/unit/core/test_modal_bank_independent_review.py
Uses only the specified public interface; never writes internal RTL state.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import random
import sys

import cocotb
from cocotb.triggers import Timer

ROOT = Path(__file__).resolve()
while not ((ROOT / "rtl").is_dir() and (ROOT / "sim").is_dir()):
    ROOT = ROOT.parent
import sys as _sim_sys  # noqa: E402
_sim_sys.path.insert(0, str(ROOT / "sim" / "support"))
from _sim_paths import bootstrap as _sim_bootstrap  # noqa: E402
ROOT = _sim_bootstrap(__file__)
sys.path.insert(0, str(ROOT / "python" / "modal_sim"))
from fixed_point import (CoeffTable, FixedModalSynth, Y_MIN, Y_MAX,
                         pack_word, unpack_word)


def signed(value, width):
    value = int(value)
    return value - (1 << width) if value & (1 << (width - 1)) else value


class Reviewer:
    def __init__(self, dut):
        self.dut = dut
        self.nmax = int(os.environ.get("REVIEW_N_MODES", "48"))
        self.mw = len(dut.cfg_mode)
        self.words = [None] * self.nmax
        self.y1 = [0] * self.nmax
        self.y2 = [0] * self.nmax
        self.frames = 0
        self.commits = 0
        self.max_cycles = 0

    async def tick(self, **inputs):
        d = self.dut
        d.clk.value = 0
        defaults = dict(rst_n=1, cfg_valid=0, cfg_mode=0, cfg_word=0,
                        clear_valid=0, sample_valid=0, n_modes=0, x_in=0)
        defaults.update(inputs)
        for name, value in defaults.items():
            getattr(d, name).value = value & ((1 << len(getattr(d, name))) - 1)
        await Timer(5, unit="ns")
        accepted = {name: bool(defaults["rst_n"]) and bool(defaults[name + "_valid"])
                    and bool(int(getattr(d, name + "_ready").value))
                    for name in ("cfg", "clear", "sample")}
        was_busy = bool(defaults["rst_n"]) and int(d.busy.value)
        if was_busy:
            assert not any(int(getattr(d, name + "_ready").value)
                           for name in ("cfg", "clear", "sample"))
        d.clk.value = 1
        await Timer(5, unit="ns")
        for name in ("busy", "cfg_ready", "clear_ready", "sample_ready",
                     "out_valid", "clear_done", "error_valid", "commit_valid"):
            assert getattr(d, name).value.is_resolvable, (name, getattr(d, name).value)
        result = {name: int(getattr(d, name).value)
                  for name in ("busy", "out_valid", "clear_done", "error_valid",
                               "error_code", "commit_valid")}
        result["accepted"] = accepted
        if result["out_valid"]:
            assert d.y_sum.value.is_resolvable and d.sat_count.value.is_resolvable
            result["sum"] = signed(d.y_sum.value, 64)
            result["sat_count"] = int(d.sat_count.value)
        result["commits"] = []
        for lane in range(4):
            if result["commit_valid"] & (1 << lane):
                for name in ("commit_mode", "commit_y1", "commit_y2", "commit_sat"):
                    assert getattr(d, name).value.is_resolvable
                mode = (int(d.commit_mode.value) >> (lane * self.mw)) & ((1 << self.mw) - 1)
                y1 = signed((int(d.commit_y1.value) >> (lane * 32)) & 0xffffffff, 32)
                y2 = signed((int(d.commit_y2.value) >> (lane * 32)) & 0xffffffff, 32)
                sat = (int(d.commit_sat.value) >> lane) & 1
                assert mode % 4 == lane, ("wrong bank tag", mode, lane)
                result["commits"].append((mode, y1, y2, sat))
        return result

    async def reset(self):
        r = await self.tick(rst_n=0)
        assert not (r["out_valid"] or r["commit_valid"] or r["error_valid"] or r["busy"])
        self.words = [None] * self.nmax
        self.y1 = [0] * self.nmax
        self.y2 = [0] * self.nmax

    async def configure(self, mode, word):
        await self.wait_idle()
        r = await self.tick(cfg_valid=1, cfg_mode=mode, cfg_word=word)
        assert r["accepted"]["cfg"] and not r["error_valid"]
        assert not (r["out_valid"] or r["commit_valid"])
        self.words[mode] = word

    async def clear(self):
        await self.wait_idle()
        r = await self.tick(clear_valid=1)
        assert r["accepted"]["clear"] and r["clear_done"]
        assert not (r["out_valid"] or r["commit_valid"] or r["error_valid"])
        self.y1 = [0] * self.nmax
        self.y2 = [0] * self.nmax

    async def wait_idle(self):
        for _ in range(8):
            if not int(self.dut.busy.value):
                return
            idle = await self.tick()
            assert not (idle["out_valid"] or idle["commit_valid"] or idle["error_valid"])
        raise AssertionError("top did not release busy after result")

    async def frame(self, n, x, mutate=False):
        await self.wait_idle()
        expected = {}
        for k in range(n):
            assert self.words[k] is not None
            a1, a2, g = unpack_word(self.words[k])
            acc = g*x - (a1 << 4)*self.y1[k] - a2*self.y2[k]
            raw = (acc + (1 << 23)) >> 24
            y = max(Y_MIN, min(Y_MAX, raw))
            expected[k] = (y, self.y1[k], int(not Y_MIN <= raw <= Y_MAX))
        seen = {}
        r = await self.tick(sample_valid=1, n_modes=n, x_in=x)
        assert r["accepted"]["sample"] and not r["error_valid"]
        limit = 3*((n + 3)//4) + 16
        for cycles in range(limit + 1):
            assert not r["error_valid"]
            for k, y1, y2, sat in r["commits"]:
                assert k in expected and k not in seen, ("duplicate/unexpected commit", k)
                assert (y1, y2, sat) == expected[k], (k, (y1, y2, sat), expected[k])
                seen[k] = (y1, y2, sat)
            if r["out_valid"]:
                assert set(seen) == set(expected), ("out before all writes", set(seen), n)
                assert r["sum"] == sum(e[0] for e in expected.values())
                assert r["sat_count"] == sum(e[2] for e in expected.values())
                for k, (y1, y2, _) in expected.items():
                    self.y1[k], self.y2[k] = y1, y2
                self.frames += 1
                self.commits += n
                self.max_cycles = max(self.max_cycles, cycles)
                return r, cycles
            changes = {}
            if mutate:
                changes = dict(x_in=Y_MIN + cycles, n_modes=self.nmax - cycles % self.nmax,
                               cfg_valid=1, cfg_mode=0, cfg_word=0,
                               clear_valid=1, sample_valid=1)
            r = await self.tick(**changes)
        raise AssertionError(("frame exceeded bound", n, limit))


@cocotb.test()
async def exhaustive_counts_and_mutation(dut):
    r = Reviewer(dut)
    await r.reset()
    rng = random.Random(20261004)
    for k in range(r.nmax):
        word = pack_word(rng.randrange(-(1 << 21), 1 << 21),
                         rng.randrange(1 << 24), rng.randrange(-(1 << 25), 1 << 25))
        await r.configure(k, word)
    counts = list(range(r.nmax + 1)) + list(range(r.nmax, -1, -1))
    for k, n in enumerate(counts):
        await r.frame(n, rng.randrange(Y_MIN, Y_MAX + 1), mutate=(k % 3 == 0))
        for _ in range(k % 4):
            idle = await r.tick()
            assert not (idle["commit_valid"] or idle["out_valid"] or idle["error_valid"])
        if k % 7 == 0:
            idx = rng.randrange(r.nmax)
            # Changing coefficients must preserve this slot's existing state.
            await r.configure(idx, pack_word(-(1 << 20), (1 << 23), -(1 << 24)))
    dut._log.info("review count sweep: %d frames, %d commits, max %d cycles",
                  r.frames, r.commits, r.max_cycles)


@cocotb.test()
async def reset_at_every_pipeline_offset(dut):
    r = Reviewer(dut)
    await r.reset()
    words = [pack_word(-(1 << 20) + k, (1 << 23) + k, (1 << 24) - k)
             for k in range(r.nmax)]
    for k, word in enumerate(words):
        await r.configure(k, word)
    _, latency = await r.frame(r.nmax, 1 << 29)
    for offset in range(latency + 1):
        await r.clear()
        start = await r.tick(sample_valid=1, n_modes=r.nmax, x_in=1 << 30)
        assert start["accepted"]["sample"]
        for _ in range(offset):
            await r.tick()
        await r.reset()
        for _ in range(latency + 8):
            idle = await r.tick()
            assert not (idle["commit_valid"] or idle["out_valid"] or idle["error_valid"])
        bad = await r.tick(sample_valid=1, n_modes=1, x_in=0)
        assert bad["accepted"]["sample"] and bad["error_valid"] and bad["error_code"] == 3
        for k, word in enumerate(words):
            await r.configure(k, word)
        await r.frame(r.nmax, -(1 << 29))
    dut._log.info("review reset sweep: every offset 0..%d passed", latency)


@cocotb.test()
async def deterministic_feedback_and_protocol(dut):
    r = Reviewer(dut)
    await r.reset()
    for k in range(r.nmax):
        await r.configure(k, pack_word(0, 0, 1 << 24))
    await r.frame(1, 1 << 28)
    await r.frame(1, 1 << 29)
    # Nonzero feedback and known nonsaturated history make a hidden clear observable.
    word = pack_word(-(1 << 19), 1 << 22, 1 << 22)
    await r.configure(0, word)
    result, _ = await r.frame(1, 0)
    assert result["sum"] == 3 * (1 << 26)  # 0.1875 in Q30
    await r.clear()
    result, _ = await r.frame(1, 1 << 29)
    assert result["sum"] == 1 << 27  # retained G=0.25, input 0.5
    await r.wait_idle()
    # clear wins; a poisonous zero coefficient must not be installed.
    response = await r.tick(clear_valid=1, cfg_valid=1, cfg_mode=0,
                            cfg_word=0, sample_valid=1, n_modes=1, x_in=1 << 30)
    assert response["accepted"] == dict(cfg=False, clear=True, sample=False)
    assert response["clear_done"] and not response["out_valid"]
    r.y1 = [0] * r.nmax
    r.y2 = [0] * r.nmax
    await r.frame(1, 1 << 29)
    await r.wait_idle()
    # cfg wins over sample, and does not emit an extra frame.
    new = pack_word(-(1 << 20), 0, 1 << 23)
    response = await r.tick(cfg_valid=1, cfg_mode=0, cfg_word=new,
                            sample_valid=1, n_modes=1, x_in=Y_MAX)
    assert response["accepted"] == dict(cfg=True, clear=False, sample=False)
    assert not (response["out_valid"] or response["error_valid"] or response["busy"])
    r.words[0] = new
    await r.frame(1, 0)
    await r.wait_idle()
    response = await r.tick(cfg_valid=1, cfg_mode=r.nmax, cfg_word=0,
                            sample_valid=1, n_modes=1, x_in=0)
    assert response["error_valid"] and response["error_code"] == 1
    assert response["accepted"]["cfg"] and not response["accepted"]["sample"]
    await r.frame(1, 0)
    if r.nmax + 1 < (1 << r.mw):
        await r.wait_idle()
        response = await r.tick(sample_valid=1, n_modes=r.nmax + 1, x_in=0)
        assert response["error_valid"] and response["error_code"] == 2
        assert not response["busy"] and not response["commit_valid"]
        await r.frame(1, 0)
    # A partially loaded prefix with a hole must fail, then work once the hole is filled.
    await r.reset()
    for k in range(r.nmax - 1):
        await r.configure(k, pack_word(0, 0, 1 << 24))
    response = await r.tick(sample_valid=1, n_modes=r.nmax, x_in=0)
    assert response["error_valid"] and response["error_code"] == 3
    assert not response["busy"]
    await r.configure(r.nmax - 1, pack_word(0, 0, 1 << 24))
    await r.frame(r.nmax, 1 << 28)
    dut._log.info("review deterministic feedback, clear/cfg/sample arbitration and error side effects passed")


@cocotb.test()
async def every_saved_table_row_against_integer_engine(dut):
    r = Reviewer(dut)
    await r.reset()
    rows = 0
    for inst in ("guitar", "piano", "banjo", "mandolin"):
        words = [int(w, 16) for w in (ROOT / f"FFT_results/params/{inst}_coeff.mem").read_text().splitlines()]
        index = json.loads((ROOT / f"FFT_results/params/{inst}_coeffindex.json").read_text())
        for key, metadata in index.items():
            midi, dyn = key.split("|")
            n = min(metadata["n_modes"], r.nmax)
            row = words[metadata["offset"]:metadata["offset"] + n]
            await r.clear()
            for k, word in enumerate(row):
                await r.configure(k, word)
            coefficients = [unpack_word(word) for word in row]
            table = CoeffTable()
            table.add(int(midi), dyn, [c[0] for c in coefficients],
                      [c[1] for c in coefficients], [c[2] for c in coefficients])
            model = FixedModalSynth(table, max_poly=1, max_modes=r.nmax, free_thr=0)
            model.note_on(int(midi), 1.0 if dyn == "forte" else 0.5)
            for _ in range(32):
                expected_audio = model.step()
                result, _ = await r.frame(n, int(model.xq[0]))
                assert r.y1[:n] == model.y1[0, :n].tolist(), (inst, key, "y1")
                assert r.y2[:n] == model.y2[0, :n].tolist(), (inst, key, "y2")
                assert result["sum"] == int(round(expected_audio * (1 << 30))), (inst, key)
            rows += 1
    assert rows == 250
    dut._log.info("review saved tables: all %d rows, %d frames, %d state commits; max %d cycles",
                  rows, r.frames, r.commits, r.max_cycles)


if __name__ == "__main__":
    from cocotb_tools.runner import get_runner
    import xml.etree.ElementTree as ET

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--n-modes", type=int, default=48, choices=range(1, 49))
    parser.add_argument("--skip-zero-input", type=int, default=1, choices=(0, 1))
    parser.add_argument("--build-dir", type=Path,
                        default=ROOT / "sim/build/modal_bank_independent_review")
    args = parser.parse_args()
    build = args.build_dir.resolve()
    build.mkdir(parents=True, exist_ok=True)
    runner = get_runner("icarus")
    runner.build(sources=[ROOT / "rtl/core/modal_lane.sv", ROOT / "rtl/core/modal_bank.sv"],
                 hdl_toplevel="modal_bank", build_dir=build,
                 parameters={"N_MODES": args.n_modes, "SKIP_ZERO_INPUT": args.skip_zero_input},
                 build_args=["-g2012", "-Wall"], always=True)
    xml = runner.test(hdl_toplevel="modal_bank", test_module=Path(__file__).stem,
                      test_dir=build, build_dir=build,
                      extra_env={"REVIEW_N_MODES": str(args.n_modes)},
                      results_xml="independent_review.xml")
    tree = ET.parse(xml)
    cases = tree.findall(".//testcase")
    if len(cases) != 4 or any(c.find("failure") is not None or c.find("error") is not None
                              or c.find("skipped") is not None for c in cases):
        raise SystemExit(1)
