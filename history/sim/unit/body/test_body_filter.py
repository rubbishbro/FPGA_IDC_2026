"""cocotb unit tests for rtl/core/body_filter.sv (shared 4-biquad body filter).

Independent of the parent review: this file re-derives the DFI-Q34 golden from
the *original* ``Patch.sos`` through ``body_fixed_point.BodyFixedPoint`` and
checks, for every frame, both the public output (out_sum/out_sat/sat_count) and
the internal per-section history (x1/x2/y1/y2) bit-for-bit.  It also covers the
missing-ROM guard, reset/clear priority, busy poisoning and the <=128-cycle
latency bound.

Artefacts go under an absolute build directory (default
/tmp/opencode/body-implementation/body_filter); ``sim/results.xml`` is never
written.  Four instrument builds + one bad-ROM build are all gated on a
non-empty, failure-free XML.
"""

from __future__ import annotations

import argparse
import os
import random
import sys

import cocotb
from cocotb.triggers import Timer

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = _HERE
while not (os.path.isdir(os.path.join(_ROOT, "rtl"))
           and os.path.isdir(os.path.join(_ROOT, "sim"))):
    _ROOT = os.path.dirname(_ROOT)
sys.path.insert(0, os.path.join(_ROOT, "sim", "support"))
from _sim_paths import bootstrap as _sim_bootstrap  # noqa: E402
_ROOT = str(_sim_bootstrap(__file__))
sys.path.insert(0, os.path.join(_ROOT, "python", "modal_sim"))

from params import Patch                       # noqa: E402
from body_fixed_point import BodyFixedPoint    # noqa: E402

NAMES = ("guitar", "piano", "banjo", "mandolin")
I = int(os.environ.get("BODY_TEST_INSTRUMENT", "0"))
GUARD = 4
SW = 64 + GUARD
LOW64, HIGH64 = -(1 << 63), (1 << 63) - 1


def _s(v, width):
    v = int(v)
    return v - (1 << width) if v & (1 << (width - 1)) else v


class Harness:
    def __init__(self, dut, instrument=None):
        self.d = dut
        inst = I if instrument is None else instrument
        self.model = BodyFixedPoint(sos=Patch(NAMES[inst]).sos, guard_bits=GUARD)
        self.max_cycles = 0
        self.samples = 0
        self.sats = 0

    async def tick(self, **updates):
        fields = dict(rst_n=1, clear_valid=0, in_valid=0, in_sum=0)
        fields.update(updates)
        self.d.clk.value = 0
        for key, value in fields.items():
            h = getattr(self.d, key)
            h.value = value & ((1 << len(h)) - 1)
        await Timer(5, unit="ns")
        accepted = bool(fields["rst_n"] and fields["in_valid"]
                        and int(self.d.in_ready.value))
        cleared = bool(fields["rst_n"] and fields["clear_valid"]
                       and int(self.d.clear_ready.value))
        self.d.clk.value = 1
        await Timer(5, unit="ns")
        return dict(accepted=accepted, cleared=cleared,
                    out=bool(int(self.d.out_valid.value)),
                    ready=bool(int(self.d.in_ready.value)))

    async def reset(self):
        for _ in range(3):
            z = await self.tick(rst_n=0, in_valid=1, in_sum=HIGH64)
            assert not z["accepted"] and not z["out"], "reset advertised a sample"
        self.model.reset()
        for _ in range(256):
            z = await self.tick()
            assert not z["out"], "ghost out_valid after reset"
            if z["ready"]:
                return
        raise AssertionError("body not ready after reset/ROM preload")

    def _check_states(self, tag):
        for s in range(4):
            want = self.model.state[s]
            for name, w in (("x1", want[0]), ("x2", want[1]),
                            ("y1", want[2]), ("y2", want[3])):
                node = getattr(self.d, name)[s]
                assert node.value.is_resolvable, f"{tag}: X on {name}[{s}]"
                got = _s(node.value, SW)
                assert got == w, f"{tag}: {name}[{s}] {got} != {w}"

    async def frame(self, value, poison=False, check_states=True):
        for _ in range(8):
            if int(self.d.in_ready.value):
                break
            z = await self.tick()
            assert not z["out"]
        else:
            raise AssertionError("ready failed to recover after output")

        want, mask, nsat = self.model.process_sample(value)
        z = await self.tick(in_valid=1, in_sum=value)
        assert z["accepted"], "frame not accepted"
        for cycle in range(129):
            if z["out"]:
                got = _s(self.d.out_sum.value, 64)
                assert got == want, (self.samples, want, got)
                assert int(self.d.out_sat.value) == mask, (self.samples, mask,
                                                           int(self.d.out_sat.value))
                assert int(self.d.sat_count.value) == nsat
                if check_states:
                    self._check_states(self.samples)
                self.max_cycles = max(self.max_cycles, cycle)
                self.samples += 1
                self.sats += nsat
                # out_valid must be a single cycle
                z2 = await self.tick()
                assert not z2["out"], "out_valid lasted more than one cycle"
                return
            z = await self.tick(in_valid=int(poison and not z["ready"]),
                                in_sum=LOW64 + cycle * 31337)
            assert not z["accepted"], "accepted a second frame while busy"
        raise AssertionError("body latency exceeds 128 core cycles")


