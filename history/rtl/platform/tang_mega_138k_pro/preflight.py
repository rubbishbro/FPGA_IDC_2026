#!/usr/bin/env python3
"""Board build preflight for the Tang Mega 138K Pro speaker top.

This script is a *gate*, not a synthesis or timing run.  It fails non-zero when a
required source/ROM file is missing, when a listed source does not resolve, when
the two Gowin PLL IP modules have not been generated (or are not a real primitive
PLL module with the expected ports), when the recorded device selection drifts,
when the ROM images are the wrong width/length, when the active SDC is missing
its generated clocks / synchronous-CDC constraints, or when the Gowin tool chain
is absent.  Passing it does NOT prove the design synthesises, meets timing or
fits, and does NOT validate PLL PFD/VCO/filter legality.

Usage:
    python3 preflight.py [--root DIR] [--ip-dir DIR] [--no-tool] [--quiet]

Exit codes:
    0  every checked item present and consistent (tool included unless --no-tool)
    1  Gowin tool chain not found
    2  a required file / ROM / source-list item is missing or malformed
    3  a Gowin PLL IP module is missing, not a primitive PLL, or has wrong ports
    4  device / manifest / constraint consistency failure
    (if several categories fail, the lowest-numbered category is returned)

The IP directory defaults to <platform>/ip; each PLL entry resolves to
<ip-dir>/<ip_subdir>/<ip_file>.  Comments are stripped before any timing/module
inspection, so a constraint that exists only in a comment does not count.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

# local IP / IO / pin facts that must never be inherited from another board
FORBIDDEN_DEVICE_TOKENS = ["PG484", "GW1NR", "GW1N-", "GW2A", "GW5A-25"]


class Report:
    def __init__(self) -> None:
        self.problems: dict[int, list[str]] = {}
        self.notes: list[str] = []

    def fail(self, code: int, msg: str) -> None:
        self.problems.setdefault(code, []).append(msg)

    def note(self, msg: str) -> None:
        self.notes.append(msg)

    @property
    def rc(self) -> int:
        return min(self.problems) if self.problems else 0


def _read(path: str) -> str:
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()


def _strip_comments(text: str, dialect: str = "verilog") -> str:
    """Remove comments only for the given dialect.

    Verilog/SystemVerilog: // line and /* */ block comments (never #, which is a
    delay control).  SDC: # line comments plus // and /* */ (so a commented-out
    constraint never counts).
    """
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    if dialect == "sdc":
        text = re.sub(r"#[^\n]*", "", text)
    return text


def check_required_files(root: str, man: dict, rep: Report) -> None:
    req = [man["cst"], man["sdc"], man["source_list"], man["readme"]]
    req += list(man["sources"])
    req += [man["rom"][k]["path"] for k in man["rom"]]
    seen = set()
    for rel in req:
        if rel in seen:
            continue
        seen.add(rel)
        p = os.path.join(root, rel)
        if not os.path.isfile(p):
            rep.fail(2, f"missing required file: {rel}")
        elif os.path.getsize(p) == 0:
            rep.fail(2, f"required file is empty: {rel}")


def parse_source_list(root: str, man: dict, rep: Report):
    """Return the list of sources.f entries, or None if it cannot be read."""
    path = os.path.join(root, man["source_list"])
    if not os.path.isfile(path):
        rep.fail(2, f"missing required file: {man['source_list']}")
        return None
    entries = []
    for raw in _read(path).splitlines():
        line = raw.split("//", 1)[0].split("#", 1)[0].strip()
        if line:
            entries.append(line.replace("\\", "/"))
    if not entries:
        rep.fail(2, f"source list is empty: {man['source_list']}")
        return None
    return entries


def check_sources(root: str, ip_dir: str, man: dict, rep: Report,
                  entries) -> None:
    """Every listed source must resolve (IP entries under --ip-dir)."""
    if entries is None:
        return
    wanted = set(s.replace("\\", "/") for s in man["sources"])
    for rel in sorted(wanted - set(entries)):
        rep.fail(2, f"sources.f is missing {rel}")

    # generated IP must be addressed by the canonical relative path, and only
    # the canonical <repo>/<ip_subdir>/<ip_file> or, with --ip-dir, the
    # redirected <ip_dir>/<ip_subdir>/<ip_file>.  A same-suffix path with a
    # different prefix (e.g. nonexistent/pll_core_100m/...) must NOT be skipped.
    plat_dir = os.path.dirname(man.get("source_list", "")).replace("\\", "/")
    ip_dir_name = os.path.basename(os.path.normpath(
        man.get("ip_dir", os.path.join(plat_dir or ".", "ip"))))
    ip_entries = {}
    canonical_list = []
    for p in man.get("pll", []):
        for fn in (p["ip_file"], p.get("mod_file")):
            if not fn:
                continue
            canonical = f"{plat_dir}/{ip_dir_name}/{p['ip_subdir']}/{fn}"
            canonical_list.append(canonical)
            ip_entries[canonical] = p
            ip_entries[os.path.normpath(canonical).replace("\\", "/")] = p
    # the PLL_ADV support file lives directly under the ip dir
    init_canonical = f"{plat_dir}/{ip_dir_name}/pll_init.v"
    ip_entries[init_canonical] = True
    ip_entries[os.path.normpath(init_canonical)] = True

    for entry in entries:
        norm = os.path.normpath(entry).replace("\\", "/")
        if norm in ip_entries or entry in ip_entries:
            # existence under --ip-dir is validated by check_pll
            continue
        # an entry that looks like generated IP but is not canonical -> error
        if any(entry.endswith(p["ip_subdir"] + "/" + fn)
               for p in man.get("pll", [])
               for fn in (p["ip_file"], p.get("mod_file") or "")):
            rep.fail(2, f"sources.f generated IP entry is not the canonical "
                        f"relative path: {entry}")
            continue
        resolved = os.path.join(root, entry)
        if not os.path.isfile(resolved):
            rep.fail(2, f"sources.f entry not found: {entry} (looked at "
                        f"{os.path.relpath(resolved, root)})")

    for only in man["test_only_sources"]:
        if only.replace("\\", "/") in entries:
            rep.fail(2, f"test-only file listed for synthesis: {only}")

    # every declared generated IP file must appear by its canonical path
    for canonical in canonical_list:
        if canonical not in entries:
            rep.fail(2, f"sources.f does not list generated IP {canonical}")

def _pll_module_ok(path: str, pll: dict, rep: Report) -> None:
    """Validate one generated PLL wrapper module and its primitive companion.

    Real Gowin V1.9.12.04 output (PLL_ADV, GW5AST-138B): the wrapper module
    declares (clkin, init_clk, clkout0, lock) and instantiates the primitive
    `PLL` inside the *_mod.v companion file.  The wrapper may contain a
    PLL_INIT support instance, so the primitive check is done on the companion.
    """
    raw = _read(path)
    code = _strip_comments(raw, "verilog")
    name = pll["module"]
    rel = os.path.relpath(path)

    m = re.search(r"\bmodule\s+" + re.escape(name) + r"\b", code)
    if not m:
        rep.fail(3, f"{rel}: does not declare module {name}")
        return

    if not re.search(r"\b(input|output|inout)\b", code):
        rep.fail(3, f"{rel}: module has no input/output ports (empty/stub)")
        return

    # test/behavioural models: initial blocks or delay controls (Verilog keeps #)
    if re.search(r"\binitial\b", code):
        rep.fail(3, f"{rel}: contains an initial block (behavioural/test model?)")
    if re.search(r"#\s*[\(\d]", code):
        rep.fail(3, f"{rel}: contains a delay control (behavioural/test model?)")

    # verify the ports in the ANSI header (fall back to declarations)
    header = re.search(
        r"\bmodule\s+" + re.escape(name) +
        r"\s*(#\s*\([^)]*\))?\s*\(([^;]*?)\)\s*;", code, re.S)
    blob = header.group(2) if (header and re.search(r"\b(input|output|inout)\b",
                                                      header.group(2))) else None
    missing = []
    for port in pll["ports"]:
        if blob is not None:
            if not re.search(r"\b" + re.escape(port) + r"\b", blob):
                missing.append(port)
        elif not re.search(r"\b(input|output|inout)\b[^;]*\b" +
                           re.escape(port) + r"\b", code):
            missing.append(port)
    if missing:
        rep.fail(3, f"{rel}: missing PLL port(s): {', '.join(missing)}")

    # the primitive PLL instance lives in the companion *_mod.v next to it
    cand = os.path.join(os.path.dirname(path), pll.get("mod_file", ""))
    if pll.get("mod_file") and not os.path.isfile(cand):
        rep.fail(3, f"{rel}: missing generated primitive companion "
                    f"{pll['mod_file']}")
    elif pll.get("mod_file"):
        mod_code = _strip_comments(_read(cand), "verilog")
        if re.search(r"\binitial\b", mod_code) or re.search(r"#\s*[\(\d]", mod_code):
            rep.fail(3, f"{os.path.relpath(cand)}: behavioural/test model")
        if not re.search(r"\bPLL\b\s*(#\s*\([^;]*?\)\s*)?[A-Za-z_]\w*\s*\(", mod_code):
            rep.fail(3, f"{os.path.relpath(cand)}: no primitive PLL instance found")
        elif not rep.problems.get(3):
            rep.note(f"PLL {name} present with real ports + primitive PLL "
                     f"({pll['output_freq_mhz']} MHz)")
    elif not missing and not rep.problems.get(3):
        rep.note(f"PLL {name} present with expected ports "
                 f"({pll['output_freq_mhz']} MHz)")


def check_pll(root: str, ip_dir: str, man: dict, rep: Report) -> None:
    for pll in man["pll"]:
        rel = os.path.join(pll["ip_subdir"], pll["ip_file"])
        path = os.path.join(ip_dir, rel)
        if not os.path.isfile(path):
            rep.fail(3, f"PLL IP not generated: expected {rel} under {ip_dir}")
            continue
        _pll_module_ok(path, pll, rep)


def check_rom(root: str, man: dict, rep: Report) -> None:
    for key, meta in man["rom"].items():
        path = os.path.join(root, meta["path"])
        if not os.path.isfile(path):
            continue
        width, depth = int(meta["width"]), int(meta["depth"])
        limit = 1 << width
        # Each $readmemh data line must hold exactly one hex word: a second token
        # would be read as another memory word and shift depth/addressing.  We
        # therefore count and validate EVERY token on the line.
        counts = []
        tokens = 0
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for lineno, raw in enumerate(fh, 1):
                body = raw.split("//", 1)[0].strip()
                if not body:
                    continue
                words = body.split()
                counts.append(len(words))
                for tok in words:
                    if not re.fullmatch(r"[0-9a-fA-F]+", tok):
                        rep.fail(2, f"{meta['path']}:{lineno} not a hex token: "
                                    f"{tok!r}")
                        continue
                    if len(tok) > (width + 3) // 4:
                        rep.fail(2, f"{meta['path']}:{lineno} token wider than "
                                    f"{width} bits: {tok!r}")
                    if int(tok, 16) >= limit:
                        rep.fail(2, f"{meta['path']}:{lineno} value exceeds "
                                    f"{width} bits: {tok!r}")
                    tokens += 1
        multi = [i for i, c in enumerate(counts, 1) if c > 1]
        if multi:
            rep.fail(2, f"{meta['path']}: {len(multi)} line(s) contain more than "
                        f"one hex word (e.g. line {multi[0]}); $readmemh would "
                        f"read them as extra entries")
        if len(counts) != depth:
            rep.fail(2, f"{meta['path']}: {len(counts)} data lines, expected {depth}")
        if tokens != depth:
            rep.fail(2, f"{meta['path']}: {tokens} total words, expected {depth} "
                        f"({depth} one-word lines)")
        if (not multi and tokens == depth and len(counts) == depth
                and not rep.problems.get(2)):
            rep.note(f"ROM {meta['path']} {width} bits x {depth} entries valid "
                     f"(one word per line)")


def check_consistency(root: str, man: dict, rep: Report) -> None:
    fpga = str(man.get("fpga", ""))
    if "GW5AST" not in fpga or "FPG676" not in fpga:
        rep.fail(4, f"manifest fpga '{fpga}' is not the FPG676 GW5AST part")
    if str(man.get("device_version", "")) != "B":
        rep.fail(4, "device_version must be B for this task")
    if str(man.get("package", "")) != "FPG676":
        rep.fail(4, "package must be FPG676")
    if man.get("bitstream_generated"):
        rep.fail(4, "manifest claims a bitstream exists; not allowed without Gowin")

    official = str(man.get("official_device_header", ""))
    if official and official != fpga:
        rep.note(f"official example header is {official} (ES); declared target is "
                 f"{fpga} -- user must confirm the physical part, target not "
                 f"changed unilaterally")

    readme = os.path.join(root, man["readme"])
    if os.path.isfile(readme) and fpga and fpga not in _read(readme):
        rep.fail(4, f"{man['readme']} does not state device {fpga}")

    for key in ("cst", "sdc"):
        p = os.path.join(root, man[key])
        if not os.path.isfile(p):
            continue
        for tok in FORBIDDEN_DEVICE_TOKENS:
            if tok in _read(p):
                rep.fail(4, f"{man[key]} mentions foreign device token {tok!r}")

    cst = os.path.join(root, man["cst"])
    if os.path.isfile(cst):
        text = _read(cst)
        for name, pin in man["pins"].items():
            if not re.search(r'IO_LOC\s+"' + re.escape(name) + r'"\s+' +
                             re.escape(pin) + r"\s*;", text):
                rep.fail(4, f"CST missing IO_LOC {name} -> {pin}")
        for token in ("amp_bclk", "amp_lrc", "amp_din", "amp_sd",
                      "clk", "reset"):
            if not re.search(r'IO_LOC\s+"' + re.escape(token) + r'"', text):
                rep.fail(4, f"CST missing IO_LOC for {token}")


def check_board_top_params(root: str, man: dict, rep: Report) -> None:
    """Verify the synthesis wrapper enables body and uses absolute ROM paths that
    match the manifest's declared ROM files (same-source requirement)."""
    body = man.get("body", {})
    plat = os.path.dirname(man.get("source_list", ""))
    wrapper = os.path.join(root, plat, body.get("top_wrapper", "board_top.sv"))
    if not os.path.isfile(wrapper):
        rep.fail(4, f"body top wrapper missing: {body.get('top_wrapper')}")
        return
    text = _strip_comments(_read(wrapper), "verilog")

    if int(body.get("enable", 0)) == 1:
        if not re.search(r"\.ENABLE_BODY\s*\(\s*1\s*\)", text):
            rep.fail(4, f"{os.path.basename(wrapper)}: ENABLE_BODY must be 1 in "
                        f"the body build")
        if not re.search(r"\.BODY_INSTRUMENT\s*\(\s*"
                         + str(int(body.get("instrument", 0))) + r"\s*\)", text):
            rep.fail(4, f"{os.path.basename(wrapper)}: BODY_INSTRUMENT must be "
                        f"{body.get('instrument')}")

    # absolute ROM paths must match the manifest ROM paths
    for key, meta in man["rom"].items():
        want = os.path.join(root, meta["path"]).replace("\\", "/")
        if want not in text.replace("\\", "/"):
            rep.fail(4, f"{os.path.basename(wrapper)}: does not reference the "
                        f"manifest absolute ROM path for {key}: {want}")
    if not rep.problems.get(4):
        rep.note("board_top body params + absolute ROM paths match the manifest")


