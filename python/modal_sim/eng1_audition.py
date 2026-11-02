#!/usr/bin/env python3
"""Six ENG1 timbres: a brief four-bar Mystery of Love guitar-score excerpt.

B instruments use current eng1_rtl. Piano/guitar are explicitly experimental
ABC patches, NOT the production eng0 path. No deployment files are changed.
"""
from __future__ import annotations
from pathlib import Path
from concurrent.futures import ProcessPoolExecutor, as_completed
import argparse, hashlib, json, math, sys, time
import numpy as np
import soundfile as sf
from scipy.signal import lfilter
import eng1_rtl as E
import router_eng1 as R

ROOT=Path(__file__).resolve().parents[2]
SCORE_URL='https://rockfactory.us/nick/Sufjan%20Stevens%20-%20Mystery%20Of%20Love.pdf'
BPM=100
LEAD=0.12
TAIL=1.4
# Only bars 5--8; the initial four silent bars are omitted. Standard tuning.
# Rhythmic cells: eighth, sixteenth, eighth, sixteenth, sixteenth, sixteenth.
BAR_NOTES=[([64,72,76,72,64,72]*2),([66,69,74,69,66,69]*2),
           ([64,67,76,67,64,67]*2),([66,69,74,69,66,69]*2)]
DURATIONS=[.5,.25,.5,.25,.25,.25]*2
VELOCITIES=[100,77,91,79,85,78]*2
NOTES=tuple(range(64,80))


def score():
    events=[]
    for bar,keys in enumerate(BAR_NOTES):
        beat=0.0
        for key,duration,velocity in zip(keys,DURATIONS,VELOCITIES):
            events.append(dict(time=LEAD+(4*bar+beat)*60/BPM,midi=key,
                               duration=duration*.94*60/BPM,velocity=velocity))
            beat+=duration
        assert beat==4
    return events


class Strike:
    """Literal current excitation_gen strike branch, at accepted clk_en edges."""
    def __init__(self,instrument,slots=16):
        self.slots=slots
        self.output_shift=0
        self.rise,self.width,self.gap,self.pulses=(5,32,448,3) if instrument=='piano' else (1,2,0,0)
        self.state=np.zeros(slots,dtype=np.int8)
        self.acc=np.zeros(slots,dtype=np.int64);self.target=self.acc.copy()
        self.count=self.acc.copy();self.number=self.acc.copy();self.prev=np.zeros(slots,dtype=bool)

    def step(self,level,gate,trigger,clear):
        for s in range(self.slots):
            a=int(self.acc[s]);n=int(self.count[s])
            if clear[s]:
                self.state[s]=self.acc[s]=self.target[s]=self.count[s]=self.number[s]=0
            elif gate[s] and (trigger[s] or not self.prev[s]):
                self.state[s]=1;self.acc[s]=0;self.target[s]=int(level[s])<<16;self.count[s]=1;self.number[s]=1
            elif self.state[s]==0:
                self.acc[s]=self.count[s]=self.number[s]=0
            elif self.state[s]==1:
                self.acc[s]=R.wrap_signed(a+(int(self.target[s])>>self.rise),32)
                if n>=self.width:self.count[s]=0;self.state[s]=2
                else:self.count[s]=(n+1)&65535
            else:
                self.acc[s]=R.wrap_signed(a-((a>>6)+(a>>8)+(a>>10)),32)
                if not gate[s]:self.state[s]=0;self.number[s]=self.count[s]=0
                elif n>=self.gap:
                    self.count[s]=0
                    if self.pulses==7 or self.number[s]<=self.pulses:
                        self.number[s]+=1
                        t=int(self.target[s]);self.target[s]=t-(t>>2)-(t>>4)
                        self.acc[s]=0;self.state[s]=1
                    else:self.state[s]=0;self.acc[s]=0
                else:self.count[s]=(n+1)&65535
        self.prev[:]=gate
        return self.acc.copy() >> self.output_shift


