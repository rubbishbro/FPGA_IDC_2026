"""cocotb tests for the audio bring-up units (module: audio).

Covers, in one file because the task owns exactly this test script:

  * rtl/audio/audio_async_fifo.sv  -- two independent clocks, random
    backpressure, full/empty, wrap (>= 4x depth), reset, byte-for-byte order;
  * rtl/audio/pt8211_tx.sv         -- independent BCK-edge protocol decoder:
    WS-low=right / WS-high=left, 16-bit MSB-first per slot, no I2S one-bit
    delay, BCLK/LRCLK ratios, underflow -> whole zero frame;
  * rtl/audio/i2s_mic_rx.sv        -- independent standard-I2S source, 24-bit
    payload after the one-BCK delay, padding ignored, channel select, high-Z
    detectable;
  * rtl/audio/audio_transport.sv   -- cross-domain TX/RX through the two async
    FIFOs, backpressure, sticky overflow/underflow, 48 kHz frame tick.

Every top is built with an explicit absolute build directory, ``-g2012 -Wall``,
``always=True`` and an explicit results XML gate (missing / empty / failed XML is
a non-zero exit).  Clock periods are scaled down to keep simulation short; the
serial *divider ratios* (not the absolute MHz) are what is verified.  All results
here are RTL simulation only.
"""

from __future__ import annotations

import argparse
import os
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer
from cocotb.utils import get_sim_time

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = _HERE
while not (os.path.isdir(os.path.join(_ROOT, "rtl"))
           and os.path.isdir(os.path.join(_ROOT, "sim"))):
    _ROOT = os.path.dirname(_ROOT)
sys.path.insert(0, os.path.join(_ROOT, "sim", "support"))
from _sim_paths import bootstrap as _sim_bootstrap  # noqa: E402
_ROOT = str(_sim_bootstrap(__file__))

AUDIO = os.path.join(_ROOT, "rtl", "audio")

MIC_CH_SEL = int(os.environ.get("MIC_CH_SEL", "0"))


# ---------------------------------------------------------------------------
# generic helpers
# ---------------------------------------------------------------------------
def _u(v, w):
    return int(v) & ((1 << w) - 1)


def _s(v, w):
    v = int(v) & ((1 << w) - 1)
    return v - (1 << w) if (v >> (w - 1)) else v


async def _clocks(dut, specs):
    for name, period in specs:
        cocotb.start_soon(Clock(getattr(dut, name), period, unit="ns").start())


async def _reset(dut, clknames, rst="rst_n", cycles=6):
    getattr(dut, rst).value = 0
    for nm in clknames:
        for _ in range(cycles):
            await RisingEdge(getattr(dut, nm))
    getattr(dut, rst).value = 1
    for _ in range(cycles):
        await RisingEdge(getattr(dut, clknames[0]))
    await Timer(1, unit="ns")


# ---------------------------------------------------------------------------
# independent PT8211 (DAC) protocol decoder
# ---------------------------------------------------------------------------
async def pt8211_decode(dut, frames, stop, bck="dac_bck", ws="dac_ws", din="dac_din"):
    """Sample ADC-style at every rising BCK edge and rebuild the two 16-bit slots.

    WS low = right, high = left; the MSB of a slot is the first bit after the WS
    change (no I2S delay).  Each entry appended is (left, right) as raw 16-bit.
    """
    bitpos, right, left = 0, 0, 0
    prev_ws = 1
    while not stop["done"]:
        await RisingEdge(getattr(dut, bck))
        await Timer(1, unit="ns")
        wsv = getattr(dut, ws).value
        dinv = getattr(dut, din).value
        assert wsv.is_resolvable and dinv.is_resolvable, "X/Z on DAC lines"
        w = int(wsv)
        d = int(dinv)
        if w == 0 and prev_ws == 1:
            bitpos = 0
        if bitpos < 16:
            right = ((right << 1) | d) & 0xFFFF
        else:
            left = ((left << 1) | d) & 0xFFFF
        bitpos += 1
        if bitpos == 32:
            frames.append((left, right))
            bitpos = 0
        prev_ws = w


async def i2s_decode(dut, frames, slots, stop,
                     bck="amp_bclk", ws="amp_ws", din="amp_din"):
    """Decode standard I2S: WS change, one-BCK delay, then 16-bit MSB-first.

    Appends (left, right) raw 16-bit per frame and the raw 32-bit slot words to
    ``slots`` (so padding can be checked separately).
    """
    bitpos, scnt = 0, 0
    raw = 0
    left, right = 0, 0
    prev_ws = 1
    while not stop["done"]:
        await RisingEdge(getattr(dut, bck))
        await Timer(1, unit="ns")
        wsv = getattr(dut, ws).value
        dinv = getattr(dut, din).value
        assert wsv.is_resolvable and dinv.is_resolvable, "X/Z on I2S lines"
        w = int(wsv)
        d = int(dinv)
        if w != prev_ws:
            bitpos, scnt, raw = 0, 0, 0
        raw = ((raw << 1) | d) & 0xFFFFFFFF
        scnt += 1
        if 1 <= bitpos <= 16:
            if w == 0:
                left = ((left << 1) | d) & 0xFFFF
            else:
                right = ((right << 1) | d) & 0xFFFF
        bitpos += 1
        if scnt == 32:
            slots.append(raw)
            if w == 1:                      # right slot completed -> whole frame
                frames.append((left, right))
        prev_ws = w


