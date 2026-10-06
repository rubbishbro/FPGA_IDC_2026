"""Parent-owned independent real-engine/standard-I2S review, no mock engine.

Golden data comes from the ORIGINAL guitar coefficient file and JSON, not the
merged ROM, audio implementer's tests, or the samples observed inside the RTL.
Clocks use 100MHz and either ps-rounded 12.288MHz or diagnostic 12.5MHz.
Optional body golden is independently derived from ORIGINAL Patch.sos, not the
implementation model or generated body ROM.
"""
from __future__ import annotations

import argparse
from collections import deque
import json
import math
import os
from pathlib import Path
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import First, RisingEdge, Timer, ValueChange
from cocotb.utils import get_sim_time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'python/modal_sim'))
from fixed_point import unpack_word

MELODY = [60, 60, 67, 67, 69, 69, 67, 65, 65, 64, 64, 62, 62, 60,
          67, 67, 65, 65, 64, 64, 62, 67, 67, 65, 65, 64, 64, 62,
          60, 60, 67, 67, 69, 69, 67, 65, 65, 64, 64, 62, 62, 60]
VOICES = int(os.environ.get('AUDIO_REVIEW_VOICES', '32'))
GAP = int(os.environ.get('AUDIO_REVIEW_GAP', '16'))
COUNT = int(os.environ.get('AUDIO_REVIEW_COUNT', str(2 * 42 * GAP + 8)))
ATT = int(os.environ.get('AUDIO_REVIEW_ATT', '3'))
BODY = int(os.environ.get('AUDIO_REVIEW_BODY', '0'))
AUDIO_PS = int(os.environ.get('AUDIO_REVIEW_AUDIO_PS', '81380'))


def signed(value, width):
    value = int(value)
    return value - (1 << width) if value & (1 << (width - 1)) else value


def reference(count):
    words = [int(x, 16) for x in
             (ROOT / 'FFT_results/params/guitar_coeff.mem').read_text().split()]
    meta = json.loads((ROOT / 'FFT_results/params/guitar_coeffindex.json').read_text())
    coeffs = {}
    for note in set(MELODY):
        e = meta[f'{note}|forte']
        coeffs[note] = [unpack_word(w) for w in words[e['offset']:e['offset'] + e['n_modes']]]
    pulse = [math.floor(0.2 * (0.5 - 0.5 * math.cos(2 * math.pi * i / 7))
                        * (1 << 30) + 0.5) for i in range(7)]
    slots = [None] * VOICES
    if BODY:
        from params import Patch
        body_c = [[math.floor(float(row[k] / row[3]) * (1 << 30) + 0.5)
                   for k in (0, 1, 2, 4, 5)] for row in Patch('guitar').sos]
        body_state = [[0] * 4 for _ in body_c]
    event = 0
    result = []
    for sample in range(count):
        if sample % GAP == 0:
            v = event % VOICES
            c = coeffs[MELODY[event]]
            slots[v] = [c, [0] * len(c), [0] * len(c), 0]
            event = (event + 1) % len(MELODY)
        mix = 0
        for slot in slots:
            if slot is None:
                continue
            c, y1, y2, p = slot
            x = pulse[p] if p < 7 else 0
            new = []
            for k, (a1, a2, g) in enumerate(c):
                raw = (g * x - (a1 << 4) * y1[k] - a2 * y2[k] + (1 << 23)) >> 24
                y = max(-(1 << 31), min((1 << 31) - 1, raw))
                new.append(y)
                mix += y
            slot[1], slot[2], slot[3] = new, y1, min(7, p + 1)
        adapted = mix
        if BODY:
            value = mix << 4
            for j, c in enumerate(body_c):
                x1, x2, y1, y2 = body_state[j]
                raw = (c[0]*value + c[1]*x1 + c[2]*x2 - c[3]*y1 - c[4]*y2
                       + (1 << 29)) >> 30
                assert -(1 << 67) <= raw < (1 << 67), 'unexpected normal body saturation'
                body_state[j] = [value, x1, raw, y1]
                value = raw
            adapted = (value + 8) >> 4
            assert -(1 << 63) <= adapted < (1 << 63)
        pcm = max(-32768, min(32767, ((adapted >> ATT) + 16384) >> 15))
        result.append((mix, pcm & 0xffff, adapted))
    return result


