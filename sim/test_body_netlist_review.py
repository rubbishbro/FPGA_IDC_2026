"""Parent original-SOS golden vs REAL Gowin synthesis netlist/vendor primitives.

No RTL fallback or mocked multiplier/ROM. Scope is the isolated guitar body
netlist only, zero-delay vendor functional models, not routed SDF or board audio.
Its original harness tied clear=0 and constant-folded coeff_error: this test
explicitly excludes clear/bad-ROM rejection (already checked against RTL).
"""
from __future__ import annotations
import argparse
from pathlib import Path
import random
import xml.etree.ElementTree as ET

import cocotb

from test_body_filter_review import HIGH, LOW, ROOT, Review, signed


class NetlistReview(Review):
    async def frame(self, value, poison=False):
        for _ in range(8):
            if int(self.d.in_ready.value):
                break
            assert not (await self.tick())['out']
        else:
            raise AssertionError('netlist ready did not recover')
        wanted, mask = self.step(value)
        result = await self.tick(in_valid=1, in_sum=value)
        assert result['accepted']
        for latency in range(129):
            if result['out']:
                self.samples += 1
                self.maximum = max(self.maximum, latency)
                self.saturations += mask.bit_count()
                assert signed(self.d.out_sum.value, 64) == wanted, (
                    self.samples, signed(self.d.out_sum.value, 64), wanted)
                assert int(self.d.out_sat.value) == mask
                assert int(self.d.sat_count.value) == mask.bit_count()
                return
            result = await self.tick(in_valid=int(poison and not result['ready']),
                                     in_sum=LOW + latency * 713)
            assert not result['accepted'], 'netlist consumed busy input'
        raise AssertionError('netlist exceeds 128-cycle contract')


@cocotb.test(timeout_time=600, timeout_unit='sec')
async def original_guitar_sos_vs_gowin_netlist(d):
    r = NetlistReview(d)
    await r.reset()
    assert int(d.coeff_ready.value) and not int(d.coeff_error.value)
    rng = random.Random(0x60B0)
    values = [0, 1 << 30] + [0]*128 + [-(1 << 30)] + [0]*128
    values += [13 << 30]*32 + [-(13 << 30)]*32
    values += [rng.randrange(-(32 << 30), 32 << 30) for _ in range(1024)]
    values += [HIGH, LOW, HIGH, LOW] + [rng.randrange(LOW, HIGH) for _ in range(96)]
    # Exercise the actual mapped section/final clamps at both polarities, not
    # merely a few full-scale inputs whose filtered responses may stay in range.
    values += [HIGH]*64 + [LOW]*64 + [HIGH, LOW]*64
    for i, value in enumerate(values):
        await r.frame(value, poison=(i % 17 == 0))
    for phase in (0, 2, 3, 15, 31, 60, 71, 72, 73, 74, 75):
        await r.reset()
        assert (await r.tick(in_valid=1, in_sum=1 << 42))['accepted']
        for _ in range(phase):
            await r.tick()
        await r.reset()
        for value in (0, -(1 << 30), 0):
            await r.frame(value)
    assert r.saturations > 0, 'mapped saturation logic was not exercised'
    d._log.info('Independent REAL Gowin guitar body netlist: %d exact public outputs, '
                '%d saturation sections, max latency %d cycles; ORIGINAL SOS golden, '
                'unmodified vendor DSP/SDPB models, clear tied0 by original synthesis; '
                'no routed SDF/board claim',
                r.samples, r.saturations, r.maximum)


def main():
    from _review_source_snapshot import freeze_sources
    from cocotb_tools.runner import Verilog, get_runner
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--netlist', type=Path, required=True)
    ap.add_argument('--vendor-library', type=Path,
                    default=Path('/home/rubbishbro/gowin/IDE/simlib/gw5a/prim_sim.v'))
    ap.add_argument('--build-dir', type=Path, default=Path('/tmp/opencode/body-review/parent-netlist-v3'))
    a = ap.parse_args()
    build = a.build_dir.resolve()
    sources = freeze_sources([a.netlist, a.vendor_library,
                              ROOT/'sim/audio_helpers/body_netlist_review_top.sv'], build)
    runner = get_runner('icarus')
    # Third-party primitive models are compiled unmodified. Their diagnostics
    # are retained in the run log, not silently filtered or patched.
    runner.build(sources=[Verilog(p) for p in sources], hdl_toplevel='body_netlist_review_top', build_dir=build,
                 build_args=['-g2012', '-Wall'], always=True)
    (build/'results.xml').unlink(missing_ok=True)
    xml = runner.test(hdl_toplevel='body_netlist_review_top',
                      test_module=Path(__file__).stem, test_dir=ROOT, build_dir=build,
                      results_xml=str(build/'results.xml'),
                      extra_env={'BODY_REVIEW_INSTRUMENT': '0'})
    cases = ET.parse(xml).findall('.//testcase')
    if len(cases) != 1 or any(c.find(tag) is not None for c in cases
                              for tag in ('failure', 'error', 'skipped')):
        raise SystemExit('Netlist review requires exactly one non-skipped passing case')


if __name__ == '__main__':
    main()
