#!/usr/bin/env python3
"""Fit current FIR drum noise to Q24 single LP/two-LP RTL candidates; offline only."""
import sys,json,pathlib
import numpy as np
from scipy.signal import freqz
from scipy.optimize import least_squares
ROOT=pathlib.Path(__file__).resolve().parents[1];(ROOT/'build/drum_filter_fit').mkdir(parents=True,exist_ok=True);sys.path[:0]=[str(ROOT/'python_monotor/fft_analysis')]
import percussion as P
fs=48000;freq=np.r_[0.,np.geomspace(20,fs/2,240)];z=np.exp(-2j*np.pi*freq/fs);Q=1<<24
rows=[]
for key,spec in P.load_kit(str(ROOT/'python_monotor/results/params/drums.npz')).items():
 hs=P.noise_filters(spec,fs)
 for branch,h in [('tail',hs[0]),('attack',hs[2])]:
  if h is None:continue
  _,resp=freqz(h,worN=2*np.pi*freq/fs);t=abs(resp)
  def evaluate(v,pair,quant=False):
   f=np.exp(v)
   if pair:f=np.array([f[0],min(f[0]*f[1],fs*2)])
   aa=1-np.exp(-2*np.pi*f/fs)
   if quant:aa=np.rint(aa*Q)/Q
   if pair:aa.sort()
   hh=aa[:,None]/(1-(1-aa[:,None])*z)
   mag=abs(hh[1]-hh[0]) if pair else abs(hh[0])
   scale=np.dot(t,mag)/max(np.dot(mag,mag),1e-30)
   return scale*mag-t,scale,aa
  variants={}
  for pair in [False,True]:
   best=None
   starts=([60],[300],[2000],[12000]) if not pair else ([.2,100],[30,100],[100,1000],[500,8000],[10000,20000],[3000,5000])
   for start in starts:
    initial=np.log([start[0],start[1]/start[0]]) if pair else np.log(start)
    bounds=(np.log([.2,1.01]),np.log([fs*2,fs*10])) if pair else (np.log(.2),np.log(fs*2))
    r=least_squares(lambda v:evaluate(v,pair)[0],initial,bounds=bounds,max_nfev=300)
    e,g,a=evaluate(r.x,pair,True);loss=float(np.linalg.norm(e)/np.linalg.norm(t))
    item=dict(relative_magnitude_error_pct=100*loss,alpha_q24=np.rint(a*Q).astype(int).tolist(),equivalent_fc_hz=(-fs*np.log(1-a)/(2*np.pi)).tolist(),fit_gain=g)
    if best is None or loss<best[0]:best=(loss,item)
   variants['two_lp_difference' if pair else 'single_lp']=best[1]
  single=variants['single_lp'];pair=variants['two_lp_difference']
  if single['relative_magnitude_error_pct']<=pair['relative_magnitude_error_pct']:
   variants['rtl_best']=dict(single,alpha_q24=[0,single['alpha_q24'][0]],structure='single lowpass; low state initialized zero')
  else:variants['rtl_best']=dict(pair,structure='two lowpass difference')
  row=dict(drum=key,branch=branch,**variants);rows.append(row)
  print(key,branch,'single',round(variants['single_lp']['equivalent_fc_hz'][0]),round(variants['single_lp']['relative_magnitude_error_pct'],1),'pair',*[round(x) for x in variants['two_lp_difference']['equivalent_fc_hz']],round(variants['two_lp_difference']['relative_magnitude_error_pct'],1),flush=True)
(ROOT/'build/drum_filter_fit/results.json').write_text(json.dumps(dict(fs=fs,metric='relative L2 magnitude error on DC + 240 log frequencies 20Hz..Nyquist, optimal positive scalar gain; quantized Q24 alpha',rows=rows),indent=2))
