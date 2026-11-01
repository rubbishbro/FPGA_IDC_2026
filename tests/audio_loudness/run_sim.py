#!/usr/bin/env python3
"""Run isolated Questa wire-decoding and reference/production comparison."""
from pathlib import Path
import json, os, re, shutil, subprocess
ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / 'tests/audio_loudness'
OUT = ROOT / 'build/audio_loudness/sim'

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT/'results.json').unlink(missing_ok=True)
    ini = Path(os.environ.get('QSIM_INI', str(Path.home()/'gowin/simlib_questa/modelsim.ini')))
    work = OUT/'work'
    (OUT/'modelsim.ini').write_text(re.sub(r'^work\s*=.*$', 'work = '+str(work), ini.read_text(), flags=re.M))
    env = dict(os.environ, QSIM_INI=str(OUT/'modelsim.ini'), MODELSIM=str(OUT/'modelsim.ini'))
    def run(tool, args, name):
        exe = shutil.which(tool) or str(Path.home()/'.local/bin'/tool)
        proc = subprocess.run([exe, *map(str,args)], cwd=OUT, env=env, capture_output=True, text=True, timeout=180)
        output = proc.stdout+proc.stderr
        (OUT/(name+'.log')).write_text(output)
        if proc.returncode or re.search(r'\*\* (?:Error|Fatal)|\bFAIL\b|Trouble making server|Error:', output):
            raise RuntimeError(output[-6000:])
        return output
    run('vlib',[work],'vlib')
    sources = [SRC/p for p in ['reference_audio_tx.sv','tone_test_core.sv','test1_reference_top.sv','test2_project_top.sv','tb_audio_loudness.sv']]
    sources += [ROOT/'rtl/audio/i2s_amp_tx.sv', ROOT/'rtl/audio/pt8211_tx.sv']
    run('vlog',['-sv','-work',work,*sources],'compile')
    output = run('vsim',['-c','-lib',work,'tb_audio_loudness','-do','run -all; quit -f'],'simulation')
    summary = [s.lstrip('# ') for s in output.splitlines() if 'PASS tb_audio_loudness' in s]
    if not summary: raise RuntimeError('Missing PASS')
    (OUT/'results.json').write_text(json.dumps(dict(passed=True,summary=summary),indent=2)+'\n')
    print('\n'.join(summary))
if __name__ == '__main__': main()
