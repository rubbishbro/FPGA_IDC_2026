"""Parent-only cache-template equivalence to the original read-first lane.

Creates a TEST-ONLY read-first clone under the build directory. All original
arithmetic and scheduling are identical; only the cache process differs. Every
observable commit and sum is compared cycle-for-cycle, including immediately
adjacent coefficient configuration, clearing, mode-count changes and resets.
This does not establish physical SPX9 mapping; Gowin reports must prove that.
"""
from __future__ import annotations
import argparse
import os
from pathlib import Path
import random
import re

import cocotb
from cocotb.triggers import Timer

ROOT = Path(__file__).resolve().parents[1]
VOICES = int(os.environ.get('RAM_REVIEW_VOICES', '32'))
MODES = int(os.environ.get('RAM_REVIEW_MODES', '48'))
LANE = int(os.environ.get('RAM_REVIEW_LANE', '0'))
LOCAL = (MODES + 3) // 4


@cocotb.test(timeout_time=120, timeout_unit='sec')
async def original_read_first_observable_equivalence(d):
    rng = random.Random(7123 + MODES * 13 + VOICES + LANE)
    commits = writes = frames = 0

    async def tick(**updates):
        nonlocal commits, writes
        fields = dict(rst_n=1, start=0, n_modes=0, x_in=0, voice=0,
                      clear=0, clear_voice=0, cfg_we=0, cfg_voice=0,
                      cfg_local=0, cfg_wdata=0)
        fields.update(updates)
        d.clk.value = 0
        for key, value in fields.items():
            signal = getattr(d, key)
            signal.value = value & ((1 << len(signal)) - 1)
        await Timer(5, unit='ns')
        writing = int(d.current.we.value)
        previous_read = d.current.rdata.value
        d.clk.value = 1
        await Timer(5, unit='ns')
        if writing and previous_read.is_resolvable:
            assert int(d.current.rdata.value) == int(previous_read), 'no-change RAM did not hold on write'
        for key in ('done', 'partial_sum', 'sat_count', 'commit_valid',
                    'commit_voice', 'commit_mode', 'commit_y1', 'commit_y2', 'commit_sat'):
            current = getattr(d.current, key).value
            original = getattr(d.original, key).value
            assert current.is_resolvable and original.is_resolvable, key
            assert int(current) == int(original), (key, int(current), int(original))
        commits += int(d.current.commit_valid.value)
        writes += fields['cfg_we']
        return int(d.current.done.value)

    await tick(rst_n=0)
    # All coefficients vary by voice/local. Include large G to cover saturation.
    for v in range(VOICES):
        for m in range(LOCAL):
            a1 = -(1 << 20) + v * 53 + m * 91
            a2 = (1 << 23) - v * 17 - m * 41
            g = ((1 << 25) - 1) if m % 3 == 0 else ((1 << 22) + v * 79 + m * 29)
            word = (g & ((1 << 26)-1)) << 46 | a2 << 22 | (a1 & ((1 << 22)-1))
            await tick(cfg_we=1, cfg_voice=v, cfg_local=m, cfg_wdata=word)
    for _ in range(256):
        v = rng.randrange(VOICES)
        if rng.randrange(5) == 0:
            await tick(clear=1, clear_voice=v)
        nm = rng.randrange(MODES + 1)
        x = rng.choice((0, -(1 << 31), (1 << 31)-1, rng.randrange(-(1 << 30), 1 << 30)))
        await tick(start=1, voice=v, n_modes=nm, x_in=x)
        frames += 1
        for cycle in range(3 * LOCAL + 20):
            if int(d.current.done.value):
                break
            # External inputs may change while running; the accepted voice,
            # count and input must be latched, regardless of the RAM write mode.
            await tick(voice=rng.randrange(VOICES), n_modes=rng.randrange(MODES + 1),
                       x_in=rng.randrange(-(1 << 31), 1 << 31))
        else:
            raise AssertionError('lane failed to complete within original cycle budget')
        await tick()
    # Reset cancels pending writes at all pipeline phases, without resetting RAM.
    for phase in range(3 * LOCAL + 3):
        await tick(start=1, voice=VOICES-1, n_modes=MODES, x_in=1 << 29)
        for _ in range(phase):
            await tick()
        await tick(rst_n=0)
        await tick(start=1, voice=0, n_modes=MODES, x_in=0)
        for _ in range(3 * LOCAL + 20):
            if int(d.current.done.value):
                break
            await tick()
        else:
            raise AssertionError('post-reset frame stalled')
        await tick()
    d._log.info('Independent original-read-first equivalence: voices=%d modes=%d lane=%d, '
                '%d frames / %d writes / %d matching commits',
                VOICES, MODES, LANE, frames, writes, commits)


