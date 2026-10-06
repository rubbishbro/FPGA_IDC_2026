"""cocotb end-to-end test for rtl/audio/audio_demo_core.sv (module: audio_demo).

SONG mode   : song_player -> mock modal_engine -> output adapter -> async FIFO ->
              standard-I2S TX.  The serial stream is decoded independently and
              compared, sample by sample, against a plain-Python model of the
              public-domain melody, the fixed excitation pulse and the documented
              Q30 -> int16 output adaptation.
MIC mode    : behavioural standard-I2S microphone source -> RX -> CDC -> core
              quantisation -> TX -> CDC -> standard-I2S decoder; the samples must
              come out in order (optional/historical microphone path).

The engine here is sim/audio_helpers/mock_modal_engine.sv (plain sum of active x
slots), so passing proves the audio sequencing, output adaptation and CDC, never
the 2C modal arithmetic.  The real modal_engine is not present in this tree.

Artefacts go under sim/build/audio_demo (never sim/results.xml).
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
sys.path.insert(0, os.path.join(_ROOT, "rtl", "audio"))

import test_audio_transport as AT  # noqa: E402  (reuses clock/reset/decode helpers)

sys.path.insert(0, os.path.join(_ROOT, "python", "modal_sim"))
from fixed_point import unpack_word  # noqa: E402

PULSE = [0, 40427475, 131267186, 204114978, 204114978, 131267186, 40427475]
SONG = [60, 60, 67, 67, 69, 69, 67, 65, 65, 64, 64, 62, 62, 60,
        67, 67, 65, 65, 64, 64, 62, 67, 67, 65, 65, 64, 64, 62,
        60, 60, 67, 67, 69, 69, 67, 65, 65, 64, 64, 62, 62, 60]

NOTE_GAP = int(os.environ.get("DEMO_NOTE_GAP", "40"))
ROM = os.path.join(_ROOT, "rtl", "rom")
Y_MIN, Y_MAX = -(1 << 31), (1 << 31) - 1


def _sum_to_i16(s):
    t = s >> 3
    t = (t + 16384) >> 15
    return max(-32768, min(32767, t))


def _mic_to_i16(m):
    t = m >> 2
    t = (t + 128) >> 8
    return max(-32768, min(32767, t))


def _s(v, w):
    return AT._s(v, w)


def _song_expected(nsamp, num_voices=8):
    seq = []
    active = [False] * num_voices
    pos = [7] * num_voices
    ev, samp = 0, 0
    for _ in range(nsamp):
        if samp == 0:
            v = ev % num_voices
            active[v] = True
            pos[v] = 0
            ev = (ev + 1) % len(SONG)
        mix = 0
        for v in range(num_voices):
            if active[v] and pos[v] < 7:
                mix += PULSE[pos[v]]
        seq.append(_sum_to_i16(mix))
        for v in range(num_voices):
            if pos[v] < 7:
                pos[v] += 1
        samp = 0 if samp == NOTE_GAP - 1 else samp + 1
    return seq


def _find_block(frames, want, where=""):
    n = len(want)
    for i in range(0, len(frames) - n + 1):
        if frames[i:i + n] == want:
            return i
    raise AssertionError(f"{where}: block of {n} frames not found "
                         f"({len(frames)} decoded)")


def _song_coeffs():
    """(a1,a2,G) lists per guitar-forte MIDI used by the score, from the ROM."""
    import json
    with open(os.path.join(ROM, "modal_manifest.json"), encoding="utf-8") as fh:
        man = json.load(fh)
    with open(os.path.join(ROM, "modal_coeff.mem"), encoding="utf-8") as fh:
        rom = [int(line, 16) for line in fh if line.strip()]
    want = set(SONG)
    out = {}
    for e in man["entries"]:
        if (e["instrument"] == "guitar" and e["dyn"] == "forte"
                and e["midi"] in want):
            words = rom[e["offset"]:e["offset"] + e["n_modes"]]
            out[e["midi"]] = [unpack_word(w) for w in words]
    assert want <= set(out), f"missing guitar-forte notes {want - set(out)}"
    return out


def _song_reference(nsamp, coeffs, num_voices=8, note_gap=512):
    """Bit-exact model of song_player + the 2C per-mode recurrence + adapter."""
    gv = [None] * num_voices
    av = [None] * num_voices
    a2v = [None] * num_voices
    y1 = [[0] * 48 for _ in range(num_voices)]
    y2 = [[0] * 48 for _ in range(num_voices)]
    nm = [0] * num_voices
    active = [False] * num_voices
    pos = [7] * num_voices
    seq = []
    ev, samp = 0, 0
    for _ in range(nsamp):
        if samp == 0:
            v = ev % num_voices
            words = coeffs[SONG[ev % len(SONG)]]
            for k in range(len(words)):
                y1[v][k] = 0
                y2[v][k] = 0
            av[v] = [w[0] for w in words]
            a2v[v] = [w[1] for w in words]
            gv[v] = [w[2] for w in words]
            nm[v] = len(words)
            active[v] = True
            pos[v] = 0
            ev = (ev + 1) % len(SONG)
        mix = 0
        for v in range(num_voices):
            if not active[v]:
                continue
            x = PULSE[pos[v]] if pos[v] < 7 else 0
            ny1 = [0] * 48
            ny2 = [0] * 48
            for k in range(nm[v]):
                acc = (gv[v][k] * x - (av[v][k] << 4) * y1[v][k]
                       - a2v[v][k] * y2[v][k])
                yn = (acc + (1 << 23)) >> 24
                if yn > Y_MAX:
                    yn = Y_MAX
                elif yn < Y_MIN:
                    yn = Y_MIN
                ny1[k] = yn
                ny2[k] = y1[v][k]
                mix += yn
            y1[v], y2[v] = ny1, ny2
        seq.append(_sum_to_i16(mix))
        for v in range(num_voices):
            if pos[v] < 7:
                pos[v] += 1
        samp = 0 if samp == note_gap - 1 else samp + 1
    return seq


@cocotb.test(timeout_time=300, timeout_unit="sec")
async def demo_song_i2s(dut):
    await AT._clocks(dut, (("clk_core", 10), ("clk_audio", 17)))
    dut.diag_clear.value = 0
    dut.mic_sd.value = 0
    await AT._reset(dut, ("clk_core", "clk_audio"))

    num_events = 12
    nsamp = num_events * NOTE_GAP
    frames, slots = [], []
    stop = {"done": False}
    dec = cocotb.start_soon(AT.i2s_decode(dut, frames, slots, stop,
                                          "dac_bck", "dac_ws", "dac_din"))

    for _ in range((nsamp + 20) * 256):
        await RisingEdge(dut.clk_audio)
    stop["done"] = True
    await dec

    # leading zeros (underflow / first zero pulse sample) are stripped by
    # searching for the block that starts at the first non-zero pulse sample
    exp = _song_expected(nsamp)
    want = [(y, y) for y in exp[1:]]
    _find_block(frames, want, "demo_song_i2s")
    assert int(dut.underflow_sticky.value) in (0, 1)   # may or may not occur
    assert int(dut.tx_overflow_sticky.value) == 0, "unexpected TX overflow"
    assert int(dut.engine_error_valid.value) == 0, "mock engine error"
    dut._log.info(f"demo_song_i2s {len(want)} produced samples matched the "
                  f"Python model through I2S; deadline={int(dut.deadline_error.value)}")


@cocotb.test(timeout_time=300, timeout_unit="sec")
async def demo_mic_i2s(dut):
    await AT._clocks(dut, (("clk_core", 10), ("clk_audio", 17)))
    dut.diag_clear.value = 0
    dut.mic_sd.value = 0

    n = 256
    # step 1024 keeps the mic_to_i16 adaptation exactly linear: output = -128+frame
    def value(fr):
        return ((-131072 + fr * 1024) & 0xFFFFFF, 0)

    state = {"done": False, "frame": 0, "value": value, "z": False}
    await AT._reset(dut, ("clk_core", "clk_audio"))
    src = cocotb.start_soon(AT.i2s_source(dut, state, "mic_bck", "mic_sd"))

    frames, slots = [], []
    stop = {"done": False}
    dec = cocotb.start_soon(AT.i2s_decode(dut, frames, slots, stop,
                                          "dac_bck", "dac_ws", "dac_din"))

    for _ in range((n + 24) * 256):
        await RisingEdge(dut.clk_audio)
    state["done"] = True
    stop["done"] = True
    await src
    await dec

    exp = []
    for i in range(n):
        left = _s(value(i)[0], 24)
        exp.append((_mic_to_i16(left), _mic_to_i16(left)))
    frames = [(_s(l, 16), _s(r, 16)) for (l, r) in frames]
    # mono duplicated, and the adapted stream must be a contiguous integer run
    # (the 1024 mic step maps to +1 after the documented q2->q8 adaptation)
    assert all(l == r for (l, r) in frames), "I2S channels not duplicated"
    lefts = [l for (l, _) in frames]
    best = 0
    for i in range(len(lefts)):
        run = 0
        while (i + run < len(lefts)) and (lefts[i + run] == lefts[i] + run):
            run += 1
        best = max(best, run)
    assert best >= n - 4, f"demo_mic_i2s: longest linear run {best} < {n - 4}"
    assert int(dut.overflow_sticky.value) == 0, "unexpected RX overflow"
    dut._log.info(f"demo_mic_i2s {n} microphone samples looped in order")


@cocotb.test(timeout_time=1200, timeout_unit="sec")
async def demo_song_real_engine(dut):
    """Real modal_engine + song_player + transport + I2S vs the integer model."""
    await AT._clocks(dut, (("clk_core", 2), ("clk_audio", 16)))
    dut.diag_clear.value = 0
    dut.mic_sd.value = 0
    await AT._reset(dut, ("clk_core", "clk_audio"))

    nsamp = 4096
    frames, slots = [], []
    stop = {"done": False}
    dec = cocotb.start_soon(AT.i2s_decode(dut, frames, slots, stop,
                                          "dac_bck", "dac_ws", "dac_din"))

    stats = {"maxbusy": 0}

    async def busy_mon():
        cur = 0
        while not stop["done"]:
            await RisingEdge(dut.clk_core)
            await Timer(1, unit="ns")
            try:
                busy = int(dut.u_engine.busy.value)
            except AttributeError:
                return
            if busy:
                cur += 1
                stats["maxbusy"] = max(stats["maxbusy"], cur)
            else:
                cur = 0

    mon = cocotb.start_soon(busy_mon())

    # startup: the FIFO is empty until the first produced sample crosses the CDC,
    # so a few initial frames are unavoidably silent and set the underflow sticky.
    startup_frames = 32
    for _ in range(startup_frames * 256):
        await RisingEdge(dut.clk_audio)
    startup_uf = int(dut.underflow_sticky.value)
    assert startup_uf == 1, "expected the unavoidable startup underflow"

    # one-event clear, driven race-free: set on a core falling edge, hold across
    # the rising edge the transport samples, deassert on the next falling edge
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

    for _ in range((nsamp - startup_frames + 24) * 256):
        await RisingEdge(dut.clk_audio)
    steady_uf = int(dut.underflow_sticky.value)
    stop["done"] = True
    await dec
    await mon

    ref = _song_reference(nsamp, _song_coeffs(), num_voices=8, note_gap=NOTE_GAP)
    frames_s = [(_s(l, 16), _s(r, 16)) for (l, r) in frames]
    start = _find_block(frames_s, [(y, y) for y in ref], "demo_song_real_engine")
    assert int(dut.deadline_error.value) == 0, "real-engine SONG hit a deadline"
    assert int(dut.tx_overflow_sticky.value) == 0, "real-engine SONG TX overflow"
    assert int(dut.engine_error_valid.value) == 0, "real engine reported an error"
    assert steady_uf == 0, "steady-state underflow"
    dut._log.info(f"demo_song_real_engine {nsamp} samples bit-exact vs the integer "
                  f"model; startup underflow={startup_uf}, {start} leading silent "
                  f"frames; steady-state underflow={steady_uf}; engine max busy "
                  f"{stats['maxbusy']} core cycles (frame budget "
                  f"{256 * 16 // 2})")


@cocotb.test(timeout_time=300, timeout_unit="sec")
async def demo_playback_ready(dut):
    """playback_ready: low in reset, sticky after the first real TX FIFO write,
    low again after reset.  This is a "producer started" flag, not an acoustic
    or pin-level verification."""
    await AT._clocks(dut, (("clk_core", 10), ("clk_audio", 16)))
    dut.diag_clear.value = 0
    dut.mic_sd.value = 0
    dut.rst_n.value = 0
    for _ in range(8):
        await RisingEdge(dut.clk_core)
    await Timer(1, unit="ns")
    assert int(dut.playback_ready.value) == 0, "playback_ready high during reset"

    dut.rst_n.value = 1
    got = False
    for _ in range(40000):
        await RisingEdge(dut.clk_core)
        await Timer(1, unit="ns")
        if int(dut.playback_ready.value):
            got = True
            break
    assert got, "playback_ready never asserted after the first real write"

    dut.rst_n.value = 0
    for _ in range(8):
        await RisingEdge(dut.clk_core)
    await Timer(1, unit="ns")
    assert int(dut.playback_ready.value) == 0, "playback_ready not cleared by reset"

    dut.rst_n.value = 1
    got = False
    for _ in range(40000):
        await RisingEdge(dut.clk_core)
        await Timer(1, unit="ns")
        if int(dut.playback_ready.value):
            got = True
            break
    assert got, "playback_ready never re-asserted after reset"
    dut._log.info("demo_playback_ready: reset low, first-write high, reset low, "
                  "re-high; producer-started only, not an acoustic claim")


# ---------------------------------------------------------------------------
# runner
# ---------------------------------------------------------------------------
def _sources():
    A = os.path.join(_ROOT, "rtl", "audio")
    return [os.path.join(A, "audio_async_fifo.sv"),
            os.path.join(A, "pt8211_tx.sv"),
            os.path.join(A, "i2s_amp_tx.sv"),
            os.path.join(A, "i2s_mic_rx.sv"),
            os.path.join(A, "audio_transport.sv"),
            os.path.join(A, "song_player.sv"),
            os.path.join(A, "audio_demo_core.sv"),
            os.path.join(_HERE, "audio_helpers", "mock_modal_engine.sv")]


def _sources_real():
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
            os.path.join(C, "modal_engine.sv")]


def _run(build_dir, tests, params, extra_env=None, sources=None, test_dir=None):
    from cocotb_tools.runner import get_runner
    build_dir = os.path.abspath(os.path.expanduser(build_dir))
    os.makedirs(build_dir, exist_ok=True)
    runner = get_runner("icarus")
    runner.build(sources=sources or _sources(), hdl_toplevel="audio_demo_core",
                 parameters=params, build_dir=build_dir, waves=False,
                 build_args=["-g2012", "-Wall"], always=True,
                 timescale=("1ns", "1ps"))
    total = 0
    for tc in tests:
        xml = os.path.join(build_dir, f"results_{tc}.xml")
        if os.path.exists(xml):
            os.remove(xml)
        runner.test(test_module="test_audio_demo", hdl_toplevel="audio_demo_core",
                    test_dir=test_dir or _HERE, build_dir=build_dir,
                    parameters=params, extra_env=extra_env or {}, testcase=tc,
                    results_xml=xml, timescale=("1ns", "1ps"))
        r = AT._parse_results(xml)
        if r is None:
            raise RuntimeError(f"{tc}: missing or unparseable XML {xml}")
        if r["n"] == 0:
            raise RuntimeError(f"{tc}: no tests ran; XML {xml}")
        if r["failures"]:
            raise RuntimeError(f"{tc}: failed {r['failures']}; XML {xml}")
        print(f"[audio_demo_core] {tc}: {r['n']} passed")
        total += r["n"]
    return total


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--build-dir", default=os.path.join(_HERE, "build", "audio_demo"))
    args = ap.parse_args(argv)
    try:
        total = _run(os.path.join(args.build_dir, "song"),
                     ["demo_song_i2s", "demo_playback_ready"],
                     {"NUM_VOICES": 8, "N_MODES": 48, "NOTE_GAP": NOTE_GAP,
                      "MODE_SONG": 1, "OUT_FORMAT": 1},
                     extra_env={"DEMO_NOTE_GAP": str(NOTE_GAP)})
        total += _run(os.path.join(args.build_dir, "mic"),
                      ["demo_mic_i2s"],
                      {"NUM_VOICES": 8, "N_MODES": 48, "NOTE_GAP": NOTE_GAP,
                       "MODE_SONG": 0, "OUT_FORMAT": 1},
                      extra_env={"DEMO_NOTE_GAP": str(NOTE_GAP)})
        # real 2B/2C engine, if present
        if os.path.exists(os.path.join(_ROOT, "rtl", "core", "modal_engine.sv")):
            total += _run(os.path.join(args.build_dir, "song_real"),
                          ["demo_song_real_engine"],
                          {"NUM_VOICES": 8, "N_MODES": 48, "NOTE_GAP": 512,
                           "MODE_SONG": 1, "OUT_FORMAT": 1},
                          extra_env={"DEMO_NOTE_GAP": "512",
                                     "PYTHONPATH": _HERE},
                          sources=_sources_real(), test_dir=_ROOT)
    except RuntimeError as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        return 1
    print(f"[audio_demo] {total} tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