def experimental_table(instrument,midi):
    index=json.loads((ROOT/f'FFT_results/params/{instrument}_coeffindex.json').read_text())
    keys=[(int(k.split('|')[0]),k.split('|')[1]) for k in index]
    source,dyn=min(keys,key=lambda k:(abs(k[0]-midi),k[1]!='forte',k[0]))
    old=R.load_a_table(instrument,source,dyn)
    radius=np.sqrt(old.a2.astype(float)/(1<<24))
    theta=np.arccos(np.clip(-old.a1/(1<<24)/np.maximum(2*radius,1e-20),-1,1))
    target_theta=theta*2**((midi-source)/12)
    valid=(target_theta>0)&(target_theta<math.pi)
    radius,theta,target_theta=radius[valid],theta[valid],target_theta[valid]
    old_g=old.G[valid].astype(float)/(1<<24)
    aa1=R.quant(-2*radius*np.cos(target_theta),24,26)
    aa2=old.a2[valid]
    # Frozen A gains were calibrated for a seven-sample raised-cosine pulse.
    # Recalibrate offline to the actual RTL strike burst, preserving each
    # source mode's peak amplitude rather than changing global timbre by guess.
    old_x=np.zeros(4096);old_x[:7]=.5-.5*np.cos(2*np.pi*np.arange(7)/7)
    strike=Strike(instrument,1);new_x=np.empty(4096)
    for n in range(4096):
        new_x[n]=strike.step([255],[True],[n==0],[False])[0]/float(255<<16)
    gains=[]
    for r,t,g,a1,a2 in zip(radius,theta,old_g,aa1,aa2):
        previous=lfilter([1.],[1.,-2*r*math.cos(t),r*r],old_x)
        current=lfilter([1.],[1.,a1/(1<<24),a2/(1<<24)],new_x)
        gains.append(g*np.max(np.abs(previous))/max(np.max(np.abs(current)),1e-15))
    raw=np.floor(np.array(gains)*(1<<24)+.5)
    if np.any((raw<-(1<<25))|(raw>=(1<<25))):raise ValueError('experimental G coefficient overflow')
    table=R.Eng1Coeffs(raw.astype(np.int64),aa1,aa2,len(gains),label=f'{instrument}:{source}->{midi}:strike_recalibrated')
    return table,dict(midi=midi,source_midi=source,source_dynamic=dyn,retuned=source!=midi,
                      modes=table.n_modes,discarded_nyquist_modes=int(np.count_nonzero(~valid)),
                      gain_calibration='legacy raised-cosine modal peak -> actual RTL strike burst')


class ExperimentalA:
    """Current ABC kernel/current strike+body, an explicitly experimental route."""
    def __init__(self,instrument):
        self.instrument=instrument;self.slots=16
        self.core=R.Eng1Core(slots=16,n_modes=64)
        self.rows=[]
        for key in sorted({e['midi'] for e in score()}):
            table,row=experimental_table(instrument,key)
            self.core.load_slot(NOTES.index(key),table);self.rows.append(row)
        self.strike=Strike(instrument)
        self.env=E.Envelope([16777216]*16,[1048576]*16)
        self.gate=np.zeros(16,dtype=bool);self.level=np.zeros(16,dtype=np.int64)
        self.trigger=np.zeros(16,dtype=bool);self.prev_gate=self.gate.copy()
        self.previous_dead=np.ones(16,dtype=bool);self.pending_dead=np.zeros(16,dtype=bool)
        self.body=R.BodyFilter(instrument=instrument);self.reverb=E.Reverb('NONE')
        self.spatial=E.Spatializer();self.rail_hits=0

    def note_on(self,midi,velocity):
        s=NOTES.index(midi);self.gate[s]=True;self.level[s]=(velocity<<1)|(velocity>>6);self.trigger[s]=True

    def note_off(self,midi):self.gate[NOTES.index(midi)]=False

    def step(self):
        gate=self.gate;trigger=self.trigger
        x=self.strike.step(self.level,gate,trigger,np.zeros(16,dtype=bool))
        if self.instrument=='piano':
            old=self.env.level.copy()
            # Current piano uses S=0x20000000 and the old-level emap latency.
            self.env.step(gate,trigger,np.zeros(16,dtype=bool))
            sus=self.env.state==self.env.SUSTAIN
            self.env.level[sus]=0x20000000
            emap=np.where(trigger,0,old)
            dead=self.env.dead.copy()
        else:
            # Current env_router's guitar dyn branch is commented out: MIDI
            # guitar has the constant envelope while gated, not velocity twice.
            emap=np.where(gate,0x7fffffff,0);dead=~gate
        zero=trigger|(gate&~self.prev_gate)|self.pending_dead
        y,_=self.core.step(x,zero,active_modes=48)
        mix=R.wrap_signed(sum((int(y[s])*int(emap[s]))>>31 for s in range(16)),64)
        body,_,_=self.body.step(mix);out=self.reverb.step(body)
        left,right=self.spatial.step(out,pan=16,itd=False)
        pcm=(E.pcm16(left,3,18),E.pcm16(right,3,18))
        self.rail_hits+=int(np.count_nonzero((self.core.y1==R.Y_MAX)|(self.core.y1==R.Y_MIN)))
        self.pending_dead=dead&~self.previous_dead;self.previous_dead=dead.copy();self.prev_gate=gate.copy()
        self.trigger[:]=False
        return out,pcm


