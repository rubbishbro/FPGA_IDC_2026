"""cocotb board-level test for rtl/platform/tang_mega_138k_pro/ top + clock_reset.

This test drives ONLY the real board top ports (``clk`` 50 MHz crystal, ``reset``
button) and observes the four amplifier pins.  The two Gowin PLL modules are
replaced by the test-only ``sim/audio_helpers/board_pll_model.v`` and the board
audio wrapper by the test-only ``board_audio_core_model.sv`` (both NOT in
sources.f, not synthesisable); the internal song producer is the test-only mock
engine.  A pass proves:

  * board wiring and reset/lock/SD sequencing,
  * that amp_sd is gated on the real TX FIFO handshake (playback_ready), not on a
    frame count: a stuck song keeps the amplifier shut down,
  * that a loss of PLL lock (without a button reset) drops SD immediately,
  * that the 100 MHz core and 12.288 MHz audio clocks come from the PLL wrapper
    (2x drive and 25/100 = 12.5/50 ratio),
  * BCLK = audio/4, LRC = BCLK/64, and a complete pin-to-pin I2S path,
  * automatic 32-voice song playback after reset.

It does NOT prove the real PLL locks, the exact physical frequency, jitter,
timing, pin electricals, or that any bitstream exists.

The melody is parsed from rtl/audio/song_player.sv so the bit-exact reference
stays in sync with the audio session.  Artefacts go under
sim/build/audio_board (never sim/results.xml).
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = _HERE
while not (os.path.isdir(os.path.join(_ROOT, "rtl"))
           and os.path.isdir(os.path.join(_ROOT, "sim"))):
    _ROOT = os.path.dirname(_ROOT)
sys.path.insert(0, os.path.join(_ROOT, "sim", "support"))
from _sim_paths import bootstrap as _sim_bootstrap  # noqa: E402
_ROOT = str(_sim_bootstrap(__file__))
sys.path.insert(0, _HERE)

import test_audio_transport as AT  # noqa: E402  (reuse I2S decoder + helpers)

NUM_VOICES = int(os.environ.get("BOARD_NUM_VOICES", "32"))
NOTE_GAP = int(os.environ.get("BOARD_NOTE_GAP", "16"))
N_EVENTS = int(os.environ.get("BOARD_N_EVENTS", "85"))
AUDIO_NUM, AUDIO_DEN = 25, 100
PULSE = [0, 40427475, 131267186, 204114978, 204114978, 131267186, 40427475]

_TOLERATED = "constant selects in always_"


def _read_song():
    path = os.path.join(_ROOT, "rtl", "audio", "song_player.sv")
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    seq = [int(m.group(1)) for m in re.finditer(
        r"6'd\d+\s*:\s*event_at\s*=\s*\{\s*1'b1\s*,\s*7'd(\d+)", text)]
    m = re.search(r"localparam\s+int\s+NUM_EVENTS\s*=\s*(\d+)", text)
    assert seq, f"could not parse any song event from {path}"
    if m:
        assert int(m.group(1)) == len(seq), \
            f"song_player NUM_EVENTS={m.group(1)} but parsed {len(seq)} events"
    return seq


SONG = _read_song()


def _s(v, w):
    return AT._s(v, w)


def _sum_to_i16(s):
    t = s >> 3
    t = (t + 16384) >> 15
    return max(-32768, min(32767, t))


def _song_expected(nsamp, song, num_voices, note_gap):
    seq = []
    active = [False] * num_voices
    pos = [7] * num_voices
    ev, samp = 0, 0
    for _ in range(nsamp):
        if samp == 0:
            v = ev % num_voices
            active[v] = True
            pos[v] = 0
            ev = (ev + 1) % len(song)
        mix = 0
        for v in range(num_voices):
            if active[v] and pos[v] < 7:
                mix += PULSE[pos[v]]
        seq.append(_sum_to_i16(mix))
        for v in range(num_voices):
            if pos[v] < 7:
                pos[v] += 1
        samp = 0 if samp == note_gap - 1 else samp + 1
    return seq


def _find_block(frames, want, where=""):
    n = len(want)
    for i in range(0, len(frames) - n + 1):
        if frames[i:i + n] == want:
            return i
    raise AssertionError(f"{where}: block of {n} frames not found "
                         f"({len(frames)} decoded)")


async def _start(dut):
    dut.reset.value = 1
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    for _ in range(8):
        await RisingEdge(dut.clk)
    await Timer(1, unit="ns")


async def _release_and_wait_play(dut, max_clk=8_000_000):
    """Release reset, require SD low before lock, then wait for SD high."""
    assert int(dut.u_clock_reset.locked.value) == 0, "locked before release"
    assert int(dut.amp_sd.value) == 0, "SD high during reset"
    dut.reset.value = 0

    saw_lock = False
    guard = 0
    while not saw_lock:
        await RisingEdge(dut.clk)
        guard += 1
        assert int(dut.amp_sd.value) == 0, "SD high before lock"
        saw_lock = int(dut.u_clock_reset.locked.value) == 1
        assert guard < max_clk, "PLL lock never arrived"

    guard = 0
    while not int(dut.amp_sd.value):
        await RisingEdge(dut.clk)
        guard += 1
        # SD may only rise once a real sample was handed to the TX FIFO
        if int(dut.playback_ready.value) == 0:
            assert int(dut.amp_sd.value) == 0, "SD high without playback_ready"
        assert guard < max_clk, "SD never went high after lock"
    await Timer(1, unit="ns")


# ---------------------------------------------------------------------------
# T01 -- reset / lock / SD sequencing and immediate shutdown
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=240, timeout_unit="sec")
async def board_t01_lock_sd(dut):
    await _start(dut)
    await _release_and_wait_play(dut)
    assert int(dut.amp_sd.value) == 1, "SD not high while playing"
    assert int(dut.playback_ready.value) == 1, "playback_ready not sticky"

    # button press must drop SD immediately (combinational shutdown).  The
    # vendor PLL has no reset port, so the button does not clear `locked`; it
    # forces rst_n low and SD low directly.
    dut.reset.value = 1
    await Timer(1, unit="ns")
    assert int(dut.amp_sd.value) == 0, "SD did not drop immediately on reset"
    assert int(dut.u_clock_reset.rst_n.value) == 0, "rst_n not forced low on reset"

    dut._log.info("T01 lock gating: SD low before lock, gated on "
                  "playback_ready, immediately low on reset")


# ---------------------------------------------------------------------------
# T02 -- automatic 32-voice song after release, full pin-to-pin I2S
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=600, timeout_unit="sec")
async def board_t02_autoplay(dut):
    await _start(dut)
    await _release_and_wait_play(dut)

    nsamp = N_EVENTS * NOTE_GAP
    frames, slots = [], []
    stop = {"done": False}
    dec = cocotb.start_soon(AT.i2s_decode(dut, frames, slots, stop,
                                          "amp_bclk", "amp_lrc", "amp_din"))

    want_frames = nsamp + 40
    guard = 0
    while len(frames) < want_frames and guard < 200_000_000:
        await RisingEdge(dut.clk)
        guard += 1
    stop["done"] = True
    await dec

    assert len(frames) >= nsamp + 4, f"only {len(frames)} I2S frames decoded"
    frames16 = [(_s(l, 16), _s(r, 16)) for (l, r) in frames]
    assert all(l == r for (l, r) in frames16), "I2S channels are not mono-duplicated"

    exp = _song_expected(nsamp, SONG, NUM_VOICES, NOTE_GAP)
    start = _find_block(frames16, [(y, y) for y in exp[1:]], "board_t02")
    dut._log.info(f"T02 V{NUM_VOICES} automatic song: {len(exp)-1} mono samples "
                  f"over {N_EVENTS} events matched through the board pins "
                  f"(first block at frame {start})")


# ---------------------------------------------------------------------------
# T03 -- clock ratios derived from the PLL wrapper, BCLK/LRC ratios
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=180, timeout_unit="sec")
async def board_t03_clock_ratios(dut):
    await _start(dut)
    await _release_and_wait_play(dut)

    N = 20000
    counts = {"core": 0, "audio": 0, "bclk": 0, "lrc": 0}
    stop = {"done": False}

    async def count(sig, key):
        while not stop["done"]:
            await RisingEdge(sig)
            counts[key] += 1

    sigs = {
        "core": dut.u_clock_reset.clk_core,
        "audio": dut.u_clock_reset.clk_audio,
        "bclk": dut.amp_bclk,
        "lrc": dut.amp_lrc,
    }
    ctrs = [cocotb.start_soon(count(sig, key)) for key, sig in sigs.items()]

    for _ in range(N):
        await RisingEdge(dut.clk)
    stop["done"] = True
    for c in ctrs:
        await c

    core, audio = counts["core"], counts["audio"]
    bclk, lrc = counts["bclk"], counts["lrc"]

    assert abs(core - 2 * N) <= 0.02 * 2 * N, \
        f"core rising edges {core} != {2 * N}"
    exp_audio = N * AUDIO_NUM / AUDIO_DEN
    assert abs(audio - exp_audio) <= 0.02 * exp_audio, \
        f"audio rising edges {audio} vs expected {exp_audio}"
    assert abs(bclk - audio / 4.0) <= 3, \
        f"BCLK/audio edge count {bclk}:{audio} != 1:4"
    assert abs(lrc - bclk / 64.0) <= 2, \
        f"LRC/BCLK edge count {lrc}:{bclk} != 1:64"
    dut._log.info(f"T03 ratios over {N} drive cycles: core={core} (2x), "
                  f"audio={audio} (~{exp_audio:.0f}), bclk={bclk}, lrc={lrc}")


# ---------------------------------------------------------------------------
# T04 -- button reset kills output and playback restarts from event 0
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=300, timeout_unit="sec")
async def board_t04_reset_restart(dut):
    await _start(dut)
    await _release_and_wait_play(dut)

    for _ in range(400_000):
        await RisingEdge(dut.clk)

    dut.reset.value = 1
    for _ in range(200):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        assert int(dut.amp_sd.value) == 0, "SD not low during reset"
    assert int(dut.u_clock_reset.rst_n.value) == 0, "rst_n not low during reset"

    dut.reset.value = 0
    frames, slots = [], []
    stop = {"done": False}
    dec = cocotb.start_soon(AT.i2s_decode(dut, frames, slots, stop,
                                          "amp_bclk", "amp_lrc", "amp_din"))
    want = 3 * NOTE_GAP + 60
    guard = 0
    while len(frames) < want and guard < 100_000_000:
        await RisingEdge(dut.clk)
        guard += 1
    stop["done"] = True
    await dec

    frames16 = [(_s(l, 16), _s(r, 16)) for (l, r) in frames]
    exp = _song_expected(3 * NOTE_GAP + 8, SONG, NUM_VOICES, NOTE_GAP)
    start = _find_block(frames16, [(y, y) for y in exp[1:]], "board_t04")
    assert start < 300, f"restart block at frame {start}, expected near 0"
    dut._log.info(f"T04 reset killed the output; playback restarted at event 0 "
                  f"(block at frame {start})")


# ---------------------------------------------------------------------------
# T05 -- loss of lock (no button reset) drops SD immediately
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=240, timeout_unit="sec")
async def board_t05_loss_of_lock(dut):
    await _start(dut)
    await _release_and_wait_play(dut)
    assert int(dut.amp_sd.value) == 1, "not playing before lock fault"

    # test-only fault injection: hold the audio PLL's lock low for a while by
    # clearing its lock register and its lock counter.  This is a simulated
    # lock loss, not a physical PLL test.
    await RisingEdge(dut.clk)
    dut.u_clock_reset.u_pll_audio.lock.value = 0
    dut.u_clock_reset.u_pll_audio.cnt.value = 0
    await Timer(1, unit="ns")
    assert int(dut.u_clock_reset.locked.value) == 0, "locked did not drop"
    assert int(dut.u_clock_reset.rst_n.value) == 0, "rst_n not asserted on unlock"
    assert int(dut.amp_sd.value) == 0, "SD did not drop immediately on unlock"

    # it must stay low for the whole fault window
    for _ in range(4):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        assert int(dut.amp_sd.value) == 0, "SD rose while lock was lost"

    # after the model relocks, SD may return only once a new sample is handed on
    guard = 0
    while int(dut.amp_sd.value) == 0 and guard < 8_000_000:
        await RisingEdge(dut.clk)
        guard += 1
        if int(dut.playback_ready.value) == 0:
            assert int(dut.amp_sd.value) == 0, "SD high without playback_ready"
    assert int(dut.amp_sd.value) == 1, "SD never recovered after relock"
    dut._log.info("T05 lock loss (no button reset): SD/rst_n low immediately, "
                  "recovered only after relock + new playback_ready")


# ---------------------------------------------------------------------------
# T06 -- stuck song: playback_ready never rises -> SD stays low (stuck build)
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=180, timeout_unit="sec")
async def board_t06_stuck_no_sd(dut):
    await _start(dut)
    dut.reset.value = 0
    guard = 0
    while int(dut.u_clock_reset.locked.value) == 0 and guard < 8_000_000:
        await RisingEdge(dut.clk)
        guard += 1
    assert int(dut.u_clock_reset.locked.value) == 1, "never locked"

    # no real sample ever reaches the FIFO in the stuck build
    for _ in range(120_000):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        assert int(dut.playback_ready.value) == 0, "playback_ready rose (stuck build)"
        assert int(dut.amp_sd.value) == 0, "SD rose on a stuck song"
    dut._log.info("T06 stuck song: playback_ready stays low, amplifier stays off")


# ---------------------------------------------------------------------------
# runner
# ---------------------------------------------------------------------------
def _audio_has_playback_ready():
    """True once the audio session exposes the public playback_ready output."""
    path = os.path.join(_ROOT, "rtl", "audio", "audio_demo_core.sv")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return re.search(r"\bplayback_ready\b", fh.read()) is not None
    except OSError:
        return False


def _sources(stuck=False):
    A = os.path.join(_ROOT, "rtl", "audio")
    P = os.path.join(_ROOT, "rtl", "platform", "tang_mega_138k_pro")
    H = os.path.join(_ROOT, "sim", "audio_helpers")
    # Prefer the real wrapper once audio_demo_core exposes playback_ready; the
    # test model (with -DBOARD_AUDIO_STUCK) is still used for the stuck build.
    if stuck or not _audio_has_playback_ready():
        wrapper = os.path.join(H, "board_audio_core_model.sv")
    else:
        wrapper = os.path.join(P, "board_audio_core.sv")
    return [
        os.path.join(A, "audio_async_fifo.sv"),
        os.path.join(A, "pt8211_tx.sv"),
        os.path.join(A, "i2s_amp_tx.sv"),
        os.path.join(A, "i2s_mic_rx.sv"),
        os.path.join(A, "audio_transport.sv"),
        os.path.join(A, "song_player.sv"),
        os.path.join(A, "audio_demo_core.sv"),
        os.path.join(H, "mock_modal_engine.sv"),
        os.path.join(P, "clock_reset.sv"),
        os.path.join(P, "top.sv"),
        wrapper,
        os.path.join(H, "board_pll_model.sv"),      # TEST ONLY, not in sources.f
    ]


def _wall(srcs, params, defines, build_dir):
    out = os.path.join(build_dir, "wallcheck.vvp")
    cmd = ["iverilog", "-g2012", "-Wall", "-o", out, "-s", "top"] + list(defines)
    for k, v in params.items():
        cmd.append(f"-Ptop.{k}={v}")
    cmd += [str(s) for s in srcs]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"iverilog -Wall build failed:\n{proc.stderr}{proc.stdout}")
    bad = []
    for line in (proc.stderr + "\n" + proc.stdout).splitlines():
        s = line.strip()
        if not s:
            continue
        low = s.lower()
        if "warning" not in low and "sorry" not in low and "error" not in low:
            continue
        if _TOLERATED in s:
            continue
        bad.append(s)
    if bad:
        raise RuntimeError("iverilog -Wall diagnostics not tolerated:\n"
                           + "\n".join(bad))


def _parse_results(xml_path):
    if not os.path.exists(xml_path):
        return None
    try:
        root = ET.parse(xml_path).getroot()
    except ET.ParseError:
        return None
    suites = [root] if root.tag == "testsuite" else root.findall("testsuite")
    cases = []
    for s in suites:
        cases.extend(s.findall("testcase"))
    failures = [c.get("name", "?") for c in cases
                if c.find("failure") is not None or c.find("error") is not None]
    return {"n": len(cases), "failures": failures}


def _run(build_dir, params, testcases, extra_env=None, defines=(), stuck=False):
    from cocotb_tools.runner import get_runner
    build_dir = os.path.abspath(os.path.expanduser(build_dir))
    os.makedirs(build_dir, exist_ok=True)
    srcs = _sources(stuck)
    _wall(srcs, params, defines, build_dir)
    runner = get_runner("icarus")
    runner.build(sources=srcs, hdl_toplevel="top", parameters=params,
                 build_dir=build_dir, waves=False,
                 build_args=["-g2012", "-Wall"] + list(defines), always=True,
                 timescale=("1ns", "1ps"))
    total = 0
    for tc in testcases:
        xml = os.path.join(build_dir, f"results_{tc}.xml")
        if os.path.exists(xml):
            os.remove(xml)
        runner.test(test_module="test_audio_board", hdl_toplevel="top",
                    test_dir=_HERE, build_dir=build_dir, parameters=params,
                    extra_env=extra_env or {}, testcase=tc, results_xml=xml,
                    timescale=("1ns", "1ps"))
        r = _parse_results(xml)
        if r is None:
            raise RuntimeError(f"{tc}: missing or unparseable XML {xml}")
        if r["n"] == 0:
            raise RuntimeError(f"{tc}: no tests ran; XML {xml}")
        if r["failures"]:
            raise RuntimeError(f"{tc}: failed {r['failures']}; XML {xml}")
        print(f"[audio_board] {tc}: {r['n']} passed")
        total += r["n"]
    return total


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--build-dir", default=os.path.join(_ROOT, "sim", "build", "audio_board"))
    args = ap.parse_args(argv)
    base = os.path.abspath(os.path.expanduser(args.build_dir))
    params = {"NUM_VOICES": NUM_VOICES, "N_MODES": 48, "NOTE_GAP": NOTE_GAP}
    env = {"BOARD_NUM_VOICES": str(NUM_VOICES),
           "BOARD_NOTE_GAP": str(NOTE_GAP), "BOARD_N_EVENTS": str(N_EVENTS)}
    try:
        total = _run(os.path.join(base, "normal"), params,
                     ["board_t01_lock_sd", "board_t02_autoplay",
                      "board_t03_clock_ratios", "board_t04_reset_restart",
                      "board_t05_loss_of_lock"], env)
        # stuck-song variant: playback_ready never rises
        total += _run(os.path.join(base, "stuck"), params,
                      ["board_t06_stuck_no_sd"], env,
                      defines=["-DBOARD_AUDIO_STUCK"], stuck=True)
    except RuntimeError as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        return 1
    print(f"[audio_board] {total} tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
