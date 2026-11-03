#!/usr/bin/env python3
"""Actual production image through GM config/MIDI/router plus ADSR retirement."""
from pathlib import Path
import sys,os,re,shutil,subprocess,json
ROOT=Path(__file__).resolve().parents[1]
def main():
 out=ROOT/'build/drum_production';out.mkdir(parents=True,exist_ok=True);work=out/'work'
 ini=Path.home()/'gowin/simlib_questa/modelsim.ini'
 (out/'modelsim.ini').write_text(re.sub(r'^work\s*=.*$',f'work = {work}',ini.read_text(),flags=re.M));env=os.environ.copy();env['QSIM_INI']=env['MODELSIM']=str(out/'modelsim.ini')
 def run(name,tool,args):
  r=subprocess.run([shutil.which(tool) or str(Path.home()/'.local/bin'/tool),*map(str,args)],cwd=out,env=env,capture_output=True,text=True,timeout=900);text=r.stdout+r.stderr;(out/(name+'.log')).write_text(text)
  if r.returncode or re.search(r'\*\* (?:Error|Fatal)|\bFAIL\b',text):raise RuntimeError(text[-4000:])
  return text
 sources=[ROOT/s.strip("'") for s in (ROOT/'sim/router_sources.list').read_text().splitlines() if s.startswith("'") and '/tb/' not in s]
 sources += [ROOT/p for p in ['rtl/midi/midi_note_state.sv','rtl/midi/midi_guide_state.sv','rtl/midi/midi_instrument_map.sv','rtl/router/midi_voice_top.sv','sim/unit/midi/w25q64_read_model.sv','sim/unit/audio/tb_plucked_release.sv','sim/unit/midi/tb_production_drums_midi.sv']]
 run('vlib','vlib',[work]);run('compile','vlog',['-sv','-work',work,*sources]);shutil.copyfile(ROOT/'rtl/router/tools/performance/resources.mem',out/'resources.mem')
 results={}
 for top in ['tb_plucked_release','tb_production_drums_midi']:
  text=run(top,'vsim',['-c','-lib',work,top,'-do','run -all; quit -f']);assert 'PASS '+top in text
  results[top]=[s.lstrip('# ') for s in text.splitlines() if 'PASS ' in s];print('\n'.join(results[top]),flush=True)
 (out/'results.json').write_text(json.dumps(dict(passed=True,tests=results),indent=2))
if __name__=='__main__':main()