def render(instrument,out_dir,resource_dir):
    started=time.time();out_dir=Path(out_dir);out_dir.mkdir(parents=True,exist_ok=True)
    events=score();n=round((LEAD+16*60/BPM+TAIL)*48000)
    ons={};offs={}
    for e in events:
        ons.setdefault(round(e['time']*48000),[]).append(e)
        offs.setdefault(round((e['time']+e['duration'])*48000),[]).append(e['midi'])
    if instrument in ['piano','guitar']:
        synth=ExperimentalA(instrument)
        resource_rows=synth.rows;route='experimental_ABC_A_current_strike_current_body_48_modes'
    else:
        bank=E.ResourceBank.from_directory(resource_dir,instrument) if resource_dir else E.ResourceBank.build(instrument,NOTES)
        synth=E.Eng1Synth(instrument,note_map=NOTES,resources=bank,reverb='NONE')
        if resource_dir:
            profiles=json.loads((Path(resource_dir)/'manifest.json').read_text())['entries']
        else:
            profiles=json.loads((ROOT/'rtl/router/tools/sustain_profiles.json').read_text())['entries']
        resource_rows=[e for e in profiles if e['name']==instrument and e['midi'] in {v['midi'] for v in events}]
        route='current_production_ENG1_B_64_storage_48_active'
    raw=np.empty(n,dtype=np.int64);pcm=np.empty((n,2),dtype=np.int16);rail=0
    for i in range(n):
        for midi in offs.get(i,[]):
            synth.note_off(midi if instrument in ['piano','guitar'] else NOTES.index(midi))
        for e in ons.get(i,[]):synth.note_on(e['midi'],e['velocity'])
        if instrument in ['piano','guitar']:raw[i],pcm[i]=synth.step()
        else:
            f=synth.step();raw[i]=f.out;pcm[i]=f.pcm
            rail+=int(np.count_nonzero((synth.core.y1==R.Y_MAX)|(synth.core.y1==R.Y_MIN)))
    # Listening copy: gain only BEFORE PCM quantization. Native PCM16 remains
    # unmodified in native/. All six use the exact same score and headroom.
    wide=raw.astype(float)/(1<<24)*(2896/4096)/8
    peak=float(np.max(np.abs(wide)));rms=float(np.sqrt(np.mean(wide**2)))
    if not np.isfinite(wide).all() or peak<=0:raise ValueError('silent/nonfinite render')
    active=wide[round(LEAD*48000):round((LEAD+9.6)*48000)]
    active_rms=float(np.sqrt(np.mean(active**2)))
    gain=min(10**(-20/20)/max(active_rms,1e-15),10**(-1/20)/peak)
    listen=wide*gain
    # A short terminal fade is only a file-boundary edit on the listening copy.
    fade=round(.02*48000);listen[-fade:]*=np.linspace(1,0,fade)
    stereo=np.repeat(listen[:,None],2,axis=1)
    native=out_dir/'native';native.mkdir(exist_ok=True)
    name=f'mystery_of_love_{instrument}_eng1.wav'
    sf.write(out_dir/name,stereo,48000,subtype='PCM_24')
    sf.write(native/name,pcm,48000,subtype='PCM_16')
    data,fs=sf.read(out_dir/name,always_2d=True)
    assert data.shape==(n,2) and fs==48000 and np.isfinite(data).all() and np.max(np.abs(data))<1
    result=dict(instrument=instrument,path=name,native_path='native/'+name,route=route,
                frames=n,seconds=n/48000,note_events=len(events),sample_rate=48000,
                native_peak=peak,native_rms=rms,native_pcm_rail_samples=int(np.count_nonzero((pcm==32767)|(pcm==-32768))),
                feedback_state_rail_hits=synth.rail_hits if instrument in ['piano','guitar'] else rail,
                listening_gain_db=20*math.log10(gain),listening_peak_dbfs=20*math.log10(max(np.max(np.abs(data)),1e-15)),
                listening_rms_dbfs=20*math.log10(max(np.sqrt(np.mean(data**2)),1e-15)),
                terminal_fade_ms=20,normalization='constant RMS-target gain limited to -1dBFS peak; no compressor',
                resources=resource_rows,sha256=hashlib.sha256((out_dir/name).read_bytes()).hexdigest(),render_seconds=time.time()-started)
    (out_dir/f'{instrument}.json').write_text(json.dumps(result,indent=2)+'\n')
    print(f'PASS {instrument}: {n/48000:.2f}s, listening gain {result["listening_gain_db"]:+.2f}dB, native rails {result["native_pcm_rail_samples"]}, state rails {result["feedback_state_rail_hits"]}',flush=True)
    return result


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,default=ROOT/'FFT_results/sim/eng1/mystery_of_love')
    ap.add_argument('--resources',type=Path)
    ap.add_argument('--instrument',action='append',choices=['piano','guitar','trumpet','violin','cello','flute'])
    ap.add_argument('--workers',type=int,default=6)
    args=ap.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
    instruments=args.instrument or ['piano','guitar','trumpet','violin','cello','flute']
    with ProcessPoolExecutor(max_workers=min(args.workers,len(instruments))) as pool:
        futures=[pool.submit(render,i,out,args.resources) for i in instruments]
        results=[f.result() for f in as_completed(futures)]
    results.sort(key=lambda r:instruments.index(r['instrument']))
    manifest=dict(title='Mystery of Love — brief instrumental excerpt',composer='Sufjan Stevens',
                  score_source=SCORE_URL,score_measures='5–8 only; initial four rest bars omitted',tempo_bpm=BPM,
                  score_seconds=9.6,total_seconds=LEAD+9.6+TAIL,lead_seconds=LEAD,tail_seconds=TAIL,
                  midi_range=[64,76],headroom_bits=3,reverb='NONE',pan=16,itd=False,
                  renderer_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  model_source_hashes={name:hashlib.sha256((Path(__file__).parent/name).read_bytes()).hexdigest()
                                       for name in ['eng1_rtl.py','router_eng1.py','body_fixed_point.py']},
                  score_sha256=hashlib.sha256(json.dumps(score(),sort_keys=True).encode()).hexdigest(),renders=results)
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2,ensure_ascii=False)+'\n')
    (out/'excerpt_events.json').write_text(json.dumps(score(),indent=2)+'\n')
    text='''# Mystery of Love — ENG1 六音色短摘录

参考谱面：'''+SCORE_URL+''' 。只取第5–8小节（正文9.6秒，100BPM）；省略开头四小节休止。
所有音色使用同一组48个事件、原谱音区E4..E5，前静音0.12秒、尾音1.4秒，文件11.12秒。

- 根目录：便于听辨的PCM24试听版。只调恒定增益以接近-20dBFS RMS、峰值不超过-1dBFS，没有压缩器；文件末端20ms淡出。
- native/：实际headroom=3、中心声像的PCM16定标版，不做增益调整/归一化/尾部淡出。
- 四种B类：当前Q24生产ENG1模型，64条存储/48模态计算，零变调、NONE混响。
- 钢琴/吉他：实验性ABC路径，**不是当前板端eng0结果**。使用已有A类模态参数，缺失音高从邻近表重定音；G离线按当前RTL锤击激励重标定。
  激励/包络/腔体参考当前RTL；实验ABC使用48模态。当前guitar MIDI包络是gate期间常数，松键会关门控，不冒称旧dyn0。
  逐音符来源、重定音和电平在各音色JSON/manifest中记录。没有生成或修改部署Flash镜像。

| 音色 | 试听增益dB | 试听峰值dBFS | 原始PCM触轨样本 | 模态触轨计数 |
|---|---:|---:|---:|---:|
'''
    for r in results:text+=f'| {r["instrument"]} | {r["listening_gain_db"]:+.2f} | {r["listening_peak_dbfs"]:.2f} | {r["native_pcm_rail_samples"]} | {r["feedback_state_rail_hits"]} |\n'
    text+='\n试听与原始定标版：\n\n'
    for r in results:
        text+=f'- {r["instrument"]}: [试听]({out/r["path"]}) / [原始PCM16]({out/r["native_path"]})\n'
    text+='\n复跑：`python python/modal_sim/eng1_audition.py`（numpy/scipy/soundfile环境）。这是一小段试听摘录，没有重新发布整首乐谱或整曲音频。\n'
    (out/'README.md').write_text(text)
    print('Wrote',out,flush=True)
if __name__=='__main__':main()