class Observe:
    def __init__(self):
        self.outputs = self.pushes = self.pops = self.frames = self.events = 0
        self.body_outputs = self.max_processing_cycles = 0
        self.processing_started = None
        self.pending = deque()
        self.serial = deque()
        self.underflows = 0
        self.ticks = []
        self.done = False
        self.i2s_launch_changes = 0


async def observe_i2s_launch_edges(d, state):
    """Pin waveform proof of the nominal edge relationship, not PVT delay STA.

    Data/WS may change only on the falling BCLK edge. The nearest sampling
    rising edge must be two audio periods away on either side. This establishes
    the 160ns nominal interval used by the diagnostic C2O differential proof.
    """
    signals = (d.dac_bck, d.dac_ws, d.dac_din)
    previous = tuple(int(s.value) for s in signals)
    last_fall = last_rise = None
    changed_at = [None, None]
    while not state.done:
        await First(*(ValueChange(s) for s in signals))
        edge_time = int(get_sim_time(unit='ps'))
        await Timer(1, unit='ps')  # settle co-occurring NBA/continuous assignments
        if state.done:
            return
        current = tuple(int(s.value) for s in signals)
        bclk, ws, din = current
        if bclk != previous[0]:
            if bclk:
                if last_fall is not None:
                    assert edge_time - last_fall == 2 * AUDIO_PS, 'wrong nominal I2S setup half-period'
                last_rise = edge_time
                for t in changed_at:
                    if t is not None:
                        assert edge_time - t >= 2 * AUDIO_PS, 'data/WS changed too near sampling BCLK'
            else:
                if last_rise is not None:
                    assert edge_time - last_rise == 2 * AUDIO_PS, 'wrong nominal I2S hold half-period'
                last_fall = edge_time
        for i, (old, new) in enumerate(zip(previous[1:], (ws, din))):
            if old != new:
                assert not bclk and last_fall == edge_time, 'I2S data/WS changed away from falling BCLK'
                if last_rise is not None:
                    assert edge_time - last_rise >= 2 * AUDIO_PS, 'data/WS violates nominal hold interval'
                changed_at[i] = edge_time
                state.i2s_launch_changes += 1
        previous = current


async def observe_core(d, state, expected):
    # Read before NBA: these are the actual values accepted at this edge.
    signals = [d.sp_load_valid, d.sp_out_valid, d.core_tx_valid, d.core_sample_pulse]
    signals.append(d.sp_sample_valid)
    if BODY:
        signals.append(d.g_body.body_out_valid)
    while not state.done:
        # Do not visit millions of idle core edges. Wake on an externally useful
        # transaction and stay awake until all handshake/pulse signals go low.
        if not any(int(s.value) for s in signals):
            await First(*(RisingEdge(s) for s in signals))
        await RisingEdge(d.clk_core)
        if state.done:
            return
        if not int(d.u_song.rst_n.value):
            await Timer(1, unit='ns')
            continue
        assert not int(d.engine_error_valid.value), 'engine error'
        assert not int(d.deadline_error.value), 'song deadline missed'
        assert not int(d.tx_overflow_sticky.value), 'adapter dropped a sample'
        if BODY:
            assert not int(d.body_overflow_sticky.value), 'body input lost a sample'
        if int(d.sp_sample_valid.value) and int(d.sp_sample_ready.value):
            assert state.processing_started is None, 'new modal frame before previous result'
            state.processing_started = get_sim_time(unit='ns')
        if int(d.sp_load_valid.value) and int(d.sp_load_ready.value):
            e = state.events % len(MELODY)
            assert int(d.sp_load_voice.value) == e % VOICES
            assert int(d.sp_load_midi.value) == MELODY[e]
            assert int(d.sp_load_instrument.value) == 0 and int(d.sp_load_dyn.value) == 1
            state.events += 1
        if int(d.sp_out_valid.value):
            if state.outputs < len(expected):
                assert signed(d.sp_out_sum.value, 64) == expected[state.outputs][0], (
                    'synthesis mismatch', state.outputs,
                    signed(d.sp_out_sum.value, 64), expected[state.outputs][0])
            state.outputs += 1
        final_valid = int(d.g_body.body_out_valid.value) if BODY else int(d.sp_out_valid.value)
        if final_valid:
            assert state.processing_started is not None, 'result without accepted modal input'
            cycles = round((get_sim_time(unit='ns') - state.processing_started) / 10)
            state.max_processing_cycles = max(state.max_processing_cycles, cycles)
            assert cycles < AUDIO_PS * 256 / 10000, 'modal+body exceeded actual frame budget'
            state.processing_started = None
            if BODY:
                if state.body_outputs < len(expected):
                    assert signed(d.g_body.body_out_sum.value, 64) == expected[state.body_outputs][2], (
                        'full precision body mismatch', state.body_outputs,
                        signed(d.g_body.body_out_sum.value, 64), expected[state.body_outputs][2])
                assert int(d.g_body.body_out_sat.value) == 0, 'normal body saturation'
                state.body_outputs += 1
        if int(d.core_tx_valid.value) and int(d.core_tx_ready.value):
            if state.pushes < len(expected):
                pcm = expected[state.pushes][1]
                assert int(d.core_tx_data.value) == pcm * 0x10001
            state.pending.append(int(d.core_tx_data.value))
            state.pushes += 1
        if int(d.core_sample_pulse.value):
            t = get_sim_time(unit='ns')
            if state.ticks:
                assert abs(t - state.ticks[-1] - AUDIO_PS * 256 / 1000) <= 10, 'wrong frame pacing'
            state.ticks.append(t)
        await Timer(1, unit='ns')


