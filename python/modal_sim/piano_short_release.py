#!/usr/bin/env python3
"""User-selected short strike + clear biquad, comparing 256/512ms release."""
from pathlib import Path
from concurrent.futures import ProcessPoolExecutor
import json,math,hashlib
import numpy as np
import soundfile as sf
import piano_body_release as B

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'FFT_results/sim/eng1/piano_short_release'

def trace(key):
 B.RELEASES={'r256':43691,'r512':21845}
 return B.excitation_trace(key,short_strike=True,output=OUT)

def main():
 OUT.mkdir(parents=True,exist_ok=True)
 rows=B.clear_body()
 with ProcessPoolExecutor(max_workers=2) as p:releases=list(p.map(trace,['r256','r512']))
 waves={}
 for rel in releases:
  d=np.load(OUT/(rel['key']+'_source.npz'))
  for scene in ['phrase','single']:
   y=B.filter_signal(d[scene],rows)
   np.save(OUT/f'clear_short_{rel["key"]}_{scene}.npy',y)
   waves[rel['key'],scene]=y
 # One shared listening gain for both release lengths and both scenes.
 scale=(2896/4096)/8/(1<<24)
 base=waves['r256','phrase'][5760:466560].astype(float)*scale
 gain=.075/max(float(np.sqrt(np.mean(base**2))),1e-20)
 peak=max(float(np.max(np.abs(y.astype(float)*scale*gain))) for y in waves.values())
 gain*=min(1,10**(-1/20)/max(peak,1e-20))
 files=[];native=OUT/'native';native.mkdir(exist_ok=True)
 for (rel,scene),y in waves.items():
  mono=y.astype(float)*scale*gain;mono[-960:]*=np.linspace(1,0,960)
  name=f'clear_short_{rel}_{scene}.wav'
  sf.write(OUT/name,np.repeat(mono[:,None],2,axis=1),48000,subtype='PCM_24')
  pcm=np.array([B.A.E.pcm16(int(v)*2896*64,3,18) for v in y],dtype=np.int16)
  assert not np.any((pcm==32767)|(pcm==-32768))
  sf.write(native/name,np.repeat(pcm[:,None],2,axis=1),48000,subtype='PCM_16')
  a,fs=sf.read(OUT/name,always_2d=True)
  assert fs==48000 and a.shape==(len(y),2) and np.isfinite(a).all() and abs(a).max()<.9
  files.append(dict(release=rel,scene=scene,file=name,seconds=len(y)/48000,
                    gain_db=20*math.log10(gain),peak_dbfs=20*math.log10(max(abs(a).max(),1e-20)),
                    native_rail_samples=0,sha256=hashlib.sha256((OUT/name).read_bytes()).hexdigest()))
 # Release must have no effect before note-off, including body history.
 assert np.array_equal(waves['r256','single'][:17760],waves['r512','single'][:17760])
 original=json.loads((ROOT/'FFT_results/sim/eng1/piano_body_release/results.json').read_text())
 assert rows==original['body_coefficients_q27']['clear']
 result=dict(baseline='short strike 2-sample rise + clear biquad; not previous 32-sample strike',
             strike=dict(rise_sh=1,pw_len=2,gap_len=478,n_pulse=3),attack_step=16777216,
             body_coefficients_q27=rows,releases=releases,files=files,
             identical_single_before_noteoff=True,biquad_matches_previous_clear=True,
             modal_coefficients_unchanged=True,production_rtl_modified=False,
             gain_policy='one constant gain for all four files; no per-release normalization',
             source_hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in
                            [Path(__file__),ROOT/'python/modal_sim/piano_body_release.py',ROOT/'python/modal_sim/eng1_audition.py']})
 (OUT/'results.json').write_text(json.dumps(result,indent=2)+'\n')
 text='''# 短击锤＋新biquad：256/512ms release（2026-10-31）

本轮按用户指定共同基线：击锤上升2采样（RISE_SH=1、PW=2、GAP=478）、4次锤击；
新biquad为此前同一组40Hz高通＋2kHz/+3dB高架。保持原attack=16777216（约2.67ms）和同一模态G/a1/a2。
原来的32采样长击锤不再作为本轮基线。均为eng1实验钢琴、NONE混响，未修改生产RTL或默认参数。

| release | R_STEP | sustain电平松键实测 | 演奏片段 | C5单音 |
|---|---:|---:|---|---|
'''
 for r in releases:
  key=r['key'];text+=f'| {key} | {r["r_step"]} | {r["measured_single_release_ms"]:.3f}ms | [播放]({OUT/("clear_short_"+key+"_phrase.wav")}) | [播放]({OUT/("clear_short_"+key+"_single.wav")}) |\n'
 text+='''
四份试听统一一个恒定增益，保留尾音差异。48kHz/PCM24立体声，片段11.12秒，单音2秒（0.12秒起音、0.37秒松键）。
末端20ms文件边界淡出；native/另存实际定标PCM16，没有试听增益。
包络release时间仍取决于松键电平，256/512ms是1/4 sustain电平对应值。
同音重触发仍会清旧模态，因此512ms不保证每个乐句音符都比256ms多出完整尾音，单音便于听清差异。

验证：两档单音松键前的body后Q24输出逐点相同；biquad系数与上一轮clear完全相同；模态无触轨、body无饱和、原始PCM与试听均无削波。
参数、文件hash和源hash见results.json。复跑：`python python/modal_sim/piano_short_release.py`。
'''
 (OUT/'README.md').write_text(text)
 print('PASS',releases,files,flush=True)
if __name__=='__main__':main()
