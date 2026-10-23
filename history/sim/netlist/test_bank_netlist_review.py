"""Independent REAL-Gowin-synthesis netlist check of the isolated modal bank.

Scope and honesty
-----------------
* Synthesizes ONLY the frozen v4 ``modal_poly_bank`` core (plus its
  ``poly_modal_lane`` child) with the installed Gowin ``gw_sh``/GowinSynthesis.
  No P&R, no bitstream, no Programmer, no SDC/CST, so this claims NO static
  timing analysis.
* Simulates the resulting vendor-primitive netlist with the UNMODIFIED vendor
  ``gw5a/prim_sim.v`` and the reused cocotb golden model
  (``test_modal_poly_bank_review.BankReview`` / ``EngineReview``) driven only
  through the public ports.
* This is an INDEPENDENT re-synthesis of an isolated bank. It is NOT a rewrite
  of, and does NOT establish equivalence with, the production song netlist or
  bitstream. It only supplements the production song netlist's first-note test
  scope. It is not full STA and not a board result.

``SKIP_ZERO_INPUT``: the Gowin CLI cannot override a top module's parameters,
so ``--skipzero 1`` (default, the production value) synthesizes the real bank
unmodified inside a one-instance transparent harness, while ``--skipzero 0``
synthesizes ``modal_poly_bank`` directly as the top. Both keep every public
cfg/clear/sample/commit/voice/mix/error port; the netlist top is parsed and its
port names/directions/widths are verified, never guessed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
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
for _extra in (ROOT / "sim/unit/core", ROOT / "python/modal_sim"):
    if str(_extra) not in sys.path:
        sys.path.insert(0, str(_extra))

# Reused cocotb tests (public-port only) and their golden model. The third test
# of that module inspects internal RTL state / vendor RAM shape and is therefore
# intentionally NOT imported; a public-contract replacement is defined below.
from test_modal_poly_bank_review import (  # noqa: E402,F401
    BankReview,
    counts_zero_tail_history_and_targeted_clear,
    full_range_saturation_count_and_64bit_sum,
)
from fixed_point import pack_word  # noqa: E402

DEFAULT_SNAPSHOT = Path("/tmp/opencode/song-control-core100-v4-20261007/parent_source_snapshot")
DEFAULT_EVIDENCE = Path("/tmp/opencode/song-bank-netlist-ds")
DEFAULT_VENDOR = Path.home() / "gowin/IDE/simlib/gw5a/prim_sim.v"

# Public contract of the bank (order as declared in RTL).
INPUT_PORTS = {
    "clk": 1, "rst_n": 1, "cfg_valid": 1, "cfg_voice": "VW", "cfg_mode": "MW",
    "cfg_word": 72, "clear_valid": 1, "clear_voice": "VW", "sample_valid": 1,
    "active_mask": "NV", "n_modes_vec": "NV*MW", "x_vec": "NV*32",
}
OUTPUT_PORTS = {
    "cfg_ready": 1, "clear_ready": 1, "clear_done": 1, "sample_ready": 1,
    "busy": 1, "out_valid": 1, "mix_sum": 64, "sat_count": "SW",
    "voice_valid": 1, "voice_id": "VW", "voice_sum": 64, "error_valid": 1,
    "error_code": 2, "commit_valid": 4, "commit_voice": "4*VW",
    "commit_mode": "4*MW", "commit_y1": 128, "commit_y2": 128, "commit_sat": 4,
}
PORT_ORDER = [
    "clk", "rst_n", "cfg_valid", "cfg_ready", "cfg_voice", "cfg_mode", "cfg_word",
    "clear_valid", "clear_ready", "clear_voice", "clear_done", "sample_valid",
    "sample_ready", "active_mask", "n_modes_vec", "x_vec", "busy", "out_valid",
    "mix_sum", "sat_count", "voice_valid", "voice_id", "voice_sum", "error_valid",
    "error_code", "commit_valid", "commit_voice", "commit_mode", "commit_y1",
    "commit_y2", "commit_sat",
]
EXPECTED_TEST_NAMES = {
    "full_range_saturation_count_and_64bit_sum",
    "counts_zero_tail_history_and_targeted_clear",
    "public_holes_rejection_history_and_coeff_retention",
}


def _clog2(n: int) -> int:
    return max(1, int(n).bit_length()) if int(n) > 1 else 1


def _dimensions(voices: int, n_modes: int):
    vw = 1 if voices < 2 else (voices - 1).bit_length()
    mw = _clog2(n_modes)  # $clog2(N_MODES+1)
    sw = _clog2(voices * n_modes)  # $clog2(N*M+1)
    return vw, mw, sw


def _resolve_width(spec, vw, mw, sw, voices, n_modes):
    if isinstance(spec, int):
        return spec
    env = {"VW": vw, "MW": mw, "SW": sw, "NV": voices}
    expr = spec.replace("*", "*")
    for key, val in env.items():
        expr = re.sub(rf"\b{key}\b", str(val), expr)
    return int(eval(expr, {"__builtins__": {}}, {}))  # noqa: S307 - trusted literal table


def _expected_signature(voices: int, n_modes: int):
    vw, mw, sw = _dimensions(voices, n_modes)
    sig = {}
    for name in PORT_ORDER:
        if name in INPUT_PORTS:
            sig[name] = ("input", _resolve_width(INPUT_PORTS[name], vw, mw, sw, voices, n_modes))
        else:
            sig[name] = ("output", _resolve_width(OUTPUT_PORTS[name], vw, mw, sw, voices, n_modes))
    return sig


# ---------------------------------------------------------------------------
# netlist parsing / wrapper generation
# ---------------------------------------------------------------------------
_MOD_DECL = re.compile(r"\bmodule\s+(\w+)\s*\((.*?)\)\s*;", re.S)
_DIR_DECL = re.compile(
    r"^\s*(input|output|inout)\s+(?:\[([^\]]+)\]\s+)?([\\A-Za-z_$][\w$\\]*)\s*;"
)


def _parse_modules(text):
    """Return [(name, ordered port names, dict name->(dir,width))] for every module."""
    text = re.sub(r"//[^\n]*", "", text)
    modules = []
    for m in _MOD_DECL.finditer(text):
        name = m.group(1)
        raw = m.group(2)
        ports = []
        for token in raw.split(","):
            token = token.strip()
            if not token:
                continue
            token = re.sub(r"^\[[^\]]*\]\s*", "", token)
            ports.append(token)
        body = text[m.end():]
        stop = body.find("\nendmodule")
        if stop >= 0:
            body = body[:stop]
        decls = {}
        for line in body.splitlines():
            d = _DIR_DECL.match(line)
            if not d:
                continue
            rng = d.group(2)
            width = 1
            if rng:
                msb, _, lsb = rng.partition(":")
                msb = int(msb.strip())
                lsb = int(lsb.strip()) if lsb.strip() else msb
                width = abs(msb - lsb) + 1
            decls[d.group(3)] = (d.group(1), width)
        modules.append((name, ports, decls))
    return modules


def _find_netlist_top(text, expected: dict):
    wanted = set(expected)
    matches = [(n, p, d) for (n, p, d) in _parse_modules(text)
               if set(p) == wanted and set(d) == wanted]
    if len(matches) != 1:
        names = [n for n, _, _ in _parse_modules(text)]
        raise SystemExit(
            "Refuse to guess the synthesized top: expected exactly one module with "
            f"the public bank ports, found {len(matches)}. modules={names}")
    name, ports, decls = matches[0]
    ordered = [(p, decls[p][0], decls[p][1]) for p in ports]
    # verify exact direction/width against the RTL-derived contract
    for p, direction, width in ordered:
        edir, ewidth = expected[p]
        assert direction == edir, (p, direction, edir)
        assert width == ewidth, (p, width, ewidth)
    return name, ordered


def _emit_wrapper(net_top, ordered):
    out = [
        "`timescale 1ns/1ps",
        "// TEST ONLY: generated by sim/netlist/test_bank_netlist_review.py.",
        f"// Adapter for the exact synthesized `{net_top}` port names plus the",
        "// UNMODIFIED vendor GSR primitive. No arithmetic is replaced.",
        "module bank_gate (",
    ]
    for i, (n, direction, width) in enumerate(ordered):
        kind = "input logic" if direction == "input" else "output wire"
        rng = "" if width == 1 else f"[{width - 1}:0] "
        out.append(f"    {kind} {rng}{n}{',' if i + 1 < len(ordered) else ''}")
    out.append(");")
    out.append("    GSR GSR (.GSRI(1'b1));")
    out.append(f"    {net_top} u_netlist (")
    for i, (n, _, _) in enumerate(ordered):
        out.append(f"        .{n}({n}){',' if i + 1 < len(ordered) else ''}")
    out.append("    );")
    out.append("endmodule")
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------------------
# shared helpers for the public-contract test
# ---------------------------------------------------------------------------
def _lowest_missing(loaded, nmax):
    k = 0
    while k < nmax and k in loaded:
        k += 1
    return k


class _Recorder(BankReview):
    """BankReview that also records every public (voice,mode,y1,y2,sat) commit."""

    def __init__(self, d):
        super().__init__(d)
        self.record = []

    async def tick(self, **updates):
        z = await super().tick(**updates)
        for commit in z.get("commits", ()):
            self.record.append(commit)
        return z


async def _cfg(r, voice, mode, word):
    await r.idle()
    z = await r.tick(cfg_valid=1, cfg_voice=voice, cfg_mode=mode, cfg_word=word)
    assert z["accepted"]["cfg"] and not z["error_valid"] and not z["busy"]
    return z


async def _reject_sample(r, code, mask, counts, x):
    """A rejected frame must reject ON the handshake edge with no stall/side effect."""
    await r.idle()
    for second in (0, 1):
        xv = x if second == 0 else ((1 << (len(r.d.x_vec))) - 2)
        z = await r.tick(sample_valid=1, active_mask=mask, n_modes_vec=counts, x_vec=xv)
        assert z["accepted"]["sample"], "rejection was not on the handshake edge"
        assert z["error_valid"] and z["error_code"] == code, ("bad reject code", code, z)
        assert not z["busy"], "rejected frame made the bank busy"
        assert not (z["commit_valid"] or z["out_valid"] or z["voice_valid"]), \
            "rejected frame emitted operational output"
        for name in ("sample_ready", "cfg_ready", "clear_ready"):
            assert int(getattr(r.d, name).value), "rejection inserted a stall: " + name
        # second rejection on the very next edge with no idle gap
    return z


async def _reject_cfg(r, voice, mode, code=1):
    await r.idle()
    for _ in range(2):
        z = await r.tick(cfg_valid=1, cfg_voice=voice, cfg_mode=mode, cfg_word=0)
        assert z["accepted"]["cfg"] and z["error_valid"] and z["error_code"] == code
        assert not z["busy"] and not (z["commit_valid"] or z["out_valid"] or z["voice_valid"])
        # check all three ready every edge: cfg/clear released, sample withheld
        assert int(r.d.cfg_ready.value) and int(r.d.clear_ready.value)
        assert not int(r.d.sample_ready.value), "cfg handshake wrongly presented sample_ready"
    return z


def _shuffled(n, seed):
    seq = list(range(n))
    random.Random(seed).shuffle(seq)
    return seq


def _one(v, x, v_total):
    return [x if i == v else 0 for i in range(v_total)]


async def _next_edge_reject(r, code, mask, counts, x):
    """Reject on the IMMEDIATE next edge after a cfg (no idle tick), twice."""
    for second in (0, 1):
        xv = x if second == 0 else ((1 << len(r.d.x_vec)) - 2)
        z = await r.tick(sample_valid=1, active_mask=mask, n_modes_vec=counts, x_vec=xv)
        assert z["accepted"]["sample"], "immediate rejection was not on the next handshake edge"
        assert z["error_valid"] and z["error_code"] == code, ("bad reject code", code, z)
        assert not z["busy"], "rejection made the bank busy"
        assert not (z["commit_valid"] or z["out_valid"] or z["voice_valid"]), \
            "rejection emitted operational output"
        for name in ("sample_ready", "cfg_ready", "clear_ready"):
            assert int(getattr(r.d, name).value), "rejection inserted a stall: " + name
    return z


async def _immediate_frame(r, v, word_list, x):
    """Frame on the immediate next clock edge after a completed cfg (no idle cycle).

    The cfg input is deasserted and one delta is allowed to settle the purely
    combinational ready, but no clock edge is generated before the frame's own
    handshake edge, so the frame sees the just-updated cfg summary on the very
    next edge.
    """
    r.words[v] = word_list
    r.d.cfg_valid.value = 0
    await Timer(1, unit="ns")
    await r.frame(1 << v, _one(v, x, r.v))


@cocotb.test(timeout_time=1800, timeout_unit="sec")
async def public_holes_rejection_history_and_coeff_retention(dut):
    """Public-port replacement for the internal-state sparse-config test."""
    r = _Recorder(dut)
    assert r.v == 32 and r.nmax == 48, (r.v, r.nmax)
    boundary = sorted({0, r.v // 2, r.v - 1})  # 0, 16, 31
    rows = {
        v: [pack_word(-(1 << 20) + (m * 67 + v * 101), (1 << 23) - (m * 13),
                      (1 << 22) + (m * 29 + v * 57)) for m in range(r.nmax)]
        for v in boundary
    }
    seen_counts = set()

    # ---- A. three cfg orders; after EACH cfg, next-edge prefix+1 reject ----
    orders = [
        ("reverse", list(range(r.nmax))[::-1]),
        ("evenodd", list(range(0, r.nmax, 2)) + list(range(1, r.nmax, 2))),
        ("shuffle", _shuffled(r.nmax, 0x0DDBA11)),
    ]
    for idx, (_name, order) in enumerate(orders):
        await r.reset()
        v = boundary[idx]
        loaded = set()
        for m in order:
            await _cfg(r, v, m, rows[v][m])
            loaded.add(m)
            prefix = _lowest_missing(loaded, r.nmax)
            if prefix < r.nmax:
                cnt = prefix + 1
                seen_counts.add(cnt)
                await _next_edge_reject(r, 3, mask=1 << v, counts=cnt << (v * r.mw), x=1 << 29)
            else:
                # row complete: immediate frame, no idle tick in between
                await _immediate_frame(r, v, rows[v][:], 1 << 28)
        assert _lowest_missing(loaded, r.nmax) == r.nmax
        # re-configuring a present mode must not disturb history
        await _cfg(r, v, order[0], rows[v][order[0]])
        await r.frame(1 << v, _one(v, 1 << 27, r.v))
        # clear drops history but keeps coefficients; frame still legal
        await r.clear(v)
        await r.frame(1 << v, _one(v, 1 << 26, r.v))

    # ---- B. explicit n=16/32/48 holes (15/31/47) and a low hole jump ------
    await r.reset()
    v = boundary[1]  # 16
    holes = (15, 31, 47)
    loaded = set()
    for m in range(r.nmax):
        if m not in holes:
            await _cfg(r, v, m, rows[v][m])
            loaded.add(m)
    assert _lowest_missing(loaded, r.nmax) == 15, "explicit hole layout wrong"
    for c in (16, 32, 48):
        await _reject_sample(r, 3, mask=1 << v, counts=c << (v * r.mw), x=1 << 29)
        seen_counts.add(c)
    # fill 15 -> prefix 31: confirm count 16 is now legal (immediate frame)
    await _cfg(r, v, 15, rows[v][15])
    loaded.add(15)
    assert _lowest_missing(loaded, r.nmax) == 31
    await _immediate_frame(r, v, rows[v][:16], 1 << 28)
    await _cfg(r, v, 31, rows[v][31])
    loaded.add(31)
    assert _lowest_missing(loaded, r.nmax) == 47
    await _immediate_frame(r, v, rows[v][:32], 1 << 28)
    await _cfg(r, v, 47, rows[v][47])
    loaded.add(47)
    assert _lowest_missing(loaded, r.nmax) == r.nmax
    await _immediate_frame(r, v, rows[v][:], 1 << 28)
    # low hole at mode 0: filling it jumps the prefix across 16 and 32
    await r.reset()
    v = boundary[0]  # 0
    loaded = set()
    for m in range(1, r.nmax):
        await _cfg(r, v, m, rows[v][m])
        loaded.add(m)
    assert _lowest_missing(loaded, r.nmax) == 0, "low hole layout wrong"
    await _next_edge_reject(r, 3, mask=1 << v, counts=1 << (v * r.mw), x=1 << 29)
    seen_counts.add(1)
    await _cfg(r, v, 0, rows[v][0])
    loaded.add(0)
    assert _lowest_missing(loaded, r.nmax) == r.nmax
    await _immediate_frame(r, v, rows[v][:], 1 << 28)

    required = {16, 32, 48}
    assert required <= seen_counts, ("required hole counts not rejected", sorted(seen_counts))
    assert 1 in seen_counts, "low-hole prefix+1 was not rejected"

    # ---- C. late-invalid multi-voice: legal voice 0 + partial voice 31 ----
    await r.reset()
    legal, late = 0, boundary[2]  # 0 and 31
    for m in range(r.nmax):
        await _cfg(r, legal, m, rows[legal][m])
    for m in range(3):
        await _cfg(r, late, m, rows[late][m])
    counts = (r.nmax << (legal * r.mw)) | (4 << (late * r.mw))
    await _reject_sample(r, 3, mask=(1 << legal) | (1 << late), counts=counts, x=1 << 29)
    # the rejected frame must not have committed any of legal voice 0
    r.words[legal] = rows[legal][:]
    await r.frame(1 << legal, _one(legal, 1 << 28, r.v))

    # ---- D. baseline vs injected: identical full golden commit streams ----
    frame_voices = (0, 16)
    mask = (1 << frame_voices[0]) | (1 << frame_voices[1])

    async def scenario(inject):
        await r.reset()
        local = random.Random(0x5771)
        for bv in frame_voices:
            for m in _shuffled(r.nmax, 0x1000 + bv):
                await _cfg(r, bv, m, rows[bv][m])
            r.words[bv] = rows[bv][:]
        for m in range(3):
            await _cfg(r, late, m, rows[late][m])

        def xs():
            return [local.randrange(-(1 << 30), 1 << 30) if i in frame_voices else 0
                    for i in range(r.v)]

        streams = []
        r.record.clear()
        await r.frame(mask, xs())
        streams.append(list(r.record))
        if inject:
            await _reject_sample(r, 3, mask=(1 << frame_voices[0]) | (1 << late),
                                 counts=(r.nmax << (frame_voices[0] * r.mw)) | (4 << (late * r.mw)),
                                 x=1 << 29)
            await _reject_sample(r, 2, mask=mask, counts=49 << (frame_voices[1] * r.mw), x=1 << 29)
            await _reject_sample(r, 3, mask=1 << late, counts=4 << (late * r.mw), x=1 << 29)
            await _reject_cfg(r, frame_voices[0], r.nmax, code=1)   # cfg_mode out of range
            await _reject_cfg(r, frame_voices[0], 63, code=1)        # second illegal cfg
        r.record.clear()
        await r.frame(mask, xs())
        streams.append(list(r.record))
        if inject:
            await _reject_sample(r, 3, mask=1 << late, counts=4 << (late * r.mw), x=1 << 29)
        await r.clear(frame_voices[0])                               # history reset, coeff kept
        r.record.clear()
        await r.frame(mask, xs())
        streams.append(list(r.record))
        await r.reset()                                              # reset + reload
        for bv in frame_voices:
            for m in _shuffled(r.nmax, 0x1000 + bv):
                await _cfg(r, bv, m, rows[bv][m])
            r.words[bv] = rows[bv][:]
        r.record.clear()
        await r.frame(mask, xs())
        streams.append(list(r.record))
        return streams

    without = await scenario(inject=False)
    with_reject = await scenario(inject=True)
    assert without == with_reject, "rejections changed the commit history / coefficients"
    assert all(stream for stream in with_reject), "a golden frame produced no commits"
    total = sum(len(s) for s in with_reject)
    dut._log.info(
        "public contract PASS: orders=reverse,evenodd,shuffle; seen_counts=%s; "
        "holes_rejected=16,32,48; low_hole_jump=0; voices=%s all %d modes; "
        "multi_voice_late_reject=yes; rejection_contract=yes; "
        "%d commits identical baseline/injected; clear/reset/reload retained; "
        "max frame %d cycles",
        sorted(seen_counts), ",".join(str(b) for b in boundary), r.nmax, total,
        r.max_cycles)


# ---------------------------------------------------------------------------
# runner
# ---------------------------------------------------------------------------
def _sha256(path: Path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _read_log_tests(xml_path: Path):
    root = ET.parse(xml_path).getroot()
    suites = [root] if root.tag == "testsuite" else root.findall(".//testsuite")
    cases = []
    for suite in suites:
        cases.extend(suite.findall("testcase"))
    names = sorted(c.get("name", "?") for c in cases)
    bad = [c.get("name", "?") for c in cases
           if any(c.find(tag) is not None for tag in ("failure", "error", "skipped"))]
    return names, bad


def _command_string(argv, stdin_text):
    return {"argv": [str(x) for x in argv], "stdin": stdin_text}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--snapshot", type=Path, default=DEFAULT_SNAPSHOT,
                    help="frozen parent_source_snapshot root (default: v4 freeze)")
    ap.add_argument("--evidence-dir", type=Path, default=DEFAULT_EVIDENCE,
                    help="non-overwritable evidence directory (default: song-bank-netlist-ds)")
    ap.add_argument("--skipzero", type=int, default=1, choices=(0, 1),
                    help="1: transparent harness with production SKIP_ZERO_INPUT=1 (default); "
                         "0: synthesize modal_poly_bank directly (SKIP default 0)")
    ap.add_argument("--voices", type=int, default=32)
    ap.add_argument("--n-modes", type=int, default=48)
    ap.add_argument("--gowin-dir", type=Path, default=Path.home() / "gowin")
    ap.add_argument("--vendor-library", type=Path, default=DEFAULT_VENDOR)
    args = ap.parse_args()

    voices, n_modes = args.voices, args.n_modes
    if voices != 32 or n_modes != 48:
        raise SystemExit(
            "only the frozen 32-voice x 48-mode bank is supported: --skipzero 0 does "
            "not pass NUM_VOICES/N_MODES to the top module and the public-contract test "
            f"is defined for 32x48 (got {voices}x{n_modes})")
    for var in ("COCOTB_TESTCASE", "COCOTB_TEST_FILTER", "TESTCASE"):
        if os.environ.get(var):
            raise SystemExit(
                f"refuse to run with test-filter env {var}={os.environ[var]!r}; unset it "
                "so all three tests run")
    vw, mw, sw = _dimensions(voices, n_modes)

    snapshot = args.snapshot.expanduser().resolve()
    bank = snapshot / "rtl/core/modal_poly_bank.sv"
    lane = snapshot / "rtl/core/poly_modal_lane.sv"
    for path in (bank, lane):
        if not path.is_file():
            raise SystemExit(f"missing frozen source (pass --snapshot): {path}")

    base = args.evidence_dir.expanduser().resolve()
    if (base / "result.json").exists():
        raise SystemExit(f"refuse to overwrite completed evidence: {base / 'result.json'}")
    base.mkdir(parents=True, exist_ok=True)
    external = base / "test_only_external"
    external.mkdir(exist_ok=True)

    vendor = args.vendor_library.expanduser().resolve()
    assert vendor.is_file(), f"missing unmodified vendor library: {vendor}"
    gowin = args.gowin_dir.expanduser().resolve()
    gw_sh = gowin / "IDE/bin/gw_sh"
    assert gw_sh.is_file(), f"missing Gowin tool: {gw_sh}"

    # ---- frozen source manifest -------------------------------------------
    source_hashes = {"rtl/core/modal_poly_bank.sv": _sha256(bank),
                     "rtl/core/poly_modal_lane.sv": _sha256(lane)}
    declared = snapshot / "sources.json"
    if declared.is_file():
        frozen = json.loads(declared.read_text())
        for rel, digest in source_hashes.items():
            if rel in frozen:
                assert frozen[rel]["sha256"] == digest, f"snapshot drift: {rel}"
    (base / "source_sha.json").write_text(json.dumps(source_hashes, indent=2) + "\n")

    # ---- synthesis-only Tcl (no PNR, no CST/SDC, no Programmer) -----------
    if args.skipzero:
        harness = external / "bank_gate_top.sv"
        harness.write_text(_emit_synthesis_harness(voices, n_modes, vw, mw, sw))
        top_name = "bank_gate_top"
    else:
        harness = None
        top_name = "modal_poly_bank"
    tcl = external / "bank_synth.tcl"
    build = base / "build"
    proj = "bank_netlist"
    files = [lane, bank] + ([harness] if harness else [])
    tcl.write_text(
        "set build_dir {" + str(build) + "}\n"
        "file mkdir $build_dir\n"
        f"create_project -name {proj} -dir $build_dir -pn GW5AST-LV138FPG676AES "
        "-device_version B -force\n"
        "set_option -verilog_std sysv2017\n"
        f"set_option -top_module {top_name}\n"
        + "".join(f"add_file {{{p}}}\n" for p in files)
        + "puts \"FILES_ADDED\"\n"
        "run syn\n"
        "puts \"BANK_SYN_DONE\"\n"
    )

    env = os.environ.copy()
    env["LD_LIBRARY_PATH"] = str(gowin / "IDE/lib") + ":" + env.get("LD_LIBRARY_PATH", "")
    env["QT_QPA_PLATFORM"] = "minimal"  # headless; Gowin tries GLX otherwise
    flow_log = base / "flow.log"
    with flow_log.open("w") as out:
        proc = subprocess.run([str(gw_sh), "-nocomp"], input=f"source {{{tcl}}}\n",
                              text=True, cwd=str(base), env=env, stdout=out,
                              stderr=subprocess.STDOUT)
    gw_command = _command_string([gw_sh, "-nocomp"], f"source {{{tcl}}}\n")
    log_text = flow_log.read_text(errors="replace")
    assert proc.returncode == 0, f"Gowin synthesis failed: see {flow_log}"
    assert re.search(r"^BANK_SYN_DONE\s*$", log_text, re.M), f"syn did not finish: {flow_log}"
    assert not re.search(r"^ERROR|invalid command name|syntax error", log_text, re.M), \
        f"Gowin Tcl/tool error: see {flow_log}"

    vgs = sorted((build / proj).rglob("*.vg"))
    assert len(vgs) == 1, f"expected exactly one netlist, found {vgs}"
    netlist = vgs[0]
    net_text = netlist.read_text(errors="replace")
    expected = _expected_signature(voices, n_modes)
    net_top, ordered = _find_netlist_top(net_text, expected)
    assert net_top == top_name, f"netlist top {net_top!r} != requested {top_name!r}"

    # ---- simulation wrapper (bank_gate + unmodified vendor GSR) -----------
    wrapper = external / "bank_gate.sv"
    wrapper.write_text(_emit_wrapper(net_top, ordered))

    # ---- cocotb gate-level simulation -------------------------------------
    verilog_bin = Path.home() / "micromamba/envs/torch312/bin"
    if verilog_bin.is_dir() and "iverilog" not in os.environ.get("PATH", ""):
        os.environ["PATH"] = str(verilog_bin) + ":" + os.environ.get("PATH", "")
    from cocotb_tools.runner import Verilog, get_runner

    sim_build = base / "sim_build"
    sources = [wrapper, Verilog(netlist), vendor]
    runner = get_runner("icarus")
    build_log = base / "build.log"
    runner.build(sources=sources, hdl_toplevel="bank_gate", build_dir=sim_build,
                 build_args=["-g2012", "-Wall"], always=True, log_file=build_log)
    results_xml = base / "results.xml"
    results_xml.unlink(missing_ok=True)
    run_log = base / "run.log"
    runner.test(hdl_toplevel="bank_gate", test_module=Path(__file__).stem,
                test_dir=ROOT, build_dir=sim_build, results_xml=str(results_xml),
                extra_env={"REVIEW_N_MODES": str(n_modes)}, log_file=run_log)
    run_text = run_log.read_text(errors="replace")

    # ---- explicit XML gate: exactly 3 distinct cases, no fail/error/skip ----
    assert results_xml.is_file(), "cocotb produced no XML results"
    names, bad = _read_log_tests(results_xml)
    assert names, "XML contains zero testcases"
    assert len(names) == 3 and set(names) == EXPECTED_TEST_NAMES, \
        f"expected 3 distinct tests {sorted(EXPECTED_TEST_NAMES)}, got {names}"
    assert not bad, f"failing/errored/skipped testcases: {bad}"

    # ---- coverage is read back from the real run log; a missing marker aborts
    markers = {
        "full_32x48_golden": r"independent full saturation: count 1536",
        "all_1536_commits": r"independent full saturation: count 1536",
        "voices_0_16_31": r"voices=0,16,31",
        "all_48_modes": r"all 48 modes",
        "orders_reverse_evenodd_shuffle": r"orders=reverse,evenodd,shuffle",
        "holes_16_32_48": r"holes_rejected=16,32,48",
        "low_hole_jump_0": r"low_hole_jump=0",
        "multi_voice_late_reject": r"multi_voice_late_reject=yes",
        "rejection_contract": r"rejection_contract=yes",
        "baseline_injected_identical": r"\d+ commits identical baseline/injected",
    }
    found = {key: bool(re.search(pattern, run_text)) for key, pattern in markers.items()}
    missing = [key for key, ok in found.items() if not ok]
    if missing:
        raise SystemExit(f"required coverage markers absent from the run log: {missing}")
    cycles = [int(m) for m in re.findall(r"max(?: frame)? (\d+) cycles", run_text)]
    cyclemax = max(cycles) if cycles else -1
    assert cyclemax > 0 and cyclemax <= 1800, f"cycle bound violated: {cyclemax}"
    commits = sum(int(m) for m in re.findall(r"(\d+) commits", run_text))
    coverage = {
        "full_32x48_golden": found["full_32x48_golden"],
        "all_1536_commits": found["all_1536_commits"],
        # test 1 asserts the +2^31-1 and -2^31 frames and passes; the log marker is
        # the value after the negative frame.
        "saturation_both_polarities": found["full_32x48_golden"],
        "voices_0_16_31": found["voices_0_16_31"],
        "all_48_modes": found["all_48_modes"],
        "orders_reverse_evenodd_shuffle": found["orders_reverse_evenodd_shuffle"],
        "holes_16_32_48": found["holes_16_32_48"],
        "low_hole_jump_0": found["low_hole_jump_0"],
        "multi_voice_late_reject": found["multi_voice_late_reject"],
        "rejection_contract": found["rejection_contract"],
        "baseline_injected_identical": found["baseline_injected_identical"],
    }

    evidence = {
        "gw_sh_command": gw_command,
        "sim_sources": [str(wrapper), str(netlist), str(vendor)],
        "sim_build_args": ["-g2012", "-Wall"],
        "snapshot": str(snapshot),
        "source_sha256": source_hashes,
        "vendor_library": str(vendor),
        "vendor_sha256": _sha256(vendor),
        "netlist": str(netlist),
        "netlist_sha256": _sha256(netlist),
        "netlist_top": net_top,
        "wrapper": str(wrapper),
        "wrapper_sha256": _sha256(wrapper),
        "test_file_sha256": _sha256(Path(__file__).resolve()),
        "reused_test_sha256": {
            "sim/unit/core/test_modal_poly_bank_review.py": _sha256(ROOT / "sim/unit/core/test_modal_poly_bank_review.py"),
            "sim/unit/core/test_modal_engine_review.py": _sha256(ROOT / "sim/unit/core/test_modal_engine_review.py"),
            "python/modal_sim/fixed_point.py": _sha256(ROOT / "python/modal_sim/fixed_point.py"),
        },
        "skipzero": args.skipzero,
        "voices": voices,
        "n_modes": n_modes,
        "tests": names,
        "tests_failed_or_skipped": bad,
        "cyclemax": cyclemax,
        "cycle_bound": 1800,
        "commits_logged": commits,
        "coverage": coverage,
        "disclaimer": ("Independent isolated bank re-synthesis; NOT a rewrite of or "
                       "equivalence proof for the production song netlist/bitstream; "
                       "no STA; not a board result."),
    }
    (base / "result.json").write_text(json.dumps(evidence, indent=2) + "\n")

    print(run_text)
    print("BANK_NETLIST_REVIEW_PASS")
    print(f"tests={len(names)} pass={len(names)} fail=0 skip=0")
    print(f"cyclemax={cyclemax} (bound 1800)")
    print(f"netlist_sha256={evidence['netlist_sha256']}")
    print(f"vendor_sha256={evidence['vendor_sha256']}")
    print(f"snapshot={snapshot} skipzero={args.skipzero} top={net_top}")
    print(f"coverage={evidence['coverage']}")
    print(evidence["disclaimer"])
    return 0


def _emit_synthesis_harness(voices, n_modes, vw, mw, sw):
    """Transparent one-instance harness so the frozen bank compiles with SKIP1."""
    nv = voices
    return f"""`timescale 1ns/1ps
// TEST ONLY transparent synthesis harness (never simulated directly): it makes
// the REAL frozen modal_poly_bank compile with the production parameter
// SKIP_ZERO_INPUT=1, which the Gowin CLI cannot set on a top module.
module bank_gate_top (
    input  logic clk,
    input  logic rst_n,
    input  logic cfg_valid,
    output logic cfg_ready,
    input  logic [{vw - 1}:0] cfg_voice,
    input  logic [{mw - 1}:0] cfg_mode,
    input  logic [71:0] cfg_word,
    input  logic clear_valid,
    output logic clear_ready,
    input  logic [{vw - 1}:0] clear_voice,
    output logic clear_done,
    input  logic sample_valid,
    output logic sample_ready,
    input  logic [{nv - 1}:0] active_mask,
    input  logic [{nv * mw - 1}:0] n_modes_vec,
    input  logic [{nv * 32 - 1}:0] x_vec,
    output logic busy,
    output logic out_valid,
    output logic signed [63:0] mix_sum,
    output logic [{sw - 1}:0] sat_count,
    output logic voice_valid,
    output logic [{vw - 1}:0] voice_id,
    output logic signed [63:0] voice_sum,
    output logic error_valid,
    output logic [1:0] error_code,
    output logic [3:0] commit_valid,
    output logic [{4 * vw - 1}:0] commit_voice,
    output logic [{4 * mw - 1}:0] commit_mode,
    output logic [127:0] commit_y1,
    output logic [127:0] commit_y2,
    output logic [3:0] commit_sat
);
    modal_poly_bank #(.NUM_VOICES({voices}), .N_MODES({n_modes}),
                      .SKIP_ZERO_INPUT(1)) u_bank (
        .clk(clk), .rst_n(rst_n),
        .cfg_valid(cfg_valid), .cfg_ready(cfg_ready),
        .cfg_voice(cfg_voice), .cfg_mode(cfg_mode), .cfg_word(cfg_word),
        .clear_valid(clear_valid), .clear_ready(clear_ready),
        .clear_voice(clear_voice), .clear_done(clear_done),
        .sample_valid(sample_valid), .sample_ready(sample_ready),
        .active_mask(active_mask), .n_modes_vec(n_modes_vec), .x_vec(x_vec),
        .busy(busy), .out_valid(out_valid), .mix_sum(mix_sum), .sat_count(sat_count),
        .voice_valid(voice_valid), .voice_id(voice_id), .voice_sum(voice_sum),
        .error_valid(error_valid), .error_code(error_code),
        .commit_valid(commit_valid), .commit_voice(commit_voice),
        .commit_mode(commit_mode), .commit_y1(commit_y1), .commit_y2(commit_y2),
        .commit_sat(commit_sat)
    );
endmodule
"""


if __name__ == "__main__":
    sys.exit(main())