def check_synthesis_log(root: str, man: dict, rep: Report) -> None:
    """If a synthesis/P&R flow log exists, fail on the real-error clues (missing
    ROM $readmemh, tool errors) even when the tool exits 0."""
    for rel in man.get("flow_logs", []):
        p = os.path.join(root, rel)
        if not os.path.isfile(p):
            continue
        text = _read(p)
        if re.search(r"EX3988|Cannot open file .*\.mem", text):
            rep.fail(2, f"{rel}: synthesis could not open a ROM image (EX3988)")
        if re.search(r"^\s*ERROR", text, re.M):
            rep.fail(2, f"{rel}: contains tool ERROR lines")
        else:
            rep.note(f"{rel}: no ROM-open / ERROR lines")


def check_sdc(root: str, man: dict, rep: Report) -> None:
    """Only ACTIVE (uncommented) timing constraints count, in Gowin SDC syntax."""
    path = os.path.join(root, man["sdc"])
    if not os.path.isfile(path):
        return
    sdc = _strip_comments(_read(path), "sdc")

    if not re.search(r"create_clock\b[^\n]*20\.000", sdc):
        rep.fail(4, "SDC missing active 50 MHz create_clock (20.000 ns)")
    if "get_ports" not in sdc or not re.search(r"get_ports\s*\{\s*clk\s*\}", sdc):
        rep.fail(4, "SDC create_clock does not target get_ports {clk}")

    for pll in man["pll"]:
        name = pll["name"]
        pat = (r"create_generated_clock\b[^;]*?-name\s+" + re.escape(name) +
               r"\b[^;]*?-divide_by\s+" + str(int(pll["divide_by"])) +
               r"\b[^;]*?-multiply_by\s+" + str(int(pll["multiply_by"])) + r"\b")
        if not re.search(pat, sdc, re.S):
            rep.fail(4, f"SDC missing active generated clock {name} "
                        f"(x{pll['multiply_by']}/"
                        f"{pll['divide_by']})")
    if not re.search(r"create_generated_clock\b[^;]*get_pins", sdc, re.S):
        rep.fail(4, "SDC generated clock does not target get_pins (path unverified)")

    # CDC: Gowin syntax is `set_max_delay -from <list> <delay_ns> -to <list>`
    for a, b in (("clk_core", "clk_audio"), ("clk_audio", "clk_core")):
        pat = (r"set_max_delay\b[^\n]*?-from\s+\[get_clocks\s*\{" + a +
               r"\}\][^\n]*?-to\s+\[get_clocks\s*\{" + b + r"\}\]")
        if not re.search(pat, sdc):
            rep.fail(4, f"SDC missing set_max_delay {a} -> {b}")

    # Broad cuts would mask the max-delay constraints.  A *scoped* hold/removal
    # exception on explicit synchroniser CLEAR pins is allowed (async-assert reset
    # release); anything from/to a whole clock/port is rejected.
    for fp in re.finditer(r"set_false_path[^\n]*", sdc):
        line = fp.group(0)
        scoped = bool(re.search(r"-to\s+\[get_pins\b", line)) and \
                 bool(re.search(r"-hold\b", line))
        broad = bool(re.search(r"get_clocks\b|get_ports\b", line))
        if not scoped or broad:
            rep.fail(4, "SDC has an un-scoped/broad set_false_path (would mask "
                        "CDC constraints): " + line.strip())
    if re.search(r"\bset_clock_groups\b", sdc):
        rep.fail(4, "SDC contains an active set_clock_groups (over-broad async "
                    "cut; use explicit max-delay CDC constraints)")
    # require the scoped reset-synchroniser removal exception to be present
    if not re.search(r"set_false_path\b[^\n]*-hold\b[^\n]*-to\s+\[get_pins\b", sdc):
        rep.fail(4, "SDC missing the scoped reset-synchroniser removal exception")

    # source-synchronous external I2S: forwarded BCLK + DIN/LRC outputs must be
    # bounded relative to the internal audio clock (no output-port generated clock)
    if re.search(r"create_generated_clock\b[^;]*?-name\s+clk_bclk\b", sdc):
        rep.fail(4, "SDC declares a generated clock on the forwarded BCLK output "
                    "port (causes spurious clk_audio->clk_bclk hold flags)")
    for port in ("amp_bclk", "amp_din", "amp_lrc"):
        for opt in ("-max", "-min"):
            pat = (r"set_output_delay\b(?=[^\n]*" + re.escape(opt) + r"\b)"
                   r"(?=[^\n]*-clock\s+clk_audio\b)"
                   r"(?=[^\n]*get_ports\s*\{\s*" + port + r"\s*\})")
            if not re.search(pat, sdc):
                rep.fail(4, f"SDC missing active {opt} output delay for {port} "
                            f"vs clk_audio")
    if not rep.problems.get(4):
        rep.note("SDC active generated clocks + CDC + bounded output delays present")


