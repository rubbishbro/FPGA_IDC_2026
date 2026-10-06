"""Independent board-top review with REAL engine/ROM, test-only PLL clocks.

Reuses only the parent's independent golden model/scoreboard, not the board
implementer's mock engine or block-search decoder. No physical PLL claim.
"""
from __future__ import annotations
import argparse
from pathlib import Path
import sys
from types import SimpleNamespace

import cocotb
from cocotb.clock import Clock
from cocotb.handle import Force, Release
from cocotb.triggers import RisingEdge, Timer

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'sim'))
import test_audio_chain_review as chain


class Pins:
    def __init__(self, d):
        self.dac_bck = d.amp_bclk
        self.dac_ws = d.amp_lrc
        self.dac_din = d.amp_din


@cocotb.test(timeout_time=600, timeout_unit='sec')
async def actual_board_top_real_engine(d):
    # The production wrapper has literal ROM paths and enables BODY, while top
    # defaults to the bypass baseline. Test both without synthesising a mock.
    pins = d
    d = getattr(d, 'u_top', d)
    pins.reset.value = 1
    cocotb.start_soon(Clock(pins.clk, 20, unit='ns').start())
    await Timer(1000, unit='ns')
    assert int(pins.amp_sd.value) == 0
    pins.reset.value = 0
    state = chain.Observe()
    expected = chain.reference(chain.COUNT)
    core = d.u_audio.u_core
    tasks = [cocotb.start_soon(chain.observe_core(core, state, expected)),
              cocotb.start_soon(chain.observe_fifo(core, state)),
              cocotb.start_soon(chain.decode(Pins(pins), state)),
              cocotb.start_soon(chain.observe_i2s_launch_edges(Pins(pins), state))]
    for _ in range(chain.COUNT + 12):
        await Timer(chain.AUDIO_PS * 256, unit='ps')
        assert not int(core.deadline_error.value)
        if int(pins.amp_sd.value):
            assert int(d.u_clock_reset.locked.value)
            assert state.pushes, 'amplifier enabled without any produced PCM sample'
        if state.frames >= chain.COUNT + state.underflows:
            break
    assert state.frames >= chain.COUNT + state.underflows
    assert state.pops >= chain.COUNT
    assert state.i2s_launch_changes > 0
    assert int(pins.amp_sd.value) == 1
    state.done = True
    for task in tasks:
        await task
    # Stop observing before deliberately destroying the transaction; verify that
    # actual audio PLL lock loss (not merely pressing reset) mutes immediately.
    d.u_clock_reset.u_pll_audio.lock.value = Force(0)
    await Timer(1, unit='ns')
    assert int(pins.amp_sd.value) == 0
    assert int(d.u_clock_reset.rst_n.value) == 0
    d.u_clock_reset.u_pll_audio.lock.value = Release()
    await Timer(200000, unit='ns')
    assert int(pins.amp_sd.value) == 1
    pins.reset.value = 1
    await Timer(1, unit='ns')
    assert int(pins.amp_sd.value) == 0
    d._log.info('Independent board REAL engine: V=%d, %d golden samples, '
                '%d events, %d pin-decoded frames; body=%d, %d body outputs, '
                'max processing=%d core cycles; audio-unlock/reset immediate mute',
                chain.VOICES, chain.COUNT, state.events, state.frames, chain.BODY,
                state.body_outputs, state.max_processing_cycles)


@cocotb.test(timeout_time=60, timeout_unit='sec')
async def failed_real_load_must_not_enable_amplifier(d):
    pins = d
    d = getattr(d, 'u_top', d)
    # No real table fits N_MODES=1 (minimum original n=2). Clocks/WS may run,
    # but no produced sample can make it through the engine or TX FIFO.
    pins.reset.value = 1
    cocotb.start_soon(Clock(pins.clk, 20, unit='ns').start())
    await Timer(1000, unit='ns')
    pins.reset.value = 0
    for _ in range(12):
        await Timer(chain.AUDIO_PS * 256, unit='ps')
        assert int(pins.amp_sd.value) == 0, 'frame tick alone enabled the amplifier'
        assert int(d.u_audio.playback_ready.value) == 0
    assert int(d.u_clock_reset.locked.value) == 1, 'test never reached locked state'
    d._log.info('Independent board failed REAL ROM load: clocks locked, amp stays muted')


