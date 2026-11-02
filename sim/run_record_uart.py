#!/usr/bin/env python3
"""Full production board recording at real UART baud, then web/MIDI decoding.

Requires Verilator 5.048 (or a compatible version), a C++ toolchain and Node.
Only PLL, ADC and Flash use the existing board simulation models.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, default=ROOT / 'build/record_uart')
    ap.add_argument('--baud', type=int, default=115200)
    args = ap.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    compiler = os.environ.get('VERILATOR') or shutil.which('verilator')
    if not compiler:
        raise RuntimeError('verilator not found; set VERILATOR')
    manifest = ROOT / 'rtl/platform/tang_mega_138k_pro/sources.f'
    sources = [ROOT / x for x in manifest.read_text().splitlines()
               if '/ip/' not in x and x != 'rtl/drivers/gowin_adc/gowin_adc.v']
    sources += [ROOT / x for x in [
        'sim/unit/board/board_ip_models.sv', 'sim/unit/midi/w25q64_read_model.sv',
        'sim/unit/audio/tb_i2s_audio_output.sv', 'sim/unit/audio/tb_pt8211_output.sv',
        'sim/unit/board/tb_instrument_board.sv']]
    memories = list((ROOT / 'rtl_FFT/board').glob('*.mem'))
    for p in memories:
        shutil.copyfile(p, out / p.name)
    tables = out / 'rtl/drivers/pad_led_tables'
    tables.mkdir(parents=True, exist_ok=True)
    for p in (ROOT / 'rtl/drivers/pad_led_tables').glob('*.mem'):
        memories.append(p)
        shutil.copyfile(p, tables / p.name)
    resource = ROOT / 'rtl/router/tools/performance/resources.mem'
    memories.append(resource)
    shutil.copyfile(resource, out / 'performance_resources.mem')
    files = sources + memories + [manifest]
    hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    (out / 'sources.f').write_text(''.join(str(p) + '\n' for p in sources))
    image = out / 'record_board'
    commands = [
        [compiler, '--binary', '--timing', '-Wno-fatal', '-j', '2',
         '--top-module', 'tb_instrument_board', '-GRECORD_TEST=1',
         f'-GUART_BAUD={args.baud}', '--Mdir', str(out / 'obj'), '-o', str(image),
         '-f', str(out / 'sources.f')],
        [str(image)],
        ['node', str(ROOT / 'web/midi-editor/tests/check-rtl-take.mjs'),
         str(out / 'recording_uart.hex'), str(out / 'recorded.mid')],
    ]
    result = dict(passed=False, baud=args.baud, commands=commands, source_sha256=hashes,
                  scope='RTL board PLL/ADC/Flash models; no physical board validation')
    # Remove stale status before a failed build can be mistaken for a fresh pass.
    (out / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    for name, command in zip(['compile', 'record', 'web_decode'], commands):
        run = subprocess.run(command, cwd=out, capture_output=True, text=True, timeout=180)
        output = run.stdout + run.stderr
        (out / f'{name}.log').write_text(output)
        failed = run.returncode != 0 or '%Error' in output
        if name != 'compile':
            failed = failed or re.search(r'\b(?:FAIL|FATAL)\b|readmem file not found', output) or 'PASS' not in output
        if failed:
            print(output[-5000:])
            return 1
        print(f'PASS {name}', flush=True)
    result['sources_unchanged'] = all(hashlib.sha256(p.read_bytes()).hexdigest() ==
                                      hashes[str(p.relative_to(ROOT))] for p in files)
    result['passed'] = result['sources_unchanged']
    (out / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
