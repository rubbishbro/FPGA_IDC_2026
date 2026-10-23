"""coeff_loaded / low_unloaded 元数据位图回归（modal_poly_bank）。

背景：综合器曾把 `modal_poly_bank` 里动态索引读-改-写的
`coeff_loaded[cfg_voice]` 推断成块 RAM，RAM 读回到最低缺失索引的组合计算
在首音符配置 mode17 后与 RTL 不等价，`low_unloaded` 最终停在 16，
27-mode sample 被 precheck 拒绝、上层永久等待。本测试独立于
该 netlist 缺陷，直接用公共端口和只读内部数组验证元数据语义。

覆盖：
  * voice0 / 中间 / 末尾不同配置顺序，重点边界 15/16/17/23/24/31/32/47
  * 先写高位留洞、再补洞（low_unloaded 跨洞跳变）
  * 重复 cfg（重复写不改位图/前缀）
  * reset 后重新装载
  * clear 只清 lane 历史、不擦 coeff_loaded / low_unloaded
  * 非法 cfg_mode / cfg_voice：error_code=1 且元数据不变、busy 低
  * sample 缺 mode：同握手周期 error_code=3、busy 低、无 side effect
  * 完整行：sample 被接受并跑出 out_valid
本文件不声称实板/STA 通过；最终验收由父会话独立完成。
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import random
import xml.etree.ElementTree as ET

import cocotb
from cocotb.triggers import Timer

ROOT = Path(__file__).resolve()
while not ((ROOT / "rtl").is_dir() and (ROOT / "sim").is_dir()):
    ROOT = ROOT.parent
import sys as _sim_sys  # noqa: E402
_sim_sys.path.insert(0, str(ROOT / "sim" / "support"))
from _sim_paths import bootstrap as _sim_bootstrap  # noqa: E402
ROOT = _sim_bootstrap(__file__)


class MetaBank:
    """按“位图”驱动的 bank 夹具；支持任意顺序 / 重复 / 留洞的 cfg。"""

    def __init__(self, d):
        self.d = d
        self.v = len(d.active_mask)
        self.vw = len(d.cfg_voice)
        self.mw = len(d.cfg_mode)
        self.nmax = int(os.environ.get("REVIEW_N_MODES", "48"))
        # 每个 voice 一个 int 位图：bit k = mode k 已配置
        self.loaded = [0] * self.v

    # ---- 期望模型（独立于 DUT）--------------------------------------------
    @staticmethod
    def lowest_missing(bitmap: int, nmax: int) -> int:
        k = 0
        while k < nmax and (bitmap >> k) & 1:
            k += 1
        return k

    def prefix(self, v: int) -> int:
        return self.lowest_missing(self.loaded[v], self.nmax)

    def count_vec(self) -> int:
        """驱动给 n_modes_vec 的“连续前缀长度”，等于各 voice 的最低缺失。"""
        c = 0
        for v in range(self.v):
            c |= self.prefix(v) << (v * self.mw)
        return c

    def meta_ok(self, v: int) -> None:
        """断言只读观测数组与独立位图一致。"""
        got_bits = int(self.d.coeff_loaded[v].value)
        assert got_bits == self.loaded[v], (
            f"v{v} coeff_loaded={got_bits:#x} expected={self.loaded[v]:#x}")
        got_pre = int(self.d.low_unloaded[v].value)
        exp = self.prefix(v)
        assert got_pre == exp, (
            f"v{v} low_unloaded={got_pre} expected={exp}")

    def meta_ok_all(self) -> None:
        for v in range(self.v):
            self.meta_ok(v)

    def meta_snapshot(self):
        return (tuple(int(self.d.coeff_loaded[v].value) for v in range(self.v)),
                tuple(int(self.d.low_unloaded[v].value) for v in range(self.v)))

    def oper_snapshot(self):
        d = self.d
        return (int(d.state.value), int(d.act_r.value), int(d.nm_r.value),
                int(d.x_r.value))

    # ---- 驱动 --------------------------------------------------------------
    async def tick(self, **updates):
        d = self.d
        defaults = dict(rst_n=1, cfg_valid=0, cfg_voice=0, cfg_mode=0, cfg_word=0,
                        seed_valid=0, seed_voice=0, seed_mode=0, seed_word=0,
                        clear_valid=0, clear_voice=0, sample_valid=0,
                        active_mask=0, n_modes_vec=self.count_vec(), x_vec=0)
        defaults.update(updates)
        d.clk.value = 0
        for name, value in defaults.items():
            s = getattr(d, name)
            s.value = int(value) & ((1 << len(s)) - 1)
        await Timer(5, unit="ns")
        accepted = {name: bool(defaults["rst_n"]) and bool(defaults[name + "_valid"])
                    and bool(int(getattr(d, name + "_ready").value))
                    for name in ("cfg", "clear", "sample")}
        d.clk.value = 1
        await Timer(5, unit="ns")
        z = {}
        for name in ("busy", "cfg_ready", "clear_ready", "sample_ready",
                     "out_valid", "error_valid", "error_code", "clear_done"):
            assert getattr(d, name).value.is_resolvable, name
            z[name] = int(getattr(d, name).value)
        z["accepted"] = accepted
        return z

    async def reset(self):
        z = await self.tick(rst_n=0)
        assert not z["busy"] and not z["out_valid"]
        self.loaded = [0] * self.v
        self.meta_ok_all()
        # 再跑一拍确认释放后空闲
        z = await self.tick()
        assert z["sample_ready"] and z["cfg_ready"] and not z["busy"]

    async def wait_idle(self, limit=6000):
        for _ in range(limit):
            if not int(self.d.busy.value) and int(self.d.sample_ready.value):
                return
            z = await self.tick()
            assert not z["error_valid"], "unexpected error while settling"
        raise AssertionError("bank never returned to idle")

    async def cfg(self, v, m, word=0):
        await self.wait_idle()
        before = self.meta_snapshot()
        z = await self.tick(cfg_valid=1, cfg_voice=v, cfg_mode=m, cfg_word=word)
        assert z["accepted"]["cfg"], "cfg handshake not accepted"
        assert not z["error_valid"], "legal cfg raised an error"
        self.loaded[v] |= 1 << m
        self.meta_ok(v)
        # 其它 voice 不受影响
        for w in range(self.v):
            if w != v:
                assert (int(self.d.coeff_loaded[w].value), int(self.d.low_unloaded[w].value)) \
                    == (before[0][w], before[1][w]), "cfg leaked into another voice"
        return z

    async def cfg_illegal(self, v, m):
        await self.wait_idle()
        before = self.meta_snapshot()
        z = await self.tick(cfg_valid=1, cfg_voice=v, cfg_mode=m)
        assert z["accepted"]["cfg"], "illegal cfg handshake not accepted"
        assert z["error_valid"] and z["error_code"] == 1, "illegal cfg not rejected with code 1"
        assert not z["busy"], "illegal cfg made bank busy"
        assert self.meta_snapshot() == before, "illegal cfg mutated metadata"
        return z

    async def clear(self, v):
        await self.wait_idle()
        before = self.meta_snapshot()
        z = await self.tick(clear_valid=1, clear_voice=v)
        assert z["accepted"]["clear"] and z["clear_done"] and not z["error_valid"]
        assert self.meta_snapshot() == before, "clear must not touch coeff_loaded/low_unloaded"
        return z

    async def sample_complete(self, mask):
        """active 各 voice 均为完整前缀时，sample 必须被接受并产生 out_valid。"""
        await self.wait_idle()
        z = await self.tick(sample_valid=1, active_mask=mask,
                            n_modes_vec=self.count_vec(), x_vec=1 << 20)
        assert z["accepted"]["sample"], "complete-row sample not accepted"
        assert not z["error_valid"], "complete-row sample raised an error"
        for _ in range(6000):
            z = await self.tick()
            if z["out_valid"]:
                await self.wait_idle()
                return
            assert not z["error_valid"], "error during accepted frame"
        raise AssertionError("complete frame produced no out_valid")

    async def sample_missing(self, mask, counts):
        """缺 mode：同握手周期 error_code=3、busy 低、元数据/运行态无副作用。"""
        await self.wait_idle()
        meta_before = self.meta_snapshot()
        oper_before = self.oper_snapshot()
        z = await self.tick(sample_valid=1, active_mask=mask,
                            n_modes_vec=counts, x_vec=1 << 20)
        assert z["accepted"]["sample"], "rejecting sample handshake not accepted"
        assert z["error_valid"] and z["error_code"] == 3, "missing-mode not rejected with code 3"
        assert not z["busy"], "rejected sample made bank busy"
        assert self.meta_snapshot() == meta_before, "rejected sample mutated metadata"
        assert self.oper_snapshot() == oper_before, "rejected sample mutated operational state"
        assert int(self.d.sample_ready.value) and int(self.d.cfg_ready.value)


def _boundary_order(nmax: int, rng: random.Random):
    """先写高位（制造洞），再补其余，重点覆盖 15/16/17/23/24/31/32/47。"""
    head = [m for m in (16, 32, 15, 17, 31, 23, 24, 47, 33) if m < nmax]
    tail = [m for m in range(nmax) if m not in set(head)]
    rng.shuffle(tail)
    return head + tail


@cocotb.test(timeout_time=1200, timeout_unit="sec")
async def metadata_bitmap_arbitrary_order(dut):
    r = MetaBank(dut)
    await r.reset()
    rng = random.Random(0xC0FFEE)

    targets = sorted({0, r.v // 2, r.v - 1})
    for target in targets:
        await r.reset()
        order = _boundary_order(r.nmax, rng)
        for i, mode in enumerate(order):
            await r.cfg(target, mode, word=(0x5A5A_0000 + mode) & ((1 << 72) - 1))
            r.meta_ok(target)
            # 每次写入后，独立位图都必须与 DUT 一致（含跳洞）
            assert r.prefix(target) == MetaBank.lowest_missing(r.loaded[target], r.nmax)

        # 重复 cfg：位图/前缀不变
        dup = order[0]
        snap = r.meta_snapshot()
        await r.cfg(target, dup, word=0x1234)
        assert r.meta_snapshot() == snap, "duplicate cfg changed metadata"

        # clear 只清历史，不擦元数据
        await r.clear(target)

        # 完整行：sample 接受并出 out_valid
        await r.sample_complete(1 << target)

        # 留洞场景：清掉一个低位（用新 DUT 位图模型模拟“未配置”需要 reset）
        await r.reset()
        hole = 0 if r.nmax > 1 else 0
        for mode in range(r.nmax):
            if mode == hole and r.nmax > 1:
                continue
            await r.cfg(target, mode)
        if r.nmax > 1:
            # 洞在 0：low_unloaded=0，驱动 counts=1 (>0) 必然拒绝
            assert r.prefix(target) == 0
            counts = r.count_vec()
            assert counts >> (target * r.mw) & 1 == 0
            over = counts | (1 << (target * r.mw))
            await r.sample_missing(1 << target, over)
            # 补洞 -> 完整 -> 立即接受
            await r.cfg(target, hole)
            assert r.prefix(target) == r.nmax
            await r.sample_complete(1 << target)

    dut._log.info("independent metadata bitmap: arbitrary order / holes / duplicates / "
                  "clear retention / reset reload passed for voices %s", targets)


@cocotb.test(timeout_time=1200, timeout_unit="sec")
async def illegal_cfg_and_metadata_isolation(dut):
    r = MetaBank(dut)
    await r.reset()
    rng = random.Random(0xBEEF)

    target = r.v - 1
    # 合法写入若干 mode，随后非法请求不得改变元数据
    for mode in (0, 1, 7):
        if mode < r.nmax:
            await r.cfg(target, mode)
    before = r.meta_snapshot()

    # 非法 mode：只要端口位宽能表达 >= N_MODES
    if r.nmax < (1 << r.mw):
        await r.cfg_illegal(target, r.nmax)
        assert r.meta_snapshot() == before

    # 非法 voice：只要端口位宽能表达 >= NUM_VOICES
    if r.v < (1 << r.vw):
        await r.cfg_illegal(r.v, 0)
        assert r.meta_snapshot() == before

    # reset 后重新装载：元数据清零再重现
    await r.reset()
    assert all(b == 0 for b in r.loaded)
    for mode in _boundary_order(r.nmax, rng):
        await r.cfg(target, mode)
    assert r.prefix(target) == r.nmax
    await r.sample_complete(1 << target)

    dut._log.info("independent illegal cfg isolation + reset reload passed "
                  "(N_MODES=%d, voices=%d)", r.nmax, r.v)


@cocotb.test(timeout_time=1200, timeout_unit="sec")
async def interleaved_voices_and_update_priority(dut):
    r = MetaBank(dut)
    await r.reset()
    targets = sorted({0, r.v // 2, r.v - 1})
    orders = {}
    for v in targets:
        order = list(range(r.nmax))
        random.Random(0xCAFE + v).shuffle(order)
        orders[v] = order
    # Switch voice every write, not only after finishing a row.
    for i in range(r.nmax):
        for v in targets:
            await r.cfg(v, orders[v][i])
            r.meta_ok_all()
    await r.sample_complete(sum(1 << v for v in targets))

    await r.reset()
    before = r.meta_snapshot()
    z = await r.tick(clear_valid=1, clear_voice=0, cfg_valid=1,
                     cfg_voice=0, cfg_mode=0)
    assert z['accepted']['clear'] and not z['accepted']['cfg']
    assert z['clear_done'] and r.meta_snapshot() == before

    # Even a zero-active frame occupies the controller: offered cfg is ignored.
    z = await r.tick(sample_valid=1, active_mask=0, n_modes_vec=0)
    assert z['accepted']['sample'] and z['busy']
    z = await r.tick(cfg_valid=1, cfg_voice=0, cfg_mode=0)
    assert not z['accepted']['cfg'] and not z['error_valid']
    assert r.meta_snapshot() == before
    await r.wait_idle()
    await r.cfg(0, 0)
    z = await r.tick(rst_n=0, cfg_valid=1, cfg_voice=0, cfg_mode=0)
    r.loaded = [0] * r.v
    r.meta_ok_all()
    assert not z['error_valid'] and not z['busy']
    dut._log.info('interleaved metadata rows, clear/cfg priority, busy cfg and reset/cfg passed')


# ---------------------------------------------------------------------------
# runner
# ---------------------------------------------------------------------------
TESTS = ["metadata_bitmap_arbitrary_order", "illegal_cfg_and_metadata_isolation",
         "interleaved_voices_and_update_priority"]


def _run_case(voices, n_modes, base, runner, freeze, frozen_sources=None):
    build = Path(base) / f"v{voices}_n{n_modes}"
    build.mkdir(parents=True, exist_ok=True)
    sources = [ROOT / "rtl/core/poly_modal_lane.sv", ROOT / "rtl/core/modal_poly_bank.sv"]
    if frozen_sources:
        sources = [frozen_sources.resolve() / p.relative_to(ROOT) for p in sources]
    sources = freeze(sources, build)
    runner.build(sources=sources, hdl_toplevel="modal_poly_bank", build_dir=build,
                 parameters={"NUM_VOICES": voices, "N_MODES": n_modes, "SKIP_ZERO_INPUT": 1},
                 build_args=["-g2012", "-Wall"], always=True)
    total = 0
    for tc in TESTS:
        xml = build / f"results_{tc}.xml"
        xml.unlink(missing_ok=True)
        runner.test(hdl_toplevel="modal_poly_bank",
                    test_module=Path(__file__).stem, test_dir=ROOT, build_dir=build,
                    results_xml=str(xml), testcase=tc,
                    extra_env={"REVIEW_N_MODES": str(n_modes)})
        root = ET.parse(xml).getroot()
        cases = root.findall(".//testcase")
        if len(cases) != 1 or any(c.find("failure") is not None or c.find("error") is not None
                            or c.find("skipped") is not None for c in cases):
            raise SystemExit(f"FAILED {tc} @ {voices}x{n_modes}")
        total += len(cases)
        print(f"[coeff_metadata_review] {voices}x{n_modes} {tc}: {len(cases)} passed")
    return total


def main(argv=None):
    from cocotb_tools.runner import get_runner
    from _review_source_snapshot import freeze_sources
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--cases", default="32x48,1x1,1x17,1x33,3x1,3x17,3x33",
                    help="逗号分隔的 VxN，例如 32x48,3x33")
    ap.add_argument("--build-dir", default="/tmp/opencode/coeff_metadata_review")
    ap.add_argument("--frozen-sources", type=Path,
                    help="review a fixed source snapshot rather than current RTL")
    a = ap.parse_args(argv)
    runner = get_runner("icarus")
    total = 0
    for case in a.cases.split(","):
        voices, n_modes = (int(x) for x in case.strip().lower().split("x"))
        total += _run_case(voices, n_modes, a.build_dir, runner, freeze_sources, a.frozen_sources)
    print(f"[coeff_metadata_review] {total} tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