def main():
    from _test_runner import build_and_run
    from _review_source_snapshot import freeze_sources
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--voices', type=int, default=32, choices=range(1, 33))
    ap.add_argument('--n-modes', type=int, default=48, choices=range(1, 49))
    ap.add_argument('--lane', type=int, default=0, choices=range(4))
    ap.add_argument('--skip-zero-input', type=int, default=1, choices=(0, 1))
    ap.add_argument('--build-dir', default='/tmp/opencode/ram-review/equivalence')
    ap.add_argument('--frozen-sources', type=Path,
                    help='review a versioned parent source snapshot, not current RTL')
    a = ap.parse_args()
    build = Path(a.build_dir).resolve()
    build.mkdir(parents=True, exist_ok=True)
    lane_source = ((a.frozen_sources.resolve() if a.frozen_sources else ROOT)
                   / 'rtl/core/poly_modal_lane.sv')
    lane_source = Path(freeze_sources([lane_source], build)[0])
    text = lane_source.read_text()
    text, count = re.subn(r'\bmodule poly_modal_lane\b', 'module original_read_first_lane', text)
    assert count == 1
    # Replace only the RAM process, bounded by its declarations and the following
    # state section. Fail closed if the implementation structure changes.
    pattern = r'(logic\s+\[71:0\]\s+wdata;\s*)always_ff.*?(?=\n\s*// -+\n\s*// state\n)'
    text, count = re.subn(pattern,
                         r'\1always_ff @(posedge clk) begin\n'
                         r'        if (we) mem[addr] <= wdata;\n'
                         r'        rdata <= mem[addr];\n    end\n', text, flags=re.S)
    assert count == 1, 'cache boundary changed; inspect the test-only clone generator'
    clone = build / 'original_read_first_lane.sv'
    clone.write_text('// TEST ONLY. NEVER include in synthesis.\n' + text)
    wrapper = build / 'ram_equivalence_top.sv'
    wrapper.write_text('''`timescale 1ns/1ps
module ram_equivalence_top #(
 parameter NUM_VOICES=32, N_MODES=48, LANE=0, SKIP_ZERO_INPUT=1,
 parameter VW=(NUM_VOICES<2)?1:$clog2(NUM_VOICES),
 parameter MW=(N_MODES<1)?1:$clog2(N_MODES+1),
 parameter LOCAL_MODES=(N_MODES+3)/4,
 parameter IDXW=(LOCAL_MODES<2)?1:$clog2(LOCAL_MODES)
)(input logic clk, rst_n, start, clear, cfg_we,
  input logic [MW-1:0] n_modes,
  input logic signed [31:0] x_in,
  input logic [VW-1:0] voice, clear_voice, cfg_voice,
  input logic [IDXW-1:0] cfg_local,
  input logic [71:0] cfg_wdata);
 poly_modal_lane #(.NUM_VOICES(NUM_VOICES),.N_MODES(N_MODES),
 .LANE(LANE),.SKIP_ZERO_INPUT(SKIP_ZERO_INPUT)) current
 (.clk(clk),.rst_n(rst_n),.start(start),.n_modes(n_modes),.x_in(x_in),.voice(voice),
 .clear(clear),.clear_voice(clear_voice),.cfg_we(cfg_we),.cfg_voice(cfg_voice),
 .cfg_local(cfg_local),.cfg_wdata(cfg_wdata));
 original_read_first_lane #(.NUM_VOICES(NUM_VOICES),.N_MODES(N_MODES),
 .LANE(LANE),.SKIP_ZERO_INPUT(SKIP_ZERO_INPUT)) original
 (.clk(clk),.rst_n(rst_n),.start(start),.n_modes(n_modes),.x_in(x_in),.voice(voice),
 .clear(clear),.clear_voice(clear_voice),.cfg_we(cfg_we),.cfg_voice(cfg_voice),
 .cfg_local(cfg_local),.cfg_wdata(cfg_wdata));
endmodule
''')
    parameters = dict(NUM_VOICES=a.voices, N_MODES=a.n_modes, LANE=a.lane,
                      SKIP_ZERO_INPUT=a.skip_zero_input)
    build_and_run([str(lane_source), str(clone), str(wrapper)],
                  'ram_equivalence_top', Path(__file__).stem, str(ROOT), str(build),
                  parameters, dict(RAM_REVIEW_VOICES=str(a.voices),
                                   RAM_REVIEW_MODES=str(a.n_modes), RAM_REVIEW_LANE=str(a.lane)))


if __name__ == '__main__':
    main()