async def observe_fifo(d, state):
    while not state.done:
        await RisingEdge(d.u_transport.tx_rready)
        await RisingEdge(d.clk_audio)
        if state.done:
            return
        if not int(d.u_transport.arst_n.value):
            continue
        if int(d.u_transport.tx_rready.value):
            if int(d.u_transport.tx_rvalid.value):
                assert state.pending, 'read without a committed core write'
                pair = state.pending.popleft()
                assert int(d.u_transport.tx_rdata.value) == pair, 'CDC reordered data'
                state.pops += 1
            else:
                assert state.pops == 0, 'underflow AFTER playback began'
                pair = 0
                state.underflows += 1
            state.serial.append(pair & 0xffff)
        await Timer(1, unit='ns')


async def decode(d, state):
    # Align on a real high->low WS transition; ignore only the reset partial frame.
    previous = 0
    position = None
    left = right = 0
    last_edge = None
    while not state.done:
        await RisingEdge(d.dac_bck)
        await Timer(1, unit='ns')
        if state.done:
            return
        now = get_sim_time(unit='ns')
        if last_edge is not None:
            assert abs(now - last_edge - AUDIO_PS * 4 / 1000) < 0.002, 'wrong BCLK'
        last_edge = now
        ws, bit = int(d.dac_ws.value), int(d.dac_din.value)
        if ws == 0 and previous == 1:
            assert position is None or position == 64, 'not 64 BCLK per frame'
            assert state.serial, 'serializer failed to pop at boundary'
            position = 0
            left = right = 0
        if position is not None:
            assert ws == int(position >= 32), 'wrong WS polarity/slot length'
            index = position % 32
            if 1 <= index <= 16:
                if ws:
                    right = (right << 1) | bit
                else:
                    left = (left << 1) | bit
            else:
                assert bit == 0, 'I2S delay/padding bit not zero'
            position += 1
            if position == 64:
                want = state.serial.popleft()
                assert (left, right) == (want, want), (
                    'external I2S mismatch', state.frames, left, right, want)
                state.frames += 1
        previous = ws


