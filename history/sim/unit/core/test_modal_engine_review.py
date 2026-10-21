"""Independent parent-review tests for the 2B/2C integrated engine.

Golden arithmetic uses public pins and original coefficient files. Read-only
internal snapshots additionally check atomic rejection preserves operational
payload, metadata and complete lane caches. Run directly with torch312 Python;
XML is explicitly checked and structural parameters rebuild.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import random
import sys
import xml.etree.ElementTree as ET

import cocotb
from cocotb.triggers import Timer

ROOT = Path(__file__).resolve()
while not ((ROOT / "rtl").is_dir() and (ROOT / "sim").is_dir()):
    ROOT = ROOT.parent
import sys as _sim_sys  # noqa: E402
_sim_sys.path.insert(0, str(ROOT / "sim" / "support"))
from _sim_paths import bootstrap as _sim_bootstrap  # noqa: E402
ROOT = _sim_bootstrap(__file__)
sys.path.insert(0, str(ROOT / "python/modal_sim"))
from fixed_point import unpack_word

INSTRUMENTS = ("guitar", "piano", "banjo", "mandolin")


def signed(v, width):
    v = int(v)
    return v - (1 << width) if v & (1 << (width - 1)) else v


class EngineReview:
    def __init__(self, d):
        self.d = d
        self.v = len(d.active_mask)
        self.vw = len(d.load_voice)
        self.mw = len(d.loaded_n_modes)
        self.nmax = int(os.environ.get("REVIEW_N_MODES", "48"))
        self.words = [None] * self.v
        self.y1 = [[0] * self.nmax for _ in range(self.v)]
        self.y2 = [[0] * self.nmax for _ in range(self.v)]
        self.frames = self.commits = self.max_cycles = 0

    async def tick(self, **updates):
        d = self.d
        defaults = dict(rst_n=1, load_valid=0, load_voice=0, load_instrument=0,
                        load_midi=0, load_dyn=0, load_vel=255, sample_valid=0,
                        active_mask=0, x_vec=0)
        defaults.update(updates)
        d.clk.value = 0
        for name, v in defaults.items():
            s = getattr(d, name)
            s.value = int(v) & ((1 << len(s)) - 1)
        await Timer(5, unit="ns")
        accepted = {name: bool(defaults["rst_n"]) and bool(defaults[name + "_valid"])
                    and bool(int(getattr(d, name + "_ready").value))
                    for name in ("load", "sample")}
        d.clk.value = 1
        await Timer(5, unit="ns")
        names = ("busy", "load_ready", "sample_ready", "load_done", "out_valid",
                 "error_valid", "commit_valid", "voice_valid")
        for name in names:
            assert getattr(d, name).value.is_resolvable, name
        result = {name: int(getattr(d, name).value) for name in names}
        result["accepted"] = accepted
        result["error_code"] = int(d.error_code.value)
        if result["load_done"]:
            result["done_voice"] = int(d.done_voice.value)
            result["n"] = int(d.loaded_n_modes.value)
        if result["voice_valid"]:
            result["voice_id"] = int(d.voice_id.value)
            result["voice_sum"] = signed(d.voice_sum.value, 64)
        if result["out_valid"]:
            result["mix_sum"] = signed(d.mix_sum.value, 64)
            result["sat_count"] = int(d.sat_count.value)
        commits = []
        for lane in range(4):
            if result["commit_valid"] & (1 << lane):
                for name in ("commit_voice", "commit_mode", "commit_y1", "commit_y2", "commit_sat"):
                    assert getattr(d, name).value.is_resolvable, name
                voice = (int(d.commit_voice.value) >> (lane * self.vw)) & ((1 << self.vw) - 1)
                mode = (int(d.commit_mode.value) >> (lane * self.mw)) & ((1 << self.mw) - 1)
                y1 = signed((int(d.commit_y1.value) >> (32 * lane)) & 0xffffffff, 32)
                y2 = signed((int(d.commit_y2.value) >> (32 * lane)) & 0xffffffff, 32)
                sat = (int(d.commit_sat.value) >> lane) & 1
                assert mode % 4 == lane, ("lane tag", voice, mode, lane)
                commits.append((voice, mode, y1, y2, sat))
        result["commits"] = commits
        return result

    async def reset(self):
        z = await self.tick(rst_n=0)
        assert not (z["busy"] or z["load_done"] or z["commit_valid"] or z["out_valid"])
        self.words = [None] * self.v
        self.y1 = [[0] * self.nmax for _ in range(self.v)]
        self.y2 = [[0] * self.nmax for _ in range(self.v)]

    async def idle(self):
        for _ in range(16):
            if int(self.d.load_ready.value) and int(self.d.sample_ready.value):
                return
            z = await self.tick()
            assert not (z["error_valid"] or z["load_done"] or z["commit_valid"] or z["out_valid"])
        raise AssertionError("engine did not become idle")

    def saved(self, inst, midi, dyn):
        index = json.loads((ROOT / f"FFT_results/params/{INSTRUMENTS[inst]}_coeffindex.json").read_text())
        meta = index.get(f"{midi}|{'forte' if dyn else 'piano'}")
        if meta is None:
            return None
        words = [int(w, 16) for w in (ROOT / f"FFT_results/params/{INSTRUMENTS[inst]}_coeff.mem").read_text().splitlines()]
        return words[meta["offset"]:meta["offset"] + meta["n_modes"]]

    async def load(self, voice, inst, midi, dyn, expected_error=0):
        await self.idle()
        z = await self.tick(load_valid=1, load_voice=voice, load_instrument=inst,
                            load_midi=midi, load_dyn=dyn, load_vel=255)
        assert z["accepted"]["load"] and not z["accepted"]["sample"]
        words = self.saved(inst, midi, dyn)
        for cycle in range(4 * 48 + 25):
            assert not (z["commit_valid"] or z["out_valid"])
            if z["error_valid"]:
                assert expected_error and z["error_code"] == expected_error, (z, expected_error)
                assert not z["load_done"]
                return cycle
            if z["load_done"]:
                assert not expected_error and words is not None
                assert z["done_voice"] == voice and z["n"] == len(words)
                self.words[voice] = words
                self.y1[voice] = [0] * self.nmax
                self.y2[voice] = [0] * self.nmax
                return cycle
            assert not z["sample_ready"], "sampling allowed midway through a load"
            z = await self.tick(load_voice=(voice + 1) % self.v,
                                load_instrument=(inst + 1) % 4, load_midi=0, load_dyn=1-dyn,
                                load_vel=0,
                                sample_valid=1, active_mask=(1 << self.v)-1, x_vec=(1 << (32*self.v))-1)
            assert not z["accepted"]["sample"]
        raise AssertionError("load deadline exceeded")

    async def frame(self, mask, inputs, poison=False):
        await self.idle()
        expected = {}
        sums = {}
        for voice in range(self.v):
            if not mask & (1 << voice):
                continue
            assert self.words[voice] is not None
            sums[voice] = 0
            for mode, word in enumerate(self.words[voice]):
                a1, a2, g = unpack_word(word)
                acc = g*inputs[voice] - (a1 << 4)*self.y1[voice][mode] - a2*self.y2[voice][mode]
                raw = (acc + (1 << 23)) >> 24
                y = max(-(1 << 31), min((1 << 31)-1, raw))
                expected[voice, mode] = (y, self.y1[voice][mode], int(y != raw))
                sums[voice] += y
        vector = sum((x & 0xffffffff) << (32*v) for v, x in enumerate(inputs))
        z = await self.tick(sample_valid=1, active_mask=mask, x_vec=vector)
        assert z["accepted"]["sample"] and not z["error_valid"]
        commits, voices = {}, {}
        for cycle in range(1801):
            assert not (z["error_valid"] or z["load_done"])
            for v, m, y1, y2, sat in z["commits"]:
                key = v, m
                assert key in expected and key not in commits, ("wrong/duplicate state", key)
                assert (y1, y2, sat) == expected[key], (key, (y1, y2, sat), expected[key])
                commits[key] = (y1, y2, sat)
            if z["voice_valid"]:
                v = z["voice_id"]
                assert v in sums and v not in voices, ("wrong/duplicate voice", v)
                assert z["voice_sum"] == sums[v], (v, z["voice_sum"], sums[v])
                assert all((v, m) in commits for m in range(len(self.words[v])))
                voices[v] = z["voice_sum"]
            if z["out_valid"]:
                assert set(commits) == set(expected) and set(voices) == set(sums)
                assert z["mix_sum"] == sum(sums.values())
                assert z["sat_count"] == sum(e[2] for e in expected.values())
                for (v, m), (y1, y2, _) in expected.items():
                    self.y1[v][m], self.y2[v][m] = y1, y2
                self.frames += 1
                self.commits += len(expected)
                self.max_cycles = max(cycle, self.max_cycles)
                return cycle
            changes = dict(active_mask=mask ^ ((1 << self.v)-1), x_vec=0)
            if poison:
                changes.update(load_valid=1, load_voice=0, load_midi=0,
                               load_instrument=3, sample_valid=1)
            z = await self.tick(**changes)
            assert not any(z["accepted"].values()), "busy requests accepted"
        raise AssertionError("full frame exceeds 1800 core cycles")

    async def rejected_frame(self, mask):
        await self.idle()

        def preserved():
            values = {name: str(getattr(self.d, name).value) for name in
                      ('estate', 'act_r', 'x_r', 'voice_loaded', 'nm_vec_r')}
            values['voice_nm'] = tuple(str(self.d.voice_nm[v].value) for v in range(self.v))
            bank = self.d.u_bank
            for name in ('state', 'act_r', 'nm_r', 'x_r', 'mix_acc', 'sat_acc', 'vcur'):
                values['bank.' + name] = str(getattr(bank, name).value)
            for name in ('coeff_loaded', 'low_unloaded'):
                if hasattr(bank, name):
                    values['bank.' + name] = tuple(str(getattr(bank, name)[v].value)
                                                   for v in range(self.v))
            for i in range(4):
                lane = bank.g_lane[i].u_lane
                values[f'lane{i}.valid'] = str(lane.state_valid.value)
                values[f'lane{i}.memory'] = tuple(str(lane.mem[k].value) for k in range(len(lane.mem)))
            return values

        # Candidate scratch may change; it is NOT a consumed operational token.
        # Consecutive invalid requests must both reject on their handshake edge
        # without busy/stall or any operational, coefficient/history mutation.
        before = preserved()
        for vector in (1 << 30, (1 << (32*self.v))-1):
            z = await self.tick(sample_valid=1, active_mask=mask, x_vec=vector)
            assert z['accepted']['sample'] and not z['accepted']['load']
            assert z['error_valid'] and z['error_code'] == 4, 'engine rejection was delayed'
            assert not (z['busy'] or z['load_done'] or z['commit_valid']
                        or z['voice_valid'] or z['out_valid'])
            assert z['sample_ready'] and z['load_ready'], 'rejected frame inserted a stall'
            assert preserved() == before, 'engine rejection mutated operational payload/history'

    async def tiny_structure_rejections(self):
        # No saved table entry has fewer than two modes. N=1 must reject the
        # original row rather than silently pretend it loaded a one-mode prefix.
        await self.reset()
        for v in range(self.v):
            await self.load(v, 1, 21, 1, expected_error=3)
        await self.frame(0, [0] * self.v)
        await self.rejected_frame(1)


@cocotb.test()
async def full_polyphony_random_inputs_and_frozen_voices(dut):
    r = EngineReview(dut)
    if r.nmax == 1:
        await r.tiny_structure_rejections()
        return
    await r.reset()
    # Small structural builds use a valid short row, never silently truncate ROM.
    if r.nmax < 48:
        chosen = next((inst, int(k.split('|')[0]), int(k.endswith('|forte')))
                      for inst, name in enumerate(INSTRUMENTS)
                      for k, meta in json.loads((ROOT / f"FFT_results/params/{name}_coeffindex.json").read_text()).items()
                      if meta['n_modes'] <= r.nmax)
    else:
        chosen = (1, 21, 1)
    for v in range(r.v):
        await r.load(v, *chosen)
    rng = random.Random(20261004)
    full = (1 << r.v)-1
    for i in range(112):
        mask = full if i < 100 else (0 if i == 100 else rng.randrange(full + 1))
        xs = [rng.randrange(-(1 << 31), 1 << 31) if i % 4 else 0 for _ in range(r.v)]
        await r.frame(mask, xs, poison=(i % 3 == 0))
    await r.frame(full, [0] * r.v)
    dut._log.info("independent poly review: V=%d N=%d, %d frames, %d state commits, max %d cycles",
                  r.v, r.nmax, r.frames, r.commits, r.max_cycles)


@cocotb.test()
async def failed_load_retains_history_and_atomic_bad_frame(dut):
    r = EngineReview(dut)
    if r.nmax == 1:
        await r.tiny_structure_rejections()
        return
    await r.reset()
    # Find a known legal row for this structure.
    rows = [(inst, int(k.split('|')[0]), int(k.endswith('|forte')))
            for inst, name in enumerate(INSTRUMENTS)
            for k, meta in json.loads((ROOT / f"FFT_results/params/{name}_coeffindex.json").read_text()).items()
            if meta['n_modes'] <= r.nmax]
    assert rows
    await r.load(0, *rows[0])
    await r.frame(1, [1 << 29] + [0] * (r.v-1))
    if r.v > 1:
        await r.rejected_frame(1 | (1 << (r.v-1)))
    await r.frame(1, [0] * r.v)
    for _ in range(3):
        await r.load(0, 1, 0, 1, expected_error=2)
        await r.frame(1, [0] * r.v)
    await r.load(0, *rows[-1])
    await r.frame(1, [1 << 27] + [0] * (r.v-1))
    await r.frame(1, [0] * r.v)
    dut._log.info('independent atomic-rejection and failed-load state preservation passed')


@cocotb.test()
async def resets_cancel_loads_and_running_frames(dut):
    r = EngineReview(dut)
    if r.nmax == 1:
        await r.tiny_structure_rejections()
        return
    rows = [(inst, int(k.split('|')[0]), int(k.endswith('|forte')))
            for inst, name in enumerate(INSTRUMENTS)
            for k, meta in json.loads((ROOT / f"FFT_results/params/{name}_coeffindex.json").read_text()).items()
            if meta['n_modes'] <= r.nmax]
    chosen = (1, 21, 1) if r.nmax == 48 else rows[0]
    for delay in (0, 1, 3, 8, 20):
        await r.reset()
        await r.idle()
        z = await r.tick(load_valid=1, load_voice=0, load_instrument=chosen[0],
                         load_midi=chosen[1], load_dyn=chosen[2], load_vel=255)
        assert z['accepted']['load']
        for _ in range(delay):
            await r.tick()
        await r.reset()
        for _ in range(220):
            z = await r.tick()
            assert not (z['load_done'] or z['commit_valid'] or z['out_valid'])
        await r.load(0, *chosen)
        await r.frame(1, [1 << 29] + [0] * (r.v-1))
    # Include the final voice as well as the first: nonzero voice address bits.
    for delay in (0, 2, 12, 35):
        await r.reset()
        await r.load(0, *chosen)
        if r.v > 1:
            await r.load(r.v-1, *chosen)
        await r.idle()
        z = await r.tick(sample_valid=1, active_mask=1 | (1 << (r.v-1)), x_vec=(1 << 29))
        assert z['accepted']['sample']
        for _ in range(delay):
            await r.tick()
        await r.reset()
        for _ in range(128):
            z = await r.tick()
            assert not (z['load_done'] or z['commit_valid'] or z['out_valid'])
    dut._log.info('independent reset cancellation across lookup/write/compute passed')


if __name__ == '__main__':
    from cocotb_tools.runner import get_runner
    from _review_source_snapshot import freeze_sources
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--voices', type=int, default=32, choices=range(1, 33))
    p.add_argument('--n-modes', type=int, default=48, choices=range(1, 49))
    p.add_argument('--skip-zero-input', type=int, default=1, choices=(0, 1))
    p.add_argument('--build-dir', type=Path, default=ROOT / 'sim/build/modal_engine_review')
    p.add_argument('--frozen-sources', type=Path,
                   help='review a versioned parent source snapshot, not current RTL')
    a = p.parse_args()
    build = a.build_dir.expanduser().resolve()
    build.mkdir(parents=True, exist_ok=True)
    runner = get_runner('icarus')
    sources = [ROOT / 'rtl/core' / f for f in ('class_format_pkg.sv', 'class_loader.sv', 'class_loader64.sv', 'class_loader_mux.sv', 'b_a1_refresh.sv', 'b_a1_engine.sv', 'poly_modal_lane.sv',
                                              'modal_poly_bank.sv', 'modal_engine.sv')]
    if a.frozen_sources:
        sources = [a.frozen_sources.resolve() / source.relative_to(ROOT) for source in sources]
    sources = freeze_sources(sources, build)
    runner.build(sources=sources, hdl_toplevel='modal_engine', build_dir=build,
                 parameters={'NUM_VOICES': a.voices, 'N_MODES': a.n_modes,
                             'SKIP_ZERO_INPUT': a.skip_zero_input},
                  build_args=['-g2012', '-Wall'], always=True)
    (build / 'review.xml').unlink(missing_ok=True)
    xml = runner.test(hdl_toplevel='modal_engine', test_module=Path(__file__).stem,
                      test_dir=ROOT, build_dir=build, results_xml=str(build / 'review.xml'),
                      extra_env={'REVIEW_N_MODES': str(a.n_modes)})
    cases = ET.parse(xml).findall('.//testcase')
    if len(cases) != 3 or any(c.find('failure') is not None or c.find('error') is not None
                             or c.find('skipped') is not None for c in cases):
        raise SystemExit(1)
