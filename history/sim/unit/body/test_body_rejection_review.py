"""Parent independent rejection tests for body parameters and bad ROM images."""
from __future__ import annotations
import argparse
from pathlib import Path

import cocotb
from cocotb.triggers import Timer

ROOT = Path(__file__).resolve()
while not ((ROOT / "rtl").is_dir() and (ROOT / "sim").is_dir()):
    ROOT = ROOT.parent
import sys as _sim_sys  # noqa: E402
_sim_sys.path.insert(0, str(ROOT / "sim" / "support"))
from _sim_paths import bootstrap as _sim_bootstrap  # noqa: E402
ROOT = _sim_bootstrap(__file__)


@cocotb.test(timeout_time=10, timeout_unit='sec')
async def invalid_body_stays_unready_and_reports_error(d):
    d.clk.value = 0
    d.rst_n.value = 0
    d.clear_valid.value = 1
    d.in_valid.value = 1
    d.in_sum.value = (1 << 63)-1
    for round_number in range(2):
        d.rst_n.value = 0
        await Timer(5, unit='ns')
        d.clk.value = 1
        await Timer(5, unit='ns')
        assert not int(d.out_valid.value)
        d.rst_n.value = 1
        for _ in range(64):
            d.clk.value = 0
            await Timer(5, unit='ns')
            assert not int(d.in_ready.value), 'bad body acknowledged a sample'
            assert not int(d.clear_ready.value)
            d.clk.value = 1
            await Timer(5, unit='ns')
            assert not int(d.out_valid.value), 'bad body emitted a fabricated sample'
            assert not int(d.coeff_ready.value)
        assert int(d.coeff_error.value) == 1
        d._log.info('Independent invalid body: reset/retry %d remains blocked with explicit error',
                    round_number)


def main():
    from _test_runner import build_and_run
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--build-dir', default='/tmp/opencode/body-review/parent-rejection')
    a = ap.parse_args()
    base = Path(a.build_dir).resolve()
    base.mkdir(parents=True, exist_ok=True)
    short = base / 'short_test_only.mem'
    short.write_text('40000000\n00000000\n00000000\n')
    for name, instrument, image in (
        ('negative-instrument', -1, ROOT / 'rtl/rom/body_coeff.mem'),
        ('high-instrument', 4, ROOT / 'rtl/rom/body_coeff.mem'),
        ('missing-image', 0, base / 'intentionally_absent.mem'),
        ('short-image', 0, short),
    ):
        build_and_run([str(ROOT / 'rtl/core/body_filter.sv')], 'body_filter',
                      Path(__file__).stem, str(ROOT), str(base / name),
                      dict(BODY_INSTRUMENT=instrument, BODY_FILE='"'+str(image)+'"'), {})


if __name__ == '__main__':
    main()
