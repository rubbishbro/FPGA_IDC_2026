"""Parent-only body review: golden coefficients from ORIGINAL Patch.sos.

No reuse of the body's implementation model or merged body ROM to obtain golden
arithmetic. The agreed local contract is DFI, signed68/Q34 internal history,
signed64/Q30 pins, Q2.30 coefficients and one round/clamp per section.
"""
from __future__ import annotations
import argparse
import math
import os
from pathlib import Path
import random
import sys

import cocotb
from cocotb.triggers import Timer

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'python/modal_sim'))
from params import Patch

I = int(os.environ.get('BODY_REVIEW_INSTRUMENT', '0'))
NAMES = ('guitar', 'piano', 'banjo', 'mandolin')
LOW, HIGH = -(1 << 63), (1 << 63) - 1
STATE_LOW, STATE_HIGH = -(1 << 67), (1 << 67) - 1


def signed(v, width):
    v = int(v)
    return v - (1 << width) if v & (1 << (width - 1)) else v


class Review:
    def __init__(self, d):
        self.d = d
        sos = Patch(NAMES[I]).sos
        self.c = [[math.floor(float(row[k] / row[3]) * (1 << 30) + 0.5)
                   for k in (0, 1, 2, 4, 5)] for row in sos]
        assert len(self.c) == 4
        assert all(-(1 << 31) <= c < (1 << 31) for row in self.c for c in row)
        self.state = [[0] * 4 for _ in self.c]
        self.maximum = self.samples = self.saturations = 0

    async def tick(self, **updates):
        fields = dict(rst_n=1, clear_valid=0, in_valid=0, in_sum=0)
        fields.update(updates)
        self.d.clk.value = 0
        for key, value in fields.items():
            h = getattr(self.d, key)
            h.value = value & ((1 << len(h)) - 1)
        await Timer(5, unit='ns')
        accepted = bool(fields['rst_n'] and fields['in_valid'] and int(self.d.in_ready.value))
        cleared = bool(fields['rst_n'] and fields['clear_valid'] and int(self.d.clear_ready.value))
        self.d.clk.value = 1
        await Timer(5, unit='ns')
        return dict(accepted=accepted, cleared=cleared,
                    out=bool(int(self.d.out_valid.value)),
                    ready=bool(int(self.d.in_ready.value)))

    async def reset(self):
        for _ in range(3):
            z = await self.tick(rst_n=0, in_valid=1, in_sum=HIGH)
            assert not z['accepted'] and not z['out']
        self.state = [[0] * 4 for _ in self.c]
        for _ in range(256):
            z = await self.tick()
            assert not z['out'], 'ghost output after reset'
            if z['ready']:
                return
        raise AssertionError('body not ready after reset/ROM initialisation')

    def step(self, value):
        mask = 0
        value <<= 4
        for section, c in enumerate(self.c):
            x1, x2, y1, y2 = self.state[section]
            acc = c[0] * value + c[1] * x1 + c[2] * x2 - c[3] * y1 - c[4] * y2
            raw = (acc + (1 << 29)) >> 30
            y = min(STATE_HIGH, max(STATE_LOW, raw))
            mask |= int(y != raw) << section
            self.state[section] = [value, x1, y, y1]
            value = y
        raw = (value + 8) >> 4
        value = min(HIGH, max(LOW, raw))
        if value != raw:
            mask |= 8
        return value, mask

    async def frame(self, value, poison=False):
        for _ in range(8):
            if int(self.d.in_ready.value):
                break
            z = await self.tick()
            assert not z['out']
        else:
            raise AssertionError('ready failed to recover after output')
        want, mask = self.step(value)
        z = await self.tick(in_valid=1, in_sum=value)
        assert z['accepted']
        for cycle in range(129):
            if z['out']:
                assert signed(self.d.out_sum.value, 64) == want, (self.samples, want,
                                                               signed(self.d.out_sum.value, 64))
                assert int(self.d.out_sat.value) == mask
                assert int(self.d.sat_count.value) == mask.bit_count()
                for section, values in enumerate(self.state):
                    for key, want_state in zip(('x1', 'x2', 'y1', 'y2'), values):
                        signal = getattr(self.d, key)[section]
                        assert signed(signal.value, len(signal)) == want_state, (
                            self.samples, section, key, want_state, signed(signal.value, len(signal)))
                self.maximum = max(self.maximum, cycle)
                self.samples += 1
                self.saturations += mask.bit_count()
                return
            # Change data in busy cycles; a valid held while ready=0 is not an
            # extra accepted input. Do not issue it in a ready/idle cycle.
            z = await self.tick(in_valid=int(poison and not z['ready']),
                                in_sum=LOW + cycle * 31337)
            assert not z['accepted'], 'body accepted a second frame while busy'
        raise AssertionError('body latency exceeds 128 core cycles')


