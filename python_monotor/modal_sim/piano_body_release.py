#!/usr/bin/env python3
"""Crossed piano body/release audition; uses experimental ENG1, no RTL changes."""
from pathlib import Path
from concurrent.futures import ProcessPoolExecutor
import json,math,os,hashlib
import numpy as np
import soundfile as sf
from scipy.signal import butter,sosfreqz
import eng1_audition as A
import router_eng1 as R

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'python_monotor/results/sim/eng1/piano_body_release'
RELEASES={'r11':1048576,'r128':87381,'r256':43691}

def clear_body():
 # RBJ high shelf, +3 dB at 2kHz, slope=1; second section is 40Hz HP.
 amp=10**(3/40);w=2*math.pi*2000/48000;c=math.cos(w);s=math.sin(w)
 alpha=s/2*math.sqrt(2);root=2*math.sqrt(amp)*alpha
 b=[amp*((amp+1)+(amp-1)*c+root),-2*amp*((amp-1)+(amp+1)*c),amp*((amp+1)+(amp-1)*c-root)]
 a=[(amp+1)-(amp-1)*c+root,2*((amp-1)-(amp+1)*c),(amp+1)-(amp-1)*c-root]
 shelf=np.array([*b,*a])/a[0]
 sos=np.vstack([butter(2,40,fs=48000,btype='highpass',output='sos'),shelf])
 rows=[[round(float(v)*(1<<27)) for v in [*r[:3],*r[4:]]] for r in sos]
 rows += [[1<<27,0,0,0,0]]*(5-len(rows))
 R.BodyFilter(coeffs=rows) # quantized stability validation
 return rows

class Capture:
 def __init__(self):self.value=0
 def step(self,x):self.value=int(x);return x,0,0

def excitation_trace(key,short_strike=False,output=None):
 step=RELEASES[key];s=A.ExperimentalA('piano');s.env.release[:]=step;s.body=Capture()
 if short_strike:s.strike.rise,s.strike.width,s.strike.gap=1,2,478
 # Default preserves the original strike; explicit short_strike selects the
 # prior 2-sample/478-gap candidate without changing attack or modal gains.
 events=A.score();n=533760;on={};off={}
 for e in events:
  on.setdefault(round(e['time']*48000),[]).append(e)
  off.setdefault(round((e['time']+e['duration'])*48000),[]).append(e['midi'])
 y=np.empty(n,dtype=np.int64)
 for i in range(n):
  for m in off.get(i,[]):s.note_off(m)
  for e in on.get(i,[]):s.note_on(e['midi'],e['velocity'])
  s.step();y[i]=s.body.value
 assert s.rail_hits==0
 # Isolated C5: hold long enough to reach sustain; noteoff at 0.37s.
 s=A.ExperimentalA('piano');s.env.release[:]=step;s.body=Capture();single=np.empty(96000,dtype=np.int64)
 if short_strike:s.strike.rise,s.strike.width,s.strike.gap=1,2,478
 noteoff=17760;zero_at=None;level_at_off=None
 for i in range(len(single)):
  if i==5760:s.note_on(72,100)
  if i==noteoff:level_at_off=int(s.env.level[8]);s.note_off(72)
  s.step();single[i]=s.body.value
  if i>=noteoff and zero_at is None and s.env.level[8]==0:zero_at=i
 assert zero_at is not None and s.rail_hits==0
 np.savez_compressed((OUT if output is None else Path(output))/(key+'_source.npz'),phrase=y,single=single)
 print('SOURCE',key,'release_ms',(zero_at-noteoff+1)/48,flush=True)
 return dict(key=key,r_step=step,nominal_sustain_release_ms=math.ceil(0x20000000/step)/48,
             measured_single_release_ms=(zero_at-noteoff+1)/48,level_at_noteoff=level_at_off)

def filter_signal(data,rows):
 body=R.BodyFilter(coeffs=rows);y=np.empty(len(data),dtype=np.int64)
 for i,x in enumerate(data):y[i]=body.step(int(x))[0]
 assert body.sat_total==0
 return y