def _check_frames(frames, want, where=""):
    """Find `want` as a contiguous block; everything after it must be zero.

    Leading frames may be underflow zeros or one decoder-startup misaligned
    frame, so the block is searched for rather than assumed to start at the
    first non-zero frame.
    """
    assert want and want[0] != (0, 0), f"{where}: block must start non-zero"
    n = len(want)
    start = None
    for i in range(0, len(frames) - n + 1):
        if frames[i:i + n] == want:
            start = i
            break
    assert start is not None, \
        f"{where}: block of {n} frames not found ({len(frames)} decoded)"
    tail = frames[start + n:]
    assert all(f == (0, 0) for f in tail), \
        f"{where}: unexpected non-zero frame after the block"
    return start


def _find_block(frames, want, where=""):
    n = len(want)
    for i in range(0, len(frames) - n + 1):
        if frames[i:i + n] == want:
            return i
    raise AssertionError(f"{where}: block of {n} not found ({len(frames)} frames)")


# ---------------------------------------------------------------------------
# independent standard-I2S microphone source (drives SD on BCK falling edges)
# ---------------------------------------------------------------------------
async def i2s_source(dut, state, bck="mic_bck", sdin="sd", ws="mic_ws"):
    """Independent standard-I2S microphone source.

    SD is launched on the BCK falling edge and aligned to the *WS* transitions
    (not a free-running counter), so it stays aligned no matter when it starts.
    A 24-bit signed payload is sent MSB-first after the one-bit delay, with zero
    padding.  state['value'](frame) returns (left, right); state['z'] drives a
    high-impedance SD for the whole frame.
    """
    prev_ws = None
    k = 0
    frame = -1
    aligned = False
    while not state["done"]:
        await FallingEdge(getattr(dut, bck))
        await Timer(1, unit="ns")
        wv = getattr(dut, ws).value
        if not wv.is_resolvable:
            prev_ws = None
            continue
        w = int(wv)
        if prev_ws is None:
            prev_ws = w
            k = 0
        elif w != prev_ws:
            k = 0
            if w == 0:                      # 1 -> 0 : a new frame begins
                frame = 0 if not aligned else frame + 1
                aligned = True
        else:
            k += 1
        prev_ws = w
        f = max(frame, 0)
        state["frame"] = f
        left, right = state["value"](f)
        if state.get("z"):
            getattr(dut, sdin).value = _Z
        elif not aligned:
            getattr(dut, sdin).value = 0
        elif 1 <= k <= 24:
            getattr(dut, sdin).value = ((left if w == 0 else right)
                                        >> (24 - k)) & 1
        else:
            getattr(dut, sdin).value = 0


try:
    from cocotb.types import Logic as _Logic
    _Z = _Logic("Z")
except Exception:                                   # pragma: no cover
    _Z = "Z"


# ===========================================================================
# FIFO
# ===========================================================================
async def _fifo_write(dut, seq, rng, idle_max=3):
    for v in seq:
        dut.wvalid.value = 1
        dut.wdata.value = v
        await Timer(1, unit="ns")
        guard = 0
        while not int(dut.wready.value):
            await RisingEdge(dut.wclk)
            await Timer(1, unit="ns")
            guard += 1
            assert guard < 200000, "wready stuck low"
        await RisingEdge(dut.wclk)          # commit
        dut.wvalid.value = 0
        for _ in range(rng.randint(0, idle_max)):
            await RisingEdge(dut.wclk)


async def _fifo_read(dut, n, rng, idle_max=3):
    out = []
    while len(out) < n:
        dut.rready.value = 1
        await Timer(1, unit="ns")
        guard = 0
        while not int(dut.rvalid.value):
            await RisingEdge(dut.rclk)
            await Timer(1, unit="ns")
            guard += 1
            assert guard < 200000, "rvalid stuck low"
        assert dut.rdata.value.is_resolvable, "X on rdata when rvalid"
        out.append(int(dut.rdata.value))
        await RisingEdge(dut.rclk)          # commit
        dut.rready.value = 0
        for _ in range(rng.randint(0, idle_max)):
            await RisingEdge(dut.rclk)
    return out


@cocotb.test(timeout_time=120, timeout_unit="sec")
async def fifo_t01_sequence(dut):
    await _clocks(dut, (("wclk", 10), ("rclk", 14)))
    dut.wvalid.value = 0
    dut.wdata.value = 0
    dut.rready.value = 0
    await _reset(dut, ("wclk", "rclk"))

    depth = 8
    n = 40 * depth                                  # >= 40 wraps
    rng = random.Random(0xC0FFEE)
    seq = [rng.randrange(0, 1 << 16) for _ in range(n)]

    done = {"done": False}
    got = []

    async def rd():
        got.extend(await _fifo_read(dut, n, random.Random(7)))
        done["done"] = True

    rdr = cocotb.start_soon(rd())
    await _fifo_write(dut, seq, rng)
    await rdr
    assert got == seq, "read sequence differs from write sequence"
    # full/empty sanity after drain
    for _ in range(6):
        await RisingEdge(dut.rclk)
    assert int(dut.rempty.value) == 1, "FIFO not empty after draining"
    dut._log.info(f"fifo_t01 {n} words across two clocks, order preserved")


