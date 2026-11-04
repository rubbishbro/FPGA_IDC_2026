"""Accepted drum coefficient method: impulse ABC plus fitted LP/LFSR noise.

48 modal slots + two 2-slot noise branches, Q24 core/filter/envelope, Q16 noise
 gain. This freezes the auditioned method; it does not enable the drum bank,
write calibrated gains or add the pending board-level drum lifecycle.
"""
import math,zlib
import numpy as np
import router_eng1 as R
from eng1_bc import build_c_table
Q=1<<24
FS=48000
# Resource slot order, independent of historical audition playback order.
DRUM_GM_NOTES=(36,38,42,45,49,59)
DRUM_KEYS=("kick","snare","hat","tom","crash","ride")
DRUM_INDEX_BY_GM={note:i for i,note in enumerate(DRUM_GM_NOTES)}
# User-selected equal-peak excitation; shared audition/production convention.
DRUM_EXCITATION=dict(shift=16,rise_sh=3,pw_len=8,gap_len=0,n_pulse=0)

def build_coefficients(key,spec,fits):
 t=build_c_table(key,48);a1=t.coeffs.a1;a2=t.coeffs.a2
 s1=(t.seed_y1+32)>>6;s2=(t.seed_y2+32)>>6
 radius=np.sqrt(a2/Q);theta=np.arccos(np.clip(-a1/Q/(2*radius),-1,1))
 b=s1/Q;c=(b*np.cos(theta)-radius*s2/Q)/np.maximum(np.sin(theta),1e-12)
 amp=radius*np.sqrt(b*b+c*c)
 times=np.arange(t.length);dot=np.zeros(len(a1))
 for j in range(len(a1)):
  h=radius[j]**times*np.sin((times+1)*theta[j])/max(np.sin(theta[j]),1e-12)
  ref=radius[j]**(times+1)*(b[j]*np.cos((times+1)*theta[j])+c[j]*np.sin((times+1)*theta[j]))
  dot[j]=np.dot(h,ref)
 g=np.floor(amp*np.sin(theta)*Q+.5).astype(np.int64)*np.where(dot>=0,1,-1)
 table=R.Eng1Coeffs(g,a1,a2,t.coeffs.n_modes)
 co=np.zeros((64,7),dtype=np.int64);co[:len(g),:3]=np.column_stack([g,a1,a2])
 desc=[]
 assert spec['gamma_lf']==0 and spec['gamma_hf']==0
 for k,branch in enumerate(['tail','attack']):
  if branch=='attack' and not(spec['att_amp']>0 and spec['att_gamma']>0):continue
  fit=next(r['rtl_best'] for r in fits if r['drum']==key and r['branch']==branch)
  alpha=fit['alpha_q24'];gamma=max(spec['env_gamma'] if branch=='tail' else spec['att_gamma'],.5)
  gain=spec['noise_gain']*(1 if branch=='tail' else spec['att_amp'])*fit['fit_gain']
  row=[zlib.crc32((key+':'+branch).encode()) or 1,Q,round(math.exp(-gamma/FS)*Q),*alpha,round(gain*65536),0]
  assert 0<row[5]<(1<<31);co[48+2*k]=row;desc.append(dict(branch=branch,co=row))
 return table,co,desc

