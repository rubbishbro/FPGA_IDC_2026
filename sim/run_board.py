#!/usr/bin/env python3
"""Questa unified board: real UART/UI/PAD/router/I2S; only PLL, ADC, Flash are models."""
from pathlib import Path
import argparse,os,re,json,shutil,subprocess
ROOT=Path(__file__).resolve().parents[1]
BOARD=ROOT/'rtl/platform/tang_mega_138k_pro'
def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,default=ROOT/'build/board_sim')
    ap.add_argument('--test',action='append',choices=['inputs','lcd','system','clocks','polyphony','audio','pcm','numeric','led','led_effects','led_protocol','stereo_sweep','guide','pt8211','visualizer','polar','polar_render','record','keymap'])
    args=ap.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
    (out/'results.json').unlink(missing_ok=True)
    ini=Path(os.environ.get('QSIM_INI') or str(Path.home()/'gowin/simlib_questa/modelsim.ini'))
    work=out/'work';txt=re.sub(r'^work\s*=.*$','work = '+str(work),ini.read_text(),flags=re.M)
    (out/'modelsim.ini').write_text(txt);env=os.environ.copy();env['QSIM_INI']=str(out/'modelsim.ini');env['MODELSIM']=env['QSIM_INI']
    for src,name in [('rtl_FFT/board/sidebar_font.mem','sidebar_font.mem'),('rtl_FFT/board/sidebar_labels.mem','sidebar_labels.mem'),('rtl/router/tools/performance/resources.mem','performance_resources.mem')]:shutil.copyfile(ROOT/src,out/name)
    for memory in (ROOT / "rtl_FFT/board").glob("*.mem"):
        shutil.copyfile(memory, out / memory.name)
    led_tables=out/'rtl/drivers/pad_led_tables';led_tables.mkdir(parents=True,exist_ok=True)
    for memory in (ROOT/'rtl/drivers/pad_led_tables').glob('*.mem'):
        shutil.copyfile(memory,led_tables/memory.name)
    def run(tool,opts,name):
        cmd=[shutil.which(tool) or str(Path.home()/'.local/bin'/tool),*map(str,opts)]
        p=subprocess.run(cmd,cwd=out,env=env,capture_output=True,text=True,timeout=1200)
        text=p.stdout+p.stderr;(out/(name+'.log')).write_text(text)
        if p.returncode or re.search(r'\*\* (?:Error|Fatal)|\b(?:FAIL|FATAL)\b',text):raise RuntimeError(name+'\n'+text[-7000:])
        return text
    run('vlib',[work],'vlib')
    src=[]
    for f in (BOARD/'sources.f').read_text().splitlines():
        if f.startswith(str(BOARD.relative_to(ROOT))+'/ip/') or f in ['rtl_FFT/board/gowin_pll.v','rtl/drivers/gowin_adc/gowin_adc.v']:continue
        src.append(ROOT/f)
    src += [ROOT/f for f in ['sim/unit/board/board_ip_models.sv','sim/unit/midi/w25q64_read_model.sv',
        'sim/unit/audio/tb_i2s_audio_output.sv','sim/unit/audio/tb_pcm_equivalence.sv','sim/unit/board/tb_board_inputs.sv','sim/unit/board/tb_clock_contracts.sv','sim/unit/board/tb_polyphonic_audio.sv','sim/unit/board/tb_numeric_contracts.sv','sim/unit/board/tb_led_prefetch.sv','sim/unit/audio/tb_i2s_stereo.sv','sim/unit/audio/tb_pt8211_output.sv','sim/unit/board/tb_board_visualizer.sv']]
    if (ROOT/'sim/unit/board/tb_instrument_board.sv').exists():src.append(ROOT/'sim/unit/board/tb_instrument_board.sv')
    src.append(ROOT/'sim/unit/board/tb_stereo_board_sweep.sv')
    src.append(ROOT/'sim/unit/board/tb_pad_led_effects.sv')
    src.append(ROOT/'sim/unit/board/tb_led_protocol.sv')
    run('vlog',['-sv','-work',work,*src],'compile')
    tops={'inputs':'tb_board_inputs','lcd':'tb_board_lcd_timing','system':'tb_instrument_board','clocks':'tb_clock_contracts','polyphony':'tb_polyphonic_audio','audio':'tb_i2s_audio_output','pcm':'tb_pcm_equivalence','numeric':'tb_numeric_contracts','led':'tb_led_prefetch','stereo_sweep':'tb_stereo_board_sweep','guide':'tb_instrument_board','pt8211':'tb_pt8211_output','visualizer':'tb_board_visualizer','polar':'tb_polar_contracts','polar_render':'tb_polar_page','record':'tb_instrument_board','keymap':'tb_instrument_board'};results=[]
    tops['led_effects']='tb_pad_led_effects'
    tops['led_protocol']='tb_led_protocol'
    for name in args.test or tops:
        top=tops[name];text=run('vsim',['-c','-lib',work,top,*(['-gGUIDE_TEST=1'] if name=='guide' else ['-gRECORD_TEST=1'] if name=='record' else ['-gKEYMAP_TEST=1'] if name=='keymap' else []),'-wlf',out/(name+'.wlf'),'-do','run -all; quit -f'],name)
        summary=[s.lstrip('# ') for s in text.splitlines() if 'PASS '+top in s]
        if not summary:raise RuntimeError(name+' missing PASS')
        print('\n'.join(summary),flush=True);results.append(dict(test=top,passed=True,summary=summary))
    (out/'results.json').write_text(json.dumps(results,indent=2)+'\n')
if __name__=='__main__':main()