@cocotb.test(timeout_time=1200, timeout_unit="sec")
async def body_patterns_and_state(d):
    """Impulse/negative impulse/step/alternating/random + saturation stress."""
    r = Harness(d)
    await r.reset()
    rng = random.Random(0x5EED + I)

    seq = [0, 1 << 30, 0, 0, -(1 << 30), 0, 0]                 # impulse pair
    seq += [3 << 30] * 48 + [0] * 24                            # step + release
    seq += [(1 if k % 2 else -1) * (5 << 30) for k in range(256)]  # alternating
    seq += [rng.randrange(-(16 << 30), 16 << 30) for _ in range(4096)]
    seq += [0] * 512                                            # silence tail
    for k, v in enumerate(seq):
        await r.frame(v, poison=(k % 23 == 0))

    # full signed64 range -> guaranteed positive/negative final saturation
    stress = [HIGH64, LOW64] * 8
    stress += [rng.randrange(LOW64, HIGH64) for _ in range(4096)]
    for v in stress:
        await r.frame(v, poison=True)

    assert r.max_cycles <= 128, f"latency {r.max_cycles} > 128"
    assert r.sats > 0, "expected at least one section saturation in the stress"
    d._log.info(f"body_patterns_and_state {NAMES[I]}: {r.samples} frames exact "
                f"(state + out), max {r.max_cycles} cycles, {r.sats} saturations")


@cocotb.test(timeout_time=600, timeout_unit="sec")
async def body_clear_reset_busy(d):
    r = Harness(d)
    await r.reset()

    for x in (1 << 30, -(1 << 30), 7 << 30, 0):
        await r.frame(x)

    # clear accepted only when idle, clears history, keeps coefficients
    while not int(d.clear_ready.value):
        await r.tick()
    z = await r.tick(clear_valid=1)
    assert z["cleared"] and not z["out"], "clear handshake wrong"
    r.model.clear()
    r._check_states("after clear")
    for x in (0, 1 << 30, 0):
        await r.frame(x)

    # busy poisoning: a held in_sum with valid high while busy must not change
    # the accepted frame (frame() already drives poison every 23rd, repeat here)
    await r.frame(11 << 30, poison=True)
    await r.frame(-(11 << 30), poison=True)

    # reset aborts computation at every pipeline phase, with no ghost output.
    # Phase list covers S_OP/S_MUL/S_ACC of each tap, the section boundaries and
    # the round/output stages of the pipelined implementation.
    for phase in (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 15, 16, 17, 31, 32, 33,
                  47, 48, 63, 64, 65, 66, 67, 70, 90):
        await r.reset()
        z = await r.tick(in_valid=1, in_sum=1 << 40)
        assert z["accepted"]
        for _ in range(phase):
            z = await r.tick()
            # an output may legitimately appear at late phases, but a *reset*
            # right after must not leave any valid/ready inconsistency.
        await r.reset()
        for x in (0, -(1 << 30), 0, 0):
            await r.frame(x)

    d._log.info(f"body_clear_reset_busy {NAMES[I]}: clear/reset/busy priority OK")