def check_tool(man: dict, rep: Report, skip: bool) -> None:
    if skip:
        rep.note("tool check skipped (--no-tool); preflight is structural only")
        return
    found = None
    for name in man.get("gowin_tools_required", ["gw_sh"]):
        if shutil.which(name):
            found = name
            break
    if not found:
        rep.fail(1, "Gowin command-line tool not found (need "
                    + ", ".join(man.get("gowin_tools_required", ["gw_sh"])) + ")")
    else:
        rep.note(f"Gowin tool found on PATH: {found}")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", default=DEFAULT_ROOT)
    ap.add_argument("--ip-dir", default=None)
    ap.add_argument("--no-tool", action="store_true",
                    help="skip the Gowin tool check (structural preflight only)")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    root = os.path.abspath(os.path.expanduser(args.root))
    ip_dir = (os.path.abspath(os.path.expanduser(args.ip_dir))
              if args.ip_dir else os.path.join(HERE, "ip"))

    man_path = os.path.join(HERE, "board_build.json")
    if not os.path.isfile(man_path):
        print(f"FAIL: manifest missing: {man_path}", file=sys.stderr)
        return 2
    try:
        man = json.loads(_read(man_path))
    except json.JSONDecodeError as exc:
        print(f"FAIL: manifest is not valid JSON: {exc}", file=sys.stderr)
        return 2

    rep = Report()
    check_required_files(root, man, rep)
    entries = parse_source_list(root, man, rep)
    check_sources(root, ip_dir, man, rep, entries)
    check_pll(root, ip_dir, man, rep)
    check_rom(root, man, rep)
    check_consistency(root, man, rep)
    check_board_top_params(root, man, rep)
    check_synthesis_log(root, man, rep)
    check_sdc(root, man, rep)
    check_tool(man, rep, args.no_tool)

    if not args.quiet:
        print(f"preflight root   : {root}")
        print(f"preflight ip-dir : {ip_dir}")
        print(f"target device    : {man.get('fpga')} (ver {man.get('device_version')})")
        for n in rep.notes:
            print(f"  ok   : {n}")

    if rep.rc == 0:
        print("preflight PASS (structural only; not a synthesis/timing claim)")
        return 0

    labels = {1: "TOOL", 2: "FILES", 3: "PLL_IP", 4: "CONSISTENCY"}
    for code in sorted(rep.problems):
        for msg in rep.problems[code]:
            print(f"  FAIL[{labels[code]}] {msg}", file=sys.stderr)
    print("preflight FAIL", file=sys.stderr)
    return rep.rc


if __name__ == "__main__":
    raise SystemExit(main())
