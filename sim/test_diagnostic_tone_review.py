"""Parent pin-level review of the isolated, continuously repeating I2S tone.

Uses a test-only PLL clock/lock model, never a physical PLL/jitter claim.
Decodes external pins without consuming the tone source's phase/sample state.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.handle import Force
from cocotb.triggers import FallingEdge, RisingEdge, Timer
from cocotb.utils import get_sim_time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'sim'))


async def decode_frames(d, count):
    # A WS falling edge is the beginning of a complete LEFT slot (delay bit).
    # Initial partial zero frame is discarded; the first complete frame must
    # contain the first +1024 sample, independently of DUT internal phase.
    await FallingEdge(d.amp_lrc)
    previous_start = None
    positive = negative = transitions = 0
    previous_din = None
    for frame in range(count):
        samples = []
        start = None
        for bit in range(64):
            await RisingEdge(d.amp_bclk)
            now = get_sim_time(unit='ns')
            await Timer(1, unit='ps')
            if bit == 0:
                start = now
                if previous_start is not None:
                    assert abs(start - previous_start - 20480) < .001
                previous_start = start
            else:
                assert abs(now - start - bit * 320) < .001
            ws, din = int(d.amp_lrc.value), int(d.amp_din.value)
            assert ws == int(bit >= 32), (frame, bit, ws)
            assert int(d.amp_sd.value), 'amp must be enabled for complete tone frames'
            if previous_din is not None and din != previous_din:
                transitions += 1
            previous_din = din
            samples.append(din)
        expected = 1024 if frame % 48 < 24 else -1024
        for slot in (0, 32):
            assert samples[slot] == 0, 'standard I2S one-bit delay'
            assert not any(samples[slot + 17:slot + 32]), '16-bit payload must be zero-padded'
            payload = 0
            for value in samples[slot + 1:slot + 17]:
                payload = (payload << 1) | value
            signed = payload - 65536 if payload & 32768 else payload
            assert signed == expected, (frame, slot, signed, expected)
        positive += expected > 0
        negative += expected < 0
    assert transitions > count, 'DIN did not keep switching throughout the capture'
    assert positive == negative == count // 2
    return transitions


@cocotb.test(timeout_time=60, timeout_unit='sec')
async def repeating_tone_and_lock_restart(d):
    cocotb.start_soon(Clock(d.clk, 20, unit='ns').start())
    lock = d.u_pll_audio.lock
    lock.value = Force(0)
    await Timer(1000, unit='ns')
    assert not int(d.amp_sd.value)
    assert not int(d.amp_bclk.value)
    assert not int(d.amp_lrc.value)
    assert not int(d.amp_din.value)

    observed = {'done': False, 'changes': 0, 'previous': None, 'last_fall': None}

    async def monitor_edges():
        # Sample 1ps after each audio-clock NBA update; DIN/WS changes are
        # allowed only on BCLK falling edges. Hold to following rise is 160ns.
        while not observed['done']:
            await RisingEdge(d.u_pll_audio.clkout0)
            await Timer(1, unit='ps')
            pins = tuple(int(p.value) for p in (d.amp_bclk, d.amp_lrc, d.amp_din))
            now = get_sim_time(unit='ns')
            previous = observed['previous']
            if previous is not None and int(lock.value):
                falling = previous[0] == 1 and pins[0] == 0
                if falling:
                    observed['last_fall'] = now
                if pins[1:] != previous[1:]:
                    assert falling, ('DIN/WS changed away from falling BCLK', previous, pins)
                    observed['changes'] += 1
                if previous[0] == 0 and pins[0] == 1 and observed['last_fall'] is not None:
                    assert abs(now - observed['last_fall'] - 160) < .001
            observed['previous'] = pins

    watcher = cocotb.start_soon(monitor_edges())
    total = 0
    for frames in (192, 96):
        lock.value = Force(1)
        # Amplifier remains disabled until the first sample is consumed.
        await Timer(1, unit='ps')
        assert not int(d.amp_sd.value)
        total += await decode_frames(d, frames)
        lock.value = Force(0)
        await Timer(1, unit='ns')
        assert not int(d.amp_sd.value), 'PLL unlock must mute asynchronously'
        await Timer(1000, unit='ns')
        assert not int(d.amp_bclk.value)
        assert not int(d.amp_lrc.value)
        assert not int(d.amp_din.value)
        observed['previous'] = None
        observed['last_fall'] = None
    observed['done'] = True
    await watcher
    assert observed['changes'] > 288
    d._log.info('PASS: 288 complete external I2S frames, 576 signed payloads, '
                'six full 48-frame tone periods including lock-loss restart; '
                '%d sampled DIN transitions, %d falling-edge DIN/WS updates; '
                'Fs=48828.125Hz, BCLK=3.125MHz, tone=1017.252604Hz. '
                'Digital simulation only, not physical PLL/jitter or speaker proof.',
                total, observed['changes'])


def main():
    from _review_source_snapshot import freeze_sources
    from _test_runner import build_and_run
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--build-dir', required=True)
    args = ap.parse_args()
    plat = ROOT / 'rtl/platform/tang_mega_138k_pro/diagnostic_tone'
    sources = [ROOT / 'sim/audio_helpers/board_pll_model.sv',
               ROOT / 'rtl/audio/i2s_amp_tx.sv',
               plat / 'tone_source.sv', plat / 'top.sv']
    sources = freeze_sources(sources, Path(args.build_dir))
    summary = build_and_run(sources, 'diagnostic_tone_top',
                            'test_diagnostic_tone_review', str(ROOT / 'sim'),
                            args.build_dir, {}, {})
    print(f"Independent diagnostic tone pin review: {summary['n']} tests, zero failures")


if __name__ == '__main__':
    main()