@cocotb.test(timeout_time=120, timeout_unit="sec")
async def fifo_t02_full_empty(dut):
    await _clocks(dut, (("wclk", 10), ("rclk", 14)))
    dut.wvalid.value = 0
    dut.wdata.value = 0
    dut.rready.value = 0
    await _reset(dut, ("wclk", "rclk"))

    depth = 8
    seq = [0x1000 + i for i in range(depth)]
    for v in seq:
        dut.wvalid.value = 1
        dut.wdata.value = v
        await Timer(1, unit="ns")
        while not int(dut.wready.value):
            await RisingEdge(dut.wclk)
            await Timer(1, unit="ns")
        await RisingEdge(dut.wclk)
        dut.wvalid.value = 0
    await RisingEdge(dut.wclk)
    await Timer(1, unit="ns")
    assert int(dut.wfull.value) == 1, "FIFO did not report full"

    # a write attempt while full must not commit or overwrite
    dut.wvalid.value = 1
    dut.wdata.value = 0xDEAD
    for _ in range(4):
        await RisingEdge(dut.wclk)
        await Timer(1, unit="ns")
        assert int(dut.wready.value) == 0, "wready high while full"
    dut.wvalid.value = 0

    got = await _fifo_read(dut, depth, random.Random(3))
    assert got == seq, f"full read {got} != {seq}"
    for _ in range(6):
        await RisingEdge(dut.rclk)
    assert int(dut.rempty.value) == 1
    dut.wvalid.value = 0
    dut.rready.value = 0
    dut._log.info("fifo_t02 full does not overwrite, empty after drain")


@cocotb.test(timeout_time=120, timeout_unit="sec")
async def fifo_t04_reset_handshake(dut):
    """During reset no write must look accepted; pointers must not advance."""
    await _clocks(dut, (("wclk", 10), ("rclk", 14)))
    dut.wvalid.value = 1
    dut.wdata.value = 0xBEEF
    dut.rready.value = 1
    dut.rst_n.value = 0
    for nm in ("wclk", "rclk"):
        for _ in range(6):
            await RisingEdge(getattr(dut, nm))
            await Timer(1, unit="ns")
            assert int(dut.wready.value) == 0, "wready high during reset"
            assert int(dut.rvalid.value) == 0, "rvalid high during reset"
    dut.wvalid.value = 0
    dut.rready.value = 0
    dut.rst_n.value = 1
    for _ in range(6):
        await RisingEdge(dut.wclk)
    await Timer(1, unit="ns")
    assert int(dut.wready.value) == 1, "wready low after release"
    assert int(dut.rempty.value) == 1, "pointer advanced during reset"

    # fresh traffic works, and the reset-time write was not committed
    await _fifo_write(dut, [0x1234], random.Random(1))
    got = await _fifo_read(dut, 1, random.Random(1))
    assert got == [0x1234], f"got {got}, reset-time write leaked"
    dut._log.info("fifo_t04 reset does not advertise or commit a write")


@cocotb.test(timeout_time=120, timeout_unit="sec")
async def fifo_t03_reset(dut):
    await _clocks(dut, (("wclk", 10), ("rclk", 14)))
    dut.wvalid.value = 0
    dut.wdata.value = 0
    dut.rready.value = 0
    await _reset(dut, ("wclk", "rclk"))

    rng = random.Random(11)
    seq = [rng.randrange(0, 1 << 16) for _ in range(5)]
    await _fifo_write(dut, seq, rng, idle_max=1)

    # asynchronous reset mid-traffic
    dut.rst_n.value = 0
    for _ in range(4):
        await RisingEdge(dut.wclk)
        await RisingEdge(dut.rclk)
    dut.rst_n.value = 1
    for _ in range(6):
        await RisingEdge(dut.wclk)
        await RisingEdge(dut.rclk)
    assert int(dut.rempty.value) == 1, "not empty after reset"
    assert int(dut.wfull.value) == 0, "full after reset"

    # fresh traffic works and is ordered
    seq2 = [0x5000 + i for i in range(20)]
    done = {"done": False}
    got = []

    async def rd():
        got.extend(await _fifo_read(dut, 20, random.Random(9)))
        done["done"] = True

    rdr = cocotb.start_soon(rd())
    await _fifo_write(dut, seq2, random.Random(13), idle_max=1)
    await rdr
    assert got == seq2, "post-reset sequence mismatch"
    dut._log.info("fifo_t03 reset mid-traffic clears both domains")


# ===========================================================================
# PT8211 TX
# ===========================================================================
async def _pt_producer(dut, pairs):
    for p in pairs:
        dut.in_valid.value = 1
        dut.in_data.value = p
        await Timer(1, unit="ns")
        while not int(dut.in_ready.value):
            await RisingEdge(dut.clk)
            await Timer(1, unit="ns")
        await RisingEdge(dut.clk)
        dut.in_valid.value = 0
        await Timer(1, unit="ns")


@cocotb.test(timeout_time=120, timeout_unit="sec")
async def pt8211_t01_protocol(dut):
    await _clocks(dut, (("clk", 10),))
    dut.in_valid.value = 0
    dut.in_data.value = 0
    dut.diag_clear.value = 0
    await _reset(dut, ("clk",))

    pairs = [0x1234_ABCD, 0x0000_0000, 0xFFFF_0001, 0x8000_7FFF,
             0x00FF_FF00, 0xAAAA_5555, 0x0001_8000, 0x7FFF_8000,
             0x1111_2222, 0x9999_3333]
    frames = []
    stop = {"done": False}
    dec = cocotb.start_soon(pt8211_decode(dut, frames, stop))

    # measure one BCK period in clk cycles
    edges = 0
    while edges < 1:
        await RisingEdge(dut.dac_bck)
        edges += 1
    t0 = get_sim_time("ns")
    await RisingEdge(dut.dac_bck)
    t1 = get_sim_time("ns")
    bck_period = t1 - t0

    # let the decoder see several WS transitions and align before data arrives
    for _ in range(4 * 256):
        await RisingEdge(dut.clk)
    await _pt_producer(dut, pairs)
    # let a few more frames clock through (underflow from here)
    for _ in range(6 * 256):
        await RisingEdge(dut.clk)
    stop["done"] = True
    await dec

    assert bck_period == 8 * 10, f"BCK period {bck_period}ns != 8 clk"
    want = [(((p >> 16) & 0xFFFF), (p & 0xFFFF)) for p in pairs]
    _check_frames(frames, want, "pt8211_t01")
    assert int(dut.underflow_sticky.value) == 1, "underflow sticky not raised"
    dut._log.info(f"pt8211_t01 {len(pairs)} pairs decoded, bck={bck_period}ns, "
                  f"{len(frames)} frames")


