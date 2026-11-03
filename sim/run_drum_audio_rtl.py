#!/usr/bin/env python3
"""Render all six drums through unmodified ENG1 and check every raw output sample."""
from pathlib import Path
import json,os,re,shutil,subprocess
import numpy as np
import soundfile as sf
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'build/drum_full_compare'
TB=r'''`timescale 1ns/1ps
module tb_drum_audio;
 import modal_step_pkg::*;
 logic clk=0,rst_n=0,start=0,st_zero=0;
 always #5 clk=~clk;
 logic[6:0] n_modes=52;
 logic co_re,st_re,st_we,x_re,y_valid;
 logic[5:0] co_addr,st_addr,st_waddr;
 coeff_t co_data,co[64];
 logic signed[31:0] st_q,st_qdot,st_q_wdata,st_qdot_wdata,x_data=0;
 logic signed[63:0] y_data;
 logic[31:0] q[64],v[64],words[2688];
 logic[63:0] expected[864000];
 integer fd,idx=0,cycles,maximum=0;
 eng1 dut(.*);
 always @(posedge clk)begin
  if(co_re)co_data<=co[co_addr];
  if(st_re)begin st_q<=q[st_addr];st_qdot<=v[st_addr];end
  if(st_we)begin q[st_waddr]<=st_q_wdata;v[st_waddr]<=st_qdot_wdata;end
 end
 initial begin
  $readmemh("coefficients.mem",words);$readmemh("expected.mem",expected);
  fd=$fopen("rtl_raw.txt","w");
  for(int drum=0;drum<6;drum++)begin
   rst_n=0;repeat(3)@(negedge clk);
   for(int m=0;m<64;m++)begin
    co[m]={words[drum*448+m*7],words[drum*448+m*7+1],words[drum*448+m*7+2],words[drum*448+m*7+3],words[drum*448+m*7+4],words[drum*448+m*7+5],words[drum*448+m*7+6]};
    q[m]=0;v[m]=0;
   end
   rst_n=1;repeat(3)@(negedge clk);
   for(int sample=0;sample<144000;sample++)begin
    x_data=sample==0 ? 32'sd13421773 : 32'sd0;
    start=1;@(negedge clk);start=0;cycles=0;
    while(!y_valid && cycles<300)begin @(negedge clk);cycles++;end
    if(!y_valid || y_data!==expected[idx])$fatal(1,"FAIL sample drum=%0d n=%0d got=%0d expected=%0d",drum,sample,y_data,$signed(expected[idx]));
    $fwrite(fd,"%0d\n",y_data);idx++;if(cycles>maximum)maximum=cycles;
    @(negedge clk);
   end
   $display("PASS drum %0d samples=144000",drum);
  end
  $fclose(fd);$display("PASS tb_drum_audio samples=%0d max_cycles=%0d",idx,maximum);$finish;
 end
 initial begin #(64'd5000000000);$fatal(1,"FAIL audio render watchdog");end
endmodule
'''
def main():
 report=json.loads((OUT/'report.json').read_text());work=OUT/'work'
 ini=Path(os.environ.get('QSIM_INI',str(Path.home()/'gowin/simlib_questa/modelsim.ini')))
 (OUT/'modelsim.ini').write_text(re.sub(r'^work\s*=.*$',f'work = {work}',ini.read_text(),flags=re.M))
 env=os.environ.copy();env['QSIM_INI']=env['MODELSIM']=str(OUT/'modelsim.ini')
 def run(name,tool,args):
  exe=shutil.which(tool) or str(Path.home()/'.local/bin'/tool)
  r=subprocess.run([exe,*map(str,args)],cwd=OUT,env=env,capture_output=True,text=True,timeout=1200)
  text=r.stdout+r.stderr;(OUT/(name+'.log')).write_text(text)
  if r.returncode or re.search(r'\*\* (?:Error|Fatal)|\bFAIL\b',text):raise RuntimeError(text[-4000:])
  return text
 (OUT/'tb_drum_audio.sv').write_text(TB);run('vlib','vlib',[work])
 run('compile','vlog',['-sv','-work',work,ROOT/'rtl/math/pkg/fxp_pkg.sv',ROOT/'rtl/router/pkg/modal_step_pkg.sv',ROOT/'rtl/router/engines/eng1.sv',OUT/'tb_drum_audio.sv'])
 text=run('rtl','vsim',['-c','-lib',work,'tb_drum_audio','-do','run -all; quit -f'])
 assert 'PASS tb_drum_audio samples=864000' in text
 raw=np.loadtxt(OUT/'rtl_raw.txt',dtype=np.int64);assert len(raw)==864000
 fade=np.ones(144000);fade[-2400:]=np.linspace(1,0,2400)**2
 audio=[]
 for i,row in enumerate(report['drums']):audio.extend([raw[i*144000:(i+1)*144000]/(1<<24)*row['reference_balance']*fade,np.zeros(48000)])
 y=np.concatenate(audio)*report['shared_listening_gain'];assert max(abs(y))<1
 sf.write(OUT/'rtl_synthesis.wav',y,48000,subtype='PCM_24')
 preview,sr=sf.read(OUT/'rtl_model_preview.wav');assert np.array_equal(preview,sf.read(OUT/'rtl_synthesis.wav')[0])
 report['rtl_verified']=dict(passed=True,samples=864000,summary=[s.lstrip('# ') for s in text.splitlines() if 'PASS ' in s],actual_rtl_audio='rtl_synthesis.wav',pcm24_matches_model=True)
 (OUT/'report.json').write_text(json.dumps(report,indent=2));print('\n'.join(report['rtl_verified']['summary']))
if __name__=='__main__':main()
