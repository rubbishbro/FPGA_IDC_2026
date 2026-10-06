"""End-to-end body integration test: real guitar song -> modal_engine -> body
-> output adapter -> async FIFO -> standard I2S.

The decoded I2S stream is compared sample-by-sample against a plain-Python
integer chain (song_player + 2C recurrence + DFI-Q34 body + adapter), so this
covers rtl/body_design.md test item 6:

  * >= 4096 samples, multiple events and voice reloads, one shared body whose
    history is never reset mid-song;
  * startup silence / startup underflow reported separately from the
    steady-state; steady-state underflow, deadline, TX overflow and body
    overflow are all zero;
  * the body per-frame latency and the engine busy cycle are measured.

Artefacts go under an absolute build directory; ``sim/results.xml`` is never
written.
"""

from __future__ import annotations

import argparse
import os
import sys

import cocotb
from cocotb.triggers import FallingEdge, RisingEdge, Timer

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_HERE)
sys.path.insert(0, _HERE)
sys.path.insert(0, os.path.join(_ROOT, "python", "modal_sim"))

import test_audio_transport as AT                      # noqa: E402
from params import Patch                               # noqa: E402
from body_fixed_point import BodyFixedPoint            # noqa: E402
from body_helpers import song_coeffs, song_chain, sum_to_i16  # noqa: E402

NOTE_GAP = int(os.environ.get("DEMO_NOTE_GAP", "512"))
NSAMP = int(os.environ.get("DEMO_NSAMP", "4096"))


def _s(v, w):
    return AT._s(v, w)


def _golden(nsamp, coeffs, note_gap):
    mix, _ = song_chain(nsamp, coeffs, note_gap=note_gap, return_mix=True)
    body = BodyFixedPoint(sos=Patch("guitar").sos, guard_bits=4)
    return [sum_to_i16(body.process_sample(m)[0]) for m in mix]


@cocotb.test(timeout_time=2400, timeout_unit="sec")
async def body_song_real_engine(dut):
    await AT._clocks(dut, (("clk_core", 2), ("clk_audio", 16)))
    dut.diag_clear.value = 0
    dut.mic_sd.value = 0
    await AT._reset(dut, ("clk_core", "clk_audio"))

    frames, slots = [], []
    stop = {"done": False}
    dec = cocotb.start_soon(AT.i2s_decode(dut, frames, slots, stop,
                                          "dac_bck", "dac_ws", "dac_din"))

    stats = {"engine_max": 0, "body_max": 0}

    async def engine_mon():
        cur = 0
        while not stop["done"]:
            await RisingEdge(dut.clk_core)
            await Timer(1, unit="ns")
            try:
                busy = int(dut.u_engine.busy.value)
            except AttributeError:
                return
            cur = cur + 1 if busy else 0
            stats["engine_max"] = max(stats["engine_max"], cur)

    async def body_mon():
        counting = False
        c = 0
        while not stop["done"]:
            await RisingEdge(dut.clk_core)
            await Timer(1, unit="ns")
            try:
                iv = int(dut.g_body.u_body.in_valid.value)
                ir = int(dut.g_body.u_body.in_ready.value)
                ov = int(dut.g_body.u_body.out_valid.value)
            except Exception:      # pragma: no cover - unelaborated/renamed scope
                return
            if iv and ir:
                counting, c = True, 0
            elif counting:
                c += 1
                if ov:
                    stats["body_max"] = max(stats["body_max"], c)
                    counting = False

    mon_e = cocotb.start_soon(engine_mon())
    mon_b = cocotb.start_soon(body_mon())

    # startup: the FIFO is empty until the first produced sample crosses the
    # CDC, so the first frames are unavoidably silent.
    startup_frames = 48
    for _ in range(startup_frames * 256):
        await RisingEdge(dut.clk_audio)
    startup_uf = int(dut.underflow_sticky.value)
    assert startup_uf == 1, "expected the unavoidable startup underflow"

    await FallingEdge(dut.clk_core)
    dut.diag_clear.value = 1
    await RisingEdge(dut.clk_core)
    await FallingEdge(dut.clk_core)
    dut.diag_clear.value = 0
    await RisingEdge(dut.clk_core)

    for _ in range(8 * 256):
        await RisingEdge(dut.clk_audio)
    assert int(dut.underflow_sticky.value) == 0, \
        "steady-state underflow after the startup cleared"

    for _ in range((NSAMP - startup_frames + 24) * 256):
        await RisingEdge(dut.clk_audio)
    steady_uf = int(dut.underflow_sticky.value)
    stop["done"] = True
    await dec
    await mon_e
    await mon_b

    ref = _golden(NSAMP, song_coeffs(), NOTE_GAP)
    frames_s = [(_s(l, 16), _s(r, 16)) for (l, r) in frames]
    start = AT._find_block(frames_s, [(y, y) for y in ref], "body_song_real_engine")

    assert int(dut.deadline_error.value) == 0, "body SONG hit a deadline"
    assert int(dut.tx_overflow_sticky.value) == 0, "body SONG TX overflow"
    assert int(dut.body_overflow_sticky.value) == 0, "body input hold overflow"
    assert int(dut.engine_error_valid.value) == 0, "engine reported an error"
    assert steady_uf == 0, "steady-state underflow"

    dut._log.info(
        f"body_song_real_engine {NSAMP} samples bit-exact vs the integer "
        f"body chain; startup underflow={startup_uf}, {start} leading silent "
        f"frames; steady underflow={steady_uf}; engine max busy "
        f"{stats['engine_max']} core cycles; body max latency "
        f"{stats['body_max']} core cycles (frame budget {256 * 16 // 2})")


