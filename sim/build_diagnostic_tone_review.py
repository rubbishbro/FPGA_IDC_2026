"""Freeze and build ONLY the isolated tone with real Gowin syn/P&R.

No Programmer invocation. Refuses to overwrite an existing frozen build.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess

from _review_source_snapshot import ROOT, freeze_sources


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--evidence-dir', required=True)
    ap.add_argument('--gowin-dir', default=str(Path.home() / 'gowin'))
    args = ap.parse_args()
    base = Path(args.evidence_dir).resolve()
    assert not (base / 'parent_source_snapshot/sources.json').exists(), 'Refuse to overwrite snapshot'
    assert not (base / 'build').exists(), 'Refuse to overwrite build'
    plat = ROOT / 'rtl/platform/tang_mega_138k_pro'
    tone = plat / 'diagnostic_tone'
    sources = [plat / 'ip/pll_init.v',
               plat / 'ip/pll_audio_12m5/gowin_pll_audio_12m5.v',
               plat / 'ip/pll_audio_12m5/gowin_pll_audio_12m5_mod.v',
               ROOT / 'rtl/audio/i2s_amp_tx.sv']
    sources += [tone / name for name in ('tone_source.sv', 'top.sv', 'tone.cst',
                                        'tone.sdc', 'gowin_build.tcl', 'README.md')]
    sources += [ROOT / 'sim' / name for name in ('test_diagnostic_tone_review.py',
                                               'review_diagnostic_tone_reports.py',
                                               'build_diagnostic_tone_review.py')]
    freeze_sources(sources, base)
    snapshot = base / 'parent_source_snapshot'
    script = snapshot / 'rtl/platform/tang_mega_138k_pro/diagnostic_tone/gowin_build.tcl'
    gowin = Path(args.gowin_dir).resolve()
    env = os.environ.copy()
    env['BUILD_DIR'] = str(base / 'build')
    env['LD_LIBRARY_PATH'] = str(gowin / 'IDE/lib') + ':' + env.get('LD_LIBRARY_PATH', '')
    with (base / 'flow.log').open('w') as output:
        proc = subprocess.run([str(gowin / 'IDE/bin/gw_sh'), '-nocomp'],
                              input=f'source {{{script}}}\n', text=True,
                              cwd=snapshot, env=env, stdout=output,
                              stderr=subprocess.STDOUT)
    (base / 'process_exit.json').write_text(json.dumps({'gw_sh_exit': proc.returncode}) + '\n')
    assert proc.returncode == 0, f'Gowin failed: see {base}/flow.log'
    console = (base / 'flow.log').read_text(errors='replace')
    assert not re.search(r'\bERROR\b|invalid command name|syntax error', console), \
        f'Gowin Tcl/tool error: see {base}/flow.log'
    assert re.search(r'^PNR_DONE\s*$', console, re.M), f'P&R did not finish: see {base}/flow.log'
    print('Real Gowin command completed; reports still require independent review:', base)


if __name__ == '__main__':
    main()