@cocotb.test(timeout_time=120, timeout_unit="sec")
async def pt8211_t02_edges(dut):
    await _clocks(dut, (("clk", 10),))
    dut.in_valid.value = 0
    dut.in_data.value = 0
    dut.diag_clear.value = 0
    await _reset(dut, ("clk",))

    pairs = [0x0000_0001, 0x8000_FFFF, 0xFFFF_0000, 0x0001_7FFF,
             0xFFFE_8000, 0x0000_8000, 0x7FFF_7FFF]
    frames = []
    stop = {"done": False}
    dec = cocotb.start_soon(pt8211_decode(dut, frames, stop))
    # let the decoder see several WS transitions and align before data arrives
    for _ in range(4 * 256):
        await RisingEdge(dut.clk)
    await _pt_producer(dut, pairs)
    for _ in range(8 * 256):
        await RisingEdge(dut.clk)
    stop["done"] = True
    await dec

    want = [((p >> 16) & 0xFFFF, p & 0xFFFF) for p in pairs]
    _check_frames(frames, want, "pt8211_t02")
    zero = [f for f in frames if f == (0, 0)]
    assert zero, "no zero frame on underflow"
    assert int(dut.underflow_sticky.value) == 1
    dut._log.info("pt8211_t02 boundaries + zero-frame underflow OK")


# ===========================================================================
# MAX98357A standard-I2S amplifier TX
# ===========================================================================
@cocotb.test(timeout_time=120, timeout_unit="sec")
async def i2samp_t01_protocol(dut):
    await _clocks(dut, (("clk", 10),))
    dut.in_valid.value = 0
    dut.in_data.value = 0
    dut.diag_clear.value = 0
    await _reset(dut, ("clk",))

    samples = [0x1234, 0x0000, 0x0001, 0x7FFF, 0x8000, 0xFFFF, 0xEDCC,
               0x00FF, 0xFF00, 0x4000, 0xBFFF]
    pairs = [((s << 16) | s) for s in samples]

    frames, slots = [], []
    stop = {"done": False}
    dec = cocotb.start_soon(i2s_decode(dut, frames, slots, stop))

    await RisingEdge(dut.amp_bclk)
    t0 = get_sim_time("ns")
    await RisingEdge(dut.amp_bclk)
    bck_period = get_sim_time("ns") - t0

    # let the decoder see several WS transitions and align before data arrives
    for _ in range(4 * 256):
        await RisingEdge(dut.clk)
    await _pt_producer(dut, pairs)
    for _ in range(12 * 256):
        await RisingEdge(dut.clk)
    stop["done"] = True
    await dec

    assert bck_period == 4 * 10, f"BCLK period {bck_period}ns != 4 clk"
    want = [(s, s) for s in samples]
    _check_frames(frames, want, "i2samp_t01")
    # 16-bit payload occupies raw[30:15]; the ignored first bit and padding are 0
    for raw in slots:
        assert (raw & 0x00007FFF) == 0, f"I2S padding not zero: {raw:#010x}"
        assert ((raw >> 31) & 1) == 0, f"I2S first bit not zero: {raw:#010x}"
    assert int(dut.underflow_sticky.value) == 1, "I2S underflow sticky not raised"
    dut._log.info(f"i2samp_t01 {len(samples)} mono samples duplicated, "
                  f"bclk={bck_period}ns, padding zero")


@cocotb.test(timeout_time=120, timeout_unit="sec")
async def i2samp_t02_underflow(dut):
    await _clocks(dut, (("clk", 10),))
    dut.in_valid.value = 0
    dut.in_data.value = 0
    dut.diag_clear.value = 0
    await _reset(dut, ("clk",))

    samples = [0x1111, 0x2222, 0x3333]
    pairs = [((s << 16) | s) for s in samples]
    frames, slots = [], []
    stop = {"done": False}
    dec = cocotb.start_soon(i2s_decode(dut, frames, slots, stop))
    # let the decoder see several WS transitions and align before data arrives
    for _ in range(4 * 256):
        await RisingEdge(dut.clk)
    await _pt_producer(dut, pairs)
    for _ in range(8 * 256):
        await RisingEdge(dut.clk)
    stop["done"] = True
    await dec

    body = [f for f in frames if f != (0, 0)]
    want = [(s, s) for s in samples]
    _check_frames(frames, want, "i2samp_t02")
    assert any(f == (0, 0) for f in frames), "no zero I2S underflow frame"
    assert int(dut.underflow_sticky.value) == 1
    dut._log.info("i2samp_t02 whole zero frame on underflow OK")