# ---------------------------------------------------------------------------
# runner
# ---------------------------------------------------------------------------
def _sources():
    A = os.path.join(_ROOT, "rtl", "audio")
    C = os.path.join(_ROOT, "rtl", "core")
    return [os.path.join(A, "audio_async_fifo.sv"),
            os.path.join(A, "pt8211_tx.sv"),
            os.path.join(A, "i2s_amp_tx.sv"),
            os.path.join(A, "i2s_mic_rx.sv"),
            os.path.join(A, "audio_transport.sv"),
            os.path.join(A, "song_player.sv"),
            os.path.join(A, "audio_demo_core.sv"),
            os.path.join(C, "coeff_loader.sv"),
            os.path.join(C, "poly_modal_lane.sv"),
            os.path.join(C, "modal_poly_bank.sv"),
            os.path.join(C, "modal_engine.sv"),
            os.path.join(C, "body_filter.sv")]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--build-dir",
                    default="/tmp/opencode/body-implementation/body_demo")
    args = ap.parse_args(argv)
    sys.path.insert(0, _HERE)
    from _test_runner import build_and_run

    params = dict(NUM_VOICES=8, N_MODES=48, NOTE_GAP=NOTE_GAP, MODE_SONG=1,
                  OUT_FORMAT=1, ENABLE_BODY=1, BODY_INSTRUMENT=0,
                  COEFF_FILE='"' + os.path.join(_ROOT, "rtl", "rom",
                                                "modal_coeff.mem") + '"',
                  INDEX_FILE='"' + os.path.join(_ROOT, "rtl", "rom",
                                                "modal_index.mem") + '"',
                  BODY_FILE='"' + os.path.join(_ROOT, "rtl", "rom",
                                               "body_coeff.mem") + '"')
    env = {"DEMO_NOTE_GAP": str(NOTE_GAP), "DEMO_NSAMP": str(NSAMP),
           "PYTHONPATH": _HERE}
    try:
        build_and_run(_sources(), "audio_demo_core", "test_body_demo", _ROOT,
                      os.path.abspath(os.path.expanduser(args.build_dir)),
                      params, env, testcase="body_song_real_engine")
    except RuntimeError as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        return 1
    print("[body_demo] body_song_real_engine passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