@cocotb.test(timeout_time=1200, timeout_unit='sec')
async def full_song_original_coeffs_to_serial(d):
    d.rst_n.value = 0
    d.diag_clear.value = 0
    d.mic_sd.value = 0
    cocotb.start_soon(Clock(d.clk_core, 10000, unit='ps').start())
    cocotb.start_soon(Clock(d.clk_audio, AUDIO_PS, unit='ps').start())
    await Timer(700, unit='ns')
    state = Observe()
    expected = reference(COUNT)
    tasks = [cocotb.start_soon(observe_core(d, state, expected)),
              cocotb.start_soon(observe_fifo(d, state)),
              cocotb.start_soon(decode(d, state)),
              cocotb.start_soon(observe_i2s_launch_edges(d, state))]
    d.rst_n.value = 1
    # Frame-level wait keeps Python off the 100MHz clock except its scoreboard.
    for _ in range(COUNT + 12):
        await Timer(AUDIO_PS * 256, unit='ps')
        assert not int(d.deadline_error.value), 'song deadline missed'
        assert not int(d.tx_overflow_sticky.value), 'adapter dropped a sample'
        if BODY:
            assert not int(d.body_overflow_sticky.value), 'body input lost a sample'
        if state.frames >= COUNT + state.underflows:
            break
    assert state.frames >= COUNT + state.underflows
    assert state.outputs >= COUNT and state.pops >= COUNT
    if BODY:
        assert state.body_outputs >= COUNT
    assert state.events >= (COUNT + GAP - 1) // GAP
    assert state.underflows <= 2, 'excessive startup underflow'
    assert int(d.overflow_sticky.value) == 0
    assert state.i2s_launch_changes > 0, 'no data/WS changes observed for edge proof'
    state.done = True
    for task in tasks:
        await task
    d._log.info('Independent audio chain: V=%d, gap=%d, %d golden samples, '
                '%d events, %d decoded frames, %d startup underflows, '
                 'ZERO stable underflows; core100MHz/audio_period=%dps, body=%d, '
                 'max modal+body processing=%d core cycles',
                 VOICES, GAP, COUNT, state.events, state.frames, state.underflows,
                  AUDIO_PS, BODY, state.max_processing_cycles)
    d._log.info('Independent I2S pin edge relation: %d data/WS transitions only on '
                'falling BCLK, nominal setup/hold interval >=%dps; NOT PVT/board-skew evidence',
                state.i2s_launch_changes, 2 * AUDIO_PS)


def main():
    from _test_runner import build_and_run
    from _review_source_snapshot import freeze_sources
    ap = argparse.ArgumentParser()
    ap.add_argument('--voices', type=int, default=32)
    ap.add_argument('--gap', type=int, default=16)
    ap.add_argument('--samples', type=int)
    ap.add_argument('--attenuation', type=int, default=3)
    ap.add_argument('--body', action='store_true')
    ap.add_argument('--diagnostic-12m5', action='store_true',
                    help='12.5MHz / 48.828125kHz diagnostic, NOT 48kHz fidelity')
    ap.add_argument('--build-dir', default='/tmp/opencode/audio-review/chain32')
    ap.add_argument('--frozen-sources', type=Path,
                    help='reuse a parent_source_snapshot tree; identifies a versioned baseline, not current RTL acceptance')
    args = ap.parse_args()
    sources = list((ROOT / 'rtl/audio').glob('*.sv')) + [
        ROOT / f'rtl/core/{name}.sv' for name in
        ('coeff_loader', 'poly_modal_lane', 'modal_poly_bank', 'modal_engine')]
    params = dict(NUM_VOICES=args.voices, NOTE_GAP=args.gap, SUM_ATT=args.attenuation,
                  MODE_SONG=1, OUT_FORMAT=1,
                  COEFF_FILE='"' + str(ROOT / 'rtl/rom/modal_coeff.mem') + '"',
                  INDEX_FILE='"' + str(ROOT / 'rtl/rom/modal_index.mem') + '"')
    if args.body:
        sources.append(ROOT / 'rtl/core/body_filter.sv')
        params.update(ENABLE_BODY=1, BODY_INSTRUMENT=0,
                      BODY_FILE='"' + str(ROOT / 'rtl/rom/body_coeff.mem') + '"')
    if args.frozen_sources:
        snapshot = args.frozen_sources.resolve()
        sources = [snapshot / source.relative_to(ROOT) for source in sources]
    env = dict(AUDIO_REVIEW_VOICES=str(args.voices), AUDIO_REVIEW_GAP=str(args.gap),
               AUDIO_REVIEW_COUNT=str(args.samples or (2 * 42 * args.gap + 8)),
               AUDIO_REVIEW_ATT=str(args.attenuation), AUDIO_REVIEW_BODY=str(int(args.body)),
               AUDIO_REVIEW_AUDIO_PS='80000' if args.diagnostic_12m5 else '81380')
    sources = freeze_sources(sources, args.build_dir)
    build_and_run(sources, 'audio_demo_core',
                  Path(__file__).stem, str(ROOT), str(Path(args.build_dir).resolve()),
                  params, env)


if __name__ == '__main__':
    main()