@cocotb.test(timeout_time=1200, timeout_unit='sec')
async def body_original_sos_and_signed64(d):
    r = Review(d)
    await r.reset()
    rng = random.Random(0xB0D0 + I)
    sequence = [0, 1 << 30] + [0] * 128 + [-(1 << 30)] + [0] * 128
    sequence += [17 << 30] * 64 + [0] * 64
    sequence += [(1 if k % 2 else -1) * (37 << 30) for k in range(128)]
    sequence += [rng.randrange(-(32 << 30), 32 << 30) for _ in range(4096)]
    for k, value in enumerate(sequence):
        await r.frame(value, poison=(k % 17 == 0))
    # Direct saturated stress uses full signed64 range, never silently narrows
    # input/history to the 32-bit modal-state format.
    for value in [HIGH, LOW, HIGH, HIGH, LOW, LOW] + [rng.randrange(LOW, HIGH) for _ in range(96)]:
        await r.frame(value, poison=True)
    d._log.info('Independent body %s: %d samples exact, max %d cycles, '
                '%d section saturations', NAMES[I], r.samples, r.maximum, r.saturations)


@cocotb.test(timeout_time=300, timeout_unit='sec')
async def body_clear_and_reset_cancel(d):
    r = Review(d)
    await r.reset()
    for x in (1 << 30, 0, 0, -(1 << 30)):
        await r.frame(x)
    while not int(d.clear_ready.value):
        await r.tick()
    z = await r.tick(clear_valid=1)
    assert z['cleared'] and not z['out']
    r.state = [[0] * 4 for _ in r.c]
    for x in (0, 1 << 30, 0):
        await r.frame(x)
    # Include the new operand/product/acc pipeline, the old output boundary,
    # and the later boundaries if exact partial-product stages are required.
    for phase in (0, 1, 2, 3, 7, 15, 24, 25, 31, 47, 59, 60, 61, 62, 63, 64,
                  65, 79, 95, 103, 104, 105, 111, 119, 127):
        await r.reset()
        z = await r.tick(in_valid=1, in_sum=1 << 40)
        assert z['accepted']
        for _ in range(phase):
            await r.tick()
        await r.reset()
        for x in (0, -(1 << 30), 0, 0):
            await r.frame(x)


def main():
    sys.path.insert(0, str(ROOT / 'sim'))
    from _test_runner import build_and_run
    ap = argparse.ArgumentParser()
    ap.add_argument('--instrument', type=int, choices=range(4), default=0)
    ap.add_argument('--build-dir', default='/tmp/opencode/body-review/guitar')
    args = ap.parse_args()
    params = dict(BODY_INSTRUMENT=args.instrument,
                  BODY_FILE='"' + str(ROOT / 'rtl/rom/body_coeff.mem') + '"')
    build_and_run([str(ROOT / 'rtl/core/body_filter.sv')], 'body_filter',
                  Path(__file__).stem, str(ROOT), str(Path(args.build_dir).resolve()),
                  params, dict(BODY_REVIEW_INSTRUMENT=str(args.instrument)))


if __name__ == '__main__':
    main()