async def _pt_feed(dut, stop, val):
    """Keep in_valid asserted with a fresh pair, one commit per frame."""
    i = 0
    dut.in_valid.value = 0
    while not stop["done"]:
        dut.in_valid.value = 1
        dut.in_data.value = val(i) & 0xFFFFFFFF
        await Timer(1, unit="ns")
        guard = 0
        while not int(dut.in_ready.value):
            await RisingEdge(dut.clk)
            await Timer(1, unit="ns")
            guard += 1
            assert guard < 200000, "in_ready stuck"
        await RisingEdge(dut.clk)               # commit
        i += 1
    dut.in_valid.value = 0


async def _tx_clear_t03(dut, is_i2s):
    """Clear must win on a normal frame and underflow must win over a clear."""
    await _clocks(dut, (("clk", 10),))
    dut.in_valid.value = 0
    dut.in_data.value = 0
    dut.diag_clear.value = 0
    await _reset(dut, ("clk",))

    # two frames of silence -> sticky underflow
    for _ in range(2 * 256):
        await RisingEdge(dut.clk)
    assert int(dut.underflow_sticky.value) == 1, "startup underflow missing"

    # continuous normal frames: a clear now must stick
    stop = {"done": False}
    feed = cocotb.start_soon(
        _pt_feed(dut, stop,
                 lambda i: (((i & 0x7FFF) << 16) | ((i + 1) & 0x7FFF))))
    for _ in range(4 * 256):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.diag_clear.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.diag_clear.value = 0
    await RisingEdge(dut.clk)
    assert int(dut.underflow_sticky.value) == 0, "clear did not clear (normal frame)"
    for _ in range(4 * 256):
        await RisingEdge(dut.clk)
    assert int(dut.underflow_sticky.value) == 0, "underflow reappeared while fed"
    stop["done"] = True
    await feed

    # stop feeding: underflow returns; a clear coinciding with an underflow frame
    # must leave the sticky set (underflow has priority over clear)
    for _ in range(2 * 256):
        await RisingEdge(dut.clk)
    assert int(dut.underflow_sticky.value) == 1
    await FallingEdge(dut.clk)
    dut.diag_clear.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.diag_clear.value = 0
    for _ in range(2 * 256):
        await RisingEdge(dut.clk)
    assert int(dut.underflow_sticky.value) == 1, "underflow must beat clear"
    dut._log.info(f"{'i2s' if is_i2s else 'pt8211'} clear priority OK")


@cocotb.test(timeout_time=120, timeout_unit="sec")
async def pt8211_t03_clear(dut):
    await _tx_clear_t03(dut, is_i2s=False)


@cocotb.test(timeout_time=120, timeout_unit="sec")
async def i2samp_t03_clear(dut):
    await _tx_clear_t03(dut, is_i2s=True)


# ===========================================================================
# I2S microphone receiver
# ===========================================================================
@cocotb.test(timeout_time=120, timeout_unit="sec")
async def mic_t01_data(dut):
    await _clocks(dut, (("clk", 10),))
    dut.sd.value = 0

    # a monotonic 24-bit ramp that crosses zero; the receiver must reproduce the
    # per-frame step exactly (catches any MSB-first bit slip and sign errors)
    step = 4097
    base = -40000

    def value(fr):
        v = (base + fr * step) & 0xFFFFFF
        return (v, (0xFFFFFF - v + 1) & 0xFFFFFF)

    state = {"done": False, "frame": 0, "value": value, "z": False}
    await _reset(dut, ("clk",))
    src = cocotb.start_soon(i2s_source(dut, state))

    got = []
    guard = 0
    while len(got) < 16:
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        if int(dut.mic_valid.value):
            got.append(_s(int(dut.mic_data.value), 24))
        guard += 1
        assert guard < 200000, "mic valid never appeared"

    state["done"] = True
    await src
    exp_step = step if MIC_CH_SEL == 0 else -step
    diffs = [got[i + 1] - got[i] for i in range(len(got) - 1)]
    assert diffs.count(exp_step) >= len(diffs) - 2, \
        f"ch{MIC_CH_SEL}: ramp diffs {diffs} (want {exp_step})"
    assert any(g < 0 for g in got) and any(g > 0 for g in got), "ramp sign range"
    dut._log.info(f"mic_t01 ch{MIC_CH_SEL} 24-bit ramp exact ({len(got)} samples)")


@cocotb.test(timeout_time=120, timeout_unit="sec")
async def mic_t02_highz(dut):
    await _clocks(dut, (("clk", 10),))
    dut.sd.value = 0

    state = {"done": False, "frame": 0, "value": lambda fr: (0x123456, 0x654321),
             "z": True}
    await _reset(dut, ("clk",))
    src = cocotb.start_soon(i2s_source(dut, state))

    seen = False
    for _ in range(600):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        if int(dut.mic_valid.value):
            seen = True
            assert not dut.mic_data.value.is_resolvable, \
                "high-Z payload should make mic_data unresolvable"
            break
    state["done"] = True
    await src
    assert seen, "no mic_valid while driving high-Z"
    dut._log.info("mic_t02 high-Z/unknown payload is detectable in simulation")


# ===========================================================================
# transport (cross-domain)
# ===========================================================================
async def _core_tx_producer(dut, seq, stop):
    i = 0
    dut.core_tx_valid.value = 0
    while i < len(seq) and not stop["done"]:
        dut.core_tx_valid.value = 1
        dut.core_tx_data.value = seq[i]
        await Timer(1, unit="ns")
        while not int(dut.core_tx_ready.value):
            await RisingEdge(dut.clk_core)
            await Timer(1, unit="ns")
        await RisingEdge(dut.clk_core)
        i += 1
        dut.core_tx_valid.value = 0
    dut.core_tx_valid.value = 0