def main():
 OUT.mkdir(parents=True,exist_ok=True)
 original=R.body_coeffs('piano');bright=clear_body();flat=R.body_coeffs('none')
 bodies={'original':original,'clear':bright,'flat':flat}
 with ProcessPoolExecutor(max_workers=3) as pool:releases=list(pool.map(excitation_trace,RELEASES))
 outputs=[]
 for rel in releases:
  d=np.load(OUT/(rel['key']+'_source.npz'))
  for b,rows in bodies.items():
   for scene in ['phrase','single']:
    y=d[scene] if b=='flat' else filter_signal(d[scene],rows)
    np.save(OUT/f'{b}_{rel["key"]}_{scene}.npy',y)
    outputs.append(dict(body=b,release=rel['key'],scene=scene,y=y))
 # Same onset calibration across release choices: each body's baseline gain is
 # held for all release variants. Do not normalize away the longer tail.
 gains={}
 for b in bodies:
  baseline=next(v['y'] for v in outputs if v['body']==b and v['release']=='r11' and v['scene']=='phrase')
  gains[b]=.075/max(np.sqrt(np.mean((baseline[5760:466560].astype(float)/(1<<24)*(2896/4096)/8)**2)),1e-20)
 peak=max(float(np.max(np.abs(v['y'].astype(float)/(1<<24)*(2896/4096)/8*gains[v['body']]))) for v in outputs)
 global_scale=min(1,10**(-1/20)/max(peak,1e-20))
 metrics=[]
 for v in outputs:
  name=f'{v["body"]}_{v["release"]}_{v["scene"]}'
  z=v.pop('y').astype(float)/(1<<24)*(2896/4096)/8*gains[v['body']]*global_scale
  fade=960;z[-fade:]*=np.linspace(1,0,fade)
  sf.write(OUT/(name+'.wav'),np.repeat(z[:,None],2,axis=1),48000,subtype='PCM_24')
  a,fs=sf.read(OUT/(name+'.wav'),always_2d=True)
  assert fs==48000 and len(a)==len(z) and np.isfinite(a).all() and abs(a).max()<.9
  metrics.append(dict(**v,file=name+'.wav',seconds=len(z)/48000,gain_db=20*math.log10(gains[v['body']]*global_scale),
                      peak_dbfs=20*math.log10(max(abs(a).max(),1e-20)),
                      sha256=hashlib.sha256((OUT/(name+'.wav')).read_bytes()).hexdigest()))
 probes=np.array([100,330,1000,2000,3000,4000,8000,12000]);responses={}
 for b,rows in bodies.items():
  sos=np.array([[*np.array(r[:3])/(1<<27),1.,*np.array(r[3:])/(1<<27)] for r in rows])
  _,h=sosfreqz(sos,worN=probes,fs=48000);responses[b]=[dict(hz=int(f),db=float(20*np.log10(max(abs(v),1e-20)))) for f,v in zip(probes,h)]
 summary=dict(releases=releases,body_coefficients_q27=bodies,responses=responses,files=metrics,
              gain_policy='same gain for all release settings of each body, calibrated from baseline phrase RMS; common peak safety scaling',
              original_strike_unchanged=True,original_attack_unchanged=True,modal_coefficients_unchanged=True,production_rtl_modified=False)
 (OUT/'results.json').write_text(json.dumps(summary,indent=2)+'\n')
 text='''# 钢琴biquad与release交叉试听（2026-10-31）

这是eng1实验钢琴，保持原击锤32采样上升、原attack、原模态G/a1/a2不变。没有修改生产RTL。
三组腔体：original=当前三段；clear=40Hz二阶高通＋2kHz/+3dB高架，余下三段直通；flat=旁路。
clear使用signed32 Q4.27量化，已验证极点稳定；它是候选听测滤波器，不是实测钢琴腔体拟合。

release通过R_STEP改变，原档约10.7ms，另两档从1/4 sustain释放约128/256ms。
不同noteoff电平会改变实际release时长，不能当固定时间包络。同音重触发仍会清旧历史，因此并非每个音尾都能自由延续。
延长release不改变模态本身的gamma/a2，只延后输出包络归零和历史清理；更长自然衰减另需改模态阻尼。

每组腔体先按原release正文RMS定增益，再将同一增益用于全部release档；因此保留尾音差异，没有每份单独归一化。
所有文件48kHz/PCM24立体声、NONE混响。phrase是同一9.6秒摘录加首尾11.12秒；single是C5单音，0.12秒起音、0.37秒松键，总长2秒。
文件末20ms淡出仅避免终点截断；单音release结束远早于此。

| 腔体 | 原release | 128ms | 256ms |
|---|---|---|---|
'''
 for b in bodies:
  text+=f'| {b} | [片段]({OUT/(b+"_r11_phrase.wav")}) / [单音]({OUT/(b+"_r11_single.wav")}) | [片段]({OUT/(b+"_r128_phrase.wav")}) / [单音]({OUT/(b+"_r128_single.wav")}) | [片段]({OUT/(b+"_r256_phrase.wav")}) / [单音]({OUT/(b+"_r256_single.wav")}) |\n'
 text+='\n建议先比较original_r11与clear_r11（只换腔体），再比较clear的三档release。flat组用来判断候选biquad是否仍过度着色。参数和校验见results.json。\n'
 (OUT/'README.md').write_text(text)
 print('PASS',len(metrics),'files validated',OUT,flush=True)
if __name__=='__main__':main()