@cocotb.test(timeout_time=180, timeout_unit='sec')
async def reset_release_phase_review(d):
    """Digital async assertion/synchronous release, NOT metastability/MTBF STA.

    Observe actual board/core/transport/FIFO chains, perturb button and both
    PLL lock levels near core/audio edges. Do not alter production synchronizers.
    """
    pins = d
    d = getattr(d, 'u_top', d)
    cr = d.u_clock_reset
    core = d.u_audio.u_core
    tr = core.u_transport
    fifo = tr.u_tx_fifo
    pins.reset.value = 1
    cocotb.start_soon(Clock(pins.clk, 20, unit='ns').start())
    await Timer(1000, unit='ns')
    # The board's three FFs are reset by !locked, not the button. The
    # button asynchronously gates board rst_n and resets the downstream chains.
    chains = [(cr.clk_core, cr.locked, cr.crst_sync),
              (cr.clk_core, cr.rst_n, core.crst_sync),
              (cr.clk_core, cr.rst_n, tr.crst_sync),
              (cr.clk_audio, cr.rst_n, tr.arst_sync),
              (cr.clk_core, cr.rst_n, fifo.wrst_sync),
              (cr.clk_audio, cr.rst_n, fifo.rrst_sync)]
    observed = SimpleNamespace(done=False, edges=0)

    async def monitor(clock, reset_n, vector):
        while not observed.done:
            await RisingEdge(clock)
            before = int(vector.value)
            running = int(reset_n.value)
            await Timer(1, unit='ps')
            if observed.done:
                return
            expected = (((before << 1) | 1) & ((1 << len(vector))-1)) if running else 0
            assert int(vector.value) == expected, (vector._path, before, running, expected)
            observed.edges += 1

    tasks = [cocotb.start_soon(monitor(*chain_)) for chain_ in chains]
    pins.reset.value = 0
    await Timer(140000, unit='ns')
    assert int(pins.amp_sd.value)
    offsets = (2, 4998, 5002, 9998, 10002, 39998, 40002, 79998)
    for kind in ('button', 'core_lock', 'audio_lock'):
        for offset in offsets:
            await RisingEdge(cr.clk_audio)
            await Timer(offset, unit='ps')
            lock = cr.u_pll_core.lock if kind == 'core_lock' else cr.u_pll_audio.lock
            if kind == 'button':
                pins.reset.value = 1
            else:
                lock.value = Force(0)
            await Timer(2, unit='ps')
            assert not int(pins.amp_sd.value) and not int(cr.rst_n.value)
            for _, _, vector in chains[1:]:
                assert not int(vector.value), 'async assert did not clear dedicated reset chain'
            assert not int(core.playback_ready.value)
            assert not int(core.sp_engine_out_valid.value)
            assert not int(core.g_body.body_out_valid.value)
            await Timer(120000 + offset, unit='ps')
            if kind == 'button':
                pins.reset.value = 0
            else:
                lock.value = Force(1)
            await Timer(2, unit='ps')
            assert not int(pins.amp_sd.value), 'release enabled amplifier before a new produced sample'
            await Timer(140000, unit='ns')
            assert int(pins.amp_sd.value), 'digital reset phase perturbation prevented restart'
            assert not int(core.deadline_error.value)
            if kind != 'button':
                lock.value = Release()
    observed.done = True
    for task in tasks:
        await task
    d._log.info('Independent digital reset phase review: 24 button/core-lock/audio-lock '
                'perturbations, %d exact synchronizer edge transitions across 6 chains; '
                'immediate mute, no ghost output, restart; NOT analog metastability/MTBF proof',
                observed.edges)