async def _core_tx_feed(dut, stop):
    """Keep the TX FIFO fed with fresh pairs until stopped."""
    i = 0
    dut.core_tx_valid.value = 0
    while not stop["done"]:
        dut.core_tx_valid.value = 1
        dut.core_tx_data.value = (((i & 0x7FFF) << 16) | ((i + 3) & 0x7FFF))
        await Timer(1, unit="ns")
        guard = 0
        while not int(dut.core_tx_ready.value):
            await RisingEdge(dut.clk_core)
            await Timer(1, unit="ns")
            guard += 1
            assert guard < 400000, "core_tx_ready stuck"
        await RisingEdge(dut.clk_core)
        i += 1
    dut.core_tx_valid.value = 0


async def _core_rx_consumer(dut, got, stop, read_prob, rng):
    dut.core_rx_ready.value = 0
    while not stop["done"]:
        await RisingEdge(dut.clk_core)
        await Timer(1, unit="ns")
        if int(dut.core_rx_valid.value) and rng.random() < read_prob:
            got.append(_s(int(dut.core_rx_data.value), 24))
            dut.core_rx_ready.value = 1
            await RisingEdge(dut.clk_core)
            dut.core_rx_ready.value = 0
        else:
            dut.core_rx_ready.value = 0


@cocotb.test(timeout_time=180, timeout_unit="sec")
async def transport_t01_tx(dut):
    await _clocks(dut, (("clk_core", 10), ("clk_audio", 17)))
    dut.core_tx_valid.value = 0
    dut.core_tx_data.value = 0
    dut.core_rx_ready.value = 0
    dut.mic_en.value = 0
    dut.diag_clear.value = 0
    dut.mic_sd.value = 0
    await _reset(dut, ("clk_core", "clk_audio"))

    n = 32
    rng = random.Random(5)
    seq = [((rng.randrange(0, 1 << 16) << 16) | rng.randrange(0, 1 << 16))
           for _ in range(n)]
    seq[0] = 0x1234_5678
    frames = []
    stop = {"done": False}
    dec = cocotb.start_soon(pt8211_decode(dut, frames, stop))
    # let the decoder see several WS transitions and align before data arrives
    for _ in range(4 * 256):
        await RisingEdge(dut.clk_audio)
    await _core_tx_producer(dut, seq, stop)
    for _ in range((n + 8) * 256):
        await RisingEdge(dut.clk_audio)
    stop["done"] = True
    await dec

    want = [(((p >> 16) & 0xFFFF), (p & 0xFFFF)) for p in seq]
    _check_frames(frames, want, "transport_t01")
    assert int(dut.underflow_sticky.value) == 1, "expected trailing underflow"
    assert int(dut.overflow_sticky.value) == 0, "unexpected overflow"
    dut._log.info(f"transport_t01 TX CDC {n} pairs exact, underflow sticky OK")


@cocotb.test(timeout_time=180, timeout_unit="sec")
async def transport_t05_tx_i2s(dut):
    """Default output format: standard I2S / MAX98357A through the full CDC."""
    await _clocks(dut, (("clk_core", 10), ("clk_audio", 17)))
    dut.core_tx_valid.value = 0
    dut.core_tx_data.value = 0
    dut.core_rx_ready.value = 0
    dut.mic_en.value = 0
    dut.diag_clear.value = 0
    dut.mic_sd.value = 0
    await _reset(dut, ("clk_core", "clk_audio"))

    n = 32
    rng = random.Random(55)
    samples = [rng.randrange(0, 1 << 16) for _ in range(n)]
    samples[0] = 0x2468
    seq = [((s << 16) | s) for s in samples]
    frames, slots = [], []
    stop = {"done": False}
    dec = cocotb.start_soon(i2s_decode(dut, frames, slots, stop,
                                       "dac_bck", "dac_ws", "dac_din"))
    # let the decoder see several WS transitions and align before data arrives
    for _ in range(4 * 256):
        await RisingEdge(dut.clk_audio)
    await _core_tx_producer(dut, seq, stop)
    for _ in range((n + 8) * 256):
        await RisingEdge(dut.clk_audio)
    stop["done"] = True
    await dec

    want = [(s, s) for s in samples]
    _check_frames(frames, want, "transport_t05")
    assert int(dut.underflow_sticky.value) == 1, "expected trailing underflow"
    assert int(dut.overflow_sticky.value) == 0, "unexpected overflow"
    dut._log.info(f"transport_t05 default I2S TX CDC {n} mono pairs exact")


@cocotb.test(timeout_time=180, timeout_unit="sec")
async def transport_t02_rx(dut):
    await _clocks(dut, (("clk_core", 10), ("clk_audio", 17)))
    dut.core_tx_valid.value = 0
    dut.core_tx_data.value = 0
    dut.core_rx_ready.value = 0
    dut.mic_en.value = 1
    dut.diag_clear.value = 0
    dut.mic_sd.value = 0

    n = 40
    step = 4097
    base = -100000
    state = {"done": False, "frame": 0,
             "value": lambda fr: ((base + fr * step) & 0xFFFFFF, 0),
             "z": False}
    await _reset(dut, ("clk_core", "clk_audio"))
    src = cocotb.start_soon(i2s_source(dut, state, "mic_bck", "mic_sd"))

    got = []
    stop = {"done": False}
    cons = cocotb.start_soon(_core_rx_consumer(dut, got, stop, 0.6,
                                               random.Random(21)))
    deadline = 0
    while len(got) < n:
        await RisingEdge(dut.clk_core)
        deadline += 1
        assert deadline < 400000, f"only {len(got)} rx samples"
    state["done"] = True
    stop["done"] = True
    await src
    await cons

    assert len(got) >= n
    diffs = [got[i + 1] - got[i] for i in range(n - 1)]
    assert diffs.count(step) >= n - 3, f"rx ramp diffs {diffs[:8]} != {step}"
    dut.core_rx_ready.value = 0
    dut._log.info(f"transport_t02 RX CDC {n} mic samples exact")