async def _dead_config_probe(d):
    """Reset and require: coeff_error set, never ready, never any output."""
    d.clk.value = 0
    d.rst_n.value = 0
    d.clear_valid.value = 0
    d.in_valid.value = 0
    d.in_sum.value = 0
    for _ in range(6):
        d.clk.value = 0
        await Timer(5, unit="ns")
        d.clk.value = 1
        await Timer(5, unit="ns")
    d.rst_n.value = 1
    saw_error = False
    for _ in range(400):
        d.clk.value = 0
        await Timer(5, unit="ns")
        d.clk.value = 1
        await Timer(5, unit="ns")
        if int(d.coeff_error.value):
            saw_error = True
        assert int(d.out_valid.value) == 0, "output from a dead configuration"
        if saw_error:
            assert int(d.in_ready.value) == 0, "ready with a dead configuration"
            assert int(d.coeff_ready.value) == 0
    assert saw_error, "dead configuration not detected (coeff_error stayed 0)"


@cocotb.test(timeout_time=120, timeout_unit="sec")
async def body_rom_missing(d):
    """A short/absent init file must not fake a valid all-zero filter."""
    await _dead_config_probe(d)
    d._log.info("body_rom_missing: broken ROM detected, no fake filtering")


@cocotb.test(timeout_time=120, timeout_unit="sec")
async def body_bad_instrument(d):
    """A negative / out-of-range BODY_INSTRUMENT must be rejected, not wrapped."""
    await _dead_config_probe(d)
    d._log.info("body_bad_instrument: invalid BODY_INSTRUMENT rejected")


# ---------------------------------------------------------------------------
# runner
# ---------------------------------------------------------------------------
def _rom_dir():
    return os.path.join(_ROOT, "rtl", "rom")


def _run(build_dir, params, env, testcase):
    sys.path.insert(0, _HERE)
    from _test_runner import build_and_run
    return build_and_run([os.path.join(_ROOT, "rtl", "core", "body_filter.sv")],
                         "body_filter", "test_body_filter", _ROOT,
                         os.path.abspath(build_dir), params, env,
                         testcase=testcase)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--build-dir",
                    default="/tmp/opencode/body-implementation/body_filter")
    args = ap.parse_args(argv)
    base = os.path.abspath(os.path.expanduser(args.build_dir))
    sys.path.insert(0, _HERE)

    total = 0
    try:
        for inst in range(4):
            params = dict(BODY_INSTRUMENT=inst,
                          BODY_FILE='"' + os.path.join(_rom_dir(), "body_coeff.mem") + '"')
            env = {"BODY_TEST_INSTRUMENT": str(inst)}
            for tc in ("body_patterns_and_state", "body_clear_reset_busy"):
                summary = _run(os.path.join(base, f"inst{inst}", tc), params, env, tc)
                total += summary["n"]

        # broken ROM: a file with only a few words leaves the rest X
        bad_dir = os.path.join(base, "badrom")
        os.makedirs(bad_dir, exist_ok=True)
        bad_mem = os.path.join(bad_dir, "bad_body.mem")
        with open(bad_mem, "w", encoding="utf-8") as fh:
            fh.write("3BE8A7C1\nE6887C48\n21DAB435\n")
        params = dict(BODY_INSTRUMENT=0, BODY_FILE='"' + bad_mem + '"')
        summary = _run(os.path.join(bad_dir, "run"), params, {}, "body_rom_missing")
        total += summary["n"]

        # negative instrument must be rejected, never wrapped by &3 to mandolin
        neg_dir = os.path.join(base, "badinst")
        os.makedirs(neg_dir, exist_ok=True)
        params = dict(BODY_INSTRUMENT=-1,
                      BODY_FILE='"' + os.path.join(_rom_dir(), "body_coeff.mem") + '"')
        summary = _run(os.path.join(neg_dir, "run"), params, {},
                       "body_bad_instrument")
        total += summary["n"]
    except RuntimeError as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        return 1

    print(f"[body_filter] {total} test cases passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