def main():
    from _test_runner import build_and_run
    from _review_source_snapshot import freeze_sources
    ap = argparse.ArgumentParser()
    ap.add_argument('--voices', type=int, default=32)
    ap.add_argument('--samples', type=int, default=256)
    ap.add_argument('--gap', type=int, default=16)
    ap.add_argument('--body', action='store_true', help='exercise platform body parameter plumbing')
    ap.add_argument('--production-wrapper', action='store_true',
                    help='actual board_top (fixed 32 voices, gap12000, bodyON); no test parameter overrides')
    ap.add_argument('--build-dir', default='/tmp/opencode/audio-review/board-real-independent')
    ap.add_argument('--frozen-sources', type=Path,
                    help='review a versioned parent source snapshot, not current RTL')
    ap.add_argument('--reset-phases', action='store_true',
                    help='additional arbitrary-phase reset test (requires body or production wrapper)')
    args = ap.parse_args()
    if args.reset_phases and not (args.body or args.production_wrapper):
        ap.error('--reset-phases requires --body or --production-wrapper')
    platform = ROOT / 'rtl/platform/tang_mega_138k_pro'
    sources = list((ROOT / 'rtl/audio').glob('*.sv')) + [
        ROOT / f'rtl/core/{name}.sv' for name in
        ('coeff_loader', 'poly_modal_lane', 'modal_poly_bank', 'modal_engine')]
    sources += [platform / 'clock_reset.sv', platform / 'board_audio_core.sv', platform / 'top.sv',
                 ROOT / 'sim/audio_helpers/board_pll_model.sv']
    params = dict(NUM_VOICES=args.voices, NOTE_GAP=args.gap,
                  COEFF_FILE='"' + str(ROOT / 'rtl/rom/modal_coeff.mem') + '"',
                  INDEX_FILE='"' + str(ROOT / 'rtl/rom/modal_index.mem') + '"')
    if args.body:
        sources.append(ROOT / 'rtl/core/body_filter.sv')
        params.update(ENABLE_BODY=1, BODY_INSTRUMENT=0,
                      BODY_FILE='"' + str(ROOT / 'rtl/rom/body_coeff.mem') + '"')
    if args.production_wrapper:
        if args.voices != 32 or args.gap != 16:
            ap.error('Production wrapper parameters are fixed; do not request voices/gap overrides')
        sources.append(platform / 'board_top.sv')
        if not args.body:
            sources.append(ROOT / 'rtl/core/body_filter.sv')
        params = {}
    env = dict(AUDIO_REVIEW_VOICES=str(args.voices), AUDIO_REVIEW_GAP=str(args.gap),
               AUDIO_REVIEW_COUNT=str(args.samples), AUDIO_REVIEW_ATT='3',
               AUDIO_REVIEW_BODY=str(int(args.body)), AUDIO_REVIEW_AUDIO_PS='80000')
    if args.production_wrapper:
        env.update(AUDIO_REVIEW_GAP='12000', AUDIO_REVIEW_BODY='1')
    if args.frozen_sources:
        sources = [args.frozen_sources.resolve() / source.relative_to(ROOT) for source in sources]
    sources = freeze_sources(sources, args.build_dir)
    build_and_run(sources, 'board_top' if args.production_wrapper else 'top', Path(__file__).stem,
                   str(ROOT), str(Path(args.build_dir).resolve() / 'real'), params, env,
                    testcase='actual_board_top_real_engine')
    if args.reset_phases:
        build_and_run(sources, 'board_top' if args.production_wrapper else 'top', Path(__file__).stem,
                      str(ROOT), str(Path(args.build_dir).resolve() / 'reset-phases'), params, env,
                      testcase='reset_release_phase_review')
    if args.production_wrapper:
        return  # Invalid-load parameter case belongs to the configurable top.
    params['N_MODES'] = 1
    build_and_run(sources, 'top', Path(__file__).stem,
                  str(ROOT), str(Path(args.build_dir).resolve() / 'reject'), params, env,
                  testcase='failed_real_load_must_not_enable_amplifier')


if __name__ == '__main__':
    main()
