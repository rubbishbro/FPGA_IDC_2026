#!/usr/bin/env python3
"""Single user entry point for the categorised sim test tree.

The 46 original flat ``sim/*.py`` scripts were moved 1:1 into category folders
(``unit/core``, ``unit/audio``, ``unit/body``, ``integration``, ``netlist``,
``regression``, ``checks``, ``diagnostics``, ``tools``, ``support``,
``archive/bringup_mock``).  ``catalog.json`` records every script's stable id,
purpose, role and kind.  This runner only reads that catalog for ``--list``; it
never imports a script just to list it, so vendor-dependent tools (Matplotlib)
and cocotb scripts are not touched during discovery.

Usage
-----
    python sim/run.py --list                  # all scripts, grouped by category
    python sim/run.py --list --category core  # one category
    python sim/run.py --list --filter 饱和     # purpose substring search
    python sim/run.py core/resonator          # run one script
    python sim/run.py core/bank --testcase t01_reset_preconfig

There is intentionally no ``--all`` (no auto full sweep) and no flashing /
programmer step.  ``--list``/``--help`` never build or run anything.
"""
from __future__ import annotations

import argparse
import json
import runpy
import sys
from pathlib import Path

_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE / "support"))

from _sim_paths import bootstrap, find_repo_root  # noqa: E402

_CATALOG = _HERE / "catalog.json"


def load_catalog():
    return json.loads(_CATALOG.read_text(encoding="utf-8"))


def select(entries, category=None, purpose=None, role=None, kind=None):
    out = []
    for e in entries:
        if category and e["category"] != category:
            continue
        if purpose and purpose.lower() not in (e["purpose"] + " " + e["id"]).lower():
            continue
        if role and e["role"] != role:
            continue
        if kind and e["kind"] != kind:
            continue
        out.append(e)
    return out


def print_list(catalog, entries, stream=sys.stdout):
    cats = {c["id"]: c for c in catalog["categories"]}
    order = [c["id"] for c in catalog["categories"]]
    print(f"sim catalog: {len(entries)} script(s)  (repo {find_repo_root(__file__)})",
          file=stream)
    print("id  |  role  |  kind  |  purpose", file=stream)
    for cat in order:
        group = [e for e in entries if e["category"] == cat]
        if not group:
            continue
        meta = cats.get(cat, {})
        print(f"\n[{cat}] {meta.get('description', '')}  ({len(group)})", file=stream)
        for e in group:
            flag = "" if e.get("runnable", True) else "  (not runnable)"
            print(f"  {e['id']:<32} {e['role']:<11} {e['kind']:<8} {e['purpose']}{flag}",
                  file=stream)
            print(f"      {e['path']}", file=stream)
    print("\nRun with:  python sim/run.py <id> [script arguments]", file=stream)
    print("Filter:    --category <core|audio|body|integration|netlist|regression|"
          "checks|diagnostics|tools|support|archive>  --filter <purpose substring>",
          file=stream)


def find_entry(entries, eid):
    exact = [e for e in entries if e["id"] == eid]
    if exact:
        return exact[0]
    alias = [e for e in entries if eid in e.get("aliases", [])]
    if len(alias) == 1:
        return alias[0]
    matches = [e for e in entries if e["id"].endswith("/" + eid)]
    if len(matches) == 1:
        return matches[0]
    return None


def run_entry(entry, passthrough):
    script = (find_repo_root(__file__) / entry["path"]).resolve()
    if not script.is_file():
        print(f"[run] catalog entry missing on disk: {script}", file=sys.stderr)
        return 2
    if not entry.get("runnable", True):
        print(f"[run] {entry['id']} is role={entry['role']} and not directly runnable",
              file=sys.stderr)
        return 2
    if passthrough and passthrough[0] == "--":
        passthrough = passthrough[1:]
    bootstrap(script)
    sys.argv = [str(script)] + list(passthrough)
    print(f"[run] {entry['id']} -> python {entry['path']}"
          + (" " + " ".join(passthrough) if passthrough else ""), file=sys.stderr)
    try:
        runpy.run_path(str(script), run_name="__main__")
    except SystemExit as exc:
        code = exc.code
        if code is None:
            return 0
        return code if isinstance(code, int) else 1
    return 0


def main(argv=None):
    catalog = load_catalog()
    entries = catalog["entries"]
    cats = [c["id"] for c in catalog["categories"]]

    ap = argparse.ArgumentParser(
        prog="python sim/run.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--list", action="store_true",
                    help="list catalogued scripts (does not run anything)")
    ap.add_argument("--category", default=None, choices=cats,
                    help="filter --list by category")
    ap.add_argument("--filter", default=None, metavar="TEXT",
                    help="filter --list by purpose/id substring")
    ap.add_argument("--role", default=None,
                    choices=["baseline", "independent", "regression", "tool",
                             "archive", "support"],
                    help="filter --list by role")
    ap.add_argument("--kind", default=None,
                    choices=["rtl", "python", "netlist", "reports", "build", "plot"],
                    help="filter --list by kind")
    ap.add_argument("id", nargs="?",
                    help="stable catalog id, e.g. core/resonator (omit to list)")
    ap.add_argument("rest", nargs=argparse.REMAINDER,
                    help="arguments forwarded to the selected script")
    args = ap.parse_args(argv)

    if args.id is not None and args.id in ("list", "help"):
        args.list = True
        args.id = None

    if args.id is None:
        selected = select(entries, args.category, args.filter, args.role, args.kind)
        if not selected:
            print("no catalog entries match the filter", file=sys.stderr)
            return 1
        print_list(catalog, selected)
        return 0

    if args.list:
        print("--list cannot be combined with a script id", file=sys.stderr)
        return 2

    entry = find_entry(entries, args.id)
    if entry is None:
        print(f"unknown id {args.id!r}. Try: python sim/run.py --list", file=sys.stderr)
        return 2
    return run_entry(entry, args.rest)


if __name__ == "__main__":
    raise SystemExit(main())
