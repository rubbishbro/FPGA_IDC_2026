"""Independent raw-bank checks: saturation width, count changes and atomic errors."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import random
import xml.etree.ElementTree as ET

import cocotb
from cocotb.triggers import Timer

from test_modal_engine_review import ROOT, EngineReview, signed
from fixed_point import pack_word


class BankReview(EngineReview):
    def __init__(self, d):
        self.d = d
        self.v = len(d.active_mask)
        self.vw = len(d.cfg_voice)
        self.mw = len(d.cfg_mode)
        self.nmax = int(os.environ.get('REVIEW_N_MODES', '48'))
        self.words = [None] * self.v
        self.y1 = [[0] * self.nmax for _ in range(self.v)]
        self.y2 = [[0] * self.nmax for _ in range(self.v)]
        self.frames = self.commits = self.max_cycles = 0

    async def tick(self, **updates):
        d = self.d
        counts = sum((len(w) if w is not None else 0) << (v*self.mw)
                     for v, w in enumerate(self.words))
        defaults = dict(rst_n=1, cfg_valid=0, cfg_voice=0, cfg_mode=0, cfg_word=0,
                        clear_valid=0, clear_voice=0, sample_valid=0,
                        active_mask=0, n_modes_vec=counts, x_vec=0)
        # The inherited poison-frame test uses the engine's load request names.
        if 'load_valid' in updates:
            updates['cfg_valid'] = updates.pop('load_valid')
        if 'load_voice' in updates:
            updates['cfg_voice'] = updates.pop('load_voice')
        updates.pop('load_midi', None)
        updates.pop('load_instrument', None)
        defaults.update(updates)
        d.clk.value = 0
        for name, value in defaults.items():
            s = getattr(d, name)
            s.value = int(value) & ((1 << len(s))-1)
        await Timer(5, unit='ns')
        accepted = {name: bool(defaults['rst_n']) and bool(defaults[name+'_valid'])
                    and bool(int(getattr(d, name+'_ready').value))
                    for name in ('cfg', 'clear', 'sample')}
        d.clk.value = 1
        await Timer(5, unit='ns')
        for name in ('busy', 'cfg_ready', 'clear_ready', 'sample_ready', 'out_valid',
                     'clear_done', 'error_valid', 'commit_valid', 'voice_valid'):
            assert getattr(d, name).value.is_resolvable, name
        z = {name: int(getattr(d, name).value) for name in
             ('busy', 'out_valid', 'error_valid', 'error_code', 'commit_valid', 'voice_valid', 'clear_done')}
        z.update(load_done=0, accepted=accepted)
        if z['voice_valid']:
            z.update(voice_id=int(d.voice_id.value), voice_sum=signed(d.voice_sum.value, 64))
        if z['out_valid']:
            z.update(mix_sum=signed(d.mix_sum.value, 64), sat_count=int(d.sat_count.value))
        z['commits'] = []
        for lane in range(4):
            if z['commit_valid'] & (1 << lane):
                for name in ('commit_voice', 'commit_mode', 'commit_y1', 'commit_y2', 'commit_sat'):
                    assert getattr(d, name).value.is_resolvable, name
                voice = (int(d.commit_voice.value) >> (lane*self.vw)) & ((1 << self.vw)-1)
                mode = (int(d.commit_mode.value) >> (lane*self.mw)) & ((1 << self.mw)-1)
                y1 = signed((int(d.commit_y1.value) >> (lane*32)) & 0xffffffff, 32)
                y2 = signed((int(d.commit_y2.value) >> (lane*32)) & 0xffffffff, 32)
                sat = (int(d.commit_sat.value) >> lane) & 1
                assert mode % 4 == lane
                z['commits'].append((voice, mode, y1, y2, sat))
        return z

    async def idle(self):
        for _ in range(16):
            if int(self.d.sample_ready.value) and int(self.d.cfg_ready.value):
                return
            z = await self.tick()
            assert not (z['error_valid'] or z['out_valid'] or z['commit_valid'])
        raise AssertionError('bank did not release ready')

    async def configure(self, v, m, word):
        await self.idle()
        z = await self.tick(cfg_valid=1, cfg_voice=v, cfg_mode=m, cfg_word=word)
        assert z['accepted']['cfg'] and not z['error_valid']
        if self.words[v] is None:
            self.words[v] = []
        if m == len(self.words[v]):
            self.words[v].append(word)
        else:
            assert m < len(self.words[v])
            self.words[v][m] = word

    async def clear(self, v):
        await self.idle()
        z = await self.tick(clear_valid=1, clear_voice=v)
        assert z['accepted']['clear'] and z['clear_done'] and not z['error_valid']
        self.y1[v] = [0] * self.nmax
        self.y2[v] = [0] * self.nmax

    async def rejected_frame(self, counts, mask, error):
        await self.idle()
        # The contract is stricter than "eventually reject without commits":
        # error is on the intake edge, busy stays low, and no operational
        # payload/accumulator, coefficients or history may change. A future
        # candidate scratch register is intentionally excluded: it is not an
        # accepted operational token and must never be consumed on rejection.
        def preserved():
            values = {name: str(getattr(self.d, name).value) for name in
                      ('state', 'act_r', 'nm_r', 'x_r', 'mix_acc', 'sat_acc', 'vcur')}
            for i in range(4):
                lane = self.d.g_lane[i].u_lane
                values[f'lane{i}.valid'] = str(lane.state_valid.value)
                values[f'lane{i}.memory'] = tuple(str(lane.mem[k].value) for k in range(len(lane.mem)))
            return values
        before = preserved()
        z = await self.tick(sample_valid=1, active_mask=mask, n_modes_vec=counts, x_vec=1 << 30)
        assert z['accepted']['sample']
        assert z['error_valid'] and z['error_code'] == error, 'rejection was not on the handshake edge'
        assert not z['busy'], 'rejected frame made bank busy'
        assert not (z['commit_valid'] or z['out_valid'] or z['voice_valid'])
        assert preserved() == before, 'rejected frame mutated operational payload/history/coefficients'
        for name in ('sample_ready', 'cfg_ready', 'clear_ready'):
            assert int(getattr(self.d, name).value), 'rejection inserted an unauthorized stall'
        # Check a second rejection on the very next edge, not after an idle gap.
        z = await self.tick(sample_valid=1, active_mask=mask, n_modes_vec=counts, x_vec=-(1 << 31))
        assert z['accepted']['sample'] and z['error_valid'] and z['error_code'] == error
        assert not (z['busy'] or z['commit_valid'] or z['out_valid'] or z['voice_valid'])
        assert preserved() == before


@cocotb.test()
async def full_range_saturation_count_and_64bit_sum(dut):
    r = BankReview(dut)
    await r.reset()
    word = pack_word(0, 0, (1 << 25)-1)
    for v in range(r.v):
        for m in range(r.nmax):
            await r.configure(v, m, word)
    await r.frame((1 << r.v)-1, [(1 << 31)-1] * r.v, poison=True)
    assert int(dut.sat_count.value) == r.v*r.nmax
    assert signed(dut.mix_sum.value, 64) == r.v*r.nmax*((1 << 31)-1)
    await r.frame((1 << r.v)-1, [-(1 << 31)] * r.v)
    assert int(dut.sat_count.value) == r.v*r.nmax
    assert signed(dut.mix_sum.value, 64) == -r.v*r.nmax*(1 << 31)
    dut._log.info('independent full saturation: count %d, max frame %d cycles',
                  r.v*r.nmax, r.max_cycles)


@cocotb.test()
async def counts_zero_tail_history_and_targeted_clear(dut):
    r = BankReview(dut)
    await r.reset()
    rng = random.Random(43901)
    originals = []
    for v in range(r.v):
        row = []
        for m in range(r.nmax):
            word = pack_word(-(1 << 20) + m*43 + v*97, (1 << 23)-v*11,
                             (1 << 22) + v*103 + m*31)
            await r.configure(v, m, word)
            row.append(word)
        originals.append(row)
    full = (1 << r.v)-1
    for phase in range(3):
        for n in range(r.nmax + 1):
            for v in range(r.v):
                count = (n + v*7) % (r.nmax + 1)
                r.words[v] = originals[v][:count]
            xs = [rng.randrange(-(1 << 30), 1 << 30) for _ in range(r.v)]
            await r.frame(full, xs, poison=phase == 1)
        target = (r.v-1) if phase % 2 else 0
        await r.clear(target)
        for v in range(r.v):
            r.words[v] = originals[v][:]
        await r.frame(full, [0] * r.v)
    dut._log.info('independent changing counts: %d frames, %d commits, max %d cycles',
                  r.frames, r.commits, r.max_cycles)


@cocotb.test()
async def precheck_late_invalid_voice_has_no_early_commits(dut):
    r = BankReview(dut)
    await r.reset()
    await r.configure(0, 0, pack_word(-(1 << 20), 1 << 23, 1 << 22))
    await r.frame(1, [1 << 29] + [0] * (r.v-1))
    last = r.v-1
    counts = 1 | (1 << (last*r.mw))
    if r.v > 1:
        await r.rejected_frame(counts, 1 | (1 << last), 3)
        await r.frame(1, [0] * r.v)
    if r.nmax + 1 < (1 << r.mw):
        bad_counts = 1 | ((r.nmax+1) << (last*r.mw))
        await r.rejected_frame(bad_counts, 1 | (1 << last), 2)
        await r.frame(1, [0] * r.v)
    await r.idle()
    z = await r.tick(clear_valid=1, clear_voice=0, cfg_valid=1,
                     cfg_voice=0, cfg_mode=0, cfg_word=0, sample_valid=1,
                     active_mask=1, x_vec=0)
    assert z['accepted'] == dict(cfg=False, clear=True, sample=False)
    assert z['clear_done']
    r.y1[0] = [0] * r.nmax
    r.y2[0] = [0] * r.nmax
    await r.frame(1, [1 << 29] + [0] * (r.v-1))
    # Config requests need not be contiguous or ascending. A cached lowest-
    # missing summary must track the full bitmap on the SAME cfg edge, including
    # filling a low hole that jumps across several already-configured modes.
    # Derive the expected prefix from writes, never from the DUT's summary.
    rng = random.Random(0xC0F16)
    ascending = list(range(r.nmax))
    shuffled = ascending[:]
    rng.shuffle(shuffled)
    for order in (ascending[::-1], ascending[::2] + ascending[1::2], shuffled):
        await r.reset()
        target = r.v - 1
        loaded = set()
        row = [pack_word(-(1 << 20) + k*31, (1 << 23)-k*11, (1 << 22)+k*73)
               for k in ascending]
        for mode in order:
            await r.idle()
            z = await r.tick(cfg_valid=1, cfg_voice=target, cfg_mode=mode, cfg_word=row[mode])
            assert z['accepted']['cfg'] and not z['error_valid']
            loaded.add(mode)
            prefix = next((k for k in ascending if k not in loaded), r.nmax)
            r.words[target] = row[:prefix]
            if hasattr(dut, 'low_unloaded'):
                assert int(dut.low_unloaded[target].value) == prefix, 'cfg summary updated late/wrong'
            # No idle edge between cfg and sample: reject the first hole, or
            # accept the complete row immediately after the last cfg handshake.
            if prefix < r.nmax:
                await r.rejected_frame((prefix+1) << (target*r.mw), 1 << target, 3)
            else:
                await r.frame(1 << target, [0]*(r.v-1) + [1 << 28])
        # Reconfiguring a present mode must retain the prefix; clear drops
        # history only, not coefficient presence or its summary.
        await r.configure(target, 0, row[0])
        await r.clear(target)
        await r.frame(1 << target, [0]*(r.v-1) + [1 << 28])
    dut._log.info('independent sparse/reverse/random configuration: same-edge prefix '
                  'updates, gap rejection, final-cfg immediate accept and clear retention passed')
    dut._log.info('independent raw-bank atomic prechecks and clear priority passed')


if __name__ == '__main__':
    from cocotb_tools.runner import get_runner
    from _review_source_snapshot import freeze_sources
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--voices', type=int, default=32, choices=range(1, 33))
    p.add_argument('--n-modes', type=int, default=48, choices=range(1, 49))
    p.add_argument('--skip-zero-input', type=int, default=1, choices=(0, 1))
    p.add_argument('--build-dir', type=Path, default=ROOT / 'sim/build/modal_poly_bank_review')
    p.add_argument('--frozen-sources', type=Path,
                   help='review a versioned parent source snapshot, not current RTL')
    a = p.parse_args()
    build = a.build_dir.expanduser().resolve()
    build.mkdir(parents=True, exist_ok=True)
    runner = get_runner('icarus')
    sources = [ROOT / 'rtl/core/poly_modal_lane.sv', ROOT / 'rtl/core/modal_poly_bank.sv']
    if a.frozen_sources:
        sources = [a.frozen_sources.resolve() / source.relative_to(ROOT) for source in sources]
    sources = freeze_sources(sources, build)
    runner.build(sources=sources,
                 hdl_toplevel='modal_poly_bank', build_dir=build,
                 parameters={'NUM_VOICES': a.voices, 'N_MODES': a.n_modes,
                             'SKIP_ZERO_INPUT': a.skip_zero_input},
                  build_args=['-g2012', '-Wall'], always=True)
    (build / 'review.xml').unlink(missing_ok=True)
    xml = runner.test(hdl_toplevel='modal_poly_bank', test_module=Path(__file__).stem,
                      test_dir=ROOT, build_dir=build, results_xml=str(build / 'review.xml'),
                      extra_env={'REVIEW_N_MODES': str(a.n_modes)})
    cases = ET.parse(xml).findall('.//testcase')
    if len(cases) != 3 or any(c.find('failure') is not None or c.find('error') is not None
                             or c.find('skipped') is not None for c in cases):
        raise SystemExit(1)
