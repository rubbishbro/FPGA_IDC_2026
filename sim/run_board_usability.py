#!/usr/bin/env python3
"""Focused production LCD/joystick/PCM checks, runnable without vendor tools."""
from pathlib import Path
import json
import os
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/board_usability'

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    iv = os.environ.get('IVERILOG') or shutil.which('iverilog')
    vvp = os.environ.get('VVP') or shutil.which('vvp')
    if not iv or not vvp:
        raise RuntimeError('Set IVERILOG/VVP or put Icarus Verilog on PATH')
    ui = (ROOT/'sim/ui_sources.f').read_text().splitlines()
    audio = ['rtl/audio/audio_async_fifo.sv', 'rtl/audio/i2s_amp_tx.sv',
             'rtl/audio/pt8211_tx.sv', 'rtl/audio/stereo_spatializer.sv',
             'rtl/audio/i2s_audio_output.sv']
    cases = [
        ('tb_board_inputs', ui+['sim/unit/board/tb_board_inputs.sv']),
        ('tb_board_lcd_timing', ['FFT_spectrumshow/src/display/lcd_timing.v', 'sim/unit/board/tb_board_inputs.sv']),
        ('tb_board_display_orientation', ui+['FFT_spectrumshow/src/display/lcd_timing.v', 'sim/unit/board/tb_board_display_orientation.sv']),
        ('tb_pcm_equivalence', audio+['sim/unit/audio/tb_pcm_equivalence.sv']),
        ('tb_polar_reverse_scan', ['FFT_spectrumshow/src/display/cordic_polar.sv',
             'FFT_spectrumshow/src/display/lcd_polar_curve.sv', 'sim/unit/board/tb_polar_reverse_scan.sv']),
    ]
    results = []
    for top, sources in cases:
        # Include UI packages for other modules in tb_board_inputs even when
        # selecting only its LCD timing top.
        if top == 'tb_board_lcd_timing':
            sources = ui + sources
        image = OUT/(top+'.vvp')
        compile_run = subprocess.run([iv,'-g2012','-Wall','-s',top,'-o',str(image),
            *[str(ROOT/p) for p in dict.fromkeys(sources)]],capture_output=True,text=True)
        (OUT/(top+'.compile.log')).write_text(compile_run.stdout+compile_run.stderr)
        if compile_run.returncode:
            raise RuntimeError((compile_run.stdout+compile_run.stderr)[-4000:])
        run = subprocess.run([vvp,str(image)],cwd=ROOT/'FFT_spectrumshow/board',
                             capture_output=True,text=True,timeout=90)
        output=run.stdout+run.stderr
        (OUT/(top+'.run.log')).write_text(output)
        passed=run.returncode==0 and 'PASS '+top in output and 'FATAL' not in output
        results.append(dict(test=top,passed=passed,summary=output.strip()))
        print(output.strip(),flush=True)
        (OUT/'results.json').write_text(json.dumps(results,indent=2)+'\n')
        if not passed:
            raise RuntimeError(top+' failed')
    print(f'PASS {len(results)} board usability cases')

if __name__ == '__main__':
    main()