@cocotb.test(timeout_time=180, timeout_unit="sec")
async def transport_t03_overflow(dut):
    await _clocks(dut, (("clk_core", 10), ("clk_audio", 17)))
    dut.core_tx_valid.value = 0
    dut.core_tx_data.value = 0
    dut.core_rx_ready.value = 0
    dut.mic_en.value = 1
    dut.diag_clear.value = 0
    dut.mic_sd.value = 0

    base = -80000
    step = 4097
    state = {"done": False, "frame": 0,
             "value": lambda fr: ((base + fr * step) & 0xFFFFFF, 0),
             "z": False}
    await _reset(dut, ("clk_core", "clk_audio"))
    src = cocotb.start_soon(i2s_source(dut, state, "mic_bck", "mic_sd"))

    # never read: the RX FIFO must fill, drop new samples and go sticky
    for _ in range(40 * 256):
        await RisingEdge(dut.clk_audio)
    assert int(dut.overflow_sticky.value) == 1, "overflow sticky not raised"

    # drain the FIFO; the samples must be the OLDEST ones, not overwritten
    got = []
    stop = {"done": False}
    cons = cocotb.start_soon(_core_rx_consumer(dut, got, stop, 1.0,
                                               random.Random(31)))
    deadline = 0
    while len(got) < 16:
        await RisingEdge(dut.clk_core)
        deadline += 1
        assert deadline < 200000, "RX FIFO did not yield 16 samples"
    state["done"] = True
    stop["done"] = True
    await src
    await cons

    diffs = [got[i + 1] - got[i] for i in range(15)]
    assert diffs.count(step) >= 13, f"overflow ramp diffs {diffs} != {step}"
    dut._log.info("transport_t03 overflow sticky, oldest samples preserved")


@cocotb.test(timeout_time=180, timeout_unit="sec")
async def transport_t04_underflow_tick(dut):
    await _clocks(dut, (("clk_core", 10), ("clk_audio", 17)))
    dut.core_tx_valid.value = 0
    dut.core_tx_data.value = 0
    dut.core_rx_ready.value = 0
    dut.mic_en.value = 0
    dut.diag_clear.value = 0
    dut.mic_sd.value = 0
    await _reset(dut, ("clk_core", "clk_audio"))

    # no data ever written: every frame is zero and underflow is sticky
    pulses = 0
    toggles = []
    guard = 0
    while pulses < 10 and guard < 400000:
        await RisingEdge(dut.clk_core)
        await Timer(1, unit="ns")
        if int(dut.core_sample_pulse.value):
            pulses += 1
            toggles.append(int(dut.core_sample_tick.value))
        guard += 1
    assert pulses >= 10, f"only {pulses} sample pulses in {guard} core cycles"
    # toggle alternates on every pulse
    assert toggles == [i & 1 for i in range(len(toggles))] or \
        toggles == [1 - (i & 1) for i in range(len(toggles))], \
        f"tick toggle not alternating: {toggles}"
    assert int(dut.underflow_sticky.value) == 1, "underflow sticky not raised"
    dut._log.info(f"transport_t04 {pulses} sample ticks, underflow sticky OK")


@cocotb.test(timeout_time=180, timeout_unit="sec")
async def transport_t06_diag_clear(dut):
    """A one-core-cycle diag_clear must be delivered across the CDC."""
    await _clocks(dut, (("clk_core", 10), ("clk_audio", 17)))
    dut.core_tx_valid.value = 0
    dut.core_tx_data.value = 0
    dut.core_rx_ready.value = 0
    dut.mic_en.value = 1
    dut.diag_clear.value = 0
    dut.mic_sd.value = 0
    await _reset(dut, ("clk_core", "clk_audio"))

    # no TX data -> underflow; microphone on but never read -> overflow
    state = {"done": False, "frame": 0,
             "value": lambda fr: ((fr * 4097) & 0xFFFFFF, 0), "z": False}
    src = cocotb.start_soon(i2s_source(dut, state, "mic_bck", "mic_sd"))
    for _ in range(30 * 256):
        await RisingEdge(dut.clk_audio)
    assert int(dut.underflow_sticky.value) == 1, "underflow sticky not set"
    assert int(dut.overflow_sticky.value) == 1, "overflow sticky not set"
    state["done"] = True
    await src
    # stop the microphone writes too, otherwise the still-full RX FIFO would
    # raise overflow again immediately after any clear
    dut.mic_en.value = 0
    for _ in range(4 * 256):
        await RisingEdge(dut.clk_audio)

    # keep the TX FIFO non-empty so it cannot underflow during/after the clear
    stop = {"done": False}
    feed = cocotb.start_soon(_core_tx_feed(dut, stop))
    for _ in range(60):
        await RisingEdge(dut.clk_core)

    # exactly one core-cycle diag_clear event, driven race-free
    await FallingEdge(dut.clk_core)
    dut.diag_clear.value = 1
    await RisingEdge(dut.clk_core)
    await FallingEdge(dut.clk_core)
    dut.diag_clear.value = 0
    await RisingEdge(dut.clk_core)
    for _ in range(400):
        await RisingEdge(dut.clk_core)

    assert int(dut.underflow_sticky.value) == 0, "1-cycle clear missed (underflow)"
    assert int(dut.overflow_sticky.value) == 0, "1-cycle clear missed (overflow)"
    stop["done"] = True
    await feed
    dut.core_tx_valid.value = 0
    dut.core_rx_ready.value = 0
    dut._log.info("transport_t06 one-core-cycle diag_clear delivered across CDC")


