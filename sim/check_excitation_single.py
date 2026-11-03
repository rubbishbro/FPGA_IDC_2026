#!/usr/bin/env python3
"""Run generated single-strike excitation vectors through actual RTL."""
from pathlib import Path
import os,re,shutil,subprocess,json,sys
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'build/excitation_single_check'
def main():
 model_python=Path.home()/'micromamba/envs/torch312/bin/python'
 subprocess.run([str(model_python) if model_python.is_file() else sys.executable,str(ROOT/'sim/prepare_excitation_single.py')],cwd=ROOT,check=True)
 ini=Path(os.environ.get('QSIM_INI',str(Path.home()/'gowin/simlib_questa/modelsim.ini')));work=OUT/'work';(OUT/'modelsim.ini').write_text(re.sub(r'^work\s*=.*$',f'work = {work}',ini.read_text(),flags=re.M));env=os.environ.copy();env['QSIM_INI']=env['MODELSIM']=str(OUT/'modelsim.ini')
 def run(name,tool,args):
  r=subprocess.run([shutil.which(tool) or str(Path.home()/'.local/bin'/tool),*map(str,args)],cwd=OUT,env=env,capture_output=True,text=True,timeout=90);text=r.stdout+r.stderr;(OUT/(name+'.log')).write_text(text)
  if r.returncode or re.search(r'\*\* (?:Error|Fatal)|\bFAIL\b',text):raise RuntimeError(text[-3500:])
  return text
 run('vlib','vlib',[work]);run('compile','vlog',['-sv','-work',work,ROOT/'rtl/router/parts/excitation.sv',OUT/'tb.sv']);text=run('run','vsim',['-c','-lib',work,'tb_excitation_single','-do','run -all; quit -f']);assert 'PASS tb_excitation_single samples=1536' in text
 (OUT/'results.json').write_text(json.dumps(dict(passed=True,samples=1536,pulse_widths=[1,2,8,32])));print('PASS actual excitation_gen matches model:1536 samples,1/2/8/32 pulse widths,4 forces,retrigger,clear')
if __name__=='__main__':main()
