"""Independent parent review of reset handshakes and short CDC clear events."""
from __future__ import annotations
import argparse
from pathlib import Path
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

ROOT = Path(__file__).resolve().parents[1]


@cocotb.test(timeout_time=60, timeout_unit='sec')
async def fifo_reset_is_not_an_accepted_write(d):
    d.rst_n.value = 0
    d.wvalid.value = 1
    d.wdata.value = 0xBAD0CAFE
    d.rready.value = 1
    cocotb.start_soon(Clock(d.wclk, 10, unit='ns').start())
    cocotb.start_soon(Clock(d.rclk, 83, unit='ns').start())
    await Timer(200, unit='ns')
    assert int(d.wready.value) == 0, 'write ready falsely indicates acceptance during reset'
    assert int(d.rvalid.value) == 0
    d.wvalid.value = 0
    d.rst_n.value = 1
    for _ in range(5):
        await RisingEdge(d.rclk)
    await Timer(1, unit='ns')
    assert int(d.rvalid.value) == 0, 'poison word escaped reset'
    await FallingEdge(d.wclk)
    d.wvalid.value = 1
    d.wdata.value = 0x10203040
    await RisingEdge(d.wclk)
    assert int(d.wready.value) == 1
    await FallingEdge(d.wclk)
    d.wvalid.value = 0
    for _ in range(6):
        await RisingEdge(d.rclk)
        if int(d.rvalid.value):
            assert int(d.rdata.value) == 0x10203040
            break
    else:
        raise AssertionError('valid post-reset write did not arrive')


@cocotb.test(timeout_time=60, timeout_unit='sec')
async def i2s_clear_at_frame_boundary(d):
    d.rst_n.value = 0
    d.diag_clear.value = 0
    d.in_valid.value = 0
    d.in_data.value = 0x12341234
    cocotb.start_soon(Clock(d.clk, 10, unit='ns').start())
    await Timer(100, unit='ns')
    d.rst_n.value = 1
    # Produce a real underflow, then clear EXACTLY at a valid frame boundary.
    await RisingEdge(d.frame_tick)
    await Timer(1, unit='ns')
    assert int(d.underflow_sticky.value) == 1
    await RisingEdge(d.in_ready)
    d.in_valid.value = 1
    d.diag_clear.value = 1
    await RisingEdge(d.clk)
    await Timer(1, unit='ns')
    assert int(d.underflow_sticky.value) == 0, 'clear overridden at normal frame boundary'
    assert int(d.underflow_pulse.value) == 0
    await FallingEdge(d.clk)
    d.diag_clear.value = 0
    await RisingEdge(d.in_ready)
    d.in_valid.value = 0
    d.diag_clear.value = 1
    await RisingEdge(d.clk)
    await Timer(1, unit='ns')
    assert int(d.underflow_sticky.value) == 1, 'new underflow must dominate clear'


@cocotb.test(timeout_time=120, timeout_unit='sec')
async def one_core_cycle_clear_crosses_slower_clock(d):
    d.rst_n.value = 0
    d.diag_clear.value = 0
    d.core_tx_valid.value = 0
    d.core_tx_data.value = 0x3C003C00
    d.core_rx_ready.value = 0
    d.mic_en.value = 0
    d.mic_sd.value = 0
    cocotb.start_soon(Clock(d.clk_core, 10, unit='ns').start())
    cocotb.start_soon(Clock(d.clk_audio, 81380, unit='ps').start())
    await Timer(1000, unit='ns')
    d.rst_n.value = 1
    for trial in range(12):
        await Timer(23000, unit='ns')
        assert int(d.underflow_sticky.value) == 1, 'no initial underflow'
        # Fill a few words to prevent immediate reassertion after the clear.
        for _ in range(4):
            await FallingEdge(d.clk_core)
            d.core_tx_valid.value = 1
            while True:
                await RisingEdge(d.clk_core)
                if int(d.core_tx_ready.value):
                    break
            await FallingEdge(d.clk_core)
            d.core_tx_valid.value = 0
        await Timer(1000 + trial * 17, unit='ns')
        # Deliberately one 10ns core cycle, with no audio-phase alignment.
        await FallingEdge(d.clk_core)
        d.diag_clear.value = 1
        await FallingEdge(d.clk_core)
        d.diag_clear.value = 0
        await Timer(1000, unit='ns')
        assert int(d.underflow_sticky.value) == 0, ('lost short clear event', trial)
        await Timer(120000, unit='ns')
        assert int(d.underflow_sticky.value) == 1, 'later underflow did not reassert'
    d._log.info('Independent CDC clear: 12 one-core-cycle events at different phases passed')


def main():
    sys.path.insert(0, str(ROOT / 'sim'))
    from _test_runner import build_and_run
    ap = argparse.ArgumentParser()
    ap.add_argument('--build-dir', default='/tmp/opencode/audio-review/transport-independent')
    args = ap.parse_args()
    audio = ROOT / 'rtl/audio'
    configs = [
        ('fifo', 'audio_async_fifo', ['audio_async_fifo'], 'fifo_reset_is_not_an_accepted_write'),
        ('tx', 'i2s_amp_tx', ['i2s_amp_tx'], 'i2s_clear_at_frame_boundary'),
        ('cdc', 'audio_transport', ['audio_async_fifo', 'i2s_amp_tx', 'pt8211_tx',
                                  'i2s_mic_rx', 'audio_transport'],
         'one_core_cycle_clear_crosses_slower_clock'),
    ]
    for label, top, files, test in configs:
        build_and_run([str(audio / (f + '.sv')) for f in files], top,
                      Path(__file__).stem, str(ROOT),
                      str(Path(args.build_dir).resolve() / label), {}, {}, testcase=test)


if __name__ == '__main__':
    main()
