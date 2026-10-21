"""Freeze and build the song metadata repair with the real Gowin toolchain.

Uses the original core100 project settings, no clock/constraint overrides, no
Programmer calls. Completion is not a functional or timing acceptance result.
"""
from __future__ import annotations
import os as _sim_os
import sys as _sim_sys

_sim_p = _sim_os.path.dirname(_sim_os.path.abspath(__file__))
while not (_sim_os.path.isdir(_sim_os.path.join(_sim_p, "rtl"))
           and _sim_os.path.isdir(_sim_os.path.join(_sim_p, "sim"))):
    _sim_p = _sim_os.path.dirname(_sim_p)
_sim_sys.path.insert(0, _sim_os.path.join(_sim_p, "sim", "support"))
from _sim_paths import bootstrap as _sim_bootstrap  # noqa: E402
ROOT = _sim_bootstrap(__file__)


import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

from _review_source_snapshot import ROOT, freeze_sources


def verilog_tokens(text):
    parts = re.findall(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/|\s+|[^\s]', text)
    return ''.join(p for p in parts if not (p.isspace() or p.startswith(('//', '/*'))))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--evidence-dir', required=True, type=Path)
    ap.add_argument('--baseline', type=Path,
                    default=Path('/tmp/opencode/core100-review/parent_source_snapshot'))
    ap.add_argument('--gowin-dir', type=Path, default=Path.home() / 'gowin')
    ap.add_argument('--allow-rtl-change', action='append', default=[],
                    help='explicit additional RTL path being repaired; all other inputs must match baseline')
    ap.add_argument('--allow-constraint-change', action='append', default=[],
                    help='explicit reviewed constraint path; records baseline/current hashes, not a timing pass')
    args = ap.parse_args()
    base = args.evidence_dir.resolve()
    assert not (base / 'parent_source_snapshot').exists(), 'Refuse to overwrite snapshot'
    assert not (base / 'build').exists(), 'Refuse to overwrite build'
    plat = Path('rtl/platform/tang_mega_138k_pro')
    names = [line.strip() for line in (ROOT / plat / 'sources.f').read_text().splitlines()
             if line.strip().startswith('rtl/')]
    names += [str(plat / name) for name in ('sources.f', 'tang_mega_138k_pro.cst',
                                          'tang_mega_138k_pro.sdc')]
    names += ['rtl/rom/' + name for name in ('modal_coeff.mem', 'modal_index.mem', 'body_coeff.mem')]
    names += ['sim/audio_helpers/board_pll_model.sv']
    verification = []
    allowed_rtl = {'rtl/core/modal_poly_bank.sv', *args.allow_rtl_change}
    for name in allowed_rtl:
        assert name in names and name.endswith(('.sv', '.v')), f'Not a listed RTL input: {name}'
    allowed_constraints = set(args.allow_constraint_change)
    constraint_checks = {}
    for name in allowed_constraints:
        assert name in names and name.endswith(('.sdc', '.cst')), f'Not a listed constraint: {name}'
        baseline = args.baseline / name
        assert baseline.is_file(), f'Cannot record missing constraint baseline: {name}'
        constraint_checks[name] = dict(
            baseline_sha256=hashlib.sha256(baseline.read_bytes()).hexdigest(),
            current_sha256=hashlib.sha256((ROOT / name).read_bytes()).hexdigest())
    allowed = allowed_rtl | allowed_constraints
    for name in names:
        if name in allowed:
            continue
        original = args.baseline / name
        if not original.is_file():
            continue
        current = (ROOT / name).read_text()
        old = original.read_text()
        if name.endswith(('.sv', '.v')):
            current, old = verilog_tokens(current), verilog_tokens(old)
            if name.endswith('board_top.sv'):
                for rom in ('modal_coeff.mem', 'modal_index.mem', 'body_coeff.mem'):
                    pattern = r'"[^"\n]*' + re.escape(rom) + r'"'
                    current = re.sub(pattern, '"' + rom + '"', current)
                    old = re.sub(pattern, '"' + rom + '"', old)
        elif name.endswith(('.sdc', '.cst', '.f')):
            def active(text):
                return '\n'.join(line.strip() for line in text.splitlines()
                                 if line.strip() and not line.lstrip().startswith(('#', '//')))
            current, old = active(current), active(old)
        assert current == old, f'Functional input differs outside metadata repair: {name}'
        verification.append(name)
    freeze_sources([ROOT / name for name in names] + [Path(__file__)], base)
    snap = base / 'parent_source_snapshot'
    # Relocate ROM paths in the COPY only, recording both hashes.
    wrapper = snap / plat / 'board_top.sv'
    data = wrapper.read_text()
    for rom in ('modal_coeff.mem', 'modal_index.mem', 'body_coeff.mem'):
        data, count = re.subn(r'"[^"\n]*' + re.escape(rom) + r'"',
                             '"' + str(snap / 'rtl/rom' / rom) + '"', data)
        assert count == 1, (rom, count)
    wrapper.write_text(data)
    manifest_path = snap / 'sources.json'
    manifest = json.loads(manifest_path.read_text())
    entry = manifest[str(plat / 'board_top.sv')]
    entry['original_sha256'] = entry['sha256']
    entry['sha256'] = hashlib.sha256(wrapper.read_bytes()).hexdigest()
    entry['transform'] = 'ROM absolute paths relocated to this immutable snapshot only'
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    (base / 'outside_repair_input_check.json').write_text(json.dumps(verification, indent=2) + '\n')
    (base / 'allowed_rtl_changes.json').write_text(json.dumps(sorted(allowed_rtl), indent=2) + '\n')
    (base / 'reviewed_constraint_changes.json').write_text(json.dumps(constraint_checks, indent=2) + '\n')
    script = base / 'build_song.tcl'
    script.write_text(f'''set evidence {{{base}}}
set root "$evidence/parent_source_snapshot"
set plat "$root/{plat}"
create_project -name song_metadata_core100 -dir "$evidence/build" -pn GW5AST-LV138FPG676AES -device_version B -force
set_option -verilog_std sysv2017
set_option -top_module board_top
set f [open "$plat/sources.f" r]
set lines [split [read $f] "\\n"]
close $f
foreach line $lines {{
    set line [string trim $line]
    if {{[string match "rtl/*" $line]}} {{add_file "$root/$line"}}
}}
add_file "$plat/tang_mega_138k_pro.cst"
add_file "$plat/tang_mega_138k_pro.sdc"
run syn
puts "SONG_METADATA_SYN_DONE"
run pnr
puts "SONG_METADATA_PNR_DONE"
''')
    env = dict(os.environ)
    env['LD_LIBRARY_PATH'] = str(args.gowin_dir / 'IDE/lib') + ':' + env.get('LD_LIBRARY_PATH', '')
    with (base / 'flow.log').open('w') as log:
        result = subprocess.run([str(args.gowin_dir / 'IDE/bin/gw_sh'), '-nocomp'],
            input=f'source {{{script}}}\n', text=True, cwd=snap, env=env,
            stdout=log, stderr=subprocess.STDOUT)
    (base / 'process_exit.json').write_text(json.dumps({'gw_sh_exit': result.returncode}) + '\n')
    result.check_returncode()
    console = (base / 'flow.log').read_text(errors='replace')
    assert not re.search(r'\bERROR\b|invalid command name|syntax error', console), console[-3000:]
    assert re.search(r'^SONG_METADATA_PNR_DONE\s*$', console, re.M), 'P&R did not finish'
    print('Build complete; independent netlist/STA review still required:', base)


if __name__ == '__main__':
    main()