# ===========================================================================
# runner
# ===========================================================================
def _fifo_sources():
    return [os.path.join(AUDIO, "audio_async_fifo.sv")]


def _pt_sources():
    return [os.path.join(AUDIO, "pt8211_tx.sv")]


def _i2samp_sources():
    return [os.path.join(AUDIO, "i2s_amp_tx.sv")]


def _mic_sources():
    return [os.path.join(AUDIO, "i2s_mic_rx.sv")]


def _tr_sources():
    return [os.path.join(AUDIO, "audio_async_fifo.sv"),
            os.path.join(AUDIO, "pt8211_tx.sv"),
            os.path.join(AUDIO, "i2s_amp_tx.sv"),
            os.path.join(AUDIO, "i2s_mic_rx.sv"),
            os.path.join(AUDIO, "audio_transport.sv")]


def _parse_results(xml_path):
    import xml.etree.ElementTree as ET
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


def _run_top(top, sources, tests, params, build_dir, extra_env=None):
    from cocotb_tools.runner import get_runner
    build_dir = os.path.abspath(os.path.expanduser(build_dir))
    os.makedirs(build_dir, exist_ok=True)
    runner = get_runner("icarus")
    runner.build(sources=sources, hdl_toplevel=top, parameters=params,
                 build_dir=build_dir, waves=False,
                 build_args=["-g2012", "-Wall"], always=True,
                 timescale=("1ns", "1ps"))
    summary = {"n": 0, "failures": []}
    for tc in tests:
        xml = os.path.join(build_dir, f"results_{tc}.xml")
        if os.path.exists(xml):
            os.remove(xml)
        runner.test(test_module="test_audio_transport", hdl_toplevel=top,
                    test_dir=_HERE, build_dir=build_dir, parameters=params,
                    extra_env=extra_env or {}, testcase=tc, results_xml=xml,
                    timescale=("1ns", "1ps"))
        r = _parse_results(xml)
        if r is None:
            raise RuntimeError(f"{top}/{tc}: missing or unparseable XML {xml}")
        if r["n"] == 0:
            raise RuntimeError(f"{top}/{tc}: no tests ran; XML {xml}")
        if r["failures"]:
            raise RuntimeError(f"{top}/{tc}: failed {r['failures']}; XML {xml}")
        print(f"[top {top}] {tc}: {r['n']} passed")
        summary["n"] += r["n"]
    return summary


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--build-dir", default=os.path.join(_ROOT, "sim", "build", "audio_transport"))
    args = ap.parse_args(argv)
    base = os.path.abspath(os.path.expanduser(args.build_dir))

    total = 0
    try:
        r = _run_top("audio_async_fifo", _fifo_sources(),
                     ["fifo_t01_sequence", "fifo_t02_full_empty",
                      "fifo_t03_reset", "fifo_t04_reset_handshake"],
                     {"WIDTH": 16, "DEPTH": 8}, os.path.join(base, "fifo"))
        total += r["n"]

        r = _run_top("pt8211_tx", _pt_sources(),
                     ["pt8211_t01_protocol", "pt8211_t02_edges",
                      "pt8211_t03_clear"],
                     {"CLK_DIV": 8}, os.path.join(base, "pt8211"))
        total += r["n"]

        r = _run_top("i2s_amp_tx", _i2samp_sources(),
                     ["i2samp_t01_protocol", "i2samp_t02_underflow",
                      "i2samp_t03_clear"],
                     {"CLK_DIV": 4}, os.path.join(base, "i2s_amp"))
        total += r["n"]

        # transport: explicit PT8211 path
        r = _run_top("audio_transport", _tr_sources(),
                     ["transport_t01_tx"],
                     {"TX_DEPTH": 16, "RX_DEPTH": 16, "CH_SEL": 0,
                      "OUT_FORMAT": 0}, os.path.join(base, "transport_pt"))
        total += r["n"]

        # transport: default standard-I2S path + shared diagnostics
        r = _run_top("audio_transport", _tr_sources(),
                     ["transport_t05_tx_i2s", "transport_t02_rx",
                      "transport_t03_overflow", "transport_t04_underflow_tick",
                      "transport_t06_diag_clear"],
                     {"TX_DEPTH": 16, "RX_DEPTH": 16, "CH_SEL": 0,
                      "OUT_FORMAT": 1}, os.path.join(base, "transport_i2s"))
        total += r["n"]
    except RuntimeError as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        return 1

    # The microphone RX is a conditional/historical block: it is exercised but
    # must not block the speaker-playback delivery.
    try:
        for ch in (0, 1):
            r = _run_top("i2s_mic_rx", _mic_sources(),
                         ["mic_t01_data", "mic_t02_highz"],
                         {"CH_SEL": ch},
                         os.path.join(base, f"mic{ch}"),
                         extra_env={"MIC_CH_SEL": str(ch)})
            total += r["n"]
    except RuntimeError as exc:
        print(f"[optional MIC] not blocking delivery: {exc}", file=sys.stderr)

    print(f"[audio_transport] {total} main tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
