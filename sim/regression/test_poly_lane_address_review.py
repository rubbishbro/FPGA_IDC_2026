"""poly_modal_lane 地址常数乘法等价回归（只观察组合地址，不写 RAM）。

背景：综合器把 `voice*LOCAL_MODES` / `cfg_voice*LOCAL_MODES` 识别成 DSP 常数
乘法，落在 cfg 写地址关键链上。lane 改用编译期常量移位/加法 helper
`voice_base()` 后，本测试对所有**可编码**的 voice/local code 用 python 整数
乘法 golden 逐位比较：

  * `vb_next`            == (voice*LOCAL_MODES) mod 2^SVW
  * `cfg_addr_w` 低 ADDRW 位 == (2*((cfg_voice*LOCAL_MODES)+cfg_local)) mod 2^ADDRW
  * 合法 (voice<NUM_VOICES 且 local<LOCAL_MODES) 时 32bit `cfg_addr_w` 全等

不驱动 cfg_we=1、不写 RAM，因此不会污染 lane 存储；合法 cfg 的真实写入与 run
由现有 bank review（test_modal_poly_bank_review.py）证明。覆盖 lane 的地址
helper 与参数化宽度（SLOTS=1/ADDRW=1/SVW=1 等），矩阵在 runner 里跑。

本测试只证明「地址组合值等价」，不声称 DSP 已被删除或时序已收敛。
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
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


@cocotb.test(timeout_time=900, timeout_unit="sec")
async def address_shift_add_matches_integer_multiply(dut):
    V = int(os.environ["PLA_NUM_VOICES"])
    N = int(os.environ["PLA_N_MODES"])
    LM = (N + 3) // 4

    svw = len(dut.vb_next)          # SVW
    addrw = len(dut.run_addr)       # ADDRW
    vw = len(dut.cfg_voice)         # VW
    idxw = len(dut.cfg_local)       # IDXW
    assert len(dut.cfg_addr_w) == 32
    svw_mask = (1 << svw) - 1
    addr_mask = (1 << addrw) - 1

    # 空闲、无写；地址是纯组合，与时钟/状态无关。
    dut.rst_n.value = 1
    dut.cfg_we.value = 0
    dut.clear.value = 0
    dut.clear_voice.value = 0
    dut.start.value = 0
    dut.n_modes.value = 0
    dut.x_in.value = 0

    checks = 0
    legal = 0
    for cv in range(1 << vw):
        dut.cfg_voice.value = cv
        dut.voice.value = cv
        for cl in range(1 << idxw):
            dut.cfg_local.value = cl
            await Timer(1, unit="ns")

            got_vb = int(dut.vb_next.value)
            exp_vb = (cv * LM) & svw_mask
            assert got_vb == exp_vb, (
                f"vb_next v={cv}: got {got_vb:#x} exp {exp_vb:#x}")

            got_w = int(dut.cfg_addr_w.value)
            exp_w = 2 * ((cv * LM) + cl)
            assert (got_w & addr_mask) == (exp_w & addr_mask), (
                f"cfg_addr_w low[ADDRW] cv={cv} cl={cl}: "
                f"got {got_w & addr_mask:#x} exp {exp_w & addr_mask:#x}")
            if cv < V and cl < LM:
                assert got_w == (exp_w & 0xFFFFFFFF), (
                    f"cfg_addr_w legal full cv={cv} cl={cl}: "
                    f"got {got_w:#x} exp {exp_w:#x}")
                legal += 1
            checks += 1

    dut._log.info(
        "address equivalence: %d voice/local codes (%d legal), "
        "vb_next[%d] and cfg_addr_w low[%d] match integer multiply golden",
        checks, legal, svw, addrw)


def _run_case(voices, n_modes, lane, base, runner, frozen_sources=None):
    build = Path(base) / f"V{voices}_N{n_modes}_L{lane}"
    build.mkdir(parents=True, exist_ok=True)
    runner.build(
        sources=[(frozen_sources.resolve() if frozen_sources else ROOT)
                 / "rtl/core/poly_modal_lane.sv"],
        hdl_toplevel="poly_modal_lane", build_dir=build,
        parameters={"NUM_VOICES": voices, "N_MODES": n_modes,
                    "LANE": lane, "SKIP_ZERO_INPUT": 0},
        build_args=["-g2012", "-Wall"], always=True)
    xml = build / "results.xml"
    xml.unlink(missing_ok=True)
    runner.test(hdl_toplevel="poly_modal_lane",
                test_module=Path(__file__).stem, test_dir=ROOT, build_dir=build,
                results_xml=str(xml),
                extra_env={"PLA_NUM_VOICES": str(voices), "PLA_N_MODES": str(n_modes)})
    root = ET.parse(xml).getroot()
    cases = root.findall(".//testcase")
    if len(cases) != 1 or any(c.find("failure") is not None or c.find("error") is not None
                              or c.find("skipped") is not None for c in cases):
        raise SystemExit(f"FAILED address review V={voices} N={n_modes} L={lane}")
    print(f"[poly_lane_address_review] V={voices} N={n_modes} L={lane}: passed")


def main(argv=None):
    from cocotb_tools.runner import get_runner
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--voices", default="1,3,32")
    ap.add_argument("--n-modes", default="1,7,17,33,48")
    ap.add_argument("--lanes", default="0,1,2,3")
    ap.add_argument("--build-dir", default="/tmp/opencode/poly_lane_address_review")
    ap.add_argument("--frozen-sources", type=Path,
                    help="use the exact source snapshot being synthesized")
    a = ap.parse_args(argv)
    runner = get_runner("icarus")
    total = 0
    for vs in a.voices.split(","):
        for ns in a.n_modes.split(","):
            for ls in a.lanes.split(","):
                _run_case(int(vs), int(ns), int(ls), a.build_dir, runner, a.frozen_sources)
                total += 1
    print(f"[poly_lane_address_review] {total} builds passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
